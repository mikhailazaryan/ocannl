(** Tensor shape types, shape inference, projection inference. *)

open Base
module Utils = Arrayjit.Utils

(** *** Shape types and inference *** *)

(** An index pointing to any of a shape's axes, including the kind of the axis ([Batch, Input, Output])
    and the position (which is counted from the end to facilitate broadcasting).

    Note the following inconsistency due to differing conventions in function notation and matrix notation:
    for label specifications and einsum notation, we write "batch|inputs->outputs", but when we convert
    a shape to an [Ndarray] index we do it in the order [[batch; outputs; inputs]]. *)
module AxisKey = struct
  module T = struct
    type kind = Batch | Input | Output [@@deriving equal, compare, sexp, hash, variants]

    type t = {
      in_axes : kind;
      from_end : int;
          (** Axes are indexed from the end, to avoid reindexing when broadcasting; starting with [1]. *)
    }
    [@@deriving equal, compare, sexp]

    let to_string key =
      (match key.in_axes with Batch -> "bch" | Input -> "inp" | Output -> "out")
      ^ Int.to_string key.from_end
  end

  include T
  include Comparator.Make (T)
end

type 'a axis_map = 'a Map.M(AxisKey).t [@@deriving compare, sexp]

type parsed_axis_labels = {
  bcast_batch : bool;
  bcast_input : bool;
  bcast_output : bool;
  given_batch : int;
  given_input : int;
  given_output : int;
  labels : (string, int) Either.t axis_map;
}
[@@deriving compare, sexp, fields]
(** The labels are strings assigned to [AxisKey] axes. Moreover the [bcast_] fields represent whether
    additional leading axes are allowed (corresponding to the dot-ellipsis syntax for broadcasting).
    The [given_] fields count the number of specified axes of the corresponding kind in [labels]. *)

let bcast_of_kind = function
  | AxisKey.Batch -> bcast_batch
  | AxisKey.Input -> bcast_input
  | AxisKey.Output -> bcast_output

let given_of_kind = function
  | AxisKey.Batch -> given_batch
  | AxisKey.Input -> given_input
  | AxisKey.Output -> given_output

module Dim_var = struct
  type t = { id : int; mutable label : string option [@compare.ignore] [@equal.ignore] [@hash.ignore] }
  [@@deriving equal, hash, compare, sexp]

  include Comparator.Make (struct
    type nonrec t = t

    let compare = compare
    let sexp_of_t = sexp_of_t
  end)
end

type dim_var = Dim_var.t [@@deriving equal, hash, compare, sexp]

(** A single axis in a shape. *)
type dim = Var of dim_var | Dim of { d : int; label : string option; proj_id : int }
[@@deriving equal, hash, compare, sexp, variants]

let uid = ref 0

let get_var ?label () : dim_var =
  Int.incr uid;
  { id = !uid; label }

let get_dim ~d ?label () =
  Int.incr uid;
  Dim { d; proj_id = !uid; label }

(** A row specifies how axes of a single kind in a shape (the shape-kind) can adapt to other shapes. *)
type row =
  | Row_var of int  (** The shape-kind can be inferred to have more axes. *)
  | Broadcastable  (** The shape does not have more axes of this kind, but is "polymorphic". *)
  | Fixed  (** A row variable of a subtensor shape will get determined from this row. *)
[@@deriving equal, hash, compare, sexp, variants]

type dims_constraint =
  | Unconstrained
  | Total_elems of int  (** The shape-kind, inclusive of the further row spec, has this many elements. *)
[@@deriving equal, hash, compare, sexp, variants]

let get_row_var () =
  Int.incr uid;
  Row_var !uid

module Row_id = struct
  type t = { sh_id : int; kind : AxisKey.kind } [@@deriving sexp, compare, equal, hash]

  include Comparator.Make (struct
    type nonrec t = t

    let compare = compare
    let sexp_of_t = sexp_of_t
  end)
end

type row_id = Row_id.t [@@deriving sexp, compare, equal, hash]

type dims = { dims : dim list; constr : dims_constraint; row : row; id : row_id }
[@@deriving equal, hash, compare, sexp]

type deduce_within_shape = Not_constrained | Input_equals_output [@@deriving compare, sexp, variants]

type t = {
  mutable batch : dims;
  mutable input : dims;
  mutable output : dims;
  id : int;  (** A node that has the same shape as this shape. *)
  debug_name : string;
}
[@@deriving equal, fields, sexp]
(** The datatype from which the actual Tensor shapes are computed.

    Mutability is sufficient to perform inference, since there is no need for backtracking and
    no explicit unification variables for now. [Unknown] stands for "not yet specified". *)

let dims_of_kind = function AxisKey.Batch -> batch | AxisKey.Input -> input | AxisKey.Output -> output

let map_over_kind ~f kind sh =
  match kind with
  | AxisKey.Batch -> { sh with batch = f sh.batch }
  | AxisKey.Input -> { sh with input = f sh.input }
  | AxisKey.Output -> { sh with output = f sh.output }

let update_kind ~f kind sh =
  match kind with
  | AxisKey.Batch -> sh.batch <- f sh.batch
  | AxisKey.Input -> sh.input <- f sh.input
  | AxisKey.Output -> sh.output <- f sh.output

type compose_type =
  | Pointwise_bin  (** NumPy-style broadcast matching batch, input and output axes, e.g. as in [s1 + s2]. *)
  | Compose
      (** Compose the outputs of the second shape with the inputs of the first shape, i.e. the shape of
      [fun x -> s1(s2(x))], or [s1 * s2] where [*] is the inner product (e.g. matrix multiply). *)
  | Einsum of string
      (** The [einsum] syntax: LABELS1;LABELS2=>LABELS3, where LABELSi are labels specifications.
      Note that currently [Compose] is not redundant with [Einsum], because it enables more shape
      inference: [Einsum] is limited to [Pointwise_bin]-like broadcasting, while [Compose] broadcasts
      inputs of the "operator" against outputs of the "operand" (matching up an arbitrary number of axes).
      The [axis_labels] use pseudo-labels local to the notation, to line up the axes.
      For [Einsum (ls1^";"^ls2^"=>"^ls3)], the symmetric difference / disjunctive union of [ls1] and [ls2]'s
      pseudo-labels should be equal to [ls3] pseudo-labels.

      Currently, we support two variants of the [einsum] syntax: either all the axes are provided,
      or all input, output axes are provided but none of the batch axes.
      Note: The "right-hand-side" is on the left! I.e. the syntax is "rhs=>lhs", "rhs1;rhs2=>lhs". *)
[@@deriving sexp, equal]

type transpose_type =
  | Transpose  (** Swaps inputs and outputs of a shape, preserves batch axes. *)
  | Pointwise_un  (** Preserves the shape. *)
  | Permute of string
      (** [Permute (ls1^"=>"^ls2)] is a variant of the [einsum] syntax [Einsum (ls1^";"^ls1^"=>"^ls2)].
      Note: The "right-hand-side" is on the left! I.e. the syntax is "rhs=>lhs", "rhs1;rhs2=>lhs". *)
  | Batch_slice of Arrayjit.Indexing.static_symbol  (** Removes the leftmost batch axis. *)
[@@deriving equal, sexp]

(** Parses a labels specification.

  * If [spec] contains any of: [' '; ','; '('; ')'], these characters are used as label separators.
    Otherwise, every character is a label.
  * If [spec] does not contain ["|"] nor ["->"], each label is of the kind [Output].
  * If [spec] doesn't contain ["|"], labels to the left of ["->"] are [Input] and to the right [Output].
  * Labels to the left of ["|"] are [Batch], and between ["|"] and ["->"] are [Input].

    The label ["..."] is only allowed at the first axis of a kind (i.e. last from-end).
    It is used to enable broadcasting for the axis kind in the einsum-related shape inference
    (like the ellipsis ["..."] in [numpy.einsum]).

    The label ["_"] is a place-holder: it is not output to the resulting map but aligns the axes
    of other labels. *)
