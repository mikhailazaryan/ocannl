(** Computational primitives for neural networks, integrating [Formula] with [Code]. *)

open Base

module CDSL = Code.CDSL

let add =
  let open Code in
  let module NFDSL = struct module O = struct end end in
  let%nn_cd op_body ~(n:NodeUI.t) ~(n1:NodeUI.t) ~(n2:NodeUI.t) projections =
    n =: n1 + n2 in
  let%nn_cd grad_body ~(n:NodeUI.t) ~(n1:NodeUI.t) ~(n2:NodeUI.t) projections =
    n1.grad =+ n.grad || n2.grad =+ n.grad in
  Formula.binop ~compose_op:Pointwise_bin ~op_label:"+" ~op_body ~grad_body

let mul compose_op =
  let open Code in
  let module NFDSL = struct module O = struct end end in
  let%nn_cd op_body ~(n:NodeUI.t) ~(n1:NodeUI.t) ~(n2:NodeUI.t) projections = 
    n =: n1 * n2 in
  let%nn_cd grad_body ~(n:NodeUI.t) ~(n1:NodeUI.t) ~(n2:NodeUI.t) projections =
    n1.grad =+ n.grad * n2 || n2.grad =+ n1 * n.grad in
  Formula.binop ~compose_op 
    ~op_label:(if Shape.equal_compose_type compose_op Pointwise_bin then "*." else "*")
    ~op_body ~grad_body

let pointmul = mul Pointwise_bin

(* N1: AxB, N2 BxC, N: AxC, A: output of N1, B: input/output of N1/N2, C: input of N2.
   Although the matrix algebra would require that we insert additional transposes in gradient multiplies:
   AxB = AxC * CxB = AxC * (BxC)^T -> N1g += Ng * N2v^T,
   BxC = BxA * AxC = (AxB)^T * AxC -> N2g += N1v^T * Ng,
   in our setup there is no transposing to do, since the projections produce correct indices for their
   corresponding matrices. *)

let matmul = mul Compose

(** Similar to the explicit mode of [numpy.einsum], the binary variant. Can compute various forms of
    matrix multiplication, inner and outer products, etc.

    Note that ["a,b->c"] from [numpy] is ["a;b=>c"] in OCANNL, since ["->"] is used to separate the input
    and the output axes. *)
let einsum ?desc_label spec =
  let open Code in
  let module NFDSL = struct module O = struct end end in
  let%nn_cd op_body ~(n:NodeUI.t) ~(n1:NodeUI.t) ~(n2:NodeUI.t) projections =
    n =+ n1 * n2 in
  let%nn_cd grad_body ~(n:NodeUI.t) ~(n1:NodeUI.t) ~(n2:NodeUI.t) projections =
    n1.grad =+ n.grad * n2 || n2.grad =+ n1 * n.grad in
  Formula.binop ?desc_label ~compose_op:(Einsum spec) ~op_label:";=>" ~op_body ~grad_body

(** Similar to the explicit mode of [numpy.einsum], the unary variant. Can permute axes, extract diagonals,
    compute traces etc.

    Note that ["a->c"] from [numpy] is ["a=>c"] in OCANNL, since ["->"] is used to separate the input
    and the output axes. *)
let einsum1 ?desc_label spec =
  let open Code in
  let module NFDSL = struct module O = struct end end in
  let%nn_cd op_body ~(n:NodeUI.t) ~(n1:NodeUI.t) projections =
    n =+ n1 in
  let%nn_cd grad_body ~(n:NodeUI.t) ~(n1:NodeUI.t) projections =
    n1.grad =+ n.grad in
  Formula.unop ?desc_label ~transpose_op:(Permute spec) ~op_label:"=>" ~op_body ~grad_body

let relu =
  let open Code in
  let module NFDSL = struct module O = struct end end in
  let%nn_cd op_body ~(n:NodeUI.t) ~(n1:NodeUI.t) projections =
    n =: !/ n1 ~projections in
  let%nn_cd grad_body ~(n:NodeUI.t) ~(n1:NodeUI.t) projections =
    n1.grad =+ n -?/ n.grad in
  Formula.unop ~transpose_op:Pointwise_un ~op_label:"r" ~op_body ~grad_body

module NFO_without_pow = struct
  let ( * ) = matmul ~is_form:false
  let ( *. ) = pointmul ~is_form:false
  let (+) = add ~is_form:false
  let (!/) = relu ~is_form:false
  let (!.) = Formula.number ~is_form:false
  let (-) ?desc_label m1 m2 = (+) ?desc_label m1 ((!. (-1.)) *. m2)
  let (~-) ?desc_label m = ( *. ) ?desc_label !.(-1.)  m
end

