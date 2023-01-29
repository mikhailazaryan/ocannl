(** `Node`: the computation type, global state and utils which the `Formula` staged code uses. *)
(* Do not depend on Base to minimize dependencies. *)
module A = Bigarray.Genarray
type elt = Bigarray.float32_elt
type data = (float, elt, Bigarray.c_layout) A.t

let error_message__ : string option ref = ref None
let set_error_message exc =
  let msg = Printexc.to_string exc^"\n"^Printexc.get_backtrace() in
  error_message__ := Some msg

let dims (arr: data) = A.dims arr
  
 let create_array = A.create Bigarray.Float32 Bigarray.C_layout
 let empty = create_array [||]

type t = {
  mutable value: data;
  mutable grad: data;
  mutable forward: (unit -> unit) option;
  mutable backprop: (unit -> unit) option;
  label: string;
  id: int;
}

type state = {
  mutable unique_id: int;
  node_store: (int, t) Hashtbl.t;
}

let global = {
  unique_id = 1;
  node_store = Hashtbl.create 16;
}
let get uid = Hashtbl.find global.node_store uid

let create ~label =
  let node = {
    value=empty; grad=empty;
    forward=None; backprop=None;
    label;
    id=let uid = global.unique_id in global.unique_id <- global.unique_id + 1; uid
  } in
  Hashtbl.add global.node_store node.id node;
  node

let minus = (-)