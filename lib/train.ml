open Base
module LA = Arrayjit.Lazy_array
module NTDSL = Operation.NTDSL
module Asgns = Arrayjit.Assignments
module Idx = Arrayjit.Indexing

module type Backend_type = Arrayjit.Backends.Backend

module Debug_runtime = Arrayjit.Utils.Debug_runtime

let debug_rt = (module Debug_runtime : Minidebug_runtime.Debug_runtime)

(** Reinitializes a backend selected via a global [backend] flag. *)
let fresh_backend ?backend_name () =
  let open Arrayjit.Backends in
  let backend =
    match
      Option.value_or_thunk backend_name ~default:(fun () ->
          Arrayjit.Utils.get_global_arg ~arg_name:"backend" ~default:"gccjit")
      |> String.lowercase
    with
    | "gccjit" -> (module Gccjit_backend : Backend)
    | "cuda" -> (module Cuda_backend : Backend)
    | "dummy" -> (module Dummy_backend : Backend)
    | backend -> invalid_arg [%string "Train.fresh_backend: unknown backend %{backend}"]
  in
  reinitialize backend;
  backend

let literal_heuristic (a : LA.t) =
  try
    ignore (Float.of_string (List.hd_exn a.label) : float);
    true
  with _ -> false

let is_param t =
  match t with { Tensor.children = []; diff = Some _; _ } -> not @@ literal_heuristic t.value | _ -> false

let get_params t =
  let rec loop accu { Tensor.subtensor = t; _ } =
    List.fold t.children ~init:(if is_param t then Set.add accu t else accu) ~f:loop
  in
  loop (Set.empty (module Tensor)) { subtensor = t; embedded = true }

let set_on_host (a : LA.t) =
  if LA.is_true a.virtual_ then
    raise
    @@ Arrayjit.Ndarray.User_error
         [%string "Train.set_on_host: array #%{a.id#Int} %{LA.label a} is already virtual"];
  if Option.is_none a.virtual_ then a.virtual_ <- Some (false, 27);
  if LA.is_true a.device_only then
    raise
    @@ Arrayjit.Ndarray.User_error
         [%string "Train.set_on_host: array #%{a.id#Int} %{LA.label a} is already device-only"];
  a.device_only <- Some (false, 28)

let set_non_local_prefer_device_only (a : LA.t) =
  if LA.is_true a.virtual_ then
    raise
    @@ Arrayjit.Ndarray.User_error
         [%string "Train.set_non_local: array #%{a.id#Int} %{LA.label a} is already virtual"];
  if Option.is_none a.virtual_ then a.virtual_ <- Some (false, 29);
  if LA.isnt_true a.device_only && LA.isnt_true !(a.hosted) then
    if LA.is_false a.device_only && LA.is_false !(a.hosted) then
      raise
      @@ Arrayjit.Ndarray.User_error
           [%string "Train.set_non_local: array #%{a.id#Int} %{LA.label a} is already local"]
    else if Option.is_none a.device_only && LA.isnt_true !(a.hosted) then (
      a.device_only <- Some (true, 30);
      if Option.is_none !(a.hosted) then a.hosted := Some (false, 3))

