open Base

module type No_device_backend = sig
  type context
  type jitted = { context : context; run : unit -> unit; bindings : unit Indexing.bindings }

  val initialize : unit -> unit
  val is_initialized : unit -> bool
  val init : unit -> context
  val finalize : context -> unit

  val jit :
    context -> ?name:string -> ?verbose:bool -> unit Indexing.bindings -> Assignments.t -> jitted

  val unsafe_cleanup : unit -> unit

  val from_host : context -> Lazy_array.t -> bool
  (** If the array is both hosted and in-context, copies from host to context and returns true. *)

  val to_host : context -> Lazy_array.t -> bool
  (** If the array is both hosted and in-context, copies from context to host and returns true. *)

  val merge :
    ?name_suffix:string -> Lazy_array.t -> dst:context -> accum:Ops.binop -> src:context -> jitted option
  (** Merges the array from the source context into the destination context: [dst =: dst accum src].
      If the array is hosted, its state on host is undefined after this operation. (A backend may chose
      to use the host array as a buffer, if that is beneficial.) [name_suffix] is appended to
      the jitted function's name. *)
end

module type Backend = sig
  include No_device_backend

  type device

  val init : device -> context
  val await : device -> unit
  val num_devices : unit -> int
  val get_device : ordinal:int -> device
  val get_ctx_device : context -> device
  val to_ordinal : device -> int
end

module Multicore_backend (Backend : No_device_backend) : Backend = struct
  module Domain = Domain [@warning "-3"]

  type device = {
    next_task : (unit -> unit) option ref;
    keep_spinning : bool ref;
    ordinal : int;
    domain : unit Domain.t;
  }

  type context = { device : device; ctx : Backend.context }
  type jitted = { context : context; run : unit -> unit; bindings : unit Indexing.bindings }

  let init device = { device; ctx = Backend.init () }
  let initialize = Backend.initialize
  let is_initialized = Backend.is_initialized

  let await device =
    while Option.is_some !(device.next_task) do
      Domain.cpu_relax ()
    done

  let finalize { device; ctx } =
    await device;
    Backend.finalize ctx

  let jit { ctx; device } ?name ?verbose bindings code : jitted =
    let result = Backend.jit ctx ?name ?verbose bindings code in
    let run () =
      assert (Domain.is_main_domain ());
      await device;
      device.next_task := Some result.run
    in

    (* let rec run : 'a. 'a = *)
    { context = { ctx = result.context; device }; run; bindings }

  let from_host { ctx; _ } = Backend.from_host ctx
  let to_host { ctx; _ } = Backend.to_host ctx

  let merge ?name_suffix la ~dst ~accum ~src =
    let src_suffix = "_from_device_" ^ Int.to_string src.device.ordinal in
    let name_suffix = Option.value name_suffix ~default:"" ^ src_suffix in
    Option.map (Backend.merge ~name_suffix la ~dst:dst.ctx ~accum ~src:src.ctx) ~f:(fun result ->
        let device = dst.device in
        let run () =
          assert (Domain.is_main_domain ());
          await device;
          device.next_task := Some result.run
        in
        { context = { ctx = result.context; device }; run; bindings = Indexing.Empty })

  let num_devices () = Domain.recommended_domain_count () - 1

  let spinup_device ~ordinal =
    let next_task = ref None in
    let keep_spinning = ref true in
    let worker () =
      while !keep_spinning do
        Option.iter !next_task ~f:(fun f -> f ());
        next_task := None;
        Domain.cpu_relax ()
      done
    in
    { next_task; keep_spinning; ordinal; domain = Domain.spawn worker }

  let devices = Array.init (num_devices ()) ~f:(fun ordinal -> spinup_device ~ordinal)

  let unsafe_cleanup () =
    assert (Domain.is_main_domain ());
    let cleanup ordinal device =
      device.keep_spinning := false;
      Domain.join device.domain;
      devices.(ordinal) <- spinup_device ~ordinal
    in
    Array.iteri devices ~f:cleanup;
    Backend.unsafe_cleanup ()

  let get_device ~ordinal = devices.(ordinal)
  let get_ctx_device { device; _ } = device
  let to_ordinal device = device.ordinal
end

module Gccjit_device : No_device_backend with type context = Exec_as_gccjit.context = struct
  type context = Exec_as_gccjit.context

  type jitted = Exec_as_gccjit.jitted = {
    context : context;
    run : unit -> unit;
    bindings : unit Indexing.bindings;
  }

  open Exec_as_gccjit

  let initialize = initialize
  let is_initialized = is_initialized
  let unsafe_cleanup = unsafe_cleanup
  let init = init
  let finalize = finalize

  let jit context ?name ?verbose bindings code =
    let name = Option.value name ~default:(Assignments.get_name code) in
    jit context ~name ?verbose bindings @@ Assignments.compile_proc ~name ?verbose code

  let from_host = from_host
  let to_host = to_host
  let merge = merge
end

module Gccjit_backend = Multicore_backend (Gccjit_device)

module Cuda_backend : Backend with type context = Exec_as_cuda.context = struct
  type context = Exec_as_cuda.context
  type device = Exec_as_cuda.device
  type jitted = Exec_as_cuda.jitted = { context : context; run : unit -> unit; bindings : unit Indexing.bindings }

  open Exec_as_cuda

  let initialize = initialize
  let is_initialized = is_initialized
  let unsafe_cleanup = unsafe_cleanup
  let init = init
  let finalize = finalize

  let jit context ?name ?verbose bindings code =
    let name = Option.value name ~default:(Assignments.get_name code) in
    jit context ~name ?verbose bindings @@ Assignments.compile_proc ~name ?verbose code

  let from_host = from_host
  let to_host = to_host
  let merge = merge
  let await = await
  let num_devices = num_devices
  let get_device = get_device
  let get_ctx_device = get_ctx_device
  let to_ordinal = to_ordinal
end

let reinitialize (module Backend : Backend) =
  if not @@ Backend.is_initialized () then Backend.initialize ()
  else (
    Core.Gc.full_major ();
    Backend.unsafe_cleanup ())
