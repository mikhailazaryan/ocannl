open Base

type mem_properties =
  | Local_only
      (** The array is only needed for a single computation and is allocated locally (or spilled). *)
  | Global  (** Could not perform optimizations: the array is computed directly in the global memory. *)
[@@deriving sexp, equal, compare, variants]

type ndarray = {
  hosted : Ndarray.t option;
  global : (string * (Cudajit.deviceptr[@sexp.opaque])) option;  (** A global device array, if any. *)
  local : string option;  (** A local name, if any. *)
  mem : mem_properties;
  dims : int array;
  size_in_bytes : int;
  size_in_elems : int;
  num_typ : string;
      (** The type of the stored values: [short] (precision [Half]), [float] (precision [Single]), [double]
          (precision [Double]). *)
  is_double : bool;
}
[@@deriving sexp_of]

module Tn = Tnode

type device = {
  dev : (Cudajit.device[@sexp.opaque]);
  ordinal : int;
  primary_context : (Cudajit.context[@sexp.opaque]);
}
[@@deriving sexp_of]

type context = {
  label : string;
  ctx : (Cudajit.context[@sexp.opaque]);
  device : device;
  run_module : (Cudajit.module_[@sexp.opaque]) option;
      (** Code jitted for this context, independent of the parent and child contexts. *)
  arrays : ndarray Map.M(Tn).t;
}
[@@deriving sexp_of]

type ctx_info = {
  ctx : Cudajit.context;  (** Context for jitting, independent of the parent and child contexts. *)
  mutable ctx_arrays : ndarray Map.M(Tn).t;
  used_tensors : Hash_set.M(Tn).t;
}

let init device =
  {
    label = "cuda " ^ Int.to_string device.ordinal;
    ctx = device.primary_context;
    device;
    arrays = Map.empty (module Tn);
    run_module = None;
  }

let is_initialized, initialize =
  let initialized = ref false in
  ( (fun () -> !initialized),
    fun () ->
      initialized := true;
      Cudajit.init () )

let num_devices = Cudajit.device_get_count
let devices = ref @@ Core.Weak.create 0

let get_device ~ordinal =
  if num_devices () <= ordinal then
    invalid_arg [%string "Exec_as_cuda.get_device %{ordinal#Int}: not enough devices"];
  if Core.Weak.length !devices <= ordinal then (
    let old = !devices in
    devices := Core.Weak.create (ordinal + 1);
    Core.Weak.blit old 0 !devices 0 (Core.Weak.length old));
  Option.value_or_thunk (Core.Weak.get !devices ordinal) ~default:(fun () ->
      let dev = Cudajit.device_get ~ordinal in
      let primary_context = Cudajit.device_primary_ctx_retain dev in
      let result = { dev; ordinal; primary_context } in
      Core.Weak.set !devices ordinal (Some result);
      result)

let get_ctx_device { device; _ } = device
let to_ordinal { ordinal; _ } = ordinal

let set_ctx ctx =
  let cur_ctx = Cudajit.ctx_get_current () in
  if not @@ phys_equal ctx cur_ctx then Cudajit.ctx_set_current ctx

let finalize ctx =
  if Option.is_some @@ Core.Weak.get !devices ctx.device.ordinal then (
    set_ctx ctx.device.primary_context;
    Option.iter ctx.run_module ~f:Cudajit.module_unload;
    Map.iter ctx.arrays ~f:(fun array -> Option.iter array.global ~f:(fun (_, ptr) -> Cudajit.mem_free ptr)))

let unsafe_cleanup ?unsafe_shutdown:_ () =
  let len = Core.Weak.length !devices in
  (* TODO: maybe better to do device_primary_ctx_reset if [unsafe_shutdown=false]. *)
  for i = 0 to len - 1 do
    Option.iter (Core.Weak.get !devices i) ~f:(fun device -> Cudajit.device_primary_ctx_release device.dev)
  done;
  Core.Weak.fill !devices 0 len None

let await device =
  set_ctx device.primary_context;
  Cudajit.ctx_synchronize ()