(** Sets the tensor's value as "fully on host",
    returns the tensor's forward code with a label-derived comment. *)
let forward t =
  set_on_host t.Tensor.value;
  let label = Option.value ~default:"tensor" @@ List.last t.Tensor.value.label in
  Asgns.Block_comment (label ^ " fwd", t.forward)

let label_suffix label = Option.value ~default:"unknown" @@ List.last label

type updaten = {
  tensor : Tensor.t;
  label : string;
  params : (Tensor.t, Tensor.comparator_witness) Base.Set.t;
  fwd_bprop : Asgns.t;
}

(** Sets the tensor's value as "fully on host", returns the tensor's forward, zeroing gradients, and
    backprop code wrapped with label-derived comments, sets the parameters and their gradients
    as "non-local" (on-device), returns the update and the parameters. *)
let grad_update l =
  let params = get_params l in
  let label = label_suffix l.value.label in
  let fwd_bprop =
    match l.Tensor.diff with
    | Some diff ->
        let%cd init_grad = l.grad =: 1 in
        Asgns.(
          Block_comment
            ( label ^ " gradient update",
              sequential
                [
                  Block_comment (label ^ " fwd", l.forward);
                  Block_comment (label ^ " zero grads", diff.zero_grads);
                  init_grad;
                  Block_comment (label ^ " bprop", diff.backprop);
                ] ))
    | None -> raise @@ Tensor.Session_error ("Train.backprop: tensor is not differentiable", Some l)
  in
  { tensor = l; label; params; fwd_bprop }

(** See: {!https://github.com/tinygrad/tinygrad/blob/master/tinygrad/nn/optim.py}. *)
let sgd_one ~learning_rate ?(momentum = 0.0) ?(weight_decay = 0.0) ?(nesterov = false) p =
  if not @@ is_param p then raise @@ Tensor.Session_error ("Train.sgd_one: not a parameter", Some p);
  let pg = NTDSL.term ~label:("sgd_delta" :: p.value.label) () in
  let b = NTDSL.term ~label:("sgd_momentum" :: p.value.label) () in
  Asgns.Block_comment
    ( label_suffix p.value.label ^ " param sgd step",
      [%cd
        pg =: p.grad + (!.weight_decay *. p);
        if Float.(momentum > 0.0) then (
          b =: (!.momentum *. b) + pg;
          if nesterov then pg =+ !.momentum *. b else pg =: b);
        p =- learning_rate *. pg] )

let sgd_update ~learning_rate ?momentum ?weight_decay ?nesterov l =
  let code =
    l.params |> Set.to_list
    |> List.map ~f:(sgd_one ~learning_rate ?momentum ?weight_decay ?nesterov)
    |> Asgns.sequential
  in
  Asgns.Block_comment (l.label ^ " sgd update", code)

(** All and only bindings with associated ranges are iterated, with the binding's initial value lost.
    Bindings without ranges remain at their initial values. *)
let sequential_loop ~f jitted_bindings =
  let rec loop = function
    | [] -> f ()
    | ({ Idx.static_range = None; static_symbol = _ }, _) :: more -> loop more
    | ({ Idx.static_range = Some range; static_symbol = _ }, idx) :: more ->
        let old_idx = !idx in
        for i = 0 to range - 1 do
          idx := i;
          loop more
        done;
        idx := old_idx
  in
  loop jitted_bindings

(** Distributes iterated indices to workers in a round-robin fashion. All and only bindings with
    associated ranges are iterated, with the binding's initial value lost.
    Bindings without ranges remain at their initial values. [sync] is called after each round of calling
    all workers, and at the end if needed, with the number of workers called during the round. *)
let%track_sexp round_robin fs parallel_jitbs jitbs ~sync : unit =
  let num_devices : int = Array.length fs in
  assert (Array.length parallel_jitbs = num_devices);
  let pos = ref 0 in
  let rec loop = function
    | [] ->
        fs.(!pos % num_devices) ();
        Int.incr pos;
        if !pos % num_devices = 0 then sync num_devices
    | ({ Idx.static_range = None; static_symbol = _ }, _) :: more -> loop more
    | (({ Idx.static_range = Some range; static_symbol = _ } as s), idx)
      :: ({ Idx.static_range = None; static_symbol = _ }, _)
      :: more
    | (({ Idx.static_range = Some range; static_symbol = _ } as s), idx) :: more ->
        for i = 0 to range - 1 do
          idx := i;
          if List.is_empty more then Idx.find_exn parallel_jitbs.(!pos % num_devices) s := i
          else Array.iter parallel_jitbs ~f:(fun jb -> Idx.find_exn jb s := i);
          loop more
        done
  in
  loop jitbs;
  if !pos % num_devices <> 0 then sync (!pos % num_devices)

let set_virtual (a : LA.t) =
  if LA.is_false a.virtual_ then
    raise
    @@ Arrayjit.Ndarray.User_error
         [%string "Train.set_virtual: array #%{a.id#Int} %{LA.label a} is already non-virtual"];
  if Option.is_none a.virtual_ then a.virtual_ <- Some (true, 29)

let every_non_literal_on_host =
  Tensor.iter_embedded_arrays ~f:(fun a -> if not @@ literal_heuristic a then set_on_host a)

let%debug_sexp all_host_to_device (type context) (module Backend : Backend_type with type context = context)
    context =
  Tensor.iter_embedded_arrays ~f:(fun a ->
      let b = Backend.from_host context a in
      if b then
        [%log
          "copied",
            LA.label a,
            LA.name a,
            "from host to device",
            (Backend.get_ctx_device context |> Backend.to_ordinal : int)])

let%debug_sexp all_device_to_host (type context) (module Backend : Backend_type with type context = context)
    context =
  Tensor.iter_embedded_arrays ~f:(fun a ->
      let b = Backend.to_host context a in
      if b then
        [%log
          "copied",
            LA.label a,
            LA.name a,
            "from device",
            (Backend.get_ctx_device context |> Backend.to_ordinal : int),
            "to host"])

(** Executes the jitted code and copies arrays embedded in the given tenosor from and to host,
    synchronizes before copying to host. If [looping] is provided, loops over bindings and executes
    the given function inside the loop after a run. All and only bindings with associated ranges
    are iterated, with the binding's initial value lost. Bindings without ranges remain at their
    initial values. *)
let sync_run ?looping (type context) (module Backend : Backend_type with type context = context)
    (jitted : Backend.jitted) t =
  all_host_to_device (module Backend) jitted.context t;
  (match looping with
  | None -> jitted.run debug_rt ()
  | Some then_ ->
      let f () =
        jitted.run debug_rt ();
        then_ ()
      in
      sequential_loop ~f jitted.bindings);
  Backend.await @@ Backend.get_ctx_device jitted.context;
  all_device_to_host (module Backend) jitted.context t

(** Performs one optimization step, potentially in parallel (if [grad_updates] are compiled for different
    devices). All jitted code must have the same bindings. Iterates over bindings with ranges, calling
    one of [grad_updates] in a round-robin fashion, and performs the following synchronization each time
    all [grad_updates] have been called: merges all gradients into the device of [grad_updates.(0)],
    calls [sgd_update], and copies all parameters from the [grad_updates.(0)] device to the other devices.

    All and only bindings with associated ranges are iterated, with the binding's initial value lost.
    Bindings without ranges remain at their initial values. *)
let%track_sexp parallel_update (type context) (module Backend : Backend_type with type context = context)
    ~(grad_updates : Backend.jitted array) ~(sgd_update : Backend.jitted) ~post_sync updaten : unit =
  set_on_host updaten.tensor.Tensor.value;
  Set.iter updaten.params ~f:(fun p -> set_non_local_prefer_device_only (Option.value_exn p.diff).grad);
  assert (not @@ Array.is_empty grad_updates);
  let num_devices : int = Array.length grad_updates in
  let bindings : Idx.static_symbol list = List.map ~f:fst sgd_update.bindings in
  [%debug_notrace
    assert (
      Array.for_all grad_updates ~f:(fun upd ->
          [%equal: Idx.static_symbol list] bindings @@ List.map ~f:fst upd.bindings))];
  let all_params : Tensor.t list = Set.to_list updaten.params in
  let param_vals = [%debug_notrace List.map all_params ~f:(fun t -> t.value)] in
  let param_grads =
    [%debug_notrace List.filter_map all_params ~f:(fun t -> Option.map t.diff ~f:(fun d -> d.grad))]
  in
  let ctxs = [%debug_notrace Array.map grad_updates ~f:(fun upd -> upd.context)] in
  (* Note: [from] indices are bigger than [to_] indices. We end up at 0. *)
  let merges : Backend.jitted list array array =
    if num_devices < 2 then [| [||] |]
    else
      Array.init (num_devices - 1) ~f:(fun (to_ : int) ->
          Array.init
            (num_devices - to_ - 1)
            ~f:(fun (delta_m_1 : int) ->
              let from : int = to_ + delta_m_1 + 1 in
              List.filter_map param_grads ~f:(fun p ->
                  Backend.merge ~name_suffix:"grad_merge" p ~dst:ctxs.(to_) ~accum:Arrayjit.Ops.Add
                    ~src:ctxs.(from))))
  in
  let merge ~(from : int) ~(to_ : int) : unit =
    (* FIXME: is this parallel? *)
    let delta_m_1 : int = from - to_ - 1 in
    List.iter merges.(to_).(delta_m_1) ~f:(fun jitted -> jitted.run debug_rt ())
  in
  let copies : Backend.jitted list array =
    if num_devices < 2 then [||]
    else
      Array.init (num_devices - 1) ~f:(fun from_m_1 ->
          let from : int = from_m_1 + 1 in
          List.filter_map param_vals ~f:(fun p ->
              Backend.merge ~name_suffix:"param_copy" p ~dst:ctxs.(0) ~accum:Arrayjit.Ops.Arg2
                ~src:ctxs.(from)))
  in
  (* let copy ~from ~to_ = List.iter copies.(to_).(from - to_ - 1) ~f:(fun jitted -> jitted.run ()) in *)
  let sync (devices_to_sync : int) : unit =
    Arrayjit.Utils.parallel_merge merge devices_to_sync;
    sgd_update.run debug_rt ();
    for from = 1 to devices_to_sync - 1 do
      List.iter copies.(from - 1) ~f:(fun jitted -> jitted.run debug_rt ())
    done;
    post_sync ()
  in
  let jitted_bindings = [%debug_notrace Array.map grad_updates ~f:(fun upd -> upd.bindings)] in
  (* FIXME: is this parallel? *)
  let fs = [%debug_notrace Array.map grad_updates ~f:(fun upd -> upd.run debug_rt)] in
  round_robin fs jitted_bindings sgd_update.bindings ~sync
