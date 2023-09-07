open Base
(** N-dimensional arrays: a precision-handling wrapper for {!Bigarray.Genarray} and its utilities. *)

module A = Bigarray.Genarray

exception User_error of string

(** {2 *** Handling of precisions ***} *)

type ('ocaml, 'elt_t) bigarray = ('ocaml, 'elt_t, Bigarray.c_layout) A.t

let sexp_of_bigarray (arr : ('a, 'b) bigarray) =
  let dims = A.dims arr in
  Sexp.Atom ("bigarray_dims_" ^ String.concat_array ~sep:"x" (Array.map dims ~f:Int.to_string))

type byte_nd = (char, Ops.uint8_elt) bigarray
type half_nd = (float, Ops.float16_elt) bigarray
type single_nd = (float, Ops.float32_elt) bigarray
type double_nd = (float, Ops.float64_elt) bigarray

type t =
  | Byte_nd of (byte_nd[@sexp.opaque])
  | Half_nd of (half_nd[@sexp.opaque])
  | Single_nd of (single_nd[@sexp.opaque])
  | Double_nd of (double_nd[@sexp.opaque])
[@@deriving sexp_of]

let as_array (type ocaml elt_t) (prec : (ocaml, elt_t) Ops.precision) (arr : (ocaml, elt_t) bigarray) =
  match prec with
  | Byte -> Byte_nd arr
  | Half -> Half_nd arr
  | Single -> Single_nd arr
  | Double -> Double_nd arr

let precision_to_bigarray_kind (type ocaml elt_t) (prec : (ocaml, elt_t) Ops.precision) :
    (ocaml, elt_t) Bigarray.kind =
  match prec with
  | Byte -> Bigarray.Char
  | Half -> Bigarray.Float32
  | Single -> Bigarray.Float32
  | Double -> Bigarray.Float64

let precision_string = function
  | Byte_nd _ -> "byte"
  | Half_nd _ -> "half"
  | Single_nd _ -> "single"
  | Double_nd _ -> "double"

let default_kind = Ops.Single
let is_double_prec_t = function Double_nd _ -> true | _ -> false

let get_prec = function
  | Byte_nd _ -> Ops.byte
  | Half_nd _ -> Ops.half
  | Single_nd _ -> Ops.single
  | Double_nd _ -> Ops.double

type 'r map_with_prec = {
  f : 'ocaml 'elt_t. ('ocaml, 'elt_t) Ops.precision -> ('ocaml, 'elt_t) bigarray -> 'r;
}

let map_with_prec { f } = function
  | Byte_nd arr -> f Byte arr
  | Half_nd arr -> f Half arr
  | Single_nd arr -> f Single arr
  | Double_nd arr -> f Double arr

let create_bigarray_of_prec (type ocaml elt_t) (prec : (ocaml, elt_t) Ops.precision) dims :
    (ocaml, elt_t) bigarray =
  A.create (precision_to_bigarray_kind prec) Bigarray.C_layout dims

let init_bigarray_of_prec (type ocaml elt_t) (prec : (ocaml, elt_t) Ops.precision) dims
    ~(f : int array -> ocaml) : (ocaml, elt_t) bigarray =
  A.init (precision_to_bigarray_kind prec) Bigarray.C_layout dims f

let indices_to_offset ~dims ~idcs =
  Array.fold2_exn dims idcs ~init:0 ~f:(fun accu dim idx -> (accu * dim) + idx)

let fixed_state_for_init = ref None