let from_host (ctx : context) la =
  match Map.find ctx.arrays la with
  | None -> false
  | Some array -> (
      match (array.hosted, array.global) with
      | Some hosted, Some (_, dst) ->
          set_ctx ctx.ctx;
          let f src = Cudajit.memcpy_H_to_D ~dst ~src () in
          Ndarray.map { f } hosted;
          true
      | _ -> false)

let to_host (ctx : context) la =
  match Map.find ctx.arrays la with
  | None -> false
  | Some array -> (
      match (array.hosted, array.global) with
      | Some hosted, Some (_, src) ->
          set_ctx ctx.ctx;
          let f dst = Cudajit.memcpy_D_to_H ~dst ~src () in
          Ndarray.map { f } hosted;
          true
      | _ -> false)

let merge ?(name_suffix = "") la ~dst ~accum ~src (bindings : Indexing.unit_bindings) =
  let ord ctx = ctx.device.ordinal in
  let name =
    [%string "merge_into_%{Tn.name la}_on_dev_%{ord dst#Int}_from_dev_%{ord src#Int}_%{name_suffix}"]
  in
  ignore (name, accum, bindings);
  failwith "NOT IMPLEMENTED YET"

(* let pp_semi ppf () = Stdlib.Format.fprintf ppf ";@ " *)
let pp_comma ppf () = Stdlib.Format.fprintf ppf ",@ "

(* let pp_symbol ppf sym = Stdlib.Format.fprintf ppf "%s" @@ Indexing.symbol_ident sym *)
let pp_index ppf sym = Stdlib.Format.fprintf ppf "%s" @@ Indexing.symbol_ident sym

let pp_index_axis ppf = function
  | Indexing.Iterator it -> pp_index ppf it
  | Fixed_idx i -> Stdlib.Format.fprintf ppf "%d" i

let pp_array_offset ppf (idcs, dims) =
  let open Stdlib.Format in
  assert (not @@ Array.is_empty idcs);
  for _ = 0 to Array.length idcs - 3 do
    fprintf ppf "@[<1>("
  done;
  for i = 0 to Array.length idcs - 1 do
    let dim = dims.(i) in
    if i = 0 then fprintf ppf "%a" pp_index_axis idcs.(i)
    else if i = Array.length idcs - 1 then fprintf ppf " * %d +@ %a" dim pp_index_axis idcs.(i)
    else fprintf ppf " * %d +@ %a@])" dim pp_index_axis idcs.(i)
  done

let array_offset_to_string (idcs, dims) =
  let b = Buffer.create 32 in
  let ppf = Stdlib.Format.formatter_of_buffer b in
  pp_array_offset ppf (idcs, dims);
  Stdlib.Format.pp_print_flush ppf ();
  Buffer.contents b

let get_run_ptr array =
  match (array.global, array.local) with
  | _, Some lv -> lv
  | Some (rv, _), _ -> rv
  | None, None -> assert false

let get_run_ptr_debug array =
  match (array.global, array.local) with
  | _, Some lv -> "local_" ^ lv
  | Some (rv, _), _ -> "global_" ^ rv
  | None, None -> assert false

let prec_to_c_type = function
  | Ops.Void_prec -> "void"
  | Byte_prec _ -> "uint8"
  | Half_prec _ -> (* FIXME: *) "uint16"
  | Single_prec _ -> "float"
  | Double_prec _ -> "double"

(* let compute_array_offset ~idcs ~dims = Array.fold2_exn idcs dims ~init:0 ~f:(fun offset idx dim -> idx +
   (offset * dim)) *)

module Debug_runtime = Utils.Debug_runtime

