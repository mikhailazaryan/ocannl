open Base
module Tn = Arrayjit.Tnode
module NTDSL = Operation.NTDSL
module Asgns = Arrayjit.Assignments
module Idx = Arrayjit.Indexing
module Utils = Arrayjit.Utils

module type Backend_type = Arrayjit.Backends.Backend

module Debug_runtime = Arrayjit.Utils.Debug_runtime

[%%global_debug_log_level_from_env_var "OCANNL_LOG_LEVEL"]

let debug_rt = (module Debug_runtime : Minidebug_runtime.Debug_runtime)
let run jitted = Tn.run debug_rt @@ jitted.Arrayjit.Backends.schedule ()

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
    | backend -> invalid_arg [%string "Train.fresh_backend: unknown backend %{backend}"]
  in
  reinitialize backend;
  backend

let is_param t =
  match t with { Tensor.children = []; diff = Some _; _ } -> not @@ Tn.known_not_param t.value | _ -> false

let get_params t =
  let rec loop accu { Tensor.subtensor = t; _ } =
    List.fold t.children ~init:(if is_param t then Set.add accu t else accu) ~f:loop
  in
  loop (Set.empty (module Tensor)) { subtensor = t; embedded = true }

let set_on_host memtype (a : Tn.t) = Tn.update_memory_mode a (Hosted memtype) 27
let set_materialized (a : Tn.t) = Tn.update_memory_mode a Materialized 28
let set_hosted (a : Tn.t) = Tn.update_memory_mode a (Hosted Changed_on_devices) 41

