(** The compositional primitives for runtime-compiled code supporting backpropagation. *)

open Base

(** Uses [code option], i.e. [None] instead of [.< () >.], to improve readability of generated code. *)
type t = {
  forward_body: unit Codelib.code option;
  init_values: unit -> unit Codelib.code;
  (** Initializes the values. The code is suspended so that it can incorporate shape inference. *)
  init_grads: unit -> unit Codelib.code;
  (** Initializes the gradient data: typically, simply creates the ndarrays.
      Gradients are zeroed separately. The code is suspended so that it can incorporate shape inference. *)
  backprop_body: unit Codelib.code option;
  zero_grads: unit Codelib.code;
  (** Initializes the backpropagation phase. Computed once per backpropagation. *)
  node_id: int;
  comp_node: Node.t;
  (** This tracks the computation node as long as the model is not cross-compiled to a different
      process etc. *)
  node: Node.t Codelib.code;
  (** The node storing the computation results. [.!(t.node)] should equal [t.comp_node]. *)
  shape_logic: Shape.logic;
  (** How to do the last update of [t.shape] when finalizing the formula. *)
  shape: Shape.t;
  (** The eventual shape of [.!(t.node).value] and [.!(t.node).grad], incorporating the current state of
      shape inference. *)
}

(** A global root is a formula that is not (currently) a subformula of another formula. *)
type global_root = {
  mutable forward_code: (unit -> unit) Codelib.code option;
  mutable forward: (unit -> unit) option;
  mutable backprop_code: (unit -> unit) Codelib.code option;
  mutable backprop: (unit -> unit) option;
  formula: t;
  subtree_shape_updates: Shape.update_step Sequence.t;
  (** We piggy-back on the code generation setup to arrange the updates. We perform each update twice
      to propagate information between all subformulas: first in postfix order while computing [t],
      second in prefix order by iterating over [t.subtree_shape_updates]. *)
}

(** If a formula with [node_id >= !first_session_id] is not among global roots, it must be a subformula
    of a global root. *)
let global_roots = ref @@ Map.empty (module Int)

let first_session_id = ref 1

let recompile = ()

let run = ()

let print_global_roots = ()

exception Session_error of string * t option

