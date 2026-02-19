(** Fiber-aware sleep compatibility.

    When an Eio clock is registered via {!set_clock}, {!sleep} suspends only
    the current fiber.  Otherwise it falls back to [Unix.sleepf]. *)

let sleep_fn : (float -> unit) ref = ref Unix.sleepf
let set_clock clock = sleep_fn := fun seconds -> Eio.Time.sleep clock seconds
let sleep seconds = !sleep_fn seconds
