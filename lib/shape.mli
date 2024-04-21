(** {1 Tensor shape types, shape inference, projection inference.} *)

(** {2 Labels specifications and einsum notation.}

    Definition and properties of the syntax of labels specifications and einsum notation:
    - Whitespace-insensitive except that whitespace separates identifiers.
    - Comes in two variants: single-character and multicharacter;
    - if there is a comma [','] anywhere in the initial text, the multicharacter version is used,
    - otherwise the single character version is used.
    - Currently, the only non-whitespace, non-alphanumeric characters that make sense / are allowed in a spec
      are: ['>', '|', '-', ',', '=', ';'].
    - identifier: single alphanum character in single-char mode, a sequence of alphanum characters otherwise
      (whitespace not allowed).
    - separators: a sequence of commas and whitespaces containing at least one comma.
    - axes_spec: separators? (identifier separators)* identifier separators?
    - ellipsis_spec: '...' <|> '..' identifier '..'
    - row_spec: axes_spec <|> ellipsis_spec axes_spec <|> axes_spec ellipsis_spec axes_spec
    - labels_spec: row_spec <|> row_spec '|' row_spec <|> row_spec '->' row_spec <|> row_spec '|' row_spec
      '->' row_spec.
    - permute_spec: labels_spec '=>' labels_spec
    - einsum_spec: labels_spec ';' labels_spec '=>' labels_spec

    If labels_spec does not contain ["|"] nor ["->"], each label is of the kind [Output]. If the spec doesn't
    contain ["|"], labels to the left of ["->"] are [Input] and to the right [Output]. Labels to the left of
    ["|"] are [Batch], and between ["|"] and ["->"] are [Input].

    The labels [".."ident".."], ["..."] (where [ident] does not contain any of the special characters) are
    only allowed once for a kind. They are used to enable (in-the-middle) broadcasting for the axis kind in
    the einsum-related shape inference (like the ellipsis ["..."] in [numpy.einsum]), and are translated to
    row variables. The ellipsis ["..."] is context dependent: in the batch row it is the same as
    ["..batch.."], in the input row the same as ["..input.."], in the output row the same as ["..output.."].
    When the same row variable is used in multiple rows, the corresponding broadcasted axes are matched
    pointwise in the resulting operation.

    The label ["_"] is a place-holder: it is not output to the resulting map but aligns the axes of other
    labels. *)

(** {2 User-ish API.} *)

open Base

type t = {
  mutable batch : Row.t;
  mutable input : Row.t;
  mutable output : Row.t;
  id : int;  (** A node that has the same shape as this shape. *)
  debug_name : string;
}
[@@deriving equal, fields, sexp]

type deduce_within_shape = Not_constrained | Input_equals_output [@@deriving compare, sexp, variants]

type compose_type =
  | Pointwise_bin  (** NumPy-style broadcast matching batch, input and output axes, e.g. as in [s1 + s2]. *)
  | Compose
      (** Compose the outputs of the second shape with the inputs of the first shape, i.e. the shape of
          [fun x -> s1(s2(x))], or [s1 * s2] where [*] is the inner product (e.g. matrix multiply). *)
  | Einsum of string
      (** The binary "einsum" syntax: RHS1;RHS2=>LHS, where RHSi, LHS are labels specifications. Since
          OCANNL's extended einsum notation supports both axis variables and row variables, it makes other
          compose types redundant. The [axis_labels] use pseudo-labels local to the notation, to line up the
          axes and row variables. The symmetric difference / disjunctive union of RHS1 and RHS2's
          pseudo-labels should be equal to LHS pseudo-labels.

          Note: The "right-hand-side" is on the left! I.e. the syntax is "rhs=>lhs", "rhs1;rhs2=>lhs". *)
[@@deriving sexp, equal]

type transpose_type =
  | Transpose  (** Swaps inputs and outputs of a shape, preserves batch axes. *)
  | Pointwise_un  (** Preserves the shape. *)
  | Permute of string  (** The unary "einsum" syntax: RHS1=>LHS. *)
  | Batch_slice of Arrayjit.Indexing.static_symbol  (** Removes the leftmost batch axis. *)
[@@deriving equal, sexp]

val make :
  ?batch_dims:int list ->
  ?input_dims:int list ->
  ?output_dims:int list ->
  ?batch_axes:(string * int) list ->
  ?input_axes:(string * int) list ->
  ?output_axes:(string * int) list ->
  ?deduced:deduce_within_shape ->
  debug_name:string ->
  id:int ->
  unit ->
  t
(** Creates a shape. [id] should be the id the associated tensor (if any). At most one of the pairs
    [batch_dims], [batch_axes] etc. should be given: if none, the corresponding row will be inferred.
    [batch_axes] etc. provide labels for the dimensions of the corresponding axes. Note that these are
    dimensions labels and not axis labels: they need not be unique for a row, are inferred when provided, and
    must match whenever the axis sizes must match. *)

val to_string_hum :
  ?style:[< `Axis_number_and_size | `Axis_size | `Only_labels > `Axis_size `Only_labels ] -> t -> string

(** {2 Internal-ish API.} *)

(** How to propagate shape updates and do the last update of [Tensor.t.shape] when finalizing the tensor. Axes
    are broadcast-expanded on a bottom-up update to fit the incoming shape. *)
type logic =
  | Broadcast of compose_type * t * t
      (** Matches the shapes for a binary operation.

          For [Broadcast (Einsum (ls1, ls2, ls3), s1, s2)], the labels of [s1] and [s2] must match according
          to the [ls1], [ls2] lineup, and the resulting shape inherits the labels according to the [ls3]
          lineup. *)
  | Transpose of transpose_type * t
      (** Permutes the axes of a shape. One case of [Transpose] is to swap inputs with outputs of [s1], hence
          the name. *)
  | Terminal of Arrayjit.Ops.init_op
      (** Extracts any available shape information from the initialization. E.g. for [File_mapped fn], opens
          the file [fn] to check its length. *)
[@@deriving equal, sexp]

type update_id [@@deriving equal, compare, hash, sexp]

val get_update_id : unit -> update_id

type update_step = { shape : t; logic : logic; id : update_id } [@@deriving sexp]
(** Data required for a shape inference update step. Ideally, an update should be performed at least twice,
    the second time after all the other relevant updates have been performed for the first time. In OCANNL,
    this is achieved by performing updates both as the tensors are constructed, and via lazy callbacks as the
    corresponding [Arrayjit.Indexing] dimensions and projections are first accessed. *)

val to_dims : t -> int array
val propagate_shapes : update_step -> unit

val derive_projections : update_step -> Arrayjit.Indexing.projections
(** Computes the indexing into subtensors given the shape information of a tensor. [derive_projections] should
    only be invoked when the shapes are fully inferred already! *)

val backprop_ith_arg : from_1:int -> Arrayjit.Indexing.projections -> Arrayjit.Indexing.projections
val of_spec : ?deduced:deduce_within_shape -> debug_name:string -> id:int -> string -> t
val default_display_indices : t -> int array
val to_labels : t -> string array

type 'a axis_map
type parsed_axis_labels

val axis_labels : parsed_axis_labels -> (string, int) Either.t axis_map
val axis_labels_of_spec : string -> parsed_axis_labels
val axis_map_to_dims_index : ?default:'a -> 'a axis_map -> 'a array
