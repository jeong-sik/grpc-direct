(** Flow-based H2 handler for TLS support.

    This module provides H2 connection handling that works with any
    [Eio.Flow.two_way] type, enabling TLS support via [Tls_eio].

    The standard h2-eio/gluten-eio APIs restrict socket types to
    [Eio.Net.stream_socket], but the underlying IO operations only
    require read/write capabilities. This module exposes a more
    permissive API. *)

open Eio.Std
module Buffer = Gluten.Buffer

(** IO operations for any two-way flow *)
module IO = struct
  let writev (flow : _ Eio.Flow.two_way) iovecs =
    let lenv, cstructs =
      List.fold_left_map
        (fun acc { Faraday.buffer; off; len } ->
           acc + len, Cstruct.of_bigarray buffer ~off ~len)
        0
        iovecs
    in
    match Eio.Flow.write flow cstructs with
    | () -> `Ok lenv
    | exception End_of_file -> `Closed
  ;;

  let read_once (flow : _ Eio.Flow.two_way) buffer =
    let p, u = Promise.create () in
    Buffer.put
      ~f:(fun buf ~off ~len k ->
        let cstruct = Cstruct.of_bigarray buf ~off ~len in
        k (Eio.Flow.single_read flow cstruct))
      buffer
      (Promise.resolve u);
    Promise.await p
  ;;

  let read flow buffer =
    match read_once flow buffer with
    | r -> r
    | exception
        ( Unix.Unix_error (ENOTCONN, _, _)
        | Eio.Io (Eio.Exn.X (Eio_unix.Unix_error (ENOTCONN, _, _)), _)
        | Eio.Io (Eio.Net.E (Connection_reset _), _) ) -> raise End_of_file
  ;;

  let shutdown (flow : _ Eio.Flow.two_way) cmd =
    try Eio.Flow.shutdown flow cmd with
    | Unix.Unix_error (ENOTCONN, _, _)
    | Eio.Io (Eio.Exn.X (Eio_unix.Unix_error (ENOTCONN, _, _)), _) -> ()
  ;;
end

(** Connection operations shared between server and client loops.
    Both [H2.Server_connection] and [H2.Client_connection] expose the
    same set of operations; this record abstracts over the difference
    so the IO loop can be written once. *)
type conn_ops =
  { next_read_operation : unit -> [ `Read | `Yield | `Close ]
  ; read : Bigstringaf.t -> off:int -> len:int -> int
  ; read_eof : Bigstringaf.t -> off:int -> len:int -> int
  ; yield_reader : (unit -> unit) -> unit
  ; report_exn : exn -> unit
  ; next_write_operation :
      unit -> [ `Write of Bigstringaf.t Faraday.iovec list | `Yield | `Close of int ]
  ; report_write_result : [ `Ok of int | `Closed ] -> unit
  ; yield_writer : (unit -> unit) -> unit
  }

(** Build [conn_ops] from an [H2.Server_connection.t]. *)
let server_ops (conn : H2.Server_connection.t) : conn_ops =
  { next_read_operation = (fun () -> H2.Server_connection.next_read_operation conn)
  ; read = H2.Server_connection.read conn
  ; read_eof = H2.Server_connection.read_eof conn
  ; yield_reader = H2.Server_connection.yield_reader conn
  ; report_exn = H2.Server_connection.report_exn conn
  ; next_write_operation =
      (fun () -> H2.Server_connection.next_write_operation conn)
  ; report_write_result = H2.Server_connection.report_write_result conn
  ; yield_writer = H2.Server_connection.yield_writer conn
  }
;;

(** Build [conn_ops] from an [H2.Client_connection.t]. *)
let client_ops (conn : H2.Client_connection.t) : conn_ops =
  { next_read_operation = (fun () -> H2.Client_connection.next_read_operation conn)
  ; read = H2.Client_connection.read conn
  ; read_eof = H2.Client_connection.read_eof conn
  ; yield_reader = H2.Client_connection.yield_reader conn
  ; report_exn = H2.Client_connection.report_exn conn
  ; next_write_operation =
      (fun () -> H2.Client_connection.next_write_operation conn)
  ; report_write_result = H2.Client_connection.report_write_result conn
  ; yield_writer = H2.Client_connection.yield_writer conn
  }
