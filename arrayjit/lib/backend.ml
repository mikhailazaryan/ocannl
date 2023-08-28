open Base

module type No_device_backend = sig
  type context
  type compiled = { context : context; run : unit -> unit  (** Potentially asynchronous. *) }

  val initialize : unit -> unit
  val init : unit -> context
  val finalize : context -> unit
  val compile : context -> name:string -> ?verbose:bool -> Assignments.t -> compiled
  val unsafe_cleanup : unit -> unit

  val from_host : context -> Lazy_array.t -> unit
  (** Potentially asynchronous. *)

  val to_host : context -> ?accum:Low_level.binop -> Lazy_array.t -> unit
  (** Potentially asynchronous. *)
end

module type Backend = sig
  include No_device_backend

  type device

  val init : device -> context
  val await : device -> unit
  val num_devices : unit -> int
  val get_device : ordinal:int -> device
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
  type compiled = { context : context; run : unit -> unit }

  let init device = { device; ctx = Backend.init () }
  let initialize = Backend.initialize

  let await device =
    while Option.is_some !(device.next_task) do
      Domain.cpu_relax ()
    done

  let finalize { device; ctx } =
    await device;
    Backend.finalize ctx

  let compile { ctx; device } ~name ?verbose code =
    let result = Backend.compile ctx ~name ?verbose code in
    let run () =
      await device;
      device.next_task := Some result.run
    in
    { context = { ctx = result.context; device }; run }

  (** Potentially asynchronous. *)
  let from_host { ctx; _ } = Backend.from_host ctx

  (** Potentially asynchronous. *)
  let to_host { ctx; _ } = Backend.to_host ctx

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
    let cleanup ordinal device =
      device.keep_spinning := false;
      Domain.join device.domain;
      devices.(ordinal) <- spinup_device ~ordinal
    in
    Array.iteri devices ~f:cleanup;
    Backend.unsafe_cleanup ()

  let get_device ~ordinal = devices.(ordinal)
  let to_ordinal device = device.ordinal
end