let%debug_sexp get_array ~traced_store:_ ctx_info key =
  Hash_set.add ctx_info.used_tensors key;
  let default () =
    (* let tn = Low_level.get_node traced_store v in *)
    (* TODO: We will need tn to perform more refined optimizations. *)
    let dims = Lazy.force key.dims in
    let size_in_elems = Array.fold ~init:1 ~f:( * ) dims in
    let hosted = Lazy.force key.array in
    let size_in_bytes = size_in_elems * Ops.prec_in_bytes key.prec in
    let is_on_host = Tn.is_hosted_force key 31 in
    let is_materialized = Tn.is_hosted_force key 32 in
    assert (Bool.(Option.is_some hosted = is_on_host));
    let is_double = Ops.is_double_prec key.prec in
    let num_typ = prec_to_c_type key.prec in
    let mem = if not is_materialized then Local_only else Global in
    let global =
      if is_local_only mem then None
      else (
        if Utils.settings.with_debug then [%log "mem_alloc", Tn.name key];
        set_ctx ctx_info.ctx;
        Some (Tn.name key, Cudajit.mem_alloc ~byte_size:size_in_bytes))
    in
    let local = Option.some_if (is_local_only mem) @@ Tn.name key ^ "_local" in
    let backend_info = sexp_of_mem_properties mem in
    if Utils.settings.with_debug then
      [%log
        "creating",
          (key.id : int),
          Tn.label key,
          "mem",
          (backend_info : Sexp.t),
          "on-host",
          (is_on_host : bool),
          "is-global",
          (Option.is_some global : bool)];
    if not @@ Utils.sexp_mem ~elem:backend_info key.backend_info then
      key.backend_info <- Utils.sexp_append ~elem:backend_info key.backend_info;
    let data = { hosted; local; mem; dims; size_in_bytes; size_in_elems; num_typ; is_double; global } in
    ctx_info.ctx_arrays <- Map.add_exn ctx_info.ctx_arrays ~key ~data;
    data
  in
  Option.value_or_thunk (Map.find ctx_info.ctx_arrays key) ~default

