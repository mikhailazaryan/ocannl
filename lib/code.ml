(** The code for operating on n-dimensional arrays. *)
open Base

type precision =
  | Half
  | Single
  | Double

type data = {node: Ocannl_runtime.Node.t; field: [`Value | `Grad]}
type routine = {node: Ocannl_runtime.Node.t; field: [`Forward | `Backprop]}

type binop =
  | Skip_arg
  | Add
  | Mul
  | Relu_gate
  | Uniform

type unop =
  | Identity
  | Relu

type t =
  | Par of t * t
  (** These tasks can proceed in parallel, there is no interaction. *)
  | ParHint of t * t
  (** Computing [ParHint (c1, c2)] can proceed in parallel on [c1] and [c2], but when [c2] reads values
      that [c1] writes, the writes in [c1] must occur before the reads in [c2]. *)
  | Seq of t * t
  (** These tasks can only benefit from mutual parallelism via operator fusion / loop fusion. *)
  | Accum_binop of {
      zero_out: bool;
      accum: binop; op: binop;
      lhs: data; rhs1: data; rhs2: data;
      projections: unit -> Shape.projections;
      precision: precision }
  | Accum_unop of {
      zero_out: bool;
      accum: binop; op: unop;
      lhs: data; rhs: data;
      projections: unit -> Shape.projections;
      precision: precision }
  | Create of {
        tensor: data; precision: precision; dims: unit -> int array;
        init_values: float array;
        (** [init_values] can be empty -- no initialization, single number -- initialize the whole tensor,
            the length of the tensor -- initialize from numbers where the rightmost axis is contiguous. *)
      }
  | Reset of {
        tensor: data; dims: unit -> int array;
        reset_values: float array;
        (** [reset_values] can be empty -- no initialization, single number -- initialize the whole tensor,
            the length of the tensor -- initialize from numbers where the rightmost axis is contiguous. *)
      }
  | Noop

(** Dynamically loading a program executes [initialization] and bounds the [procedure] to [routine]. *)
type program = {initialization: t; procedure: t; routine: routine}

let sprint_code (c: t): string = ignore c; failwith "NOT IMPLEMENTED YET"
let sprint_program (c: program): string = ignore c; failwith "NOT IMPLEMENTED YET"