;;

(** Generic IO loop for any H2 connection (server or client). *)
let start_loop ~read_buffer_size (ops : conn_ops) (flow : _ Eio.Flow.two_way) =
  let read_closed_p, read_closed_u = Promise.create () in
  let write_closed = Atomic.make false in
  let read_buffer = Buffer.create read_buffer_size in
  let rec read_loop () =
    let read flow buffer =
      Fiber.first
        (fun () -> IO.read flow buffer)
        (fun () ->
           Promise.await read_closed_p;
           raise End_of_file)
    in
    let rec read_loop_step () =
      match ops.next_read_operation () with
      | `Read ->
        (match read flow read_buffer with
         | _n ->
           let (_ : int) =
             Buffer.get read_buffer ~f:(fun buf ~off ~len ->
               ops.read buf ~off ~len)
           in
           ()
         | exception End_of_file ->
           let (_ : int) =
             Buffer.get read_buffer ~f:(fun buf ~off ~len ->
               ops.read_eof buf ~off ~len)
           in
           ());
        read_loop_step ()
      | `Yield ->
        let p, u = Promise.create () in
        ops.yield_reader (fun () -> Promise.resolve u ());
        Promise.await p;
        read_loop ()
      | `Close ->
        (match Promise.is_resolved read_closed_p with
         | true -> ()
         | false ->
           (match read flow read_buffer with
            | _n -> assert false
            | exception (End_of_file as exn) ->
              IO.shutdown flow `Receive;
              Promise.resolve read_closed_u ();
              (match Atomic.get write_closed with
               | true -> ()
               | false -> ops.report_exn exn)))
    in
    match read_loop_step () with
    | () -> ()
    | exception exn -> ops.report_exn exn
  in
  let rec write_loop () =
    match ops.next_write_operation () with
    | `Write iovecs ->
      (match IO.writev flow iovecs with
       | `Ok n ->
         ops.report_write_result (`Ok n);
         write_loop ()
       | `Closed ->
         ops.report_write_result `Closed;
         write_loop ())
    | `Yield ->
      let p, u = Promise.create () in
      ops.yield_writer (fun () -> Promise.resolve u ());
      Promise.await p;
      write_loop ()
    | `Close _ ->
      Atomic.set write_closed true;
      IO.shutdown flow `Send
  in
  Fiber.both read_loop write_loop
;;

(** Create H2 server connection handler for any [Eio.Flow.two_way].

    This function provides the same functionality as
    [H2_eio.Server.create_connection_handler] but accepts any two-way
    flow, enabling TLS support via [Tls_eio.server_of_flow]. *)
let create_server_handler
      ?(config = H2.Config.default)
      ~request_handler
      ~error_handler
      ~sw:_
      client_addr
      (flow : _ Eio.Flow.two_way)
  =
  let connection =
    H2.Server_connection.create
      ~config
      ~error_handler:(error_handler client_addr)
      (request_handler client_addr)
  in
  start_loop
    ~read_buffer_size:config.H2.Config.read_buffer_size
    (server_ops connection)
    flow
;;

(** Create H2 client connection for any [Eio.Flow.two_way].

    This function provides the same functionality as
    [H2_eio.Client.create_connection] but accepts any two-way
    flow, enabling TLS support via [Tls_eio.client_of_flow].

    @return H2 client connection that can be used for requests *)
let create_client_connection
      ?(config = H2.Config.default)
      ~sw
      ~error_handler
      (flow : _ Eio.Flow.two_way)
  : H2.Client_connection.t
  =
  let connection = H2.Client_connection.create ~config ~error_handler () in
  Fiber.fork ~sw (fun () ->
    start_loop
      ~read_buffer_size:config.H2.Config.read_buffer_size
      (client_ops connection)
      flow);
  connection
;;