let binop ~op_label ?(compose_op=`Pointwise) ~op_body ~grad_body m1arg m2arg: t =
  let m1, m2 = if m1arg.node_id <= m2arg.node_id then m1arg, m2arg else m2arg, m1arg in
  (if (m1.node_id < !first_session_id) then
    raise @@ Session_error ("The subformula is outside of current session", Some m1));
  (if (m2.node_id < !first_session_id) then
     raise @@ Session_error ("The subformula is outside of current session", Some m2));
  let m1_l = m1.comp_node.label in
  let m1_l = if String.length m1_l > 11 then "n"^Int.to_string m1.node_id else m1_l in
  let m2_l = m2.comp_node.label in
  let m2_l = if String.length m2_l > 11 then "n"^Int.to_string m2.node_id else m2_l in
  let label = m1_l ^ op_label ^ m2_l in
  let comp_node = Node.create ~label in
  let node_id = comp_node.id in
  let shape = Shape.{ batch=Unknown; input=Unknown; output=Unknown;
                      axis_labels=Map.empty (module AxisKey);
                      of_node_id=node_id; deduce_output_from_input=`Not_deduced } in
  let shape_logic = Shape.Broadcast (compose_op, m1.shape, m2.shape) in
  let local_shape_update = Shape.{ shape; logic=shape_logic } in
  Shape.propagate_shapes local_shape_update;
  let node = Codelib.genlet ~name:label (.< Node.get node_id >.) in
  let nv = (.< .~node.value >.) in
  let n1v = (.< .~(m1.node).value >.) in
  let n2v = (.< .~(m2.node).value >.) in
  let dims: int array Codelib.code = failwith "figure this out" in
  let op_body = op_body dims ~nv ~n1v ~n2v in
  let m1_processed = not @@ Map.mem !global_roots m1.node_id in
  let m2_processed = not @@ Map.mem !global_roots m2.node_id in
  (* The code needs to be included in the order it was computed! *)
  let forward_body =
    match m1_processed, m1.forward_body, m2_processed, m2.forward_body with
    | true, _, true, _ | true, _, _, None | _, None, true, _ | _, None, _, None -> op_body
    | false, Some m1_body, false, Some m2_body ->
      (.< .~m1_body; .~m2_body; .~op_body >.)
    | _, _, false, Some m2_body -> (.< .~m2_body; .~op_body >.)
    | false, Some m1_body, _, _ -> (.< .~m1_body; .~op_body >.)
  in
  let init_values_body = fun () -> (.< .~node.value <- Ndarray.create .~(Shape.to_dims_code shape) >.) in
  let m1_init_values = m1.init_values in
  let m2_init_values = m2.init_values in
  let init_values =
    if m1_processed && m2_processed then init_values_body
    else if m1_processed then fun () -> (.< .~(m2_init_values ()); .~(init_values_body ()) >.)
    else if m2_processed then fun () -> (.< .~(m1_init_values ()); .~(init_values_body ()) >.)
    else fun () -> (.< .~(m1_init_values ()); .~(m2.init_values ()); .~(init_values_body ()) >.) in
  let ng = (.< .~node.grad >.) in
  let n1g = (.< .~(m1.node).grad >.) in
  let n2g = (.< .~(m2.node).grad >.) in
  let zero_body = (.< Ndarray.reset_zeros .~ng >.) in
  (* The order of zeroing gradients is irrelevant and multiple zeroing is fine, but we avoid it
     and keep the backprop order for readability. *)
  let zero_grads =
    if m1_processed && m2_processed then zero_body
    else if m1_processed then (.< .~zero_body; .~(m2.zero_grads) >.)
    else if m2_processed then (.< .~zero_body; .~(m1.zero_grads) >.)
    else (.< .~zero_body; .~(m2.zero_grads); .~(m1.zero_grads) >.) in
  (* The code needs to be included in the reverse order to which it was computed! This guarantees
     that all ancestors of a node are backpropagated before the node is backpropagated, even for
     non-tree DAGs. *)
  let dims: int array Codelib.code = failwith "figure this out" in
  let grad_body = grad_body dims ~n1g ~n2g ~ng ~nv ~n1v ~n2v in
  let backprop_body =
    match m1_processed, m1.backprop_body, m2_processed, m2.backprop_body with
    | true, _, true, _ | true, _, _, None | _, None, true, _ | _, None, _, None -> grad_body
    | false, Some m1_body, false, Some m2_body ->
      (.< .~grad_body; .~m1_body; .~m2_body >.)
    | _, _, false, Some m2_body -> (.< .~grad_body; .~m2_body  >.)
    | false, Some m1_body, _, _ -> (.< .~grad_body; .~m1_body  >.)
    in
  let init_grads_body = fun () -> (.< .~node.grad <- Ndarray.create .~(Shape.to_dims_code shape) >.) in
  (* The order is not relevant, we keep the same order as in backprop for readability. *)
  let m1_init_grads = m1.init_grads in
  let m2_init_grads = m2.init_grads in
  let init_grads =
    if m1_processed && m2_processed then init_grads_body
    else if m1_processed then fun () -> (.< .~(init_grads_body ()); .~(m2_init_grads ()) >.)
    else if m2_processed then fun () -> (.< .~(init_grads_body ()); .~(m1_init_grads ()) >.)
    else fun () -> (.< .~(init_grads_body ()); .~(m2_init_grads ()); .~(m1_init_grads ()) >.) in
  (* The order is reverse to the order the updates were already executed for the first time. *)
  let local_shape_updates = Sequence.singleton local_shape_update in
  let subtree_shape_updates: Shape.update_step Sequence.t =
    if m1_processed && m2_processed then local_shape_updates
    else if m1_processed then Sequence.append local_shape_updates @@
      (Map.find_exn !global_roots m2.node_id).subtree_shape_updates
    else if m2_processed then Sequence.append local_shape_updates @@
      (Map.find_exn !global_roots m1.node_id).subtree_shape_updates
    else
      Sequence.(concat @@ of_list
                  [local_shape_updates; (Map.find_exn !global_roots m2.node_id).subtree_shape_updates;
                  (Map.find_exn !global_roots m1.node_id).subtree_shape_updates]) in

  (if not m1_processed then global_roots := Map.remove !global_roots m1.node_id);
  (if not m2_processed then global_roots := Map.remove !global_roots m2.node_id);
  let formula = {forward_body=Some forward_body; backprop_body=Some backprop_body;
                init_values; init_grads; zero_grads;
                node_id; comp_node; node; shape_logic; shape} in
  let root = {forward_code=None; forward=None; backprop_code=None; backprop=None; 
              formula; subtree_shape_updates} in
  global_roots := Map.add_exn !global_roots ~key:node_id ~data:root;
  formula