let axis_labels_of_spec spec : parsed_axis_labels =
  let check_dot s =
    if String.length s > 3 && (Option.is_some @@ String.substr_index ~pos:3 s ~pattern:"...") then
      invalid_arg ("axis_labels_of_spec: dot only allowed at first axis of a kind: " ^ spec)
    else if String.is_prefix s ~prefix:"..." then (true, String.drop_prefix s 3)
    else (false, s)
  in
  let parse spec in_axes =
    let bcast, spec = check_dot @@ String.strip spec in
    ( bcast,
      let on = [ ' '; ','; '('; ')'; '\t'; '\r'; '\n' ] in
      let parse_label labels_num from_start s =
        let key = AxisKey.{ in_axes; from_end = labels_num - from_start } in
        if String.equal s "_" then None
        else try Some (key, Either.Second (Int.of_string s)) with _ -> Some (key, First s)
      in
      if List.exists ~f:(String.contains spec) on then
        let labels = String.split_on_chars spec ~on |> List.filter ~f:(fun s -> not @@ String.is_empty s) in
        let labels_num = List.length labels in
        (labels_num, List.filter_mapi labels ~f:(parse_label labels_num) |> Map.of_alist_exn (module AxisKey))
      else
        let labels_num = String.length spec in
        ( labels_num,
          String.to_list spec |> List.map ~f:String.of_char
          |> List.filter_mapi ~f:(parse_label labels_num)
          |> Map.of_alist_exn (module AxisKey) ) )
  in
  let batch_spec, spec =
    match String.substr_index spec ~pattern:"|" with
    | Some end_bch ->
        ( String.sub ~pos:0 ~len:end_bch spec,
          String.sub ~pos:(end_bch + 1) ~len:(String.length spec - end_bch - 1) spec )
    | None -> ("", spec)
  in
  let input_spec, output_spec =
    match String.substr_index spec ~pattern:"->" with
    | Some end_inp ->
        ( String.sub ~pos:0 ~len:end_inp spec,
          String.sub ~pos:(end_inp + 2) ~len:(String.length spec - end_inp - 2) spec )
    | None -> ("", spec)
  in
  let bcast_batch, (given_batch, batch_labels) = parse batch_spec Batch in
  let bcast_input, (given_input, input_labels) = parse input_spec Input in
  let bcast_output, (given_output, output_labels) = parse output_spec Output in
  let labels =
    match Map.append ~lower_part:input_labels ~upper_part:output_labels with
    | `Ok m -> (
        match Map.append ~lower_part:batch_labels ~upper_part:m with `Ok r -> r | _ -> assert false)
    | _ -> assert false
  in
  { bcast_batch; bcast_input; bcast_output; given_batch; given_input; given_output; labels }

let einsum_of_spec spec =
  let rhs_spec, lhs_spec =
    match String.substr_index spec ~pattern:"=>" with
    | Some endp ->
        ( String.sub ~pos:0 ~len:endp spec,
          String.sub ~pos:(endp + 2) ~len:(String.length spec - endp - 2) spec )
    | None -> ("", spec)
  in
  let lhs_spec = String.strip lhs_spec in
  let rhs_spec = String.strip rhs_spec in
  if String.is_empty lhs_spec then invalid_arg ("einsum_of_spec: missing the result spec in " ^ spec);
  if String.is_empty rhs_spec then invalid_arg ("einsum_of_spec: missing the argument spec in " ^ spec);
  let rhs1_spec, rhs2_spec =
    match String.substr_index rhs_spec ~pattern:";" with
    | Some endp ->
        ( String.sub ~pos:0 ~len:endp rhs_spec,
          String.sub ~pos:(endp + 1) ~len:(String.length rhs_spec - endp - 1) rhs_spec )
    | None -> (rhs_spec, "")
  in
  let rhs1_spec = String.strip rhs1_spec in
  let rhs2_spec = String.strip rhs2_spec in
  let lhs_ls = axis_labels_of_spec lhs_spec in
  let rhs1_ls = axis_labels_of_spec rhs1_spec in
  if String.is_empty rhs2_spec then (rhs1_ls, None, lhs_ls)
  else (rhs1_ls, Some (axis_labels_of_spec rhs2_spec), lhs_ls)

(** How to propagate shape updates and do the last update of [Tensor.t.shape] when finalizing the tensor.
    Axes are broadcast-expanded on a bottom-up update to fit the incoming shape. *)
type logic =
  | Broadcast of compose_type * t * t
      (** Matches the shapes for a binary operation, allowing for broadcasting e.g. an axis of dimension 1
      does not conflict with a matching axis of a greater dimension.

      For [Broadcast (Einsum (ls1, ls2, ls3), s1, s2)], the labels of [s1] and [s2] must match according
      to the [ls1], [ls2] lineup, and the resulting shape inherits the labels according to the [ls3] lineup.
  *)
  | Transpose of transpose_type * t
      (** Permutes the axes of a shape. One case of [Transpose] is to swap inputs with outputs of [s1],
      hence the name. *)
  | Terminal of Arrayjit.Ops.init_op
      (** Extracts any available shape information from the initialization from the initialization. E.g.
      for [File_mapped fn], opens the file [fn] to check its length. *)
[@@deriving equal, sexp]

let logic_to_spec = function
  | Broadcast (Pointwise_bin, _, _) | Transpose (Pointwise_un, _) -> "."
  | Broadcast (Compose, _, _) -> "@"
  | Broadcast (Einsum spec, _, _) | Transpose (Permute spec, _) -> spec
  | Transpose (Transpose, _) -> "T"
  | Transpose (Batch_slice _, _) -> "@|"
  | Terminal _ -> "<terminal>"

type shape_error =
  | Shape_mismatch of t list
  | Row_mismatch of dims list
  | Dim_mismatch of dim list
  | Index_mismatch of Arrayjit.Indexing.axis_index list
[@@deriving sexp]

exception Shape_error of string * shape_error list [@@deriving sexp]

let dim_to_int_exn = function Dim { d; _ } -> d | Var _ -> invalid_arg "dim_to_int: dim still unknown"

let meet more_constr constr =
  match (more_constr, constr) with
  | Unconstrained, c -> c
  | c, Unconstrained -> c
  | (Total_elems n1 as c), Total_elems n2 when n1 = n2 -> c
  | Total_elems _, Total_elems _ -> raise @@ Shape_error ("Incompatible Total_elems constraints", [])

module Env : sig
  type dim_env = dim Map.M(Dim_var).t
  type row_env = dims Map.M(Int).t
  type proj_classes = int Map.M(Int).t [@@deriving sexp]
  type broadcast = { dim_vars : Set.M(Dim_var).t; row_vars : Set.M(Int).t }

  type t = private {
    dim_env : dim_env;
    row_env : row_env;
    proj_classes : proj_classes;
    broadcast : broadcast;
  }

  val t_of_sexp : Sexp.t -> t
  val sexp_of_t : t -> Sexp.t
  val subst_dim : ?freshen_proj:bool -> t -> dim -> dim
  val occurs_dim : dim_var -> dim -> bool
  val subst_row : t -> dims -> dims
  val occurs_row : int -> dims -> bool
  val update_dim : ?freshen_proj:bool -> dim_var -> dim -> t -> t
  val update_row : ?freshen_proj:bool -> int -> dims -> t -> t
  val apply_constraint : dims -> t -> t
  val update_row_broadcast : rv:dims -> rd:dims -> t -> t
  val update_proj_classes : int -> int -> t -> t
  val empty_env : t
  val with_proj_classes_and_broadcast : proj_classes -> broadcast -> t -> t
  val merge_fresh_proj : update:t -> state:t -> t
