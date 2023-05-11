open Base
(** The code for operating on n-dimensional arrays. *)

(** *** High-level representation. *** *)
type binop = Add | Mul | ToPowOf | Relu_gate | Arg2 | Arg1 [@@deriving sexp]

type unop = Identity | Relu [@@deriving sexp]

module N = Node

type global_identifier =
  | Task_id  (** Retrieves the identifier (a non-negative integer) of the task running the computation. *)
  | C_function of string  (** Calls a no-argument C function. *)
[@@deriving sexp, equal, compare]

(** Initializes a tensor by filling in the corresponding numbers, at the appropriate precision. *)
type init_op = N.init_op =
  | Constant_fill of float array
      (** Fills in the numbers where the rightmost axis is contiguous, looping over the provided values
      if necessary. *)
  | Range_over_offsets
      (** Fills in the offset number of each cell (i.e. how many cells away it is from the beginning). *)
  | Standard_uniform  (** Draws the values from U(0,1). *)
[@@deriving sexp]

(** Resets a tensor by performing the specified computation or data fetching. *)
type fetch_op = Constant of float | Synthetic of t | Imported of global_identifier [@@deriving sexp]

and t =
  | Synchronize of string  (** Wait for all tasks to reach this point before proceeding. *)
  | Par of t * t  (** These tasks can proceed in parallel, there is no interaction. *)
  | ParHint of t * t
      (** Computing [ParHint (c1, c2)] can proceed in parallel on [c1] and [c2], but when [c2] reads values
      that [c1] writes, the writes in [c1] must occur before the reads in [c2]. *)
  | Seq of t * t
      (** These tasks can only benefit from mutual parallelism via operator fusion / loop fusion. *)
  | Accum_binop of {
      zero_out : bool;
      accum : binop;
      op : binop;
      lhs : NodeUI.tensor_ptr;
      rhs1 : NodeUI.tensor_ptr;
      rhs2 : NodeUI.tensor_ptr;
      projections : unit -> Shape.projections;
    }
  | Accum_unop of {
      zero_out : bool;
      accum : binop;
      op : unop;
      lhs : NodeUI.tensor_ptr;
      rhs : NodeUI.tensor_ptr;
      projections : unit -> Shape.projections;
    }
  | Fetch of { tensor : NodeUI.tensor_ptr; fetch_op : fetch_op }
  | Block_comment of string * t
  | Noop
[@@deriving sexp]

(** If a backend does not support detection of when [ParHint (c1, c2)] is safe to parallelize,
    one can try setting [force_unsafe_parhint] to always parallelize if the particular code
    does not have a form of computation sharing that would get broken. *)
let force_unsafe_parhint = ref false

type create = { tensor : NodeUI.tensor_ptr; dims : unit -> Shape.dim array; init_op : init_op }
(** Information to create a tensor, once its shape is inferred. *)

let remove_updates tensor c =
  let rec rm check = function
    | ( Par ((Accum_binop { lhs; _ } | Accum_unop { lhs; _ }), t)
      | ParHint ((Accum_binop { lhs; _ } | Accum_unop { lhs; _ }), t)
      | Seq ((Accum_binop { lhs; _ } | Accum_unop { lhs; _ }), t)
      | Par (t, (Accum_binop { lhs; _ } | Accum_unop { lhs; _ }))
      | ParHint (t, (Accum_binop { lhs; _ } | Accum_unop { lhs; _ }))
      | Seq (t, (Accum_binop { lhs; _ } | Accum_unop { lhs; _ })) ) as c
      when check ->
        if NodeUI.equal_tensor_ptr tensor lhs then rm true t else rm false c
    | Par (t1, t2) -> Par (rm true t1, rm true t2)
    | ParHint (t1, t2) -> ParHint (rm true t1, rm true t2)
    | Seq (t1, t2) -> Seq (rm true t1, rm true t2)
    | (Accum_binop { lhs; _ } | Accum_unop { lhs; _ }) when NodeUI.equal_tensor_ptr tensor lhs -> Noop
    | c -> c
  in
  rm true c

let all_parallel = List.fold ~init:Noop ~f:(fun sts st -> Par (st, sts))
let sequential = List.fold_right ~init:Noop ~f:(fun st sts -> Seq (st, sts))

let rec flat_parallel ~force_hints ts =
  Array.concat_map ts ~f:(function
    | Par (t1, t2) -> flat_parallel ~force_hints [| t1; t2 |]
    | ParHint (t1, t2) when force_hints -> flat_parallel ~force_hints [| t1; t2 |]
    | Block_comment (_, Noop) as t -> [| t |]
    | Block_comment (s, t) -> flat_parallel ~force_hints [| Block_comment (s, Noop); t |]
    | Noop -> [||]
    | t -> [| t |])

type scope_id = { tensor : NodeUI.tensor_ptr; scope_id : int } [@@deriving sexp, equal, hash]
(** *** Low-level representation. *)

let get_scope =
  let uid = ref 0 in
  fun tensor ->
    Int.incr uid;
    { tensor; scope_id = !uid }

type sym_index = { sym : Shape.symbol; uid : int } [@@deriving sexp, equal, compare]
type index = sym_index Shape.axis_index [@@deriving sexp, equal, compare]

let new_sym_index =
  let uid = ref 0 in
  fun sym ->
    Int.incr uid;
    { sym; uid = !uid }

(** Cases: [unit low_level] -- code, [float low_level] -- single number at some precision. *)
type _ low_level =
  | Comment : string -> unit low_level
  | Lines : unit low_level array -> unit low_level
  | For_loop : { index : sym_index; from_ : int; to_ : int; body : unit low_level } -> unit low_level
  | If_task_id_is : { for_task_id : int; body : unit low_level } -> unit low_level
  | Synchronize : { stage : int; info : string } -> unit low_level
  | Reset_synchronizer : unit low_level
  | Dynamic_indices : {
      tensor : NodeUI.tensor_ptr;
      tensor_idcs : index array;
      dynamic_idcs : Shape.symbol array;
      target_dims : Shape.dim array;
      body : unit low_level;
    }
      -> unit low_level
  | Set : NodeUI.tensor_ptr * index array * float low_level -> unit low_level
  | Set_local : scope_id * float low_level -> unit low_level
  | Local_scope : {
      id : scope_id;
      prec : NodeUI.prec;
      body : unit low_level;
      orig_indices : index array;
    }
      -> float low_level
  | Get_local : scope_id -> float low_level
  | Get_global : global_identifier -> float low_level
  | Get : NodeUI.tensor_ptr * index array -> float low_level
  | Binop : binop * float low_level * float low_level -> float low_level
  | Unop : unop * float low_level -> float low_level
  | Constant : float -> float low_level
[@@deriving sexp_of]

let binop ~op ~rhs1 ~rhs2 = match op with Arg1 -> rhs1 | Arg2 -> rhs2 | _ -> Binop (op, rhs1, rhs2)
let unop ~op ~rhs = match op with Identity -> rhs | _ -> Unop (op, rhs)
let rec flat_lines ts = Array.concat_map ts ~f:(function Lines ts -> flat_lines ts | t -> [| t |])