let create_bigarray (type ocaml elt_t) (prec : (ocaml, elt_t) Ops.precision) ~dims (init_op : Ops.init_op) :
    (ocaml, elt_t) bigarray =
  Option.iter !fixed_state_for_init ~f:(fun seed -> Random.init seed);
  let constant_fill_f f values strict =
    let len = Array.length values in
    if strict then (
      let size = Array.fold ~init:1 ~f:( * ) dims in
      if size <> len then
        raise
        @@ User_error
             [%string
               "Ndarray.create_bigarray: Constant_fill: invalid data size %{len#Int}, expected %{size#Int}"];
      init_bigarray_of_prec prec dims ~f:(fun idcs -> f values.(indices_to_offset ~dims ~idcs)))
    else init_bigarray_of_prec prec dims ~f:(fun idcs -> f values.(indices_to_offset ~dims ~idcs % len))
  in
  let constant_fill_float values strict = constant_fill_f Fn.id values strict in
  match (prec, init_op) with
  | Ops.Half, Constant_fill { values; strict } -> constant_fill_float values strict
  | Ops.Half, Range_over_offsets ->
      init_bigarray_of_prec prec dims ~f:(fun idcs -> Float.of_int @@ indices_to_offset ~dims ~idcs)
  | Ops.Half, Standard_uniform -> init_bigarray_of_prec prec dims ~f:(fun _ -> Random.float_range 0.0 1.0)
  | Ops.Single, Constant_fill { values; strict } -> constant_fill_float values strict
  | Ops.Single, Range_over_offsets ->
      init_bigarray_of_prec prec dims ~f:(fun idcs -> Float.of_int @@ indices_to_offset ~dims ~idcs)
  | Ops.Single, Standard_uniform -> init_bigarray_of_prec prec dims ~f:(fun _ -> Random.float_range 0.0 1.0)
  | Ops.Double, Constant_fill { values; strict } -> constant_fill_float values strict
  | Ops.Double, Range_over_offsets ->
      init_bigarray_of_prec prec dims ~f:(fun idcs -> Float.of_int @@ indices_to_offset ~dims ~idcs)
  | Ops.Double, Standard_uniform -> init_bigarray_of_prec prec dims ~f:(fun _ -> Random.float_range 0.0 1.0)
  | Ops.Byte, Constant_fill { values; strict } ->
      constant_fill_f (Fn.compose Char.of_int_exn Int.of_float) values strict
  | Ops.Byte, Range_over_offsets ->
      init_bigarray_of_prec prec dims ~f:(fun idcs -> Char.of_int_exn @@ indices_to_offset ~dims ~idcs)
  | Ops.Byte, Standard_uniform -> init_bigarray_of_prec prec dims ~f:(fun _ -> Random.char ())
  | _, File_mapped (filename, stored_prec) ->
      (* See: https://github.com/janestreet/torch/blob/master/src/torch/dataset_helper.ml#L3 *)
      if not @@ Ops.equal_prec stored_prec (Ops.pack_prec prec) then
        raise
        @@ User_error
             [%string
               "Ndarray.create_bigarray: File_mapped: precision mismatch %{Ops.prec_string stored_prec} vs \
                %{Ops.precision_to_string prec}"];
      let fd = Unix.openfile filename [ Unix.O_RDONLY ] 0o640 in
      let len = Unix.lseek fd 0 Unix.SEEK_END in
      ignore (Unix.lseek fd 0 Unix.SEEK_SET : int);
      let size = Array.fold ~init:1 ~f:( * ) dims in
      if len / Ops.prec_in_bytes stored_prec <> size then (
        Unix.close fd;
        raise
        @@ User_error
             [%string
               "Ndarray.create_bigarray: File_mapped: invalid file bytes %{len#Int}, expected %{size * \
                Ops.prec_in_bytes stored_prec#Int}"]);
      let ba =
        Unix.map_file fd (precision_to_bigarray_kind prec) Bigarray.c_layout false dims ~pos:(Int64.of_int 0)
      in
      Unix.close fd;
      ba

let create_array prec ~dims init_op =
  let f prec = as_array prec @@ create_bigarray prec ~dims init_op in
  Ops.map_prec { f } prec

let empty_array prec = create_array prec ~dims:[||] (Constant_fill { values = [| 0.0 |]; strict = false })

(** {2 *** Accessing ***} *)

type 'r map_as_bigarray = { f : 'ocaml 'elt_t. ('ocaml, 'elt_t) bigarray -> 'r }

let map { f } = function
  | Byte_nd arr -> f arr
  | Half_nd arr -> f arr
  | Single_nd arr -> f arr
  | Double_nd arr -> f arr

type 'r map2_as_bigarray = {
  f2 : 'ocaml 'elt_t. ('ocaml, 'elt_t) bigarray -> ('ocaml, 'elt_t) bigarray -> 'r;
}

let map2 { f2 } x1 x2 =
  match (x1, x2) with
  | Byte_nd arr1, Byte_nd arr2 -> f2 arr1 arr2
  | Half_nd arr1, Half_nd arr2 -> f2 arr1 arr2
  | Single_nd arr1, Single_nd arr2 -> f2 arr1 arr2
  | Double_nd arr1, Double_nd arr2 -> f2 arr1 arr2
  | _ -> invalid_arg "Ndarray.map2: precision mismatch"

