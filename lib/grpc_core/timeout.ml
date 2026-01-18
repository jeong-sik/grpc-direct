(** gRPC timeout: 1-8 digits + unit (H/M/S/m/u/n).
    Internally stored as nanoseconds (int64) for simplicity. *)

type t = int64  (* nanoseconds *)

(* Unit multipliers *)
let ns = 1L
let us = 1_000L
let ms = 1_000_000L
let s  = 1_000_000_000L
let m  = Int64.mul 60L s
let h  = Int64.mul 60L m

(** Parse grpc-timeout header: "30S" -> 30 seconds *)
let parse str =
  let len = String.length str in
  if len < 2 || len > 9 then None
  else
    let digits = String.sub str 0 (len - 1) in
    let unit_char = str.[len - 1] in
    let mult = match unit_char with
      | 'H' -> Some h | 'M' -> Some m | 'S' -> Some s
      | 'm' -> Some ms | 'u' -> Some us | 'n' -> Some ns
      | _ -> None
    in
    match mult with
    | None -> None
    | Some mult ->
        (try
           let value = Int64.of_string digits in
           (* Reject negative or zero values *)
           if value <= 0L then None
           else Some (Int64.mul value mult)
         with Failure _ -> None)

(** Convert to string for header *)
let to_string t =
  if Int64.rem t h = 0L then Printf.sprintf "%Ld%c" (Int64.div t h) 'H'
  else if Int64.rem t m = 0L then Printf.sprintf "%Ld%c" (Int64.div t m) 'M'
  else if Int64.rem t s = 0L then Printf.sprintf "%Ld%c" (Int64.div t s) 'S'
  else if Int64.rem t ms = 0L then Printf.sprintf "%Ld%c" (Int64.div t ms) 'm'
  else if Int64.rem t us = 0L then Printf.sprintf "%Ld%c" (Int64.div t us) 'u'
  else Printf.sprintf "%Ld%c" t 'n'

(** Conversions *)
let to_nanoseconds t = t
let to_seconds t = Int64.to_float t /. 1_000_000_000.0
let to_milliseconds t = Int64.to_int (Int64.div t ms)

let of_seconds secs = Int64.mul (Int64.of_int secs) s
let of_milliseconds millis = Int64.mul (Int64.of_int millis) ms

(** Defaults *)
let default = of_seconds 30    (* 30s *)
(* Max safe value: ~2.5M hours before int64 overflow *)
let infinite = Int64.mul 2500000L h