let unop ~op_label ?(transpose_op=`Transpose) ~op_body ~grad_body m: t =
  let m_l = m.comp_node.label in
  let m_l = if String.length m_l > 11 then "n"^Int.to_string m.node_id else m_l in
  let label = op_label ^ m_l in
  let comp_node = Node.create ~label in
  let node_id = comp_node.id in

  (* The default is that a transpose is its own inverse. *)
  let shape = Shape.{ batch=Unknown; input=Unknown; output=Unknown;
                      axis_labels=Map.empty (module AxisKey);
                      of_node_id=node_id; deduce_output_from_input=`Not_deduced } in
  let shape_logic = Shape.Transpose(transpose_op, m.shape) in
  let local_shape_update = Shape.{ shape; logic=shape_logic } in
  Shape.propagate_shapes local_shape_update;

  let node = Codelib.genlet ~name:label (.< Node.get node_id >.) in
  let nv = (.< .~node.value >.) in
  let n1v = (.< .~(m.node).value >.) in
  let dims: int array Codelib.code = failwith "figure this out" in
  let op_body = op_body dims ~nv ~n1v in
  let m_processed = not @@ Map.mem !global_roots m.node_id in
  (* The code needs to be included in the order it was computed! *)
  let forward_body =
    match m_processed, m.forward_body with
    | true, _ | _, None -> op_body
    | false, Some m_body -> (.< .~m_body; .~op_body >.) in
  let m_init_values = m.init_values in
  let init_values = fun () -> (.<
    .~(m_init_values ());
    .~node.value <- Ndarray.create .~(Shape.to_dims_code shape);
  >.) in
  let ng = (.< .~node.grad >.) in
  let n1g = (.< .~(m.node).grad >.) in
  let zero_body = (.< Ndarray.reset_zeros .~ng >.) in
  (* The order of zeroing gradients is irrelevant and multiple zeroing is fine, but we avoid it
       and keep the backprop order for readability. *)
  let zero_grads =
    if m_processed then zero_body
    else (.< .~zero_body; .~(m.zero_grads) >.) in
  let dims: int array Codelib.code = failwith "figure this out" in
  let grad_body = grad_body dims ~n1g ~ng ~nv ~n1v in
  (* The code needs to be included in the reverse order to which it was computed! *)
  let backprop_body =
    match m_processed, m.backprop_body with
    | true, _ | _, None -> grad_body
    | false, Some m_body -> (.< .~grad_body; .~m_body >.) in
  let init_grads_body = fun () -> (.< .~node.grad <- Ndarray.create .~(Shape.to_dims_code shape) >.) in
  (* The order is not relevant, we keep the same order as in backprop for readability. *)
  let m_init_grads = m.init_grads in
  let init_grads =
    if m_processed then init_grads_body
    else fun () -> (.< .~(init_grads_body ()); .~(m_init_grads ()) >.) in
  let local_shape_updates = Sequence.singleton local_shape_update in
  let subtree_shape_updates: Shape.update_step Sequence.t =
    if m_processed then local_shape_updates
    else Sequence.append local_shape_updates @@
    (Map.find_exn !global_roots m.node_id).subtree_shape_updates in

  (if not m_processed then global_roots := Map.remove !global_roots m.node_id);
  let formula = {forward_body=Some forward_body; backprop_body=Some backprop_body;
                 init_values; init_grads; zero_grads;
                 node_id; comp_node; node; shape_logic; shape} in
  let root = {forward_code=None; forward=None; backprop_code=None; backprop=None; 
              formula; subtree_shape_updates} in
  global_roots := Map.add_exn !global_roots ~key:node_id ~data:root;
  formula