let dims = map { f = A.dims }

let get_voidptr =
  let f arr =
    let open Ctypes in
    coerce
      (ptr @@ typ_of_bigarray_kind @@ Bigarray.Genarray.kind arr)
      (ptr void) (bigarray_start genarray arr)
  in
  map { f }

let get_as_float arr idx =
  match arr with
  | Byte_nd arr -> Float.of_int @@ Char.to_int @@ A.get arr idx
  | Half_nd arr -> A.get arr idx
  | Single_nd arr -> A.get arr idx
  | Double_nd arr -> A.get arr idx

let set_from_float arr idx v =
  match arr with
  | Byte_nd arr -> A.set arr idx @@ Char.of_int_exn @@ Int.of_float v
  | Half_nd arr -> A.set arr idx v
  | Single_nd arr -> A.set arr idx v
  | Double_nd arr -> A.set arr idx v

let fill_from_float arr v =
  match arr with
  | Byte_nd arr -> A.fill arr @@ Char.of_int_exn @@ Int.of_float v
  | Half_nd arr -> A.fill arr v
  | Single_nd arr -> A.fill arr v
  | Double_nd arr -> A.fill arr v

let set_bigarray arr ~f =
  let dims = A.dims arr in
  let rec cloop idx f col =
    if col = Array.length idx then A.set arr idx (f idx)
    else
      for j = 0 to Int.pred dims.(col) do
        idx.(col) <- j;
        cloop idx f (Int.succ col)
      done
  in
  let len = Array.length dims in
  cloop (Array.create ~len 0) f 0

let reset_bigarray (init_op : Ops.init_op) (type o b) (prec : (o, b) Ops.precision) (arr : (o, b) bigarray) =
  let dims = A.dims arr in
  let constant_set_f f values strict =
    let len = Array.length values in
    if strict then (
      let size = Array.fold ~init:1 ~f:( * ) dims in
      if size <> len then
        raise
        @@ User_error
             [%string
               "Ndarray.reset_bigarray: Constant_fill: invalid data size %{len#Int}, expected %{size#Int}"];
      set_bigarray arr ~f:(fun idcs -> f values.(indices_to_offset ~dims ~idcs)))
    else set_bigarray arr ~f:(fun idcs -> f values.(indices_to_offset ~dims ~idcs % len))
  in
  let constant_set_float values strict = constant_set_f Fn.id values strict in
  match (prec, init_op) with
  | Byte, Constant_fill { values; strict } ->
      constant_set_f (Fn.compose Char.of_int_exn Int.of_float) values strict
  | Byte, Range_over_offsets ->
      set_bigarray arr ~f:(fun idcs -> Char.of_int_exn @@ indices_to_offset ~dims ~idcs)
  | Byte, Standard_uniform -> set_bigarray arr ~f:(fun _ -> Random.char ())
  | Half, Constant_fill { values; strict } -> constant_set_float values strict
  | Half, Range_over_offsets ->
      set_bigarray arr ~f:(fun idcs -> Float.of_int @@ indices_to_offset ~dims ~idcs)
  | Half, Standard_uniform -> set_bigarray arr ~f:(fun _ -> Random.float_range 0.0 1.0)
  | Single, Constant_fill { values; strict } -> constant_set_float values strict
  | Single, Range_over_offsets ->
      set_bigarray arr ~f:(fun idcs -> Float.of_int @@ indices_to_offset ~dims ~idcs)
  | Single, Standard_uniform -> set_bigarray arr ~f:(fun _ -> Random.float_range 0.0 1.0)
  | Double, Constant_fill { values; strict } -> constant_set_float values strict
  | Double, Range_over_offsets ->
      set_bigarray arr ~f:(fun idcs -> Float.of_int @@ indices_to_offset ~dims ~idcs)
  | Double, Standard_uniform -> set_bigarray arr ~f:(fun _ -> Random.float_range 0.0 1.0)
  | _, File_mapped _ -> A.blit (create_bigarray prec ~dims init_op) arr

let reset init_op arr =
  let f arr = reset_bigarray init_op arr in
  map_with_prec { f } arr