let jit_code ~traced_store info ppf llc : unit =
  let open Stdlib.Format in
  let locals = ref @@ Map.empty (module Low_level.Scope_id) in
  let rec pp_ll ppf c : unit =
    match c with
    | Low_level.Noop -> ()
    | Seq (c1, c2) ->
        (* Note: no separator. Filter out some entries known to not generate code to avoid whitespace. *)
        fprintf ppf "@[<v 0>%a@]" (pp_print_list pp_ll)
          (List.filter [ c1; c2 ] ~f:(function
            | Noop -> false
            | Zero_out ptr -> not Low_level.(get_node traced_store ptr).zero_initialized
            | _ -> true))
    | For_loop { index = i; from_; to_; body; trace_it = _ } ->
        fprintf ppf "@[<2>for (unsigned int@ %a = %d;@ %a <= %d;@ ++%a) {@ %a@]@ }@," pp_index i from_
          pp_index i to_ pp_index i pp_ll body
    | Zero_out array ->
        if Map.mem info.ctx_arrays array then
          failwith
            ("exec_as_cuda: Non-initialization zeroing-out NOT IMPLEMENTED YET: " ^ Sexp.to_string_hum
            @@ [%sexp_of: Tn.t] array);
        let tn = Low_level.(get_node traced_store array) in
        assert tn.zero_initialized
        (* The initialization will be emitted by get_array. *)
    | Set { array; idcs; llv; debug } ->
        let array = get_array ~traced_store info array in
        let old_locals = !locals in
        let loop_f = pp_float ~num_typ:array.num_typ ~is_double:array.is_double in
        let loop_debug_f = debug_float ~num_typ:array.num_typ ~is_double:array.is_double in
        let num_closing_braces = pp_top_locals ppf llv in
        (* No idea why adding any cut hint at the end of the assign line breaks formatting! *)
        fprintf ppf "@[<2>%s[@,%a] =@ %a;@]@ " (get_run_ptr array) pp_array_offset (idcs, array.dims) loop_f
          llv;
        (if Utils.settings.debug_log_from_routines then
           let v_code, v_idcs = loop_debug_f llv in
           let pp_args =
             pp_print_list @@ fun ppf -> function
             | `Accessor idx ->
                 pp_comma ppf ();
                 pp_array_offset ppf idx
             | `Value v ->
                 pp_comma ppf ();
                 pp_print_string ppf v
           in
           let run_ptr_debug = get_run_ptr_debug array in
           let run_ptr = get_run_ptr array in
           let offset = (idcs, array.dims) in
           (* FIXME: does this work or should \n be \\n? *)
           let debug_line = "# " ^ String.substr_replace_all debug ~pattern:"\n" ~with_:"$" ^ "\n" in
           fprintf ppf
             "@ @[<2>if @[<2>(threadIdx.x == 0 && blockIdx.x == 0@]) {@ printf(\"%s\");@ \
              printf(@[<h>\"%s[%%u] = %%f = %s\\n\"@],@ %a,@ %s[%a]%a);@ @]}"
             debug_line run_ptr_debug v_code pp_array_offset offset run_ptr pp_array_offset offset pp_args
             v_idcs);
        for _ = 1 to num_closing_braces do
          fprintf ppf "@]@ }@,"
        done;
        locals := old_locals
    | Comment message ->
        if Utils.settings.debug_log_from_routines then
          fprintf ppf
            "@[<2>if @[<2>(threadIdx.x == 0 && blockIdx.x == 0@]) {@ printf(@[<h>\"COMMENT: %s\\n\"@]);@ @]}"
            (String.substr_replace_all ~pattern:"%" ~with_:"%%" message)
        else fprintf ppf "/* %s */@ " message
    | Staged_compilation callback -> callback ()
    | Set_local (({ scope_id; _ } as id), value) ->
        let num_typ, is_double = Map.find_exn !locals id in
        let old_locals = !locals in
        let num_closing_braces = pp_top_locals ppf value in
        fprintf ppf "@[<2>v%d =@ %a;@]" scope_id (pp_float ~num_typ ~is_double) value;
        for _ = 1 to num_closing_braces do
          fprintf ppf "@]@ }@,"
        done;
        locals := old_locals
  and pp_top_locals ppf (vcomp : Low_level.float_t) : int =
    match vcomp with
    | Local_scope { id = { scope_id = i; _ } as id; prec; body; orig_indices = _ } ->
        let typ = prec_to_c_type prec in
        (* Arrays are initialized to 0 by default. However, there is typically an explicit initialization for
           virtual nodes. *)
        fprintf ppf "@[<2>{@ %s v%d = 0;@ " typ i;
        locals := Map.update !locals id ~f:(fun _ -> (typ, Ops.is_double_prec prec));
        pp_ll ppf body;
        pp_print_space ppf ();
        1
    | Get_local _ | Get_global _ | Get _ | Constant _ | Embed_index _ -> 0
    | Binop (Arg1, v1, _v2) -> pp_top_locals ppf v1
    | Binop (Arg2, _v1, v2) -> pp_top_locals ppf v2
    | Binop (_, v1, v2) -> pp_top_locals ppf v1 + pp_top_locals ppf v2
    | Unop (_, v) -> pp_top_locals ppf v
  and pp_float ~num_typ ~is_double ppf value =
    let loop = pp_float ~num_typ ~is_double in
    match value with
    | Local_scope { id; _ } ->
        (* Embedding of Local_scope is done by pp_top_locals. *)
        loop ppf @@ Get_local id
    | Get_local id ->
        let typ, _local_is_double = Map.find_exn !locals id in
        if not @@ String.equal num_typ typ then fprintf ppf "(%s)" num_typ;
        fprintf ppf "v%d" id.scope_id
    | Get_global _ -> failwith "Exec_as_cuda: Get_global / FFI NOT IMPLEMENTED YET"
    | Get (array, idcs) ->
        let array = get_array ~traced_store info array in
        fprintf ppf "@[<2>%s[%a@]]" (get_run_ptr array) pp_array_offset (idcs, array.dims)
    | Constant c -> fprintf ppf "(%f)" c
    | Embed_index idx ->
        if not @@ List.exists ~f:(String.equal num_typ) [ "int"; "size_t" ] then fprintf ppf "(%s)" num_typ;
        pp_index_axis ppf idx
    | Binop (Arg1, v1, _v2) -> loop ppf v1
    | Binop (Arg2, _v1, v2) -> loop ppf v2
    | Binop (op, v1, v2) ->
        let prefix, infix, postfix = Ops.binop_C_syntax ~is_double op in
        fprintf ppf "@[<1>%s%a%s@ %a@]%s" prefix loop v1 infix loop v2 postfix
    | Unop (Identity, v) -> loop ppf v
    | Unop (Relu, v) ->
        (* FIXME: don't recompute v *)
        fprintf ppf "@[<1>(%a > 0.0 ?@ %a : 0.0@])" loop v loop v
  and debug_float ~num_typ ~is_double (value : Low_level.float_t) : string * 'a list =
    let loop = debug_float ~num_typ ~is_double in
    match value with
    | Local_scope { id; _ } ->
        (* Not printing the inlined definition: (1) code complexity; (2) don't overload the debug logs. *)
        loop @@ Get_local id
    | Get_local id ->
        let typ, _local_is_double = Map.find_exn !locals id in
        let v =
          (if not @@ String.equal num_typ typ then "(" ^ num_typ ^ ")" else "")
          ^ "v" ^ Int.to_string id.scope_id
        in
        (v ^ "{=%f}", [ `Value v ])
    | Get_global _ -> failwith "Exec_as_cuda: Get_global / FFI NOT IMPLEMENTED YET"
    | Get (ptr, idcs) ->
        let array = get_array ~traced_store info ptr in
        let v = sprintf "@[<2>%s[%s@]]" (get_run_ptr array) (array_offset_to_string (idcs, array.dims)) in
        (get_run_ptr_debug array ^ "[%u]{=%f}", [ `Accessor (idcs, array.dims); `Value v ])
    | Constant c -> (Float.to_string c, [])
    | Embed_index (Fixed_idx i) -> (Int.to_string i, [])
    | Embed_index (Iterator s) -> (Indexing.symbol_ident s, [])
    | Binop (Arg1, v1, _v2) -> loop v1
    | Binop (Arg2, _v1, v2) -> loop v2
    | Binop (op, v1, v2) ->
        let prefix, infix, postfix = Ops.binop_C_syntax ~is_double op in
        let v1, idcs1 = loop v1 in
        let v2, idcs2 = loop v2 in
        (String.concat [ prefix; v1; infix; " "; v2; postfix ], idcs1 @ idcs2)
    | Unop (Identity, v) -> loop v
    | Unop (Relu, v) ->
        let v, idcs = loop v in
        (String.concat [ "("; v; " > 0.0 ? "; v; " : 0.0)" ], idcs @ idcs)
  in
  pp_ll ppf llc

let%debug_sexp jit_func ~name (old_context : context) idx_params (traced_store, llc) =
  set_ctx old_context.ctx;
  [%log "generating the .cu source"];
  let info =
    { ctx = old_context.ctx; ctx_arrays = old_context.arrays; used_tensors = Hash_set.create (module Tn) }
  in
  let b = Buffer.create 4096 in
  let ppf = Stdlib.Format.formatter_of_buffer b in
  jit_code ~traced_store info ppf llc;
  Stdlib.Format.pp_print_newline ppf ();
  let cu_body = Buffer.contents b in
  let arrays = Hash_set.to_list info.used_tensors in
  let params, args =
    List.unzip
    @@ List.filter_map arrays ~f:(fun la ->
           let tn = Map.find_exn info.ctx_arrays la in
           if Utils.settings.with_debug then
             [%log "array-used:", (la : Tn.t), Tn.label la, (tn.mem : mem_properties)];
           match tn.mem with
           | Local_only -> None
           | Global -> Option.map tn.global ~f:(fun (n, ptr) -> (tn.num_typ ^ " *" ^ n, ptr)))
  in
  let idx_params =
    List.map idx_params ~f:(fun { Indexing.static_symbol; _ } -> "int " ^ Indexing.symbol_ident static_symbol)
  in
  (* TODO: optimize zero-initializations? E.g.
     https://stackoverflow.com/questions/23712558/how-do-i-best-initialize-a-local-memory-array-to-0 *)
  let thread_decls =
    List.filter_map arrays ~f:(fun la ->
        let tn = Map.find_exn info.ctx_arrays la in
        match tn.mem with
        | Local_only ->
            Option.map tn.local ~f:(fun t_name ->
                tn.num_typ ^ " " ^ t_name ^ "[" ^ Int.to_string tn.size_in_elems
                ^ if (Hashtbl.find_exn traced_store la).zero_initialized then "] = {0};" else "];")
        | _ -> None)
  in
  let cu_src =
    [%string
      {|
%{if Utils.settings.debug_log_from_routines then "__device__ int printf (const char * format, ... );" else ""}
extern "C" __global__ void %{name}(%{String.concat ~sep:", " @@ idx_params @ params}) {
  /* TODO: this initial toy prototype is single-threaded. */
  if (threadIdx.x != 0 || blockIdx.x != 0) { return; }
  
  /* Thread-local declarations. */
  %{String.concat ~sep:"\n  " thread_decls}

  /* Main logic. */
  %{String.substr_replace_all cu_body ~pattern:"\n" ~with_:"\n  "}
}
|}]
  in
  let f_name = name ^ "-cudajit-debug" in
  if Utils.settings.output_debug_files_in_run_directory then (
    let oc = Out_channel.open_text @@ f_name ^ ".cu" in
    Stdio.Out_channel.output_string oc cu_src;
    Stdio.Out_channel.flush oc;
    Stdio.Out_channel.close oc);
  [%log "compiling to PTX"];
  let module Cu = Cudajit in
  let ptx =
    Cu.compile_to_ptx ~cu_src ~name ~options:[ "--use_fast_math" ] ~with_debug:Utils.settings.with_debug
  in
  if Utils.settings.output_debug_files_in_run_directory then (
    let f_name = name ^ "-cudajit-debug" in
    let oc = Out_channel.open_text @@ f_name ^ ".ptx" in
    Stdio.Out_channel.output_string oc @@ Cu.string_from_ptx ptx;
    Stdio.Out_channel.flush oc;
    Stdio.Out_channel.close oc;
    let oc = Out_channel.open_text @@ f_name ^ ".cu_log" in
    Stdio.Out_channel.output_string oc @@ Option.value_exn ptx.log;
    Stdio.Out_channel.flush oc;
    Stdio.Out_channel.close oc);
  let run_module = Cu.module_load_data_ex ptx [] in
  let func = Cu.module_get_function run_module ~name in
  let args = List.map args ~f:(fun p -> Cu.Tensor p) in
  [%log "compilation finished"];
  (func, args, run_module, info)

let jit ?name old_context bindings ((traced_store, llc) as compiled) =
  let name : string = Option.value_or_thunk name ~default:(fun () -> Low_level.extract_block_name [ llc ]) in
  let idx_params = Indexing.bound_symbols bindings in
  let func, args, run_module, info = jit_func ~name old_context idx_params compiled in
  let context = { old_context with ctx = info.ctx; run_module = Some run_module; arrays = info.ctx_arrays } in
  let idx_args = List.map idx_params ~f:(fun s -> (s, ref 0)) in
  let%diagn_sexp schedule () =
    [%log_result "Scheduling", name];
    let module Cu = Cudajit in
    let idx_args =
      List.map idx_args ~f:(fun ({ static_symbol; static_range }, i) ->
          if !i < 0 then
            raise
            @@ Utils.User_error
                 [%string
                   "Exec_as_cuda: static index %{Indexing.symbol_ident static_symbol} is negative: %{!i#Int}"];
          Option.iter static_range ~f:(fun upto ->
              if !i >= upto then
                raise
                @@ Utils.User_error
                     [%string
                       "Exec_as_cuda: static index %{Indexing.symbol_ident static_symbol} is too big: \
                        %{upto#Int}"]);
          Cu.Int !i)
    in
    let%diagn_rt_sexp work () : unit =
      [%log "zeroing-out global memory"];
      set_ctx context.ctx;
      Map.iteri context.arrays ~f:(fun ~key:ptr ~data ->
          if Hash_set.mem info.used_tensors ptr then
            match data with
            | { global = Some (_, dev_ptr); size_in_bytes; _ } ->
                let tn = Hashtbl.find_exn traced_store ptr in
                if tn.zero_initialized then Cu.memset_d8 dev_ptr Unsigned.UChar.zero ~length:size_in_bytes
            | _ -> ());
      [%log "launching the kernel"];
      (* if Utils.settings.debug_log_from_routines then Cu.ctx_set_limit CU_LIMIT_PRINTF_FIFO_SIZE 4096; *)
      Cu.launch_kernel func ~grid_dim_x:1 ~block_dim_x:1 ~shared_mem_bytes:0 Cu.no_stream @@ idx_args @ args;
      [%log "kernel launched"]
    in
    Tnode.Work work
  in
  (context, idx_args, schedule)