let get_toplevel m =
  let forward_body = match m.forward_body with None -> .< () >. | Some body -> body in
   let toplevel_forward = (.< .~(m.init_values ()); fun () -> .~forward_body >.) in
   let backprop_body = match m.backprop_body with None -> .< () >. | Some body -> body in
   let toplevel_backprop = (.<
   .~(m.init_grads ());
   fun () ->
     .~(m.zero_grads);
     Ndarray.reset_ones .~(m.node).grad;
     .~backprop_body
 >.) in
  toplevel_forward, toplevel_backprop

(* ********** User API below ********** *)

(** A terminal: a constant, a parameter, an input of the model. *)
let term ~label (spec: Shape.term_spec) ~(init_code:Ndarray.t Codelib.code) : t =
  let comp_node = Node.create ~label in
  let node_id = comp_node.id in
  let shape = Shape.of_term_spec ~node_id spec in
  let shape_logic = Shape.Terminal in
  (* NOTE: this update does not do any work, but that might change in the future,
     and having it in the update sequence might help with debuggability. *)
  let local_shape_update = Shape.{ shape; logic=shape_logic } in
  Shape.propagate_shapes local_shape_update;

  let node = Codelib.genlet ~name:label (.< Node.get node_id >.) in
  (* Very unlikely someone will compute just the parameters. *)
  let forward_body = None in
  (* FIXME: should use shape probably instead of [init_code], which should be [forward_code]? *)
  let init_values = fun () -> (.< .~node.value <- .~init_code >.) in
  let ng = Codelib.genlet ~name:(label^"d") (.< .~node.grad >.) in
  let zero_grads = (.< Ndarray.reset_zeros .~ng >.) in
  let backprop_body = None in
  (* Very unlikely someone will want dw/dw. *)
  let init_grads = fun () -> (.< .~node.grad <- Ndarray.create .~(Shape.to_dims_code shape) >.) in
  let subtree_shape_updates = Sequence.singleton local_shape_update in
  let formula = {forward_body; backprop_body;
                 init_values; init_grads; zero_grads;
                 node_id; comp_node; node; shape_logic; shape} in
  let root = {forward_code=None; forward=None; backprop_code=None; backprop=None; 
              formula; subtree_shape_updates} in
  global_roots := Map.add_exn !global_roots ~key:node_id ~data:root;
  formula

let add =
  let op_body _dims ~nv ~n1v ~n2v = (.< Ndarray.assign_add .~nv .~n1v .~n2v >.) in
  let grad_body _dims ~n1g ~n2g ~ng ~nv:_ ~n1v:_ ~n2v:_ = (.<
    Ndarray.assign_add .~n1g .~n1g .~ng;
    Ndarray.assign_add .~n2g .~n2g .~ng
  >.) in
  binop ~compose_op:`Pointwise ~op_label:"t" ~op_body ~grad_body

let mul_pointwise =
  let op_body _dims ~nv ~n1v ~n2v = (.< Ndarray.assign_mul .~nv .~n1v .~n2v >.) in
  let grad_body dims ~n1g ~n2g ~ng ~nv:_ ~n1v ~n2v = (.<
    Ndarray.assign_add .~n1g .~n1g (Ndarray.mul .~dims .~ng .~n2v);
    Ndarray.assign_add .~n2g .~n2g (Ndarray.mul .~dims .~ng .~n1v)
  >.) in
  binop ~compose_op:`Pointwise ~op_label:"" ~op_body ~grad_body

