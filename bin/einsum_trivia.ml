open Base
open Ocannl
module IDX = Arrayjit.Indexing.IDX
module CDSL = Arrayjit.Low_level.CDSL
module TDSL = Operation.TDSL
module Utils = Arrayjit.Utils

let () =
  Random.init 0;
  let module Backend = (val Train.fresh_backend ()) in
  let device = Backend.get_device ~ordinal:0 in
  let ctx = Backend.init device in
  Utils.settings.output_debug_files_in_run_directory <- true;
  let a = TDSL.range_of_shape ~label:[ "a" ] ~batch_dims:[ 3 ] ~input_dims:[ 4 ] ~output_dims:[ 2 ] () in
  let b = TDSL.range_of_shape ~label:[ "b" ] ~batch_dims:[ 3 ] ~input_dims:[ 5 ] ~output_dims:[ 4 ] () in
  let%op c = a *+ "...|i->1; ...|...->i => ...|i" b in
  let jitted = Backend.jit ctx ~verbose:true IDX.empty @@ Train.forward c in
  Train.sync_run ~verbose:true (module Backend) jitted c;
  Tensor.print ~with_code:false ~with_grad:false `Default @@ a;
  Tensor.print ~with_code:false ~with_grad:false `Default @@ b;
  Tensor.print ~with_code:false ~with_grad:false `Default @@ c;
  Stdlib.Format.force_newline ()