(** Sets the tensor's value as "fully on host",
    returns the tensor's forward code with a label-derived comment. *)
let forward t =
  set_on_host Changed_on_devices t.Tensor.value;
  let label = Option.value ~default:"tensor" @@ List.last t.Tensor.value.label in
  Asgns.Block_comment (label ^ " fwd", t.forward)

let label_suffix label = Option.value ~default:"unknown" @@ List.last label

type updaten = {
  loss : Tensor.t;
  label : string;
  params : (Tensor.t, Tensor.comparator_witness) Base.Set.t;
  fwd_bprop : Asgns.t;
}

(** Returns the tensor's forward, zeroing gradients, and backprop code wrapped with label-derived comments.
    Sets the tensor's value as "fully on host". If [setup_for_parallel] is true (false by default),
    sets the parameters and their gradients as "non-local" (on-device). *)
let grad_update ?(setup_for_parallel = false) loss =
  set_on_host Changed_on_devices loss.Tensor.value;
  let params = get_params loss in
  if setup_for_parallel then Set.iter params ~f:(fun p -> set_materialized (Option.value_exn p.diff).grad);
  let label = label_suffix loss.value.label in
  let fwd_bprop =
    match loss.Tensor.diff with
    | Some diff ->
        let%cd init_grad = loss.grad =: 1 in
        Asgns.(
          Block_comment
            ( label ^ " gradient update",
              sequential
                [
                  Block_comment (label ^ " fwd", loss.forward);
                  Block_comment (label ^ " zero grads", diff.zero_grads);
                  init_grad;
                  Block_comment (label ^ " bprop", diff.backprop);
                ] ))
    | None -> raise @@ Tensor.Session_error ("Train.backprop: tensor is not differentiable", Some loss)
  in
  { loss; label; params; fwd_bprop }

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

let%track_sexp round_robin_dry_run ~num_devices jitbs ~dry_sync : unit =
  let pos = ref 0 in
  let rec loop = function
    | [] ->
        Int.incr pos;
        if !pos % num_devices = 0 then dry_sync num_devices
    | ({ Idx.static_range = None; static_symbol = _ }, _) :: more -> loop more
    | ({ Idx.static_range = Some range; static_symbol = _ }, idx)
      :: ({ Idx.static_range = None; static_symbol = _ }, _)
      :: more
    | ({ Idx.static_range = Some range; static_symbol = _ }, idx) :: more ->
        for i = 0 to range - 1 do
          idx := i;
          loop more
        done
  in
  loop jitbs;
  if !pos % num_devices <> 0 then dry_sync (!pos % num_devices)

let set_virtual (a : Tn.t) = Tn.update_memory_mode a Virtual 29

let every_non_literal_on_host =
  Tensor.iter_embedded_arrays ~f:(fun a ->
      if Tn.mode_is_unspecified a && not (Tn.known_constant a) then set_hosted a)

let%debug_sexp all_host_to_device (type context) (module Backend : Backend_type with type context = context)
    context =
  Tensor.iter_embedded_arrays ~f:(fun a ->
      let b = Backend.from_host context a in
      if b then
        [%log
          "copied",
            Tn.label a,
            Tn.name a,
            "from host to device",
            (Backend.get_ctx_device context |> Backend.to_ordinal : int)])

let%debug_sexp all_device_to_host (type context) (module Backend : Backend_type with type context = context)
    context =
  Tensor.iter_embedded_arrays ~f:(fun a ->
      let b = Backend.to_host context a in
      if b then
        [%log
          "copied",
            Tn.label a,
            Tn.name a,
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
  let work = jitted.schedule () in
  all_host_to_device (module Backend) jitted.context t;
  (match looping with
  | None -> Tn.run debug_rt work
  | Some then_ ->
      let f () =
        Tn.run debug_rt work;
        then_ ()
      in
      sequential_loop ~f jitted.bindings);
  Backend.await @@ Backend.get_ctx_device jitted.context;
  all_device_to_host (module Backend) jitted.context t

module Lazy = Utils.Lazy

let collapse_merges merges =
  Hashtbl.data merges
  |> List.map ~f:(Array.map ~f:Option.to_list)
  |> List.reduce_exn ~f:(Array.map2_exn ~f:( @ ))

(** Performs one optimization step, potentially in parallel (if [grad_updates] are compiled for different
    devices). All jitted code must have the same bindings. Iterates over bindings with ranges, calling
    one of [grad_updates] in a round-robin fashion, and performs the following synchronization each time
    all [grad_updates] have been called:

    1. merges all gradients into the device of [grad_updates.(0)],
    2. calls [sgd_update],
    3. copies all parameters from the [grad_updates.(0)] device to the other devices, if needed,
    4. calls [post_sync] with the number of devices synced since the previous sync.

    All and only bindings with associated ranges are iterated, with the binding's initial value lost.
    Bindings without ranges remain at their initial values. *)
let%track_sexp parallel_update (type context) (module Backend : Backend_type with type context = context)
    ~(grad_updates : Backend.jitted array) ~(sgd_update : Backend.jitted) ~post_sync updaten : unit -> unit =
  assert (not @@ Array.is_empty grad_updates);
  let num_devices : int = Array.length grad_updates in
  let bindings : Idx.static_symbol list = List.map ~f:fst sgd_update.bindings in
  let occupancies = Array.init num_devices ~f:(fun _ -> Array.create ~len:num_devices false) in
  (* to_, from positions correspond to the contexts (and devices) of grad_updates at the position. *)
  let dry_merge ~from ~to_ = occupancies.(from).(to_) <- true in
  let dry_sync devices_to_sync = Arrayjit.Utils.parallel_merge dry_merge devices_to_sync in
  round_robin_dry_run ~num_devices sgd_update.bindings ~dry_sync;
  [%debug_notrace
    assert (
      Array.for_all grad_updates ~f:(fun upd ->
          [%equal: Idx.static_symbol list] bindings @@ List.map ~f:fst upd.bindings))];
  let all_params : Tensor.t list = Set.to_list updaten.params in
  let param_vals = [%debug_notrace List.map all_params ~f:(fun t -> t.value)] in
  let param_grads = [%debug_notrace List.map all_params ~f:(fun t -> (Option.value_exn t.diff).grad)] in
  let ctxs = [%debug_notrace Array.map grad_updates ~f:(fun upd -> upd.context)] in
  let occupancy _tn ~src_n ~src:_ =
    if Array.exists ~f:Fn.id occupancies.(src_n) then Utils.Required else Utils.Skip
  in
  let name_prefixes = Array.create ~len:num_devices "grad_merge" in
  let grad_merges =
    collapse_merges
    @@ Backend.merge_batch ~name_prefixes ~occupancy param_grads ~accum:Arrayjit.Ops.Add ~srcs:ctxs
  in
  let grad_merges =
    Array.init num_devices ~f:(fun (to_ : int) ->
        Array.init num_devices ~f:(fun (from : int) ->
            (* It is safe to cache scheduling, because merging does not use static indices. *)
            List.map grad_merges.(from) ~f:(fun c -> (Backend.jit ctxs.(to_) c).schedule ())))
  in
  (* We can cache scheduling, because merging and copying does not depend on static indexing. *)
  let name_prefixes = Array.create ~len:num_devices "loss_merge" in
  let loss_merges =
    collapse_merges
    @@ Backend.merge_batch ~name_prefixes ~occupancy [ updaten.loss.value ] ~accum:Arrayjit.Ops.Add ~srcs:ctxs
  in
  let loss_merges =
    Array.init num_devices ~f:(fun (to_ : int) ->
        Array.init num_devices ~f:(fun (from : int) ->
            (* It is safe to cache scheduling, because merging does not use static indices. *)
            match loss_merges.(from) with
            | [] -> None
            | [ c ] -> Some ((Backend.jit ctxs.(to_) c).schedule ())
            | _ -> assert false))
  in
  let merge ~(from : int) ~(to_ : int) : unit =
    Backend.(await @@ get_ctx_device ctxs.(from));
    Option.iter ~f:(Tn.run debug_rt) loss_merges.(to_).(from);
    List.iter ~f:(Tn.run debug_rt) grad_merges.(to_).(from)
  in
  let needed_on_host = ref @@ Set.empty (module Tn) in
  (* Backends may choose to not store parameters on devices other than the 0th. *)
  let occupancy p ~src_n:_ ~src:_ =
    Utils.Optional { callback_if_missing = (fun () -> needed_on_host := Set.add !needed_on_host p) }
  in
  let copies =
    collapse_merges @@ Backend.merge_batch ~name_prefixes:[| "param_copy" |] ~occupancy param_vals ~accum:Arrayjit.Ops.Arg2
      ~srcs:[| sgd_update.context |]
  in
  let copies =
    assert (Array.length copies = 1);
    copies.(0)
  in
  let copies =
    Array.init (num_devices - 1) ~f:(fun (to_m_1 : int) ->
        List.map copies ~f:(fun c -> (Backend.jit ctxs.(to_m_1 + 1) c).schedule ()))
  in
  let%track_sexp sync (devices_to_sync : int) : unit =
    Arrayjit.Utils.parallel_merge merge devices_to_sync;
    Tn.run debug_rt @@ sgd_update.schedule ();
    (* We need to wait, because copying happens on other devices. *)
    Backend.(await @@ get_ctx_device sgd_update.context);
    Set.iter !needed_on_host ~f:(fun p ->
        if not @@ Backend.to_host sgd_update.context p then
          invalid_arg @@ "Train.parallel_update: parameter missing on one of the devices: " ^ Tn.name p);
    (* We will need to update params on all devices! Not only the ones that computed gradients. *)
    for to_ = 1 to num_devices - 1 do
      List.iter copies.(to_ - 1) ~f:(Tn.run debug_rt)
    done;
    post_sync ~num_synced_devices:devices_to_sync
  in
  let jitted_bindings = [%debug_notrace Array.map grad_updates ~f:(fun upd -> upd.bindings)] in
  let fs = [%debug_notrace Array.map grad_updates ~f:(fun upd () -> Tn.run debug_rt @@ upd.schedule ())] in
  fun () -> round_robin fs jitted_bindings sgd_update.bindings ~sync
