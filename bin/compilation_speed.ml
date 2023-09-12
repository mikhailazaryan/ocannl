open Base
open Ocannl
module LA = Arrayjit.Lazy_array
module IDX = Arrayjit.Indexing.IDX
module CDSL = Arrayjit.Low_level.CDSL
module TDSL = Operation.TDSL
module NTDSL = Operation.NTDSL

let benchmark_overhead backend () =
  let open (val backend : Arrayjit.Backends.Backend) in
  CDSL.disable_all_debugs ();
  Stdio.prerr_endline @@ "\n\n****** Benchmarking " ^ name ^ " ******";
  Random.init 0;
  let init_time = Time_now.nanoseconds_since_unix_epoch () in
  let%op f = (3 *. ("x" [ 5 ] **. 2)) - (4 *. x) + 5 in
  Train.set_fully_on_host x.value;
  Train.set_fully_on_host f.value;

  let device = get_device ~ordinal:0 in
  let ctx = init device in
  let update_f = Train.grad_update f in
  let jitted_f = jit ctx IDX.empty update_f in
  Tensor.iter_embedded_arrays f ~f:(fun a ->
      if from_host jitted_f.context a then Stdio.printf "Sent array %s.\n%!" @@ LA.name a);

  let xs = Array.init 100 ~f:Float.(fun i -> of_int i - 50.) in
  let open Tensor.O in
  let ys =
    Array.map xs ~f:(fun v ->
        let%cd update_x = x =: !.v in
        let jitted_x = jit ~name:"assign_x" jitted_f.context IDX.empty update_x in
        jitted_x.run ();
        await device;
        jitted_f.run ();
        await device;
        Tensor.iter_embedded_arrays f ~f:(fun a -> ignore (to_host jitted_f.context a : bool));
        f.@[0])
  in
  let plot_box =
    let open PrintBox_utils in
    plot ~size:(75, 35) ~x_label:"x" ~y_label:"f(x)"
      [ Scatterplot { points = Array.zip_exn xs ys; pixel = "#" } ]
  in
  let final_time = Time_now.nanoseconds_since_unix_epoch () in
  let time_in_sec = Int63.(to_float @@ (final_time - init_time)) /. 1000_000_000. in
  let result =
    PrintBox_utils.Benchmark
      {
        bench_title = name ^ " overhead";
        time_in_sec;
        (* FIXME: global mem consumption *)
        mem_in_bytes = 0;
        result_label = "x, f(x)";
        result = [%sexp_of: (float * float) list] @@ [ (xs.(0), ys.(0)); (xs.(50), ys.(50)) ];
      }
  in
  PrintBox_text.output Stdio.stdout plot_box;
  Stdio.print_endline "\n";
  result

let benchmarks =
  [
    benchmark_overhead (module Arrayjit.Backends.Gccjit_backend);
    benchmark_overhead (module Arrayjit.Backends.Cuda_backend);
  ]

let () =
  List.map benchmarks ~f:(fun bench -> bench ()) |> PrintBox_utils.table |> PrintBox_text.output Stdio.stdout