let fold_bigarray arr ~init ~f =
  let dims = A.dims arr in
  let accu = ref init in
  let rec cloop idx col =
    if col = Array.length idx then accu := f !accu idx @@ A.get arr idx
    else
      for j = 0 to Int.pred dims.(col) do
        idx.(col) <- j;
        cloop idx (Int.succ col)
      done
  in
  let len = Array.length dims in
  cloop (Array.create ~len 0) 0;
  !accu

let fold_as_float ~init ~f arr =
  match arr with
  | Byte_nd arr -> fold_bigarray ~init ~f:(fun accu idx c -> f accu idx @@ Float.of_int @@ Char.to_int c) arr
  | Half_nd arr -> fold_bigarray ~init ~f arr
  | Single_nd arr -> fold_bigarray ~init ~f arr
  | Double_nd arr -> fold_bigarray ~init ~f arr

let size_in_bytes v =
  (* Cheating here because 1 number Bigarray is same size as empty Bigarray:
     it's more informative to report the cases differently. *)
  let f arr = if Array.is_empty @@ A.dims arr then 0 else A.size_in_bytes arr in
  map { f } v

let retrieve_2d_points ?from_axis ~xdim ~ydim arr =
  let dims = dims arr in
  if Array.is_empty dims then [||]
  else
    let n_axes = Array.length dims in
    let from_axis = Option.value from_axis ~default:(n_axes - 1) in
    let result = ref [] in
    let idx = Array.create ~len:n_axes 0 in
    let rec iter axis =
      if axis = n_axes then
        let x =
          idx.(from_axis) <- xdim;
          get_as_float arr idx
        in
        let y =
          idx.(from_axis) <- ydim;
          get_as_float arr idx
        in
        result := (x, y) :: !result
      else if axis = from_axis then iter (axis + 1)
      else
        for p = 0 to dims.(axis) - 1 do
          idx.(axis) <- p;
          iter (axis + 1)
        done
    in
    iter 0;
    Array.of_list_rev !result

let retrieve_1d_points ?from_axis ~xdim arr =
  let dims = dims arr in
  if Array.is_empty dims then [||]
  else
    let n_axes = Array.length dims in
    let from_axis = Option.value from_axis ~default:(n_axes - 1) in
    let result = ref [] in
    let idx = Array.create ~len:n_axes 0 in
    let rec iter axis =
      if axis = n_axes then
        let x =
          idx.(from_axis) <- xdim;
          get_as_float arr idx
        in
        result := x :: !result
      else if axis = from_axis then iter (axis + 1)
      else
        for p = 0 to dims.(axis) - 1 do
          idx.(axis) <- p;
          iter (axis + 1)
        done
    in
    iter 0;
    Array.of_list_rev !result

(** {2 *** Printing ***} *)

(** Dimensions to string, ["x"]-separated, e.g. 1x2x3 for batch dims 1, input dims 3, output dims 2.
    Outputs ["-"] for empty dimensions. *)
let int_dims_to_string ?(with_axis_numbers = false) dims =
  if Array.is_empty dims then "-"
  else if with_axis_numbers then
    String.concat_array ~sep:" x " @@ Array.mapi dims ~f:(fun d s -> Int.to_string d ^ ":" ^ Int.to_string s)
  else String.concat_array ~sep:"x" @@ Array.map dims ~f:Int.to_string

(** When rendering arrays, outputs this many decimal digits. *)
let print_decimals_precision = ref 2

let concise_float ~prec v =
  Printf.sprintf "%.*e" prec v
  |> (* The C99 standard requires at least two digits for the exponent, but the leading zero
        is a waste of space. *)
  String.substr_replace_first ~pattern:"e+0" ~with_:"e+"
  |> String.substr_replace_first ~pattern:"e-0" ~with_:"e-"

(** Prints 0-based [indices] entries out of [arr], where a number between [-5] and [-1] in an axis means
    to print out the axis, and a non-negative number means to print out only the indexed dimension of the axis.
    Prints up to [entries_per_axis] or [entries_per_axis+1] entries per axis, possibly with ellipsis
    in the middle. [labels] provides the axis labels for all axes (use [""] or ["_"] for no label).
    The last label corresponds to axis [-1] etc. The printed out axes are arranged as:
    * -1: a horizontal segment in an inner rectangle (i.e. column numbers of the inner rectangle),
    * -2: a sequence of segments in a line of text (i.e. column numbers of an outer rectangle),
    * -3: a vertical segment in an inner rectangle (i.e. row numbers of the inner rectangle),
    * -4: a vertical sequence of segments (i.e. column numbers of an outer rectangle),
    * -5: a sequence of screens of text (i.e. stack numbers of outer rectangles).
    Printing out of axis [-5] is interrupted when a callback called in between each outer rectangle
    returns true. *)
let render_array ?(brief = false) ?(prefix = "") ?(entries_per_axis = 4) ?(labels = [||]) ~indices arr =
  let module B = PrintBox in
  let dims = dims arr in
  let has_nan = fold_as_float ~init:false ~f:(fun has_nan _ v -> has_nan || Float.is_nan v) arr in
  let has_inf = fold_as_float ~init:false ~f:(fun has_inf _ v -> has_inf || Float.(v = infinity)) arr in
  let has_neg_inf =
    fold_as_float ~init:false ~f:(fun has_neg_inf _ v -> has_neg_inf || Float.(v = neg_infinity)) arr
  in
  let header =
    prefix
    ^ (if has_nan || has_inf || has_neg_inf then " includes" else "")
    ^ (if has_nan then " NaN" else "")
    ^ (if has_inf then " pos. inf." else "")
    ^ if has_neg_inf then " neg. inf." else ""
  in
  if Array.is_empty dims then B.vlist ~bars:false [ B.text header; B.line "<void>" ]
  else
    let indices = Array.copy indices in
    let entries_per_axis = if entries_per_axis % 2 = 0 then entries_per_axis + 1 else entries_per_axis in
    let var_indices = Array.filter_mapi indices ~f:(fun i d -> if d <= -1 then Some (5 + d, i) else None) in
    let extra_indices =
      [| (0, -1); (1, -1); (2, -1); (3, -1); (4, -1) |]
      |> Array.filter ~f:(Fn.non @@ Array.mem var_indices ~equal:(fun (a, _) (b, _) -> Int.equal a b))
    in
    let var_indices = Array.append extra_indices var_indices in
    Array.sort ~compare:(fun (a, _) (b, _) -> Int.compare a b) var_indices;
    let var_indices = Array.map ~f:snd @@ var_indices in
    let ind0, ind1, ind2, ind3, ind4 =
      match var_indices with
      | [| ind0; ind1; ind2; ind3; ind4 |] -> (ind0, ind1, ind2, ind3, ind4)
      | _ -> raise @@ User_error "render: indices should contain at most 5 negative numbers"
    in
    let labels = Array.map labels ~f:(fun l -> if String.is_empty l then "" else l ^ "=") in
    let entries_per_axis = (entries_per_axis / 2 * 2) + 1 in
    let size0 = if ind0 = -1 then 1 else min dims.(ind0) entries_per_axis in
    let size1 = if ind1 = -1 then 1 else min dims.(ind1) entries_per_axis in
    let size2 = if ind2 = -1 then 1 else min dims.(ind2) entries_per_axis in
    let size3 = if ind3 = -1 then 1 else min dims.(ind3) entries_per_axis in
    let size4 = if ind4 = -1 then 1 else min dims.(ind4) entries_per_axis in
    let no_label ind = Array.length labels <= ind in
    let label0 = if ind0 = -1 || no_label ind0 then "" else labels.(ind0) in
    let label1 = if ind1 = -1 || no_label ind1 then "" else labels.(ind1) in
    let label2 = if ind2 = -1 || no_label ind2 then "" else labels.(ind2) in
    let label3 = if ind3 = -1 || no_label ind3 then "" else labels.(ind3) in
    let label4 = if ind4 = -1 || no_label ind4 then "" else labels.(ind4) in
    (* FIXME: handle ellipsis. *)
    let halfpoint = (entries_per_axis / 2) + 1 in
    let expand i ~ind =
      if dims.(ind) <= entries_per_axis then i
      else if i < halfpoint then i
      else dims.(ind) - entries_per_axis + i
    in
    let update_indices v i j k l =
      if ind0 <> -1 then indices.(ind0) <- expand v ~ind:ind0;
      if ind1 <> -1 then indices.(ind1) <- expand i ~ind:ind1;
      if ind2 <> -1 then indices.(ind2) <- expand j ~ind:ind2;
      if ind3 <> -1 then indices.(ind3) <- expand k ~ind:ind3;
      if ind4 <> -1 then indices.(ind4) <- expand l ~ind:ind4
    in
    let elide_for i ~ind = ind >= 0 && dims.(ind) > entries_per_axis && i + 1 = halfpoint in
    let is_ellipsis () = Array.existsi indices ~f:(fun ind i -> elide_for i ~ind) in
    let inner_grid v i j =
      B.init_grid ~bars:false ~line:size3 ~col:size4 (fun ~line ~col ->
          update_indices v i j line col;
          try
            B.hpad 1 @@ B.line
            @@
            if is_ellipsis () then "..."
            else concise_float ~prec:!print_decimals_precision (get_as_float arr indices)
          with Invalid_argument _ ->
            raise
            @@ User_error
                 [%string
                   "Invalid indices: %{int_dims_to_string indices} into array: %{(int_dims_to_string dims)}"])
    in
    let tag ?pos label ind =
      if ind = -1 then ""
      else
        match pos with
        | Some pos when elide_for pos ~ind -> "~~~~~"
        | Some pos when pos >= 0 -> Int.to_string (expand pos ~ind) ^ " @ " ^ label ^ Int.to_string ind
        | _ -> "axis " ^ label ^ Int.to_string ind
    in
    let nlines = if brief then size1 else size1 + 1 in
    let ncols = if brief then size2 else size2 + 1 in
    let outer_grid v =
      (if brief then Fn.id else B.frame)
      @@ B.init_grid ~bars:true ~line:nlines ~col:ncols (fun ~line ~col ->
             if (not brief) && line = 0 && col = 0 then
               B.lines @@ List.filter ~f:(Fn.non String.is_empty) @@ [ tag ~pos:v label0 ind0 ]
             else if (not brief) && line = 0 then
               B.lines
               @@ List.filter ~f:(Fn.non String.is_empty)
               @@ [ tag ~pos:(col - 1) label2 ind2; tag label4 ind4 ]
             else if (not brief) && col = 0 then
               B.lines
               @@ List.filter ~f:(Fn.non String.is_empty)
               @@ [ tag ~pos:(line - 1) label1 ind1; tag label3 ind3 ]
             else
               let nline = if brief then line else line - 1 in
               let ncol = if brief then col else col - 1 in
               if elide_for ncol ~ind:ind2 || elide_for nline ~ind:ind1 then B.hpad 1 @@ B.line "..."
               else inner_grid v nline ncol)
    in
    let screens =
      B.init_grid ~bars:true ~line:size0 ~col:1 (fun ~line ~col:_ ->
          if elide_for line ~ind:ind0 then B.hpad 1 @@ B.line "..." else outer_grid line)
    in
    (if brief then Fn.id else B.frame) @@ B.vlist ~bars:false [ B.text header; screens ]

let pp_array fmt ?prefix ?entries_per_axis ?labels ~indices arr =
  PrintBox_text.pp fmt @@ render_array ?prefix ?entries_per_axis ?labels ~indices arr

(** Prints the whole array in an inline syntax. *)
let pp_array_inline fmt ~num_batch_axes ~num_output_axes ~num_input_axes ?axes_spec arr =
  let dims = dims arr in
  let num_all_axes = num_batch_axes + num_output_axes + num_input_axes in
  let open Caml.Format in
  let ind = Array.copy dims in
  (match axes_spec with None -> () | Some spec -> fprintf fmt "\"%s\" " spec);
  let rec loop axis =
    let sep =
      if axis < num_batch_axes then ";" else if axis < num_batch_axes + num_output_axes then ";" else ","
    in
    let open_delim =
      if axis < num_batch_axes then "[|"
      else if axis < num_batch_axes + num_output_axes then "["
      else if axis = num_batch_axes + num_output_axes then ""
      else "("
    in
    let close_delim =
      if axis < num_batch_axes then "|]"
      else if axis < num_batch_axes + num_output_axes then "]"
      else if axis = num_batch_axes + num_output_axes then ""
      else ")"
    in
    if axis = num_all_axes then fprintf fmt "%.*f" !print_decimals_precision (get_as_float arr ind)
    else (
      fprintf fmt "@[<hov 2>%s@," open_delim;
      for i = 0 to dims.(axis) - 1 do
        ind.(axis) <- i;
        loop (axis + 1);
        if i < dims.(axis) - 1 then fprintf fmt "%s@ " sep
      done;
      fprintf fmt "@,%s@]" close_delim)
  in
  loop 0