end = struct
  type dim_env = dim Map.M(Dim_var).t [@@deriving sexp]
  type row_env = dims Map.M(Int).t [@@deriving sexp]
  type proj_classes = int Base.Map.M(Base.Int).t [@@deriving sexp]
  type broadcast = { dim_vars : Set.M(Dim_var).t; row_vars : Set.M(Int).t } [@@deriving sexp]

  type t = { dim_env : dim_env; row_env : row_env; proj_classes : proj_classes; broadcast : broadcast }
  [@@deriving sexp]
  (** The substitutions should be idempotent: FV(Dom(env)) n FV(Im(env)) = 0. *)

  let s_dim_one v ~value ~in_ = match in_ with Var v2 when equal_dim_var v v2 -> value | _ -> in_

  let subst_dim ?(freshen_proj = false) env = function
    | Dim { d; label; proj_id = _ } when freshen_proj -> get_dim ~d ?label ()
    | Dim _ as d -> d
    | Var v as default -> Option.value ~default @@ Map.find env.dim_env v

  let occurs_dim v = function Dim _ -> false | Var v' -> equal_dim_var v v'

  let s_row_one v ~value:{ dims = more_dims; constr = more_constr; row; id = _ } ~in_ =
    match in_ with
    | { dims; constr; row = Row_var v2; id } when v = v2 ->
        let more_constr =
          match more_constr with
          | Unconstrained -> Unconstrained
          | Total_elems m ->
              if List.for_all dims ~f:is_dim then
                Total_elems (m * List.fold dims ~init:1 ~f:(fun n d -> n * dim_to_int_exn d))
              else Unconstrained (* Wait for more shape inference. *)
        in
        { dims = more_dims @ dims; constr = meet more_constr constr; row; id }
    | _ -> in_

  let subst_row env { dims; constr; row; id } =
    let result = { dims = List.map dims ~f:(subst_dim env); constr; row; id } in
    match row with
    | Broadcastable | Fixed -> result
    | Row_var v -> (
        match Map.find env.row_env v with
        | None -> result
        | Some { dims = more_dims; constr = Unconstrained; row; id = _ } ->
            { dims = more_dims @ dims; constr; row; id }
        | Some { dims = more_dims; constr = Total_elems m; row; id = _ } ->
            let more_constr =
              if List.for_all dims ~f:is_dim then
                Total_elems (m * List.fold dims ~init:1 ~f:(fun n d -> n * dim_to_int_exn d))
              else Unconstrained (* Wait for more shape inference. *)
            in
            { dims = more_dims @ dims; constr = meet more_constr constr; row; id })

  let occurs_row v = function { row = Row_var v'; _ } -> v = v' | _ -> false

  let update_dim ?(freshen_proj = false) v dim env =
    (* Prevent the projection equivalences from leaking across [propagate_shapes update_step] invocations.
       Concluding that two axes have an equal size can span multiple update steps, and should not prevent
       them from being distinct axes in a product space. *)
    let dim = subst_dim ~freshen_proj env dim in
    if occurs_dim v dim then env
    else
      let env = { env with dim_env = Map.add_exn env.dim_env ~key:v ~data:dim } in
      { env with dim_env = Map.map env.dim_env ~f:(fun in_ -> s_dim_one v ~value:dim ~in_) }

  let update_row ?(freshen_proj = false) v row env =
    let row = subst_row env { row with dims = List.map row.dims ~f:(subst_dim ~freshen_proj env) } in
    if occurs_row v row then
      if List.is_empty row.dims then env
      else raise @@ Shape_error ("Infinite row via self-reference", [ Row_mismatch [ row ] ])
    else
      let env = { env with row_env = Map.add_exn env.row_env ~key:v ~data:row } in
      let row_env = Map.map env.row_env ~f:(fun in_ -> s_row_one v ~value:row ~in_) in
      { env with row_env }

  let apply_constraint r env =
    let r = subst_row env r in
    match r.constr with
    | Unconstrained -> env
    | Total_elems n -> (
        match r.row with
        | Row_var _ -> env (* Wait for more shape inference. *)
        | Fixed | Broadcastable -> (
            let dims = List.map r.dims ~f:(subst_dim env) in
            let vars, nonvars = List.partition_tf dims ~f:is_var in
            if List.length vars > 1 then env (* Wait for more shape inference. *)
            else
              let known = List.fold nonvars ~init:1 ~f:(fun n d -> n * dim_to_int_exn d) in
              match vars with
              | [] ->
                  if n <> known then (
                    if Utils.settings.with_debug then
                      Stdlib.Format.printf "Env.apply_constraint: shape error env=@ %a\n%!" Sexp.pp_hum
                        (sexp_of_t env);
                    raise @@ Shape_error ("Total_elems constraint failed", [ Row_mismatch [ r ] ]))
                  else env
              | [ Var v ] ->
                  let rem = n / known in
                  if rem = 0 then (
                    if Utils.settings.with_debug then
                      Stdlib.Format.printf "Env.apply_constraint: shape error env=@ %a\n%!" Sexp.pp_hum
                        (sexp_of_t env);
                    raise @@ Shape_error ("Total_elems constraint failed", [ Row_mismatch [ r ] ]))
                  else update_dim v (get_dim ~d:rem ()) env
              | _ -> assert false))

  let update_row_broadcast ~rv ~rd env =
    let eliminate_row = function Fixed -> Broadcastable | _ -> get_row_var () in
    match rv with
    | { dims = []; row = Row_var v; _ } ->
        let b_var, b_vars, data =
          let b_var, row =
            match (rd.row, eliminate_row rd.row) with
            | Row_var _, row -> (None, row)
            | _, (Row_var v as row) -> (Some v, row)
            | _, row -> (None, row)
          in
          let b_vars, dims =
            List.fold_map rd.dims
              ~init:(Set.empty (module Dim_var))
              ~f:(fun vars -> function
                | Dim { d = 1; _ } ->
                    let v = get_var () in
                    (Set.add vars v, Var v)
                | d -> (vars, d))
          in
          (b_var, b_vars, { row; dims; constr = meet rv.constr rd.constr; id = rv.id })
        in
        let dim_vars = Set.union b_vars env.broadcast.dim_vars in
        let row_vars = Option.fold b_var ~init:env.broadcast.row_vars ~f:Set.add in
        update_row v data { env with broadcast = { dim_vars; row_vars } } |> apply_constraint data
    | _ -> invalid_arg "Env.update_row_broadcast: the rv argument must be a bare row variable"

  let update_proj_classes pid1 pid2 env =
    { env with proj_classes = Utils.union_add ~equal:Int.equal env.proj_classes pid1 pid2 }

  let empty_env =
    {
      dim_env = Map.empty (module Dim_var);
      row_env = Map.empty (module Int);
      proj_classes = Map.empty (module Int);
      (* The state's proj_classes come from the most recent propagate_shapes and are not used across calls
         to propagate_shapes. *)
      broadcast = { dim_vars = Set.empty (module Dim_var); row_vars = Set.empty (module Int) };
    }

  let with_proj_classes_and_broadcast proj_classes broadcast env = { env with proj_classes; broadcast }

  let merge_fresh_proj ~update ~state =
    let state =
      Map.fold ~init:state
        ~f:(fun ~key ~data env -> update_dim ~freshen_proj:true key data env)
        update.dim_env
    in
    let state =
      Map.fold ~init:state
        ~f:(fun ~key ~data env -> update_row ~freshen_proj:true key data env)
        update.row_env
    in
    let broadcast =
      {
        dim_vars = Set.union update.broadcast.dim_vars state.broadcast.dim_vars;
        row_vars = Set.union update.broadcast.row_vars state.broadcast.row_vars;
      }
    in
    { dim_env = state.dim_env; row_env = state.row_env; proj_classes = state.proj_classes; broadcast }
end

type proj_environment = {
  proj_classes : Env.proj_classes;
  proj_env : Arrayjit.Indexing.axis_index Map.M(Dim_var).t;
}
[@@deriving sexp]

let empty_proj_environment = { proj_classes = Map.empty (module Int); proj_env = Map.empty (module Dim_var) }

type update_step = { shape : t; logic : logic; mutable env : proj_environment } [@@deriving sexp]
(** Data required for a shape inference update step. Ideally, an update should be performed at least twice,
    the second time after all the other relevant updates have been performed for the first time.
    In OCANNL, this is achieved by performing updates both as the tensors are constructed, and via
    lazy callbacks as the corresponding [Arrayjit.Indexing] dimensions and projections are first accessed. *)

let with_error_trace = ref true

type environment = Env.t [@@deriving sexp]
type dim_eq = { d1 : dim; d2 : dim } [@@deriving sexp, equal, hash, compare]
type dim_eqs = dim_eq list [@@deriving sexp]

type row_eq = { r : dims; subr : dims } [@@deriving sexp, equal]
(** Where applicable, [subr] comes from a subtensor of [r]. *)

type row_eqs = row_eq list [@@deriving sexp, equal]

let drop_from_end l n = List.rev @@ List.drop (List.rev l) n
let take_from_end l n = List.rev @@ List.take (List.rev l) n

module Debug_runtime = Utils.Debug_PrintBox ()

let%debug_sexp rec unify_dims (row_eqs : row_eq list) (env : environment) : environment =
  match row_eqs with
  | [] -> env
  | { r; subr } :: row_eqs when equal_dims r subr -> Env.apply_constraint r env |> unify_dims row_eqs
  | { r = { dims = []; row = Row_var v; _ } as rv; subr = rd as subr } :: row_eqs
  | { r = rd; subr = { dims = []; row = Row_var v; _ } as rv as subr } :: row_eqs -> (
      let rd_is_subtensor : bool = phys_equal rd subr in
      let rd : dims = Env.subst_row env rd in
      match Map.find env.row_env v with
      | None when equal_row rv.row rd.row && List.is_empty rd.dims ->
          Env.apply_constraint rv env |> Env.apply_constraint rd |> unify_dims row_eqs
      | None ->
          (* Prefer substituting-out a broadcast variable, to prevent it from being closed. *)
          if
            (not (Set.mem env.broadcast.row_vars v))
            && List.is_empty rd.dims
            && match rd.row with Row_var v2 -> Set.mem env.broadcast.row_vars v2 | _ -> false
          then Env.update_row_broadcast ~rv:rd ~rd:rv env |> unify_dims row_eqs
          else Env.update_row_broadcast ~rv ~rd env |> unify_dims row_eqs
      | Some r' ->
          let row_eq : row_eq = if rd_is_subtensor then { r = r'; subr = rd } else { r = rd; subr = r' } in
          Env.apply_constraint rv env |> unify_dims (row_eq :: row_eqs))
  | {
      r = { dims = []; constr = constr1; row = Fixed; id };
      subr = { dims = []; constr = constr2; row = Fixed | Broadcastable; id = _ };
    }
    :: row_eqs
  | {
      r = { dims = []; constr = constr1; row = Broadcastable; id = _ };
      subr = { dims = []; constr = constr2; row = Fixed; id };
    }
    :: row_eqs ->
      let constr = meet constr1 constr2 in
      Env.apply_constraint { dims = []; constr; row = Fixed; id } env |> unify_dims row_eqs
  | ({ r = { dims = []; row = Fixed; _ }; subr = _ } as eq) :: _ ->
      raise @@ Shape_error ("unify_dims: Fixed-mode axis number mismatch", [ Row_mismatch [ eq.r; eq.subr ] ])
  | (( { r = { dims = []; row = Broadcastable; _ }; subr = _ }
     | { r = _; subr = { dims = []; row = Broadcastable | Fixed; _ } } ) as eq)
    :: row_eqs ->
      Env.apply_constraint eq.r env |> Env.apply_constraint eq.subr |> unify_dims row_eqs
  | ({
       r = { dims = _ :: _ as ds1; constr = constr1; row = r1; id = id1 };
       subr = { dims = _ :: _ as ds2; constr = constr2; row = r2; id = id2 };
     } as eq)
    :: row_eqs ->
      let constr = meet constr1 constr2 in
      let len1 = List.length ds1 and len2 = List.length ds2 in
      let suffix = min len1 len2 in
      let dims, row = if len2 > len1 then (ds2, r2) else (ds1, r1) in
      let ds1_suf = take_from_end ds1 suffix in
      let ds2_suf = take_from_end ds2 suffix in
      let dim_eqs = List.map2_exn ~f:(fun d1 d2 -> { d1; d2 }) ds1_suf ds2_suf in
      (try unify_dim dim_eqs env
       with Shape_error (s, trace) when !with_error_trace ->
         raise @@ Shape_error ("dim tail / " ^ s, Row_mismatch [ eq.r; eq.subr ] :: trace))
      |> Env.apply_constraint { dims; constr; row; id = id1 }
      |> unify_dims
           ({
              r = { dims = drop_from_end ds1 suffix; constr = Unconstrained; row = r1; id = id1 };
              subr = { dims = drop_from_end ds2 suffix; constr = Unconstrained; row = r2; id = id2 };
            }
           :: row_eqs)

and unify_dim (dim_eqs : dim_eq list) (env : environment) : environment =
  match dim_eqs with
  | [] -> env
  | { d1 = Dim { label = Some l1; _ } as d1; d2 = Dim { label = Some l2; _ } as d2 } :: _
    when not (String.equal l1 l2) ->
      if Utils.settings.with_debug then
        Stdlib.Format.printf "unify_dim: different labels: shape error env=@ %a\n%!" Sexp.pp_hum
          (Env.sexp_of_t env);
      raise @@ Shape_error ("unify_dim: different labels", [ Dim_mismatch [ d1; d2 ] ])
  | { d1 = Dim { d = d1; label = _; proj_id = pid1 }; d2 = Dim { d = d2; label = _; proj_id = pid2 } }
    :: dim_eqs
    when d1 = d2 ->
      Env.update_proj_classes pid1 pid2 env |> unify_dim dim_eqs
  | { d1 = Dim { d = 1; _ }; d2 = _ } :: dim_eqs | { d1 = _; d2 = Dim { d = 1; _ } } :: dim_eqs ->
      unify_dim dim_eqs env
  | ({ d1 = Var v as d1; d2 } | { d2 = Var v as d1; d1 = d2 }) :: dim_eqs -> (
      match (Map.find env.dim_env v, d2) with
      | None, Var v2 when (not (Set.mem env.broadcast.dim_vars v)) && Set.mem env.broadcast.dim_vars v2 ->
          (* Prefer substituting-out a broadcast variable, to prevent it from being closed. *)
          Env.update_dim v2 d1 env |> unify_dim dim_eqs
      | None, _ -> Env.update_dim v d2 env |> unify_dim dim_eqs
      | Some d1, _ -> unify_dim ({ d1; d2 } :: dim_eqs) env)
  | { d1; d2 } :: _ ->
      if Utils.settings.with_debug then
        Stdlib.Format.printf "unify_dim: shape error env=@ %a\n%!" Sexp.pp_hum (Env.sexp_of_t env);
      raise @@ Shape_error ("unify_dim", [ Dim_mismatch [ d1; d2 ] ])

(** Converts an axes-keyed map into three arrays of values: batch axes, input axes, output axes.
    If the map is incomplete, the result might be invalid: gaps in the array are filled with an arbitrary
    one of the provided values. *)
let axis_map_to_dims_bio (type a) ?(default : a option) (idcs : a axis_map) =
  if Map.is_empty idcs then ([||], [||], [||])
  else
    let witness = match default with Some witness -> witness | None -> snd @@ Map.min_elt_exn idcs in
    let bch_axes, other =
      Map.partition_mapi idcs ~f:(fun ~key:{ in_axes; _ } ~data ->
          if AxisKey.is_batch in_axes then Either.First data else Either.Second data)
    in
    let inp_axes, out_axes =
      Map.partition_mapi other ~f:(fun ~key:{ in_axes; _ } ~data ->
          if AxisKey.is_input in_axes then Either.First data else Either.Second data)
    in
    let bch_axes = Map.to_alist bch_axes |> List.map ~f:(fun ({ from_end = i; _ }, v) -> (i, v)) in
    let bch_size = List.fold bch_axes ~init:0 ~f:(fun accu (i, _) -> max i accu) in
    let bch = Array.create ~len:bch_size witness in
    List.iter bch_axes ~f:(fun (i, v) -> bch.(bch_size - i) <- v);
    let inp_axes = Map.to_alist inp_axes |> List.map ~f:(fun ({ from_end = i; _ }, v) -> (i, v)) in
    let inp_size = List.fold inp_axes ~init:0 ~f:(fun accu (i, _) -> max i accu) in
    let inp = Array.create ~len:inp_size witness in
    List.iter inp_axes ~f:(fun (i, v) -> inp.(inp_size - i) <- v);
    let out_axes = Map.to_alist out_axes |> List.map ~f:(fun ({ from_end = i; _ }, v) -> (i, v)) in
    let out_size = List.fold out_axes ~init:0 ~f:(fun accu (i, _) -> max i accu) in
    let out = Array.create ~len:out_size witness in
    List.iter out_axes ~f:(fun (i, v) -> out.(out_size - i) <- v);
    (bch, inp, out)

(** Converts an axes-keyed map into an array of values using the [force_to_dims] semantics of axes.
    If the map is incomplete and the [~default] is not given, the result might be invalid: gaps in
    the array are filled with an arbitrary one of the provided values. *)
let axis_map_to_dims_index (type a) ?(default : a option) (idcs : a axis_map) : a array =
  let bch, inp, out = axis_map_to_dims_bio ?default idcs in
  Array.concat [ bch; out; inp ]

let axes_spec_to_dims_bio ?b_row ?i_row ?o_row ~sh_id ~f labels =
  let b_dims, i_dims, o_dims = axis_map_to_dims_bio labels.labels in
  let vars = Hashtbl.create (module String) in
  let to_dim kind = Array.(Fn.compose to_list @@ map ~f:(f kind vars)) in
  let upd_row = function None, true -> Some (get_row_var ()) | old, true -> old | _, false -> None in
  let b_row = upd_row (b_row, labels.bcast_batch) in
  let i_row = upd_row (i_row, labels.bcast_input) in
  let o_row = upd_row (o_row, labels.bcast_output) in
  let to_row v = Option.value v ~default:Fixed in
  let batch =
    {
      dims = to_dim AxisKey.Batch b_dims;
      constr = Unconstrained;
      row = to_row b_row;
      id = { sh_id; kind = AxisKey.Batch };
    }
  in
  let input =
    {
      dims = to_dim AxisKey.Input i_dims;
      constr = Unconstrained;
      row = to_row i_row;
      id = { sh_id; kind = AxisKey.Input };
    }
  in
  let output =
    {
      dims = to_dim AxisKey.Output o_dims;
      constr = Unconstrained;
      row = to_row o_row;
      id = { sh_id; kind = AxisKey.Output };
    }
  in
  (b_row, i_row, o_row, batch, input, output)

let einsum_slot_spec_to_dims_bio ~generative ?b_row ?i_row ?o_row ~sh_id labels =
  let equal = AxisKey.equal_kind in
  let proj_env_update = ref @@ Map.empty (module Dim_var) in
  let f kind vars = function
    | Either.First label -> Var (Hashtbl.find_or_add vars label ~default:(fun () -> get_var ~label ()))
    | Second 0 when Option.value ~default:false @@ List.Assoc.find generative ~equal kind -> get_dim ~d:1 ()
    | Second i ->
        let var = get_var () in
        proj_env_update := Map.add_exn !proj_env_update ~key:var ~data:(Arrayjit.Indexing.Fixed_idx i);
        Var var
  in
  let result = axes_spec_to_dims_bio ?b_row ?i_row ?o_row ~f ~sh_id labels in
  (!proj_env_update, result)

let%debug_sexp unify_shapes (env : environment)
    ({ shape = cur_sh; logic; env = _ } as update_step : update_step) : environment =
  let row_eq_side kind row = { dims = []; constr = Unconstrained; row; id = { sh_id = cur_sh.id; kind } } in
  let row_eq ~kind_r ~r ~kind_subr ~subr =
    Option.to_list
    @@ Option.map2 r subr ~f:(fun r subr -> { r = row_eq_side kind_r r; subr = row_eq_side kind_subr subr })
  in
  let dims_label_assoc dims =
    let f = function Var { label = Some l; _ } as d -> Some (l, d) | _ -> None in
    List.filter_map dims.dims ~f
  in
  let dim_assoc_eqs assoc =
    List.Assoc.sort_and_group assoc ~compare:String.compare
    |> List.concat_map ~f:(function
         | _, [] -> assert false
         | _, d1 :: ds -> List.map ds ~f:(fun d2 -> { d1; d2 }))
  in
  let generative =
    AxisKey.
      [
        (Batch, List.is_empty cur_sh.batch.dims);
        (Input, List.is_empty cur_sh.input.dims);
        (Output, List.is_empty cur_sh.output.dims);
      ]
  in
  match logic with
  | Terminal (Range_over_offsets | Standard_uniform | Constant_fill { strict = false; _ }) -> env
  | Terminal (Constant_fill { values; strict = true }) -> (
      let len = Array.length values in
      let io_dims =
        try List.map ~f:dim_to_int_exn @@ cur_sh.output.dims @ cur_sh.input.dims
        with Invalid_argument _ ->
          raise
          @@ Shape_error
               ( "unify_shapes Constant_fill strict: non-batch dimensions must be known",
                 [ Shape_mismatch [ cur_sh ] ] )
      in
      let batch_elems = len / abs (List.fold ~init:1 ~f:( * ) io_dims) in
      let b_row =
        {
          dims = [];
          constr = Total_elems batch_elems;
          row = get_row_var ();
          id = { sh_id = cur_sh.id; kind = Batch };
        }
      in
      try unify_dims [ { r = b_row; subr = cur_sh.batch } ] env
      with Shape_error (s, trace) when !with_error_trace ->
        raise @@ Shape_error ("Constant_fill / " ^ s, Shape_mismatch [ cur_sh ] :: trace))
  | Terminal (File_mapped (filename, prec)) -> (
      let fd = Unix.openfile filename [ Unix.O_RDONLY ] 0o640 in
      let len = Unix.lseek fd 0 Unix.SEEK_END / Arrayjit.Ops.prec_in_bytes prec in
      Unix.close fd;
      let io_dims =
        try List.map ~f:dim_to_int_exn @@ cur_sh.output.dims @ cur_sh.input.dims
        with Invalid_argument _ ->
          raise
          @@ Shape_error
               ( "unify_shapes Constant_fill strict: non-batch dimensions must be known",
                 [ Shape_mismatch [ cur_sh ] ] )
      in
      let batch_elems = len / abs (List.fold ~init:1 ~f:( * ) io_dims) in
      let b_row =
        {
          dims = [];
          constr = Total_elems batch_elems;
          row = get_row_var ();
          id = { sh_id = cur_sh.id; kind = Batch };
        }
      in
      try unify_dims [ { r = b_row; subr = cur_sh.batch } ] env
      with Shape_error (s, trace) when !with_error_trace ->
        raise @@ Shape_error ("File_mapped / " ^ s, Shape_mismatch [ cur_sh ] :: trace))
  | Transpose (Transpose, sh) -> (
      try
        unify_dims
          [
            { r = cur_sh.batch; subr = sh.batch };
            { r = cur_sh.input; subr = sh.output };
            { r = cur_sh.output; subr = sh.input };
          ]
          env
      with Shape_error (s, trace) when !with_error_trace ->
        raise @@ Shape_error ("Transpose / " ^ s, Shape_mismatch [ cur_sh; sh ] :: trace))
  | Transpose (Pointwise_un, sh) -> (
      try
        unify_dims
          [
            { r = cur_sh.batch; subr = sh.batch };
            { r = cur_sh.input; subr = sh.input };
            { r = cur_sh.output; subr = sh.output };
          ]
          env
      with Shape_error (s, trace) when !with_error_trace ->
        raise @@ Shape_error ("Pointwise unary / " ^ s, Shape_mismatch [ cur_sh; sh ] :: trace))
  | Broadcast (Compose, sh1, sh2) -> (
      try
        unify_dims
          [
            { r = sh1.input; subr = sh2.output };
            { r = cur_sh.batch; subr = sh1.batch };
            { r = cur_sh.batch; subr = sh2.batch };
            { r = cur_sh.input; subr = sh2.input };
            { r = cur_sh.output; subr = sh1.output };
          ]
          env
      with Shape_error (s, trace) when !with_error_trace ->
        raise @@ Shape_error ("Compose / " ^ s, Shape_mismatch [ cur_sh; sh1; sh2 ] :: trace))
  | Broadcast (Pointwise_bin, sh1, sh2) ->
      unify_dims
        [
          { r = cur_sh.batch; subr = sh1.batch };
          { r = cur_sh.batch; subr = sh2.batch };
          { r = cur_sh.input; subr = sh1.input };
          { r = cur_sh.input; subr = sh2.input };
          { r = cur_sh.output; subr = sh1.output };
          { r = cur_sh.output; subr = sh2.output };
        ]
        env
  | Transpose (Batch_slice { static_range; static_symbol }, sh) -> (
      if is_row_var sh.batch.row && is_row_var cur_sh.batch.row then (* Wait for more information *) env
      else
        let range_eq, batch_eq =
          let slice_var = Var (get_var ()) in
          if is_row_var sh.batch.row then
            let expanded_batch =
              {
                dims = slice_var :: cur_sh.batch.dims;
                constr = Unconstrained;
                row = cur_sh.batch.row;
                id = { sh_id = cur_sh.id; kind = Batch };
              }
            in
            ( Option.to_list static_range
              |> List.map ~f:(fun range -> { d1 = get_dim ~d:range (); d2 = slice_var }),
              { r = expanded_batch; subr = sh.batch } )
          else
            match sh.batch.dims with
            | [] ->
                raise
                @@ Shape_error
                     ("Batch slice: insufficent number of batch axes", [ Shape_mismatch [ cur_sh; sh ] ])
            | d2 :: dims ->
                let reduced_batch =
                  {
                    dims;
                    constr = Unconstrained;
                    row = sh.batch.row;
                    id = { sh_id = cur_sh.id; kind = Batch };
                  }
                in
                ( Option.to_list static_range |> List.map ~f:(fun range -> { d1 = get_dim ~d:range (); d2 }),
                  { r = cur_sh.batch; subr = reduced_batch } )
        in
        try
          unify_dim range_eq env |> Env.apply_constraint cur_sh.batch
          |> unify_dims
               [ batch_eq; { r = cur_sh.input; subr = sh.input }; { r = cur_sh.output; subr = sh.output } ]
        with Shape_error (s, trace) when !with_error_trace ->
          raise
          @@ Shape_error
               ( [%string "Batch slice %{Arrayjit.Indexing.symbol_ident static_symbol} / %{s}"],
                 Shape_mismatch [ cur_sh; sh ] :: trace ))
  | Transpose (Permute spec, sh) -> (
      let ls_rhs, ls_lhs =
        match einsum_of_spec spec with
        | ls_rhs, None, ls_lhs -> (ls_rhs, ls_lhs)
        | _ ->
            raise
            @@ Shape_error
                 ( "Invalid permutation spec (expected one argument): " ^ spec,
                   [ Shape_mismatch [ cur_sh; sh ] ] )
      in
      let proj_env_rhs, (b_row_rhs, i_row_rhs, o_row_rhs, b_rhs, i_rhs, o_rhs) =
        einsum_slot_spec_to_dims_bio ~generative:[] ~sh_id:sh.id ls_rhs
      in
      let proj_env_lhs, (b_row_lhs, i_row_lhs, o_row_lhs, b_lhs, i_lhs, o_lhs) =
        einsum_slot_spec_to_dims_bio ~generative ?b_row:b_row_rhs ?i_row:i_row_rhs ?o_row:o_row_rhs
          ~sh_id:cur_sh.id ls_lhs
      in
      let label_groups = List.concat_map ~f:dims_label_assoc [ b_lhs; i_lhs; o_lhs; b_rhs; i_rhs; o_rhs ] in
      let proj_env =
        let combine ~key:_ _ _ = assert false in
        Map.merge_skewed ~combine proj_env_rhs proj_env_lhs
      in
      (* Forget the old proj_env as it is not relevant after a propagate_shapes call completes. *)
      update_step.env <- { update_step.env with proj_env };
      try
        unify_dims
          ({ r = cur_sh.batch; subr = b_lhs } :: { r = b_rhs; subr = sh.batch }
           :: { r = cur_sh.input; subr = i_lhs } :: { r = i_rhs; subr = sh.input }
           :: { r = cur_sh.output; subr = o_lhs } :: { r = o_rhs; subr = sh.output }
           :: row_eq ~kind_r:Batch ~r:b_row_lhs ~kind_subr:Batch ~subr:b_row_rhs
          @ row_eq ~kind_r:Input ~r:i_row_lhs ~kind_subr:Input ~subr:i_row_rhs
          @ row_eq ~kind_r:Output ~r:o_row_lhs ~kind_subr:Output ~subr:o_row_rhs)
        @@ unify_dim (dim_assoc_eqs label_groups) env
      with Shape_error (s, trace) when !with_error_trace ->
        raise @@ Shape_error ([%string "Permute %{spec} / %{s}"], Shape_mismatch [ cur_sh; sh ] :: trace))
  | Broadcast (Einsum spec, sh1, sh2) -> (
      let ls_rhs1, ls_rhs2, ls_lhs =
        match einsum_of_spec spec with
        | ls_rhs1, Some ls_rhs2, ls_lhs -> (ls_rhs1, ls_rhs2, ls_lhs)
        | _, None, _ ->
            raise
            @@ Shape_error
                 ( "Invalid permutation spec (expected one argument): " ^ spec,
                   [ Shape_mismatch [ cur_sh; sh1; sh2 ] ] )
      in
      let proj_env_rhs1, (b_row_rhs1, i_row_rhs1, o_row_rhs1, b_rhs1, i_rhs1, o_rhs1) =
        einsum_slot_spec_to_dims_bio ~generative:[] ~sh_id:sh1.id ls_rhs1
      in
      let proj_env_rhs2, (b_row_rhs2, i_row_rhs2, o_row_rhs2, b_rhs2, i_rhs2, o_rhs2) =
        einsum_slot_spec_to_dims_bio ~generative:[] ?b_row:b_row_rhs1 ?i_row:i_row_rhs1 ?o_row:o_row_rhs1
          ~sh_id:sh2.id ls_rhs2
      in
      let proj_env_lhs, (b_row_lhs, i_row_lhs, o_row_lhs, b_lhs, i_lhs, o_lhs) =
        einsum_slot_spec_to_dims_bio ~generative ?b_row:b_row_rhs2 ?i_row:i_row_rhs2 ?o_row:o_row_rhs2
          ~sh_id:cur_sh.id ls_lhs
      in
      let label_groups =
        List.concat_map ~f:dims_label_assoc
          [ b_lhs; i_lhs; o_lhs; b_rhs1; i_rhs1; o_rhs1; b_rhs2; i_rhs2; o_rhs2 ]
      in
      let proj_env =
        let combine ~key:_ _ _ = assert false in
        Map.merge_skewed ~combine proj_env_rhs1 @@ Map.merge_skewed ~combine proj_env_rhs2 proj_env_lhs
      in
      (* Forget the old proj_env as it is not relevant after a propagate_shapes call completes. *)
      update_step.env <- { update_step.env with proj_env };
      let eqs =
        { r = cur_sh.batch; subr = b_lhs } :: { r = b_rhs1; subr = sh1.batch }
        :: { r = b_rhs2; subr = sh2.batch } :: { r = cur_sh.input; subr = i_lhs }
        :: { r = i_rhs1; subr = sh1.input } :: { r = i_rhs2; subr = sh2.input }
        :: { r = cur_sh.output; subr = o_lhs } :: { r = o_rhs1; subr = sh1.output }
        :: { r = o_rhs2; subr = sh2.output }
        :: row_eq ~kind_r:Batch ~r:b_row_lhs ~kind_subr:Batch ~subr:b_row_rhs1
        @ row_eq ~kind_r:Input ~r:i_row_lhs ~kind_subr:Input ~subr:i_row_rhs1
        @ row_eq ~kind_r:Output ~r:o_row_lhs ~kind_subr:Output ~subr:o_row_rhs1
        @ row_eq ~kind_r:Batch ~r:b_row_lhs ~kind_subr:Batch ~subr:b_row_rhs2
        @ row_eq ~kind_r:Input ~r:i_row_lhs ~kind_subr:Input ~subr:i_row_rhs2
        @ row_eq ~kind_r:Output ~r:o_row_lhs ~kind_subr:Output ~subr:o_row_rhs2
      in
      try unify_dims eqs @@ unify_dim (dim_assoc_eqs label_groups) env
      with Shape_error (s, trace) when !with_error_trace ->
        raise @@ Shape_error ([%string "Einsum %{spec} / %{s}"], Shape_mismatch [ cur_sh; sh1; sh2 ] :: trace)
      )

let indices_bio sh (type v) (arr : v array) =
  let n_batch = List.length sh.batch.dims in
  let batch : v Array.t = Array.sub arr ~pos:0 ~len:n_batch in
  let n_input = List.length sh.input.dims in
  let input = Array.sub arr ~pos:n_batch ~len:n_input in
  let n_output = List.length sh.output.dims in
  let output = Array.sub arr ~pos:(n_batch + n_input) ~len:n_output in
  (batch, input, output)

let state = ref Env.empty_env
let second_stage_inference = ref []

let rec close_row_broadcast env row =
  let row = Env.subst_row env row in
  let rec f env = function
    | Var v when Set.mem env.Env.broadcast.dim_vars v -> (
        match Map.find env.dim_env v with
        | None -> Env.update_dim v (get_dim ~d:1 ()) env
        | Some dim -> f env dim)
    | _ -> env
  in
  match row with
  | { dims; constr; row = Row_var v; id } when Set.mem env.Env.broadcast.row_vars v -> (
      match Map.find env.row_env v with
      | None ->
          let init = Env.update_row v { dims = []; constr; row = Broadcastable; id } env in
          List.fold dims ~f ~init
      | Some row -> close_row_broadcast env row)
  | { dims; _ } -> List.fold dims ~f ~init:env

(** Uses the matrix convention of putting the input axes last.
    Note: [force_to_dims] is "destructive": it closes shapes that remain incomplete after inference. *)
let close_shape_broadcast sh env =
  List.fold ~init:env ~f:close_row_broadcast [ sh.batch; sh.output; sh.input ]

let deep_copy_update_step update_step =
  let upd sh = { sh with id = sh.id } in
  {
    update_step with
    shape = upd update_step.shape;
    logic =
      (match update_step.logic with
      | Terminal l -> Terminal l
      | Transpose (l, sh1) -> Transpose (l, upd sh1)
      | Broadcast (l, sh1, sh2) -> Broadcast (l, upd sh1, upd sh2));
  }

let propagate_shapes (update_step : update_step) : unit =
  if not @@ List.mem ~equal:phys_equal !second_stage_inference update_step then
    second_stage_inference := update_step :: !second_stage_inference;
  let upd env sh =
    sh.batch <- Env.subst_row env sh.batch;
    sh.input <- Env.subst_row env sh.input;
    sh.output <- Env.subst_row env sh.output
  in
  let upd_all env =
    upd env update_step.shape;
    match update_step.logic with
    | Terminal _ -> ()
    | Transpose (_, sh1) -> upd env sh1
    | Broadcast (_, sh1, sh2) ->
        upd env sh1;
        upd env sh2
  in
  (* Update dimension information coming from other propagation steps. *)
  upd_all !state;
  let env = unify_shapes (Env.with_proj_classes_and_broadcast update_step.env.proj_classes !state.broadcast Env.empty_env) update_step in
  (* Update both dimension and projections information (i.e. keep the update step's projections). *)
  upd_all env;
  update_step.env <- { update_step.env with proj_classes = env.proj_classes };
  (* "Forget" the projections information of this propagation step to not contaminate other steps. *)
  state := Env.merge_fresh_proj ~update:env ~state:!state

let finish_inference () =
  let f update_step =
    propagate_shapes update_step;
    state := close_shape_broadcast update_step.shape !state
  in
  List.iter !second_stage_inference ~f;
  second_stage_inference := []

let row_to_dims row =
  let row = Env.subst_row !state row in
  let f = function
    | Dim { d; _ } -> d
    | Var _ as dim ->
        raise @@ Shape_error ("Not enough shape information: unresolved variable", [ Dim_mismatch [ dim ] ])
  in
  match row with
  | { row = Row_var _; _ } ->
      raise @@ Shape_error ("Not enough shape information: unresolved row variable", [ Row_mismatch [ row ] ])
  | { dims; constr = _; row = Broadcastable | Fixed; id = _ } -> Array.of_list_map dims ~f

(** Uses the matrix convention of putting the input axes last.
    Note: [force_to_dims] is "destructive": it closes shapes that remain incomplete after inference. *)
let to_dims (sh : t) : int array =
  try Array.concat_map ~f:row_to_dims [| sh.batch; sh.output; sh.input |]
  with Shape_error (s, trace) -> raise @@ Shape_error (s, Shape_mismatch [ sh ] :: trace)

let rec row_to_labels env =
  let rec f = function
    | Dim { label = Some l; _ } -> l
    | Dim { label = None; _ } -> ""
    | Var v -> (
        match Map.find env.Env.dim_env v with None -> Option.value v.label ~default:"" | Some dim -> f dim)
  in
  function
  | { dims; constr; row = Row_var v; id } -> (
      match Map.find env.row_env v with
      | None -> Array.of_list_map dims ~f
      | Some row2 -> row_to_labels env { dims = row2.dims @ dims; constr; row = row2.row; id })
  | { dims; constr = _; row = Broadcastable | Fixed; id = _ } -> Array.of_list_map dims ~f

(** Uses the matrix convention of putting the input axes last. *)
let to_labels (sh : t) : string array =
  Array.concat_map ~f:(row_to_labels !state) [| sh.batch; sh.output; sh.input |]

(** *** Projection inference *** *)

open Arrayjit.Indexing

(** Computes the indexing into subtensors given the shape information of a tensor. 
    [derive_projections] should only be invoked when the shapes are fully inferred already! *)
let derive_projections (update_step : update_step) : projections =
  let dims_of sh = sh.batch.dims @ sh.output.dims @ sh.input.dims in
  let lhs = update_step.shape in
  let project rhs =
    let lhs_dims = to_dims lhs in
    let rhs_dims = Array.of_list_map ~f:to_dims rhs in
    let all_dims = List.concat_map ~f:dims_of @@ (lhs :: rhs) in
    let proj_repr proj_id =
      fst @@ Utils.union_find ~equal:Int.equal update_step.env.proj_classes ~key:proj_id ~rank:0
    in
    (* Since shapes are already inferred, these variables unify directly with the proj_id of this operation. *)
    let constrained_projs =
      Map.to_alist update_step.env.proj_env
      |> List.filter_map ~f:(fun (v, idx) ->
             match Map.find !state.dim_env v with
             | Some (Dim { proj_id; _ }) -> Some (proj_id, idx)
             | other ->
                 if Utils.settings.with_debug then
                   Stdlib.Format.printf
                     "derive_projections: unresolved variable %a for projection constraints=@ %a\n%!"
                     Sexp.pp_hum (sexp_of_dim_var v) Sexp.pp_hum
                     ([%sexp_of: dim option] other);
                 None)
      |> Map.of_alist_multi (module Int)
      |> Map.map ~f:(Utils.unique_keep_first ~equal:equal_axis_index)
      |> Map.map ~f:(function
           | [] -> assert false
           | [ idx ] -> idx
           | idcs ->
               raise @@ Shape_error ("Multiple constraints on the same projection", [ Index_mismatch idcs ]))
    in
    let rec get_product_proj = function
      | Dim { proj_id; _ } when Map.mem constrained_projs proj_id -> None
      | Dim { d; proj_id; _ } -> if iterated d then Some (proj_repr proj_id, d) else None
      | Var v as dim -> (
          match Map.find !state.dim_env v with
          | None ->
              raise
              @@ Shape_error
                   ( "derive_projections: shape still not fully inferred",
                     [ Shape_mismatch (lhs :: rhs); Dim_mismatch [ dim ] ] )
          | Some dim -> get_product_proj dim)
    in
    (* Note: the ordering will affect performance of naive backends. *)
    let all_product_projs =
      Utils.unique_keep_first ~equal:(fun (p, _) (q, _) -> p = q)
      @@ List.filter_map all_dims ~f:get_product_proj
    in
    let product_iterators = List.map all_product_projs ~f:(fun (p, _) -> (p, get_symbol ())) in
    let product_space = Array.of_list_map all_product_projs ~f:snd in
    let rec get_slot_proj = function
      | Dim { proj_id; _ } when Map.mem constrained_projs proj_id -> Map.find_exn constrained_projs proj_id
      | Dim { d; proj_id; _ } ->
          if iterated d then
            Iterator (List.Assoc.find_exn product_iterators ~equal:Int.equal (proj_repr proj_id))
          else Fixed_idx 0
      | Var v as dim -> (
          match Map.find !state.dim_env v with
          | None ->
              raise
              @@ Shape_error
                   ( "derive_projections: shape still not fully inferred",
                     [ Shape_mismatch (lhs :: rhs); Dim_mismatch [ dim ] ] )
          | Some dim -> get_slot_proj dim)
    in
    let product_iterators = Array.of_list_map product_iterators ~f:snd in
    let f (sh : t) : axis_index array = Array.of_list_map (dims_of sh) ~f:get_slot_proj in
    {
      product_space;
      lhs_dims;
      rhs_dims;
      product_iterators;
      project_lhs = f lhs;
      project_rhs = Array.of_list_map ~f rhs;
      debug_info =
        {
          spec = logic_to_spec update_step.logic;
          derived_for = sexp_of_update_step update_step;
          trace = [ ("derive_projections", unique_debug_id ()) ];
        };
    }
  in
  match update_step.logic with
  | Terminal _ -> project []
  | Transpose (_, sh) -> project [ sh ]
  | Broadcast (_, sh1, sh2) -> project [ sh1; sh2 ]

let backprop_ith_arg ~from_1 projections =
  let project_lhs = projections.project_rhs.(from_1 - 1) in
  let project_rhs = Array.copy projections.project_rhs in
  project_rhs.(from_1 - 1) <- projections.project_lhs;
  let lhs_dims = projections.rhs_dims.(from_1 - 1) in
  let rhs_dims = Array.copy projections.rhs_dims in
  rhs_dims.(from_1 - 1) <- projections.lhs_dims;
  {
    product_space = projections.product_space;
    product_iterators = projections.product_iterators;
    lhs_dims;
    rhs_dims;
    project_lhs;
    project_rhs;
    debug_info =
      {
        projections.debug_info with
        trace =
          ("backprop_ith_arg " ^ Int.to_string from_1, unique_debug_id ()) :: projections.debug_info.trace;
      };
  }

(** *** Shape builders *** *)

let make ?(fix_b = false) ?(fix_i = false) ?(fix_o = false) ?batch_dims ?input_dims ?output_dims ?batch_axes
    ?input_axes ?output_axes ?(deduced = Not_constrained) ~debug_name ~id () =
  let make_row fix = if fix then Fixed else Broadcastable in
  let make_dims fix kind ds =
    {
      dims = List.map ~f:(fun d -> get_dim ~d ()) ds;
      constr = Unconstrained;
      row = make_row fix;
      id = { sh_id = id; kind };
    }
  in
  let make_axes fix kind ds =
    {
      dims = List.map ~f:(fun (label, d) -> get_dim ~d ~label ()) ds;
      constr = Unconstrained;
      row = make_row fix;
      id = { sh_id = id; kind };
    }
  in
  let make_unknown kind =
    { dims = []; constr = Unconstrained; row = get_row_var (); id = { sh_id = id; kind } }
  in
  let batch =
    match (batch_dims, batch_axes) with
    | Some batch_dims, None -> make_dims fix_b Batch batch_dims
    | None, Some batch_axes -> make_axes fix_b Batch batch_axes
    | None, None when not fix_b -> make_unknown Batch
    | Some _, Some _ -> invalid_arg "Shape.make: do not provide both batch_dims, batch_axes"
    | None, None -> invalid_arg "Shape.make: do not provide fix_b:true for unknown batch axes"
  in
  let input =
    match (input_dims, input_axes) with
    | Some input_dims, None -> make_dims fix_i Input input_dims
    | None, Some input_axes -> make_axes fix_i Input input_axes
    | None, None when not fix_i -> make_unknown Input
    | Some _, Some _ -> invalid_arg "Shape.make: do not provide both input_dims, input_axes"
    | None, None -> invalid_arg "Shape.make: do not provide fix_b:true for unknown input axes"
  in
  let output =
    match (output_dims, output_axes) with
    | Some output_dims, None -> make_dims fix_o Output output_dims
    | None, Some output_axes -> make_axes fix_o Output output_axes
    | None, None when not fix_o -> make_unknown Output
    | Some _, Some _ -> invalid_arg "Shape.make: do not provide both output_dims, output_axes"
    | None, None -> invalid_arg "Shape.make: do not provide fix_b:true for unknown output axes"
  in
  let result = { input; output; batch; id; debug_name } in
  (match deduced with
  | Not_constrained -> ()
  | Input_equals_output -> (
      try state := unify_dims [ { r = input; subr = output } ] !state
      with Shape_error (s, trace) when !with_error_trace ->
        raise @@ Shape_error ("Input_equals_output / " ^ s, Shape_mismatch [ result ] :: trace)));
  result

let shape_spec_to_dims_bio ?b_row ?i_row ?o_row labels =
  let f _kind vars = function
    | Either.First s when String.contains s '=' -> (
        let label, dim =
          match String.split s ~on:'=' with
          | [ l; d ] -> (l, d)
          | _ -> invalid_arg "shape_spec_to_dims_bio: too many '='"
        in
        try get_dim ~d:(Int.of_string dim) ~label ()
        with _ -> invalid_arg "shape_spec_to_dims_bio: int expected after '='")
    | First label -> Var (Hashtbl.find_or_add vars label ~default:(fun () -> get_var ~label ()))
    | Second d -> get_dim ~d ()
  in
  axes_spec_to_dims_bio ?b_row ?i_row ?o_row ~f labels

let of_spec ?(deduced = Not_constrained) ~debug_name ~id spec =
  let _, _, _, batch, input, output = shape_spec_to_dims_bio ~sh_id:id @@ axis_labels_of_spec spec in
  let result = { input; output; batch; id; debug_name } in
  (match deduced with
  | Not_constrained -> ()
  | Input_equals_output -> (
      try state := unify_dims [ { r = input; subr = output } ] !state
      with Shape_error (s, trace) when !with_error_trace ->
        raise @@ Shape_error ("of spec / " ^ s, Shape_mismatch [ result ] :: trace)));
  result

let to_string_hum ?(style = `Axis_size) sh =
  let n_outputs = List.length @@ sh.output.dims in
  let n_batch = List.length @@ sh.batch.dims in
  let dim_to_string = function
    | Dim { label = None; _ } when phys_equal style `Only_labels -> "_"
    | Dim { label = Some l; _ } when phys_equal style `Only_labels -> l
    | Dim { d; label = None; _ } -> Int.to_string d
    | Dim { d; label = Some l; _ } -> [%string "%{l}=%{d#Int}"]
    | Var { id; label = Some l } -> [%string "$%{id#Int}:%{l}"]
    | Var { id; label = None } -> "$" ^ Int.to_string id
  in
  let dims_to_string kind =
    let dims = (dims_of_kind kind sh).dims in
    String.concat ~sep:","
    @@ List.mapi dims ~f:(fun i d ->
           let num =
             match kind with Input -> n_batch + n_outputs + i | Output -> n_batch + i | Batch -> i
           in
           match style with
           | `Only_labels | `Axis_size -> dim_to_string d
           | `Axis_number_and_size -> Int.to_string num ^ ":" ^ dim_to_string d)
  in
  let batch_dims = dims_to_string Batch in
  let input_dims = dims_to_string Input in
  let output_dims = dims_to_string Output in
  if String.is_empty batch_dims && String.is_empty input_dims then output_dims
  else if String.is_empty batch_dims then input_dims ^ "->" ^ output_dims
  else if String.is_empty input_dims then batch_dims ^ "|" ^ output_dims
  else batch_dims ^ "|" ^ input_dims ^ "->" ^ output_dims

(** Given a fully-inferred shape, maps axes to their corresponding positions in an index using the
    [force_to_dims] semantics. *)
let axis_keys_to_idcs (sh : t) : int axis_map =
  let b_dims =
    (* Enumerate axes backwards. *)
    Array.of_list_rev_mapi sh.batch.dims ~f:(fun i _ -> AxisKey.{ in_axes = Batch; from_end = i + 1 })
  in
  let i_dims =
    Array.of_list_rev_mapi sh.input.dims ~f:(fun i _ -> AxisKey.{ in_axes = Input; from_end = i + 1 })
  in
  let o_dims =
    Array.of_list_rev_mapi sh.output.dims ~f:(fun i _ -> AxisKey.{ in_axes = Output; from_end = i + 1 })
  in
  let idcs = Array.concat [ i_dims; o_dims; b_dims ] in
  Array.rev_inplace idcs;
  Map.of_alist_exn (module AxisKey) @@ Array.to_list @@ Array.mapi idcs ~f:(fun i key -> (key, i))

let default_display_indices sh =
  let axes = axis_keys_to_idcs sh |> Map.map ~f:(fun _ -> 0) in
  let occupied = Array.create ~len:5 false in
  let set_occu prio =
    occupied.(prio + 5) <- true;
    prio
  in
  let occu prio = occupied.(prio + 5) in
  let num_input_axes = List.length sh.input.dims in
  let remaining =
    Stack.of_list
    @@ List.filter ~f:(Map.mem axes)
    @@ AxisKey.
         [
           { in_axes = Input; from_end = 1 };
           { in_axes = Output; from_end = 1 };
           { in_axes = Input; from_end = 2 };
           { in_axes = Output; from_end = 2 };
           (if num_input_axes > 1 then { in_axes = Batch; from_end = 1 }
            else { in_axes = Output; from_end = 3 });
           { in_axes = Batch; from_end = 1 };
           { in_axes = Batch; from_end = 2 };
           { in_axes = Input; from_end = 3 };
           { in_axes = Output; from_end = 3 };
           { in_axes = Input; from_end = 4 };
           { in_axes = Output; from_end = 4 };
           { in_axes = Input; from_end = 5 };
           { in_axes = Output; from_end = 5 };
         ]
  in
  let rec loop offset axes =
    if Stack.is_empty remaining || offset > 5 then axes
    else if Fn.non occu ~-offset then
      loop (offset + 1)
      @@ Map.change axes (Stack.pop_exn remaining) ~f:(Option.map ~f:(fun _ -> set_occu ~-offset))
    else loop (offset + 1) axes
  in
  let axes = loop 1 axes in
  axis_map_to_dims_index axes