let rec pointpow ?desc_label ~is_form p m1: Formula.t =
  let module NFDSL = struct module O = NFO_without_pow end in
  let open Code in
  let p_f = Formula.number ~is_form p in
  let%nn_cd op_body ~(n:NodeUI.t) ~(n1:NodeUI.t) ~(n2:NodeUI.t) projections =
    n =: n1 ** n2 ~projections in
  let%nn_cd grad_body =
    if not is_form then 
      fun ~n:_ ~n1:_ ~n2:_ _projections -> Noop
    else if Float.equal p 2.0 then
      fun ~(n:NodeUI.t) ~(n1:NodeUI.t) ~n2:_ projections -> n1.grad =+ p_f *. m1 * n.grad
    else
      fun ~(n:NodeUI.t) ~(n1:NodeUI.t) ~n2:_ projections -> n1.grad =+ (p_f *. m1 **. (p -. 1.)) * n.grad in
  Formula.binop ?desc_label ~compose_op:Pointwise_bin ~op_label:"**."
    ~op_body ~grad_body ~is_form m1 p_f

let range ?desc_label ~is_form ?axis_label upto =
  Formula.term ?desc_label ~is_form ~label:("0"^"..."^Int.to_string upto)
    ~batch_dims:[] ~input_dims:[] ~output_dims:[upto + 1] ?axis_labels:axis_label
    (First Range_over_offsets)

let range_of_shape ?desc_label ~is_form ?(batch_dims=[]) ?(input_dims=[]) ?(output_dims=[]) ?axis_labels () =
  let dims = Array.concat_map [|batch_dims; output_dims; input_dims|] ~f:Array.of_list in
  Formula.term ?desc_label ~is_form ~needs_gradient:false ~batch_dims ~input_dims ~output_dims ?axis_labels
    ~label:("r"^NodeUI.dims_to_string dims) (First Range_over_offsets)

let data ?desc_label ?axis_labels ?(needs_gradient=false) ~label ~batch_dims ~output_dims reset_op =
  Formula.term ?desc_label ~label ~is_form:true ~needs_gradient
    ~batch_dims ~input_dims:[] ~output_dims ?axis_labels (Second reset_op)

let assign =
  let module NFDSL = struct module O = struct end end in
  let%nn_cd assign ~(lhs:Code.data) ~(rhs:Code.data) projections =
    lhs =: rhs ~projections in
  assign

let assign_op field ~(n:NodeUI.t) ~(n1:NodeUI.t) projections =
  assign ~lhs:(field n) ~rhs:(field n1) projections

(** A [stop_gradient] is an identity in the forward pass and a no-op in the backprop pass. *)
let stop_gradient =
  let grad_body ~n:_ ~n1:_ _projections = Code.Noop in
  let op_body = assign_op @@ Code.CDSL.data_of_node `Value in
  Formula.unop ~transpose_op:Pointwise_un ~op_label:"stop_grad" ~op_body ~grad_body
    ~is_form:true

(** A [stop_broadcast] mutates the partially-inferred shape of a formula in-place, substituting-in
    a [Fixed] marker on the dimensions. This way we avoid introducing a new node. *)
let stop_broadcast m = Shape.set_dims_type m.Formula.shape Shape.fixed

(** [identity] introduces a new node, which is an identity in both the forward and backward pass. *)
let identity ?desc_label ~is_form m =
  let grad_body ~(n:NodeUI.t) ~(n1:NodeUI.t) = 
    assign_op (Code.CDSL.data_of_node `Grad) ~n:n1 ~n1:n in
  let op_body = assign_op @@ Code.CDSL.data_of_node `Value in
  Formula.(unop ?desc_label ~init_shape:m.shape ~transpose_op:Pointwise_un ~op_label:"="
             ~op_body ~grad_body ~is_form)

module O = struct
  let ( * ) = matmul ~is_form:true
  let ( *. ) = pointmul ~is_form:true
  let (+) = add ~is_form:true
  let ( **. ) ?desc_label base exp = pointpow ?desc_label exp base ~is_form:true
  let (!/) = relu ~is_form:true
  let (!~) ?desc_label label = Formula.params ?desc_label label
  let (!.) = Formula.number ~is_form:true
  let (-) ?desc_label m1 m2 = (+) ?desc_label m1 (!.(-1.) *. m2)
  let (~-) ?desc_label m = ( *. ) ?desc_label !.(-1.) m
  let (/.) ?desc_label m1 m2 = ( *. ) ?desc_label m1 (m2 **. (-1.0))
end
      
module FDSL = struct
  include Formula.FDSL
  module O = O
  let einsum ?desc_label s = einsum ?desc_label s ~is_form:true
  let einsum1 ?desc_label s = einsum1 ?desc_label s ~is_form:true
  let range = range ~is_form:true
  let range_of_shape = range_of_shape ~is_form:true
  let data = data
  let stop_broadcast = stop_broadcast
  let stop_gradient = stop_gradient
end


module NFO = struct
  include NFO_without_pow
  let ( **. ) ?desc_label base exp = pointpow ?desc_label exp base ~is_form:false
  let (/.) ?desc_label m1 m2 = ( *. ) ?desc_label m1 (m2 **. (-1.0))
end

module NFDSL = struct
  include Formula.NFDSL
  module O = NFO
  let einsum ?desc_label s = einsum ?desc_label s ~is_form:false
  let einsum1 ?desc_label s = einsum1 ?desc_label s ~is_form:false
  let term = Formula.term ~is_form:false
  let range = range ~is_form:false
  let range_of_shape = range_of_shape ~is_form:false
end