let matmul =
  let op_body _dims ~nv ~n1v ~n2v = (.< Ndarray.assign_mul .~nv .~n1v .~n2v >.) in
  let grad_body dims ~n1g ~n2g ~ng ~nv:_ ~n1v ~n2v = (.<
    Ndarray.assign_add .~n1g .~n1g (Ndarray.mul .~dims .~ng .~n2v);
    Ndarray.assign_add .~n2g .~n2g (Ndarray.mul .~dims .~ng .~n1v)
  >.) in
  binop ~compose_op:`Compose ~op_label:"" ~op_body ~grad_body

let relu =
  let op_body _dims ~nv ~n1v = (.< Ndarray.assign_relu .~nv .~n1v >.) in
  let grad_body dims ~n1g ~ng ~nv ~n1v:_ = (.<
    Ndarray.assign_add .~n1g .~n1g (Ndarray.relu_gate .~dims .~nv .~ng)
  >.) in
  unop ~op_label:"r" ~op_body ~grad_body

let init_zeroes shape = (.< let p = Ndarray.create shape in Ndarray.reset_zeros p; p >.)
let init_uniform shape = (.< Ndarray.get_uniform ~low:(-1.0) ~high:1.0 shape >.)

let float_to_label v = "v" ^ (
  Float.to_string v |> String.substr_replace_all ~pattern:"." ~with_:"p"
  |> String.substr_replace_all ~pattern:"-" ~with_:"m")

let number v =
  (* Note: no axis label so that we do not conflict with user labels. *)
  term ~label:(float_to_label v) (`Constant ([1], ""))
    ~init_code:(.< Ndarray.get_val v [|1|] >.)

module O = struct
  let ( * ) = matmul
  let ( *. ) = mul_pointwise
  let (+) = add
  let (!/) = relu
  let (!~) label shape = term ~label ~init_code:(init_uniform shape)
  let (!.) = number
  let (-) m1 m2 = m1 + !.(-1.) * m2
end

let sprint code =
  let closed, check = Codelib.close_code_delay_check code in
  ignore (Caml.Format.flush_str_formatter());
  Caml.Format.pp_set_margin Caml.Format.str_formatter 160;
  Codelib.format_code Caml.Format.str_formatter closed;
  let s = Caml.Format.flush_str_formatter() in
  let s = String.substr_replace_all s ~pattern:"Base." ~with_:"" in
  let s = String.substr_replace_all s ~pattern:"Ocannl." ~with_:"" in
  let s = String.substr_replace_all s ~pattern:"Ndarray." ~with_:"" in
  let s = String.substr_replace_all s ~pattern:"Node." ~with_:"" in
  s, check

let sexp_of_t m =
  Sexp.message "Formula" [
    "label", String.sexp_of_t m.comp_node.label; "node_id", Int.sexp_of_t m.node_id;
  ]

include Comparator.Make(struct
    type nonrec t = t
    let compare m1 m2 = Int.compare m1.node_id m2.node_id
    let sexp_of_t = sexp_of_t
end)

module Summable = struct
  type nonrec t = t
  let (+) = add
  let zero = number 0.0
end

(*
let postprocess code =
  let closed, check = Codelib.close_code_delay_check code in
  let ast = Codelib.ast_of_code closed in
  Printast.expression
*)

(* 
~/ocannl$ dune utop

open Base
#load "_build/default/lib/ocannl.cma"
open Ocannl
module F = Formula
let d = [|3; 3|]
let nn = F.O.(!/(!~"w" d * !~"x" d + !~"b" d))
let () = Stdio.print_endline @@ fst @@ F.sprint nn.toplevel_forward
let () = Stdio.print_endline @@ fst @@ F.sprint nn.toplevel_backprop
*)