let partition_tf_with_comment t ~f =
  let both = Array.map t ~f:(fun tc -> if f tc then Either.First tc else Either.Second tc) in
  let trues =
    Array.filter_map both ~f:(function
      | First x -> Some x
      | Second ((_, Comment _) as x) -> Some x
      | Second _ -> None)
  in
  let falses =
    Array.filter_map both ~f:(function
      | First ((_, Comment _) as x) -> Some x
      | First _ -> None
      | Second x -> Some x)
  in
  (trues, falses)

let rebalance llcs =
  (* FIXME: implement actual rebalancing. *)
  If_task_id_is { for_task_id = 0; body = Lines (flat_lines llcs) }

let rec has_parallel_dim : type a. a low_level -> bool = function
  | Comment _ -> false
  | Lines ls -> Array.exists ~f:has_parallel_dim ls
  | For_loop { body; _ } -> has_parallel_dim body
  | If_task_id_is { body; _ } -> has_parallel_dim body
  | Synchronize _ -> false
  | Reset_synchronizer -> false
  | Dynamic_indices { tensor = _; tensor_idcs; dynamic_idcs = _; target_dims; body } ->
      Array.exists tensor_idcs ~f:Shape.is_task_id
      || Array.exists ~f:Shape.is_parallel target_dims
      || has_parallel_dim body
  | Set (_, indices, llv) -> Array.exists indices ~f:Shape.is_task_id || has_parallel_dim llv
  | Set_local (_, llv) -> has_parallel_dim llv
  | Local_scope { body; orig_indices; _ } ->
      Array.exists orig_indices ~f:Shape.is_task_id || has_parallel_dim body
  | Get_local _ -> false
  | Get_global Task_id -> true
  | Get_global _ -> false
  | Get (_, indices) -> Array.exists indices ~f:Shape.is_task_id
  | Binop (_, llv1, llv2) -> has_parallel_dim llv1 || has_parallel_dim llv2
  | Unop (_, llv) -> has_parallel_dim llv
  | Constant _ -> false

let rec has_synchronize = function
  | Par (t1, t2) | ParHint (t1, t2) | Seq (t1, t2) -> has_synchronize t1 || has_synchronize t2
  | Block_comment (_, t) -> has_synchronize t
  | Accum_binop _ | Accum_unop _ | Fetch _ | Noop -> false
  | Synchronize _ -> true

let parallelizable (t, c) = not (has_parallel_dim c || has_synchronize t)

