(** Close-aware stream wrapper over Eio.Stream. *)

type 'a t =
  { stream : 'a Eio.Stream.t
  ; mutable closed : bool [@atomic]
  ; close_promise : unit Eio.Promise.t
  ; close_resolver : unit Eio.Promise.u
  }

let create capacity =
  let close_promise, close_resolver = Eio.Promise.create () in
  { stream = Eio.Stream.create capacity
  ; closed = false
  ; close_promise
  ; close_resolver
  }
;;

let is_closed t = Atomic.Loc.get [%atomic.loc t.closed]
let add t value = if not (is_closed t) then Eio.Stream.add t.stream value

let close t =
  if Atomic.Loc.compare_and_set [%atomic.loc t.closed] false true
  then
    if not (Eio.Promise.is_resolved t.close_promise)
    then Eio.Promise.resolve t.close_resolver ()
;;

let take t =
  match Eio.Stream.take_nonblocking t.stream with
  | Some value -> value
  | None ->
    if is_closed t then raise End_of_file;
    (match
       Eio.Fiber.first
         (fun () -> `Msg (Eio.Stream.take t.stream))
         (fun () ->
            Eio.Promise.await t.close_promise;
            `Closed)
     with
     | `Msg value -> value
     | `Closed ->
       (match Eio.Stream.take_nonblocking t.stream with
        | Some value -> value
        | None -> raise End_of_file))
;;

let take_nonblocking t =
  match Eio.Stream.take_nonblocking t.stream with
  | Some value -> Some value
  | None -> None
;;

let length t = Eio.Stream.length t.stream
let is_empty t = Eio.Stream.is_empty t.stream
