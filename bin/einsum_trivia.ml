open Base
open Ocannl
module CDSL = Code.CDSL
module FDSL = Operation.FDSL

let () = Session.SDSL.set_executor Gccjit

let () =
  let open Session.SDSL in
  drop_all_sessions ();
  Random.init 0;
  let a = FDSL.range_of_shape ~batch_dims:[ CDSL.dim 3 ] ~input_dims:[ CDSL.dim 4 ] ~output_dims:[ CDSL.dim 2 ] () in
  let b = FDSL.range_of_shape ~batch_dims:[ CDSL.dim 3 ] ~input_dims:[ CDSL.dim 1 ] ~output_dims:[ CDSL.dim 4 ] () in
  let%nn_op c = a *+ "...|i->1; ...|...->i => ...|i" b in
  refresh_session ();
  print_formula ~with_code:false ~with_grad:false `Default @@ a;
  print_formula ~with_code:false ~with_grad:false `Default @@ b;
  print_formula ~with_code:false ~with_grad:false `Default @@ c