let to_low_level (code : t) : unit low_level =
  let synchronizer_stage = ref 0 in
  let rec loop ~single_task code =
    match code with
    | Accum_binop { zero_out; accum; op; lhs; rhs1; rhs2; projections } ->
        let projections = projections () in
        let lhs_idx = Shape.(derive_index projections.product_iterators projections.project_lhs) in
        let rhs1_idx = Shape.(derive_index projections.product_iterators projections.project_rhs1) in
        let rhs2_idx =
          match projections.project_rhs2 with
          | None -> invalid_arg "accum_binop: projections missing project_rhs2"
          | Some rhs2 -> Shape.(derive_index projections.product_iterators rhs2)
        in
        let basecase rev_iters =
          let iters = Array.of_list_rev rev_iters in
          let rhs1_idcs = rhs1_idx iters in
          let rhs2_idcs = rhs2_idx iters in
          let lhs_idcs = lhs_idx iters in
          let lhs_ll = Get (lhs, lhs_idcs) in
          let rhs1_ll = Get (rhs1, rhs1_idcs) in
          let rhs2_ll = Get (rhs2, rhs2_idcs) in
          let body =
            Set (lhs, lhs_idcs, binop ~op:accum ~rhs1:lhs_ll ~rhs2:(binop ~op ~rhs1:rhs1_ll ~rhs2:rhs2_ll))
          in
          let body = if single_task || has_parallel_dim body then body else rebalance [| body |] in
          match Array.find rhs2_idcs ~f:Shape.is_dynamic_provider with
          | Some (Dynamic_provider { idcs = dynamic_idcs; target_dims }) ->
              Dynamic_indices { tensor = rhs2; tensor_idcs = rhs2_idcs; dynamic_idcs; target_dims; body }
          | _ -> (
              match Array.find rhs1_idcs ~f:Shape.is_dynamic_provider with
              | Some (Dynamic_provider { idcs = dynamic_idcs; target_dims }) ->
                  Dynamic_indices { tensor = rhs1; tensor_idcs = rhs1_idcs; dynamic_idcs; target_dims; body }
              | _ -> (
                  match Array.find lhs_idcs ~f:Shape.is_dynamic_provider with
                  | Some (Dynamic_provider { idcs = dynamic_idcs; target_dims }) ->
                      Dynamic_indices
                        { tensor = lhs; tensor_idcs = lhs_idcs; dynamic_idcs; target_dims; body }
                  | _ -> body))
        in
        let rec for_loop rev_iters = function
          | [], [] -> basecase rev_iters
          | Shape.Dim dim :: product, it :: iters ->
              let it = new_sym_index it in
              For_loop
                { index = it; from_ = 0; to_ = dim - 1; body = for_loop (it :: rev_iters) (product, iters) }
          | Shape.Parallel :: _product, _it :: _iters ->
              (* FIXME: was this filtered out? *)
              invalid_arg "Code.to_low_level: Accum_binop projections parallel dim found in product space"
          | _ -> invalid_arg "Code.to_low_level: Accum_binop projections dims-iterators mismatch"
        in
        let for_loops =
          for_loop [] (Array.to_list projections.product_space, Array.to_list projections.product_iterators)
        in
        if zero_out then
          Lines [| loop ~single_task (Fetch { tensor = lhs; fetch_op = Constant 0. }); for_loops |]
        else for_loops
    | Accum_unop { zero_out; accum; op; lhs; rhs; projections } ->
        let projections = projections () in
        let lhs_idx = Shape.(derive_index projections.product_iterators projections.project_lhs) in
        let rhs_idx = Shape.(derive_index projections.product_iterators projections.project_rhs1) in
        let basecase rev_iters =
          let iters = Array.of_list_rev rev_iters in
          let lhs_idcs = lhs_idx iters in
          let lhs_ll = Get (lhs, lhs_idcs) in
          let rhs_ll = Get (rhs, rhs_idx iters) in
          let body = Set (lhs, lhs_idcs, binop ~op:accum ~rhs1:lhs_ll ~rhs2:(unop ~op ~rhs:rhs_ll)) in
          if single_task || has_parallel_dim body then body else rebalance [| body |]
        in
        let rec for_loop rev_iters = function
          | [], [] -> basecase rev_iters
          | Shape.Dim dim :: product, it :: iters ->
              let it = new_sym_index it in
              For_loop
                { index = it; from_ = 0; to_ = dim - 1; body = for_loop (it :: rev_iters) (product, iters) }
          | Parallel :: _product, _it :: _iters ->
              (* FIXME: was this filtered out? *)
              invalid_arg "Code.to_low_level: Accum_binop projections parallel dim found in product space"
          | _ -> invalid_arg "Code.to_low_level: Accum_unop projections dims-iterators mismatch"
        in
        let for_loops =
          for_loop [] (Array.to_list projections.product_space, Array.to_list projections.product_iterators)
        in
        if zero_out then
          Lines [| loop ~single_task (Fetch { tensor = lhs; fetch_op = Constant 0. }); for_loops |]
        else for_loops
    | Noop -> Lines [||]
    | Synchronize info ->
        assert (not single_task);
        Int.incr synchronizer_stage;
        Synchronize { stage = !synchronizer_stage; info }
    | Block_comment (s, (Par _ as c)) when not single_task -> loop_par ~s c
    | Block_comment (s, (ParHint _ as c)) when !force_unsafe_parhint && not single_task -> loop_par ~s c
    | Par _ when not single_task -> loop_par code
    | ParHint _ when !force_unsafe_parhint && not single_task -> loop_par code
    | Block_comment (s, c) -> Lines [| Comment s; loop ~single_task c |]
    | Par (c1, c2) | ParHint (c1, c2) | Seq (c1, c2) -> (
        (* TODO: this ignores parallelization altogether, don't! *)
        let ll1 = loop ~single_task c1 in
        let ll2 = loop ~single_task c2 in
        match (ll1, ll2) with
        | Lines ls1, Lines ls2 -> Lines (Array.append ls1 ls2)
        | _, Lines ls2 -> Lines (Array.append [| ll1 |] ls2)
        | Lines ls1, _ -> Lines (Array.append ls1 [| ll2 |])
        | _ -> Lines [| ll1; ll2 |])
    | Fetch { tensor; fetch_op = Constant c } ->
        let product_space : Shape.dim array = Shape.to_dims (NodeUI.get tensor.id).shape in
        let rec loop rev_idcs = function
          | [] -> Set (tensor, Array.of_list_rev rev_idcs, Constant c)
          | Shape.Dim 1 :: product -> loop (Fixed_idx 0 :: rev_idcs) product
          | Dim dim :: product ->
              let it = new_sym_index (Shape.get_symbol ()) in
              let idx = Shape.Iterator it in
              For_loop { index = it; from_ = 0; to_ = dim - 1; body = loop (idx :: rev_idcs) product }
          | Parallel :: product -> loop (Shape.Task_id :: rev_idcs) product
        in
        let for_loops = loop [] (Array.to_list product_space) in
        for_loops
    | Fetch { tensor = _; fetch_op = Synthetic gen } -> loop ~single_task gen
    | Fetch { tensor = _; fetch_op = Imported _ } -> failwith "to_low_level: Imported NOT IMPLEMENTED YET"
  and loop_par ?s c =
    let ts = flat_parallel ~force_hints:!force_unsafe_parhint [| c |] in
    let t_c_s = Array.map ts ~f:(fun t -> (t, loop ~single_task:false t)) in
    let nontask_ts, task_ts = partition_tf_with_comment ~f:parallelizable t_c_s in
    Int.incr synchronizer_stage;
    let sync =
      Synchronize
        {
          stage = !synchronizer_stage;
          info = (match s with Some s -> "past-par-" ^ s | None -> "past-parallel");
        }
    in
    let nontask_ts = rebalance @@ Array.map nontask_ts ~f:(fun (t, _) -> loop ~single_task:true t) in
    let task_ts = Lines (Array.map ~f:snd task_ts) in
    match s with
    | None -> Lines (flat_lines [| nontask_ts; task_ts; sync |])
    | Some s -> Lines (flat_lines [| Comment s; nontask_ts; task_ts; sync |])
  in

  loop ~single_task:false code

let interpreter_print_comments = ref false
let keep_files_in_run_directory = ref false
let with_debug = ref false
let debug_virtual_nodes = ref false

type int_env = (sym_index, int) Base.Map.Poly.t * (Shape.symbol, int) Base.Map.Poly.t

let sexp_of_int_env (env, dyn_env) =
  [%sexp_of: (sym_index * int) list * (Shape.symbol * int) list] (Map.to_alist env, Map.to_alist dyn_env)

let set_from_float ptr idcs value =
  match ptr.NodeUI.field with
  | Value -> N.set_from_float (N.get ptr.id).value idcs value
  | Grad -> N.set_from_float (Option.value_exn (N.get ptr.id).grad) idcs value

let fill_from_float ptr value =
  match ptr.NodeUI.field with
  | Value -> N.fill_from_float (N.get ptr.id).value value
  | Grad -> N.fill_from_float (Option.value_exn (N.get ptr.id).grad) value

let get_as_float ptr idcs =
  match ptr.NodeUI.field with
  | Value -> N.get_as_float (N.get ptr.id).value idcs
  | Grad -> N.get_as_float (Option.value_exn (N.get ptr.id).grad) idcs

let debug_trace_interpretation = ref false

let interpret_code ?task_id synchronizer llc =
  (* Local scope ids can be non-unique due to inlining. *)
  let locals = ref Map.Poly.empty in
  let task_id () =
    match task_id with
    | Some id -> id
    | None -> invalid_arg "interpret_code: task_id not set, use interpret_task_id_func"
  in
  let lookup ?provider_dim (env, dyn_env) indices =
    try
      Array.map indices ~f:(function
        | Shape.Fixed_idx i -> i
        | Task_id -> task_id ()
        | Iterator s -> Map.find_exn env s
        | Dynamic_recipient s -> Map.find_exn dyn_env s
        | Dynamic_provider _ -> Option.value_exn provider_dim)
    with Caml.Not_found | Not_found_s _ ->
      if !debug_trace_interpretation then
        Caml.Format.printf "TRACE: lookup error for env=@ %a\n%!" Sexp.pp_hum
          ([%sexp_of: (sym_index * int) list] @@ Map.to_alist env);
      failwith "interpret_code: index lookup error, set CDSL.debug_trace_interpretation for details"
  in
  let rec loop_proc env llc : unit =
    let loop = loop_proc env in
    match llc with
    | Lines body -> Array.iter ~f:loop body
    | For_loop { index = key; from_; to_; body } ->
        for data = from_ to to_ do
          loop_proc (Map.add_exn ~key ~data @@ fst env, snd env) body
        done
    | If_task_id_is { for_task_id; body } -> if task_id () = for_task_id then loop body
    | Synchronize { stage; info } ->
        let task_id = task_id () in
        if !debug_trace_interpretation then
          Caml.Format.printf "TRACE: synchronize task_id %d for %d: %s\n%!" task_id stage info;
        Synchronizer.synchronize ~task_id ~stage synchronizer;
        if !debug_trace_interpretation then
          Caml.Format.printf "TRACE: task_id %d synchronized for %d: %s\n%!" task_id stage info
    | Reset_synchronizer -> Synchronizer.synchronize_and_reset ~task_id:(task_id ()) synchronizer
    | Set (ptr, indices, llv) ->
        if !debug_trace_interpretation then
          Caml.Format.printf "{TRACE: %a [%a] <- ...\n%!" Sexp.pp_hum
            ([%sexp_of: NodeUI.tensor_ptr] ptr)
            Sexp.pp_hum
            ([%sexp_of: index array] indices);
        let idcs = lookup env indices in
        let result = loop_float env llv in
        if !debug_trace_interpretation then
          Caml.Format.printf "TRACE: %a [%a -> %a] (%f) <- %f}\n%!" Sexp.pp_hum
            ([%sexp_of: NodeUI.tensor_ptr] ptr)
            Sexp.pp_hum
            ([%sexp_of: index array] indices)
            Sexp.pp_hum
            ([%sexp_of: int array] idcs)
            (get_as_float ptr idcs) result;
        try set_from_float ptr idcs result
        with e ->
          Caml.Format.printf "ERROR: %a [%a -> %a] <- %f -- indices out of bounds\n%!" Sexp.pp_hum
            ([%sexp_of: NodeUI.tensor_ptr] ptr)
            Sexp.pp_hum
            ([%sexp_of: index array] indices)
            Sexp.pp_hum
            ([%sexp_of: int array] idcs)
            result;
          (* if task_id () = 0 then *) NodeUI.print_node_preamble ptr.id;
          raise e
    | Set_local (id, llv) -> locals := Map.update !locals id ~f:(fun _ -> loop_float env llv)
    | Comment message when !with_debug && !interpreter_print_comments -> Stdio.printf "%s\n%!" message
    | Dynamic_indices { tensor = { id; field = Value }; tensor_idcs; dynamic_idcs; target_dims; body } ->
        dynamic_indices env (N.get id).value ~tensor_idcs ~dynamic_idcs ~target_dims body
    | Dynamic_indices { tensor = { id; field = Grad }; tensor_idcs; dynamic_idcs; target_dims; body } ->
        dynamic_indices env (Option.value_exn (N.get id).grad) ~tensor_idcs ~dynamic_idcs ~target_dims body
    | Comment c ->
        if !debug_trace_interpretation then (
          Caml.Format.printf "TRACE: %s -- prior state of nodes: {\n%!" c;
          NodeUI.print_decimals_precision := 9;
          for i = 1 to Node.global.unique_id - 1 do
            Caml.Format.printf "TRACE: %a\n%!" PrintBox_text.pp
              (NodeUI.to_printbox ~single_node:true ~with_grad:true ~depth:9 i)
          done;
          Caml.Format.printf "}\n%!")
  and loop_float env llv =
    let open Float in
    let loop = loop_float env in
    match llv with
    | Constant c -> c
    | Get (ptr, indices) ->
        if !debug_trace_interpretation then
          Caml.Format.printf "{TRACE: %a [%a] -> ...\n%!" Sexp.pp_hum
            ([%sexp_of: NodeUI.tensor_ptr] ptr)
            Sexp.pp_hum
            ([%sexp_of: index array] indices);
        let idcs = lookup env indices in
        let result =
          try get_as_float ptr idcs
          with e ->
            Caml.Format.printf "ERROR: %a [%a -> %a] -- indices out of bounds\n%!" Sexp.pp_hum
              ([%sexp_of: NodeUI.tensor_ptr] ptr)
              Sexp.pp_hum
              ([%sexp_of: index array] indices)
              Sexp.pp_hum
              ([%sexp_of: int array] idcs);
            (* if Int.(task_id () = 0) then *) NodeUI.print_node_preamble ptr.id;
            raise e
        in
        if !debug_trace_interpretation then
          Caml.Format.printf "TRACE: %a [%a -> %a] -> %f}\n%!" Sexp.pp_hum
            ([%sexp_of: NodeUI.tensor_ptr] ptr)
            Sexp.pp_hum
            ([%sexp_of: index array] indices)
            Sexp.pp_hum
            ([%sexp_of: int array] idcs)
            result;
        result
    | Local_scope { id; prec = _; body; orig_indices } ->
        if !debug_trace_interpretation then
          Caml.Format.printf "{TRACE: %a [%a] <-> ...\n%!" Sexp.pp_hum
            ([%sexp_of: NodeUI.tensor_ptr] id.tensor)
            Sexp.pp_hum
            ([%sexp_of: index array] orig_indices);
        let old_locals = !locals in
        locals := Map.update !locals id ~f:(fun _ -> 0.0);
        loop_proc env body;
        let result = Map.find_exn !locals id in
        locals := old_locals;
        let idcs = lookup env orig_indices in
        if !debug_virtual_nodes then (
          try set_from_float id.tensor idcs result
          with e ->
            Caml.Format.printf "ERROR: virtual %a [%a -> %a] -- original indices out of bounds\n%!"
              Sexp.pp_hum
              ([%sexp_of: NodeUI.tensor_ptr] id.tensor)
              Sexp.pp_hum
              ([%sexp_of: index array] orig_indices)
              Sexp.pp_hum
              ([%sexp_of: int array] idcs);
            (* if Int.(task_id () = 0) then *) NodeUI.print_node_preamble id.tensor.id;
            raise e);
        if !debug_trace_interpretation then
          Caml.Format.printf "TRACE: %a [%a / %a] (%f) <-> %f}\n%!" Sexp.pp_hum
            ([%sexp_of: NodeUI.tensor_ptr] id.tensor)
            Sexp.pp_hum
            ([%sexp_of: index array] orig_indices)
            Sexp.pp_hum
            ([%sexp_of: int array] idcs)
            (get_as_float id.tensor idcs) result;
        result
    | Get_local id -> Map.find_exn !locals id
    | Get_global Task_id -> Float.of_int @@ task_id ()
    | Get_global (C_function _) -> failwith "NOT IMPLEMENTED YET: jit-dynloading C calls in the interpreter"
    | Binop (Arg1, llv1, _llv2) -> loop llv1
    | Binop (Arg2, _llv1, llv2) -> loop llv2
    | Binop (Add, llv1, llv2) -> loop llv1 + loop llv2
    | Binop (Mul, llv1, llv2) -> loop llv1 * loop llv2
    | Binop (ToPowOf, llv1, llv2) ->
        let v1 = loop llv1 in
        let v2 = loop llv2 in
        Float.(if is_integer v2 then int_pow v1 @@ to_int v2 else v1 ** v2)
    | Binop (Relu_gate, llv1, llv2) -> if loop llv1 > 0.0 then loop llv2 else 0.0
    | Unop (Identity, llv) -> loop llv
    | Unop (Relu, llv) ->
        let v = loop llv in
        if v > 0.0 then v else 0.0
  and dynamic_indices env tensor ~tensor_idcs ~dynamic_idcs ~target_dims body =
    let env =
      Array.foldi dynamic_idcs ~init:env ~f:(fun provider_dim env key ->
          let idcs = lookup ~provider_dim env tensor_idcs in
          let actual =
            try N.get_as_int tensor idcs
            with e ->
              Caml.Format.printf "ERROR: dynamic index at [%a -> %a] -- indices out of bounds\n%!" Sexp.pp_hum
                ([%sexp_of: index array] tensor_idcs)
                Sexp.pp_hum
                ([%sexp_of: int array] idcs);
              raise e
          in
          let target_dim =
            match target_dims.(provider_dim) with Dim d -> d | Parallel -> !Shape.num_parallel_tasks
          in
          (fst env, Map.add_exn ~key ~data:(actual % target_dim) @@ snd env))
    in
    loop_proc env body
  in
  loop_proc (Map.Poly.empty, Map.Poly.empty) llc

let fprint_code ppf c =
  (* TODO: something nicely concise. *)
  Caml.Format.fprintf ppf "%s" @@ Sexp.to_string_hum @@ sexp_of_t c

let fprint_low_level ppf c =
  (* TODO: something nicely concise. *)
  Caml.Format.fprintf ppf "%s" @@ Sexp.to_string_hum @@ sexp_of_low_level Unit.sexp_of_t (to_low_level c)

let interpreter_error_message ~name ~prefix ?extra_error_msg ~contents exc =
  let backtrace = Caml.Printexc.get_backtrace () in
  let exc_str = Caml.Printexc.to_string exc in
  let message = Buffer.create (String.length contents + String.length backtrace + String.length exc_str) in
  let msg = Buffer.add_string message in
  msg name;
  msg ": ";
  msg prefix;
  msg exc_str;
  msg "\n";
  msg backtrace;
  (match extra_error_msg with
  | None -> ()
  | Some extra ->
      msg "\nIn the context of:\n";
      msg extra);
  msg contents;
  Buffer.contents message

(** *** Optimization *** *)

type virtualize_settings = {
  mutable virtualize : bool;
  mutable max_visits : int;
  mutable consider_grads : bool;
  mutable inline_constants : bool;
}

let virtualize_settings =
  { virtualize = true; max_visits = 3; consider_grads = false; inline_constants = true }

type visits =
  | Visits of int
  | Recurrent  (** A [Recurrent] visit is when there is an access prior to any assignment in an update. *)
[@@deriving sexp, equal]

type data_node = {
  id : int;
  kind : NodeUI.data_kind;
  prec : NodeUI.prec;
  mutable computations : (index array option * unit low_level) list;
      (** The computations (of the data node) are retrieved for optimization just as they are populated,
          so that the inlined code corresponds precisely to the changes to the tensors that would happen
          up till that point. Within the code blocks paired with an index tuple, all assignments and accesses
          must happen via the index tuple; if this is not the case for some assignment, the node cannot
          be virtual. Currently, we only allow for-loop symbols in assignment indices of virtual nodes. *)
  assignments : int array Hash_set.t;
  accesses : (int array, visits) Hashtbl.t;
      (** For dynamic indexes, we take a value of 0. This leads to an overestimate of visits, which is safe. *)
  mutable non_virtual : bool;
  mutable scalar : float option;
}
[@@deriving sexp_of]

let get_node store (uid : NodeUI.tensor_ptr) =
  Hashtbl.find_or_add store uid ~default:(fun () ->
      {
        id = uid.id;
        kind = uid.field;
        prec = NodeUI.node_prec uid;
        computations = [];
        assignments = Hash_set.Poly.create ();
        accesses = Hashtbl.Poly.create ();
        non_virtual = (NodeUI.get uid.id).cannot_be_virtual;
        scalar = None;
      })

let get_other_node node_store ptr =
  get_node node_store
    { ptr with field = (if NodeUI.equal_data_kind ptr.NodeUI.field Value then Grad else Value) }

let precompute_constants ?idcs node_store top_node llv =
  let exception Non_literal of int in
  let rec loop llv =
    match llv with
    | Constant c -> c
    | Get (ptr, indices) ->
        let node = get_node node_store ptr in
        Array.iter indices ~f:(function Shape.Fixed_idx 0 -> () | _ -> raise @@ Non_literal 1);
        Option.value_or_thunk node.scalar ~default:(fun () -> raise @@ Non_literal 2)
    | Local_scope { id; orig_indices; _ } ->
        let node = get_node node_store id.tensor in
        Array.iter orig_indices ~f:(function Shape.Fixed_idx 0 -> () | _ -> raise @@ Non_literal 3);
        Option.value_or_thunk node.scalar ~default:(fun () -> raise @@ Non_literal 4)
    | Get_local scope_id ->
        let node = get_node node_store scope_id.tensor in
        Option.value_or_thunk node.scalar ~default:(fun () -> raise @@ Non_literal 5)
    | Get_global _ -> raise @@ Non_literal 9
    | Binop (Arg1, llv1, _llv2) -> loop llv1
    | Binop (Arg2, _llv1, llv2) -> loop llv2
    | Binop (Add, llv1, llv2) -> Float.(loop llv1 + loop llv2)
    | Binop (Mul, llv1, llv2) -> Float.(loop llv1 * loop llv2)
    | Binop (ToPowOf, llv1, llv2) ->
        let v1 = loop llv1 in
        let v2 = loop llv2 in
        Float.(if is_integer v2 then int_pow v1 @@ to_int v2 else v1 ** v2)
    | Binop (Relu_gate, llv1, llv2) -> Float.(if loop llv1 > 0.0 then loop llv2 else 0.0)
    | Unop (Identity, llv) -> loop llv
    | Unop (Relu, llv) ->
        let v = loop llv in
        Float.(if v > 0.0 then v else 0.0)
  in
  let n = NodeUI.get top_node.id in
  try
    if n.cannot_be_virtual then raise @@ Non_literal 8;
    if (not @@ Hashtbl.is_empty top_node.accesses) && not n.literal then raise @@ Non_literal 6;
    (match idcs with
    | None -> ()
    | Some idcs ->
        if Array.exists idcs ~f:(function Shape.Fixed_idx 0 -> false | _ -> true) then raise @@ Non_literal 7);
    top_node.scalar <- Some (loop llv)
  with Non_literal i ->
    if !with_debug && !debug_trace_interpretation then
      Caml.Format.printf "TRACE: Node #%d is non-literal because no. %d\n%!" n.id i;
    (* In principle we might conclude again that the node is to be inlined as scalar, that's OK. *)
    top_node.scalar <- None

let visit is_assigned old =
  if not is_assigned then Recurrent
  else match old with None -> Visits 1 | Some (Visits i) -> Visits (i + 1) | Some Recurrent -> Recurrent

let visit_llc node_store reverse_node_map ~max_visits ~consider_grads llc =
  let is_too_many = function Visits i -> i > max_visits | Recurrent -> true in
  let nodes = Hash_set.create (module Int) in
  let lookup ?provider_dim ~task_id dem_env indices =
    let env, dyn_env = dem_env in
    Array.map indices ~f:(function
      | Shape.Fixed_idx i -> i
      | Iterator s -> Map.find_exn env s
      | Dynamic_recipient s -> Map.find_exn dyn_env s
      | Dynamic_provider _ -> Option.value_exn provider_dim
      | Task_id -> task_id)
  in
  let rec loop_proc ~task_id env llc =
    let loop = loop_proc ~task_id env in
    match llc with
    | Lines body -> Array.iter ~f:loop body
    | For_loop { index = key; from_; to_; body } ->
        for data = from_ to to_ do
          loop_proc ~task_id (Map.add_exn ~key ~data @@ fst env, snd env) body
        done
    | If_task_id_is { for_task_id; body } -> if task_id = for_task_id then loop body
    | Synchronize _ | Reset_synchronizer -> ()
    | Set (tensor, idcs, llv) ->
        loop_float ~task_id env llv;
        Hash_set.add nodes tensor.id;
        let set_node : data_node = get_node node_store tensor in
        Hash_set.add set_node.assignments (lookup ~task_id env idcs);
        if virtualize_settings.inline_constants then precompute_constants ~idcs node_store set_node llv;
        Array.iter idcs ~f:(function
          | Shape.Dynamic_provider _ | Shape.Dynamic_recipient _ -> set_node.non_virtual <- true
          | Shape.Fixed_idx _ | Task_id -> ()
          | Shape.Iterator s ->
              let old_tensor = Hashtbl.find_or_add reverse_node_map s ~default:(fun () -> tensor) in
              (* TODO(#134): this prevents multiple virtual tensors from sharing for loops. *)
              assert (NodeUI.equal_tensor_ptr old_tensor tensor))
    | Set_local (_, llv) -> loop_float ~task_id env llv
    | Comment _ -> ()
    | Dynamic_indices { tensor; tensor_idcs; dynamic_idcs; target_dims; body } ->
        let data_node = get_node node_store tensor in
        (* FIXME(132): implement virtual dynamic indices. *)
        data_node.non_virtual <- true;
        data_node.scalar <- None;
        Hash_set.add nodes data_node.id;
        dynamic_indices data_node ~task_id env ~tensor_idcs ~dynamic_idcs ~target_dims body
  and loop_float ~task_id env llv =
    let loop = loop_float ~task_id env in
    match llv with
    | Constant _ -> ()
    | Get (tensor, indices) ->
        let get_node : data_node = get_node node_store tensor in
        Hash_set.add nodes get_node.id;
        let at_pos = lookup ~task_id env indices in
        Hashtbl.update get_node.accesses at_pos ~f:(visit @@ Hash_set.mem get_node.assignments at_pos)
    | Local_scope { body; _ } -> loop_proc ~task_id env body
    | Get_local _ -> ()
    | Get_global _ -> ()
    | Binop (Arg1, llv1, _llv2) -> loop llv1
    | Binop (Arg2, _llv1, llv2) -> loop llv2
    | Binop (_, llv1, llv2) ->
        loop llv1;
        loop llv2
    | Unop (_, llv) -> loop llv
  and dynamic_indices node ~task_id env ~tensor_idcs ~dynamic_idcs ~target_dims:_ body =
    let env =
      Array.foldi dynamic_idcs ~init:env ~f:(fun provider_dim env key ->
          let at_pos = lookup ~provider_dim ~task_id env tensor_idcs in
          Hashtbl.update node.accesses at_pos ~f:(visit @@ Hash_set.mem node.assignments at_pos);
          (fst env, Map.add_exn ~key ~data:0 @@ snd env))
    in
    loop_proc ~task_id env body
  in
  (* Do not penalize parallel use. *)
  loop_proc ~task_id:0 (Map.Poly.empty, Map.Poly.empty) llc;
  Hash_set.iter nodes ~f:(fun node_id ->
      let value_node : data_node = get_node node_store { id = node_id; field = Value } in
      if Hashtbl.exists value_node.accesses ~f:is_too_many then (
        value_node.non_virtual <- true;
        (* TODO(#135): For now, value and gradient are non-virtual reciprocically. *)
        Option.iter
          (Hashtbl.find node_store { id = node_id; field = Grad })
          ~f:(fun grad_node -> grad_node.non_virtual <- true));
      if consider_grads then
        Option.iter
          (Hashtbl.find node_store { id = node_id; field = Grad })
          ~f:(fun grad_node ->
            if Hashtbl.exists grad_node.accesses ~f:is_too_many then grad_node.non_virtual <- true;
            (* TODO(#135): For now, value and gradient are non-virtual reciprocically. *)
            if value_node.non_virtual then grad_node.non_virtual <- true;
            if grad_node.non_virtual then value_node.non_virtual <- true))

type tensor_ptrs = NodeUI.tensor_ptr Set.Poly.t
type sym_indices = sym_index Set.Poly.t

let sexp_of_tensor_ptrs ts = Fn.compose [%sexp_of: NodeUI.tensor_ptr list] Set.to_list ts
let sexp_of_sym_indices s = [%sexp_of: sym_index list] @@ Set.to_list s

let process_computation node_store node top_llc =
  let exception Non_virtual in
  let top_data = { NodeUI.id = node.id; field = node.kind } in
  let at_idcs = ref None in
  let has_setter = ref false in
  let check_idcs indices =
    (match !at_idcs with
    | None -> at_idcs := Some indices
    | Some at -> if not @@ [%equal: index array] at indices then raise Non_virtual);
    (* TODO(#133): For non-recursive accesses, non-linearity is not supported yet. *)
    let syms =
      Set.Poly.of_array
      @@ Array.filter_map indices
           ~f:
             Shape.(
               function
               | Task_id | Fixed_idx _ | Dynamic_recipient _ | Dynamic_provider _ -> None
               | Iterator s -> Some s)
    in
    let num_syms = Array.count indices ~f:(function Iterator _ -> true | _ -> false) in
    if Set.length syms <> num_syms then raise Non_virtual
  in
  (* Traverse the float code too, for completeness / future use-cases. *)
  let rec loop_proc ~(env_dom : sym_indices) llc =
    let loop = loop_proc ~env_dom in
    match llc with
    | Lines body -> Array.iter ~f:loop body
    | For_loop { index; from_ = _; to_ = _; body } -> loop_proc ~env_dom:(Set.add env_dom index) body
    | If_task_id_is { for_task_id = _; body } -> loop body
    | Synchronize _ -> raise Non_virtual
    | Reset_synchronizer -> raise Non_virtual
    | Set (tensor, indices, llv) ->
        if NodeUI.equal_tensor_ptr tensor top_data then (
          check_idcs indices;
          has_setter := true)
        else
          (* Check for escaping variables. *)
          Array.iter indices ~f:(function
            | Iterator s ->
                if not @@ Set.mem env_dom s then (
                  if !with_debug then
                    Caml.Format.printf "INFO: Inlining candidate has an escaping variable %a:@ %a\n%!"
                      Sexp.pp_hum (sexp_of_sym_index s) Sexp.pp_hum
                      ([%sexp_of: unit low_level] top_llc);
                  raise Non_virtual)
            | _ -> ());
        loop_float ~env_dom llv
    | Set_local (_, llv) -> loop_float ~env_dom llv
    | Comment _ -> ()
    | Dynamic_indices { body; _ } -> loop body
  and loop_float ~(env_dom : sym_indices) llv =
    match llv with
    | Constant _ -> ()
    | Get (tensor, idcs) ->
        if NodeUI.equal_tensor_ptr tensor top_data then check_idcs idcs
        else
          (* Check for escaping variables. *)
          Array.iter idcs ~f:(function
            | Iterator s ->
                if not @@ Set.mem env_dom s then (
                  if !with_debug then
                    Caml.Format.printf "INFO: Inlining candidate has an escaping variable %a:@ %a\n%!"
                      Sexp.pp_hum (sexp_of_sym_index s) Sexp.pp_hum
                      ([%sexp_of: unit low_level] top_llc);
                  raise Non_virtual)
            | _ -> ())
    | Local_scope { body; _ } -> loop_proc ~env_dom body
    | Get_local _ -> ()
    | Get_global _ -> ()
    | Binop (_, llv1, llv2) ->
        loop_float ~env_dom llv1;
        loop_float ~env_dom llv2
    | Unop (_, llv) -> loop_float ~env_dom llv
  in
  (* Issue #135: For now, value and gradient are non-virtual reciprocically. *)
  let other_node =
    get_node node_store
      { id = node.id; field = (if NodeUI.equal_data_kind node.kind Value then Grad else Value) }
  in
  try
    if node.non_virtual then raise Non_virtual;
    if other_node.non_virtual then raise Non_virtual;
    loop_proc ~env_dom:Set.Poly.empty top_llc;
    if not !has_setter then raise Non_virtual;
    node.computations <- (!at_idcs, top_llc) :: node.computations
  with Non_virtual ->
    (NodeUI.get node.id).cannot_be_virtual <- true;
    node.non_virtual <- true;
    other_node.non_virtual <- true

let inline_computation ~id node call_args =
  let exception Non_virtual in
  let make_subst i lhs_ind =
    let rhs_ind = call_args.(i) in
    match lhs_ind with
    | Shape.Iterator s -> Some (s, rhs_ind)
    | _ when Shape.equal_axis_index equal_sym_index lhs_ind rhs_ind -> None
    | _ -> raise Non_virtual
  in
  let at_data = { id = node.id; NodeUI.field = node.kind } in
  (* In the order of computation. *)
  let loop_proc (def_args, def) : unit low_level option =
    let env =
      match def_args with
      | None -> Map.Poly.empty
      | Some def_args -> Map.Poly.of_alist_exn @@ Array.to_list @@ Array.filter_mapi def_args ~f:make_subst
    in
    let subst = function Shape.Iterator s when Map.mem env s -> Map.find_exn env s | idx -> idx in
    let rec loop llc : unit low_level option =
      match llc with
      | Lines body ->
          let body = Array.filter_map ~f:loop body in
          if Array.is_empty body then None else Some (Lines body)
      | For_loop { index; body; _ } when Map.mem env index -> loop body
      | For_loop { index; from_; to_; body } ->
          Option.map ~f:(fun body -> For_loop { index; from_; to_; body }) @@ loop body
      | If_task_id_is { for_task_id; body } ->
          Option.map ~f:(fun body -> If_task_id_is { for_task_id; body }) @@ loop body
      | Synchronize info -> Some (Synchronize info)
      | Reset_synchronizer -> Some Reset_synchronizer
      | Set (tensor, indices, llv) when NodeUI.equal_tensor_ptr tensor at_data ->
          assert ([%equal: index array option] (Some indices) def_args);
          Some (Set_local (id, loop_float llv))
      | Set _ -> None
      | Set_local (id, llv) -> Some (Set_local (id, loop_float llv))
      | Comment _ -> Some llc
      | Dynamic_indices dyn_idcs ->
          (* FIXME(132): implement virtual dynamic indices. *)
          Option.map ~f:(fun body -> Dynamic_indices { dyn_idcs with body }) @@ loop dyn_idcs.body
    and loop_float llv : float low_level =
      match llv with
      | Constant _ -> llv
      | Get (tensor, indices) when NodeUI.equal_tensor_ptr tensor at_data ->
          assert ([%equal: index array option] (Some indices) def_args);
          Get_local id
      | Get (tensor, indices) -> Get (tensor, Array.map ~f:subst indices)
      | Local_scope { id; prec; body; orig_indices } ->
          Local_scope
            { id; prec; body = Option.value_exn @@ loop body; orig_indices = Array.map ~f:subst orig_indices }
      | Get_local _ -> llv
      | Get_global _ -> llv
      | Binop (op, llv1, llv2) -> Binop (op, loop_float llv1, loop_float llv2)
      | Unop (op, llv) -> Unop (op, loop_float llv)
    in
    loop def
  in
  try Some (Lines (Array.filter_opt @@ Array.of_list_rev_map ~f:loop_proc node.computations))
  with Non_virtual ->
    node.non_virtual <- true;
    None

let virtual_llc node_store reverse_node_map (llc : unit low_level) : unit low_level =
  (* The current position is within scope of the definitions of the process_for virtual tensors. *)
  let rec loop_proc ~(process_for : tensor_ptrs) (llc : unit low_level) : unit low_level =
    let loop = loop_proc ~process_for in
    match llc with
    | Lines body -> Lines (Array.map ~f:loop body)
    | For_loop { index; from_; to_; body } -> (
        match Hashtbl.find reverse_node_map index with
        | Some tensor when not @@ Set.mem process_for tensor ->
            let node : data_node = Hashtbl.find_exn node_store tensor in
            let result = loop_proc ~process_for:(Set.add process_for tensor) llc in
            if not node.non_virtual then process_computation node_store node result;
            result
        | _ -> For_loop { index; from_; to_; body = loop body })
    | If_task_id_is { for_task_id; body } -> If_task_id_is { for_task_id; body = loop body }
    | Synchronize info -> Synchronize info
    | Reset_synchronizer -> Reset_synchronizer
    | Set (tensor, indices, llv) ->
        let node : data_node = Hashtbl.find_exn node_store tensor in
        let next = if node.non_virtual then process_for else Set.add process_for tensor in
        let result = Set (tensor, indices, loop_float ~process_for:next llv) in
        if (not @@ Set.mem process_for tensor) && not node.non_virtual then
          process_computation node_store node result;
        result
    | Set_local (id, llv) -> Set_local (id, loop_float ~process_for llv)
    | Comment _ -> llc
    | Dynamic_indices dyn_idcs ->
        (* FIXME(132): implement virtual dynamic indices. *)
        Dynamic_indices { dyn_idcs with body = loop dyn_idcs.body }
  and loop_float ~(process_for : tensor_ptrs) (llv : float low_level) : float low_level =
    match llv with
    | Constant _ -> llv
    | Get (tensor, _) when Set.mem process_for tensor ->
        (* [Get_local] will replace this [Get] during [inline_computation] if [tensor] remains virtual. *)
        llv
    | Get (tensor, indices) ->
        let node : data_node = get_node node_store tensor in
        if node.non_virtual then llv
        else
          let id = get_scope tensor in
          Option.value ~default:llv
          @@ Option.map (inline_computation ~id node indices) ~f:(fun body ->
                 Local_scope { id; prec = node.prec; body; orig_indices = indices })
    | Local_scope opts ->
        Local_scope { opts with body = loop_proc ~process_for:(Set.add process_for opts.id.tensor) opts.body }
    | Get_local _ -> llv
    | Get_global _ -> llv
    | Binop (op, llv1, llv2) -> Binop (op, loop_float ~process_for llv1, loop_float ~process_for llv2)
    | Unop (op, llv) -> Unop (op, loop_float ~process_for llv)
  in
  loop_proc ~process_for:Set.Poly.empty llc

let cleanup_virtual_llc node_store reverse_node_map (llc : unit low_level) : unit low_level =
  let is_inline tensor =
    let node = Hashtbl.find_exn node_store tensor in
    (virtualize_settings.inline_constants && Option.is_some node.scalar) || not node.non_virtual
  in
  (* The current position is within scope of the definitions of the process_for virtual tensors. *)
  let rec loop_proc ~(env_dom : sym_indices) (llc : unit low_level) : unit low_level option =
    let loop = loop_proc ~env_dom in
    match llc with
    | Lines body ->
        let body = Array.filter_map ~f:loop body in
        if Array.is_empty body then None else Some (Lines body)
    | For_loop { index; from_; to_; body } -> (
        let env_dom = Set.add env_dom index in
        match Hashtbl.find reverse_node_map index with
        | Some tensor ->
            if is_inline tensor then None
            else Option.map ~f:(fun body -> For_loop { index; from_; to_; body }) @@ loop_proc ~env_dom body
        | None -> Option.map ~f:(fun body -> For_loop { index; from_; to_; body }) @@ loop_proc ~env_dom body)
    | If_task_id_is { for_task_id; body } ->
        Option.map ~f:(fun body -> If_task_id_is { for_task_id; body }) @@ loop_proc ~env_dom body
    | Synchronize info -> Some (Synchronize info)
    | Reset_synchronizer -> Some Reset_synchronizer
    | Set (tensor, indices, llv) ->
        if is_inline tensor then None
        else (
          assert (Array.for_all indices ~f:(function Shape.Iterator s -> Set.mem env_dom s | _ -> true));
          Some (Set (tensor, indices, loop_float ~env_dom llv)))
    | Set_local (id, llv) ->
        let node = Hashtbl.find_exn node_store id.tensor in
        if virtualize_settings.inline_constants && Option.is_some node.scalar && not !debug_virtual_nodes then
          None
        else (
          assert (not node.non_virtual);
          Some (Set_local (id, loop_float ~env_dom llv)))
    | Comment _ -> Some llc
    | Dynamic_indices { tensor; tensor_idcs; dynamic_idcs; target_dims; body } ->
        assert (Array.for_all tensor_idcs ~f:(function Shape.Iterator s -> Set.mem env_dom s | _ -> true));
        (* Dynamic indices use a separate environment. *)
        (* FIXME(132): implement virtual dynamic indices. *)
        Option.map ~f:(fun body -> Dynamic_indices { tensor; tensor_idcs; dynamic_idcs; target_dims; body })
        @@ loop body
  and loop_float ~(env_dom : sym_indices) (llv : float low_level) : float low_level =
    let loop = loop_float ~env_dom in
    match llv with
    | Constant _ -> llv
    | Get (tensor, indices) -> (
        let node = get_node node_store tensor in
        match node.scalar with
        | Some c when virtualize_settings.inline_constants && !debug_virtual_nodes ->
            let id = get_scope tensor in
            Local_scope { id; prec = node.prec; body = Set_local (id, Constant c); orig_indices = indices }
        | Some c when virtualize_settings.inline_constants -> Constant c
        | _ ->
            if not node.non_virtual then
              Caml.Format.printf "WARNING: unexpected Get of a virtual tensor, details:@ %a\n%!" Sexp.pp_hum
                (sexp_of_data_node node);
            assert (Array.for_all indices ~f:(function Shape.Iterator s -> Set.mem env_dom s | _ -> true));
            llv)
    | Local_scope { id; prec; body; orig_indices } -> (
        let node = get_node node_store id.tensor in
        match node.scalar with
        | Some c when virtualize_settings.inline_constants && !debug_virtual_nodes ->
            Local_scope { id; prec; body = Set_local (id, Constant c); orig_indices }
        | Some c when virtualize_settings.inline_constants -> Constant c
        | _ ->
            assert (
              Array.for_all orig_indices ~f:(function Shape.Iterator s -> Set.mem env_dom s | _ -> true));
            if node.non_virtual then Get (id.tensor, orig_indices)
            else
              Option.value_or_thunk ~default:(fun () ->
                  Caml.Format.printf
                    "WARNING: unexpected non-eliminable virtual tensor:@ %a@ Compilation data:@ %a@ \
                     Compilation for the other tensor:@ %a@ Node:@ %a\n\
                     %!"
                    Sexp.pp_hum
                    (NodeUI.sexp_of_tensor_ptr id.tensor)
                    Sexp.pp_hum (sexp_of_data_node node) Sexp.pp_hum
                    (sexp_of_data_node @@ get_other_node node_store id.tensor)
                    Sexp.pp_hum
                    (NodeUI.sexp_of_t @@ NodeUI.get id.tensor.id);
                  Get (id.tensor, orig_indices))
              @@ Option.map ~f:(fun body -> Local_scope { id; prec; orig_indices; body })
              @@ loop_proc ~env_dom body)
    | Get_local id -> (
        let node = get_node node_store id.tensor in
        match node.scalar with
        | Some c when virtualize_settings.inline_constants -> Constant c
        | _ ->
            assert (not node.non_virtual);
            llv)
    | Get_global _ -> llv
    | Binop (op, llv1, llv2) -> Binop (op, loop llv1, loop llv2)
    | Unop (op, llv) -> Unop (op, loop llv)
  in
  Option.value_exn @@ loop_proc ~env_dom:Set.Poly.empty llc

let optimize_proc llc =
  let node_store : (NodeUI.tensor_ptr, data_node) Hashtbl.t = Hashtbl.Poly.create () in
  (* Identifies the computations that the code block associated with the symbol belongs to. *)
  let reverse_node_map : (sym_index, NodeUI.tensor_ptr) Hashtbl.t = Hashtbl.Poly.create () in
  if not virtualize_settings.virtualize then llc
  else
    let result =
      visit_llc node_store reverse_node_map ~max_visits:virtualize_settings.max_visits
        ~consider_grads:virtualize_settings.consider_grads llc;
      cleanup_virtual_llc node_store reverse_node_map @@ virtual_llc node_store reverse_node_map llc
    in
    let is_inline node =
      (virtualize_settings.inline_constants && Option.is_some node.scalar) || not node.non_virtual
    in
    Hashtbl.iter node_store ~f:(fun dn ->
        let n = NodeUI.get dn.id in
        if is_inline dn then
          if Option.is_none n.node.grad then n.virtual_ <- true
          else
            match
              Hashtbl.find node_store
                { id = dn.id; field = (if NodeUI.equal_data_kind dn.kind Value then Grad else Value) }
            with
            | Some other_n when not @@ is_inline other_n -> ()
            | _ -> n.virtual_ <- true);
    result

let compile_proc ~name proc =
  let result = optimize_proc @@ to_low_level proc in
  if !with_debug && !keep_files_in_run_directory then
    Stdio.Out_channel.write_all (name ^ ".llc")
      ~data:(Sexp.to_string_hum @@ sexp_of_low_level Unit.sexp_of_t result);
  result

let synchronizer = ref None

let interpret_task_id_func ~name:_ compiled ~task_id =
  if task_id = 0 then (
    synchronizer := Some (Synchronizer.make !Shape.num_parallel_tasks);
    if !debug_trace_interpretation then
      Caml.Format.printf "TRACE: Interpreted program:@ %a\n%!" Sexp.pp_hum
      @@ sexp_of_low_level Unit.sexp_of_t compiled)
  else
    while Option.is_none !synchronizer do
      Caml.Domain.cpu_relax ()
    done;
  interpret_code ~task_id (Option.value_exn !synchronizer) compiled;
  synchronizer := None

let interpret_unit_func ~name:_ compiled () =
  let synchronizer = Synchronizer.make 1 in
  interpret_code synchronizer compiled

module CDSL = struct
  let value_of_id id : NodeUI.tensor_ptr = { id; field = Value }
  let grad_of_id id : NodeUI.tensor_ptr = { id; field = Grad }
  let data_of_node field (n : NodeUI.t) : NodeUI.tensor_ptr = { id = n.id; field }
  let single = NodeUI.single
  let double = NodeUI.double
  let interpreter_print_comments = interpreter_print_comments
  let keep_files_in_run_directory = keep_files_in_run_directory
  let with_debug = with_debug
  let virtualize_settings = virtualize_settings
  let debug_virtual_nodes = debug_virtual_nodes
  let debug_trace_interpretation = debug_trace_interpretation
end
