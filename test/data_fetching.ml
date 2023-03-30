open Base
open Ocannl
module FDSL = Operation.FDSL

let () = Session.SDSL.set_executor OCaml

let%expect_test "Constants and synthetic data" =
  (* let open Operation.FDSL in *)
  let open Session.SDSL in
  drop_all_sessions();
  Random.init 0;
  let big_range = Array.init 300 ~f:(Int.to_float) in
  let r_data = FDSL.data ~label:"big_range" ~batch_dims:[2] ~output_dims:[3;5]
      (Init_op (Fixed_constant big_range)) in
  refresh_session ();
  print_formula ~with_code:false ~with_grad:false `Default @@ r_data;
  [%expect {|
    ┌────────────────────────────────────────────────────────────────────────────────────────────────────┐
    │[1]: shape 0:2|1:3,2:5                                                                              │
    │┌──────┬─────────────────────────────────────────────┬─────────────────────────────────────────────┐│
    ││      │0 @ 0                                        │1 @ 0                                        ││
    ││      │axis 2                                       │axis 2                                       ││
    │├──────┼─────────────────────────────────────────────┼─────────────────────────────────────────────┤│
    ││axis 1│ 0.00e+0  1.00e+0  2.00e+0  3.00e+0  4.00e+0 │ 1.50e+1  1.60e+1  1.70e+1  1.80e+1  1.90e+1 ││
    ││      │ 5.00e+0  6.00e+0  7.00e+0  8.00e+0  9.00e+0 │ 2.00e+1  2.10e+1  2.20e+1  2.30e+1  2.40e+1 ││
    ││      │ 1.00e+1  1.10e+1  1.20e+1  1.30e+1  1.40e+1 │ 2.50e+1  2.60e+1  2.70e+1  2.80e+1  2.90e+1 ││
    │└──────┴─────────────────────────────────────────────┴─────────────────────────────────────────────┘│
    └────────────────────────────────────────────────────────────────────────────────────────────────────┘ |}];
  refresh_session ();
  print_formula ~with_code:false ~with_grad:false `Default @@ r_data;
  [%expect {|
    ┌────────────────────────────────────────────────────────────────────────────────────────────────────┐
    │[1]: shape 0:2|1:3,2:5                                                                              │
    │┌──────┬─────────────────────────────────────────────┬─────────────────────────────────────────────┐│
    ││      │0 @ 0                                        │1 @ 0                                        ││
    ││      │axis 2                                       │axis 2                                       ││
    │├──────┼─────────────────────────────────────────────┼─────────────────────────────────────────────┤│
    ││axis 1│ 3.00e+1  3.10e+1  3.20e+1  3.30e+1  3.40e+1 │ 4.50e+1  4.60e+1  4.70e+1  4.80e+1  4.90e+1 ││
    ││      │ 3.50e+1  3.60e+1  3.70e+1  3.80e+1  3.90e+1 │ 5.00e+1  5.10e+1  5.20e+1  5.30e+1  5.40e+1 ││
    ││      │ 4.00e+1  4.10e+1  4.20e+1  4.30e+1  4.40e+1 │ 5.50e+1  5.60e+1  5.70e+1  5.80e+1  5.90e+1 ││
    │└──────┴─────────────────────────────────────────────┴─────────────────────────────────────────────┘│
    └────────────────────────────────────────────────────────────────────────────────────────────────────┘ |}];
  refresh_session ();
  print_formula ~with_code:false ~with_grad:false `Default @@ r_data;
  [%expect {|
    ┌────────────────────────────────────────────────────────────────────────────────────────────────────┐
    │[1]: shape 0:2|1:3,2:5                                                                              │
    │┌──────┬─────────────────────────────────────────────┬─────────────────────────────────────────────┐│
    ││      │0 @ 0                                        │1 @ 0                                        ││
    ││      │axis 2                                       │axis 2                                       ││
    │├──────┼─────────────────────────────────────────────┼─────────────────────────────────────────────┤│
    ││axis 1│ 6.00e+1  6.10e+1  6.20e+1  6.30e+1  6.40e+1 │ 7.50e+1  7.60e+1  7.70e+1  7.80e+1  7.90e+1 ││
    ││      │ 6.50e+1  6.60e+1  6.70e+1  6.80e+1  6.90e+1 │ 8.00e+1  8.10e+1  8.20e+1  8.30e+1  8.40e+1 ││
    ││      │ 7.00e+1  7.10e+1  7.20e+1  7.30e+1  7.40e+1 │ 8.50e+1  8.60e+1  8.70e+1  8.80e+1  8.90e+1 ││
    │└──────┴─────────────────────────────────────────────┴─────────────────────────────────────────────┘│
    └────────────────────────────────────────────────────────────────────────────────────────────────────┘ |}];
  let c_data = FDSL.data ~label:"fetch_callback" ~batch_dims:[1] ~output_dims:[2;3]
    (Compute_point (fun ~session_step ~dims:_ ~idcs ->
          Int.to_float @@ session_step*100 + idcs.(1)*10 + idcs.(2))) in
  refresh_session ();
  print_formula ~with_code:false ~with_grad:false `Default @@ c_data;
  [%expect {|
    ┌────────────────────────────────────┐
    │[2]: shape 0:1|1:2,2:3              │
    │┌──────┬───────────────────────────┐│
    ││      │0 @ 0                      ││
    ││      │axis 2                     ││
    │├──────┼───────────────────────────┤│
    ││axis 1│ 3.00e+2  3.01e+2  3.02e+2 ││
    ││      │ 3.10e+2  3.11e+2  3.12e+2 ││
    │└──────┴───────────────────────────┘│
    └────────────────────────────────────┘ |}];
  refresh_session ();
  print_formula ~with_code:false ~with_grad:false `Default @@ c_data;
  [%expect {|
    ┌────────────────────────────────────┐
    │[2]: shape 0:1|1:2,2:3              │
    │┌──────┬───────────────────────────┐│
    ││      │0 @ 0                      ││
    ││      │axis 2                     ││
    │├──────┼───────────────────────────┤│
    ││axis 1│ 4.00e+2  4.01e+2  4.02e+2 ││
    ││      │ 4.10e+2  4.11e+2  4.12e+2 ││
    │└──────┴───────────────────────────┘│
    └────────────────────────────────────┘ |}];
  refresh_session ();
  print_formula ~with_code:false ~with_grad:false `Default @@ c_data;
  [%expect {|
    ┌────────────────────────────────────┐
    │[2]: shape 0:1|1:2,2:3              │
    │┌──────┬───────────────────────────┐│
    ││      │0 @ 0                      ││
    ││      │axis 2                     ││
    │├──────┼───────────────────────────┤│
    ││axis 1│ 5.00e+2  5.01e+2  5.02e+2 ││
    ││      │ 5.10e+2  5.11e+2  5.12e+2 ││
    │└──────┴───────────────────────────┘│
    └────────────────────────────────────┘ |}]
