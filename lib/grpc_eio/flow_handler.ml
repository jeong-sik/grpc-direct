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

(** Start IO loop for H2 server connection *)
let start_server_loop
      ~read_buffer_size
      ~sw:_
      (connection : H2.Server_connection.t)
      (flow : _ Eio.Flow.two_way)
  =
  let read_closed_p, read_closed_u = Promise.create () in
  let write_closed = ref false in
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
      match H2.Server_connection.next_read_operation connection with
      | `Read ->
        (match read flow read_buffer with
         | _n ->
           let (_ : int) =
             Buffer.get read_buffer ~f:(fun buf ~off ~len ->
               H2.Server_connection.read connection buf ~off ~len)
           in
           ()
         | exception End_of_file ->
           let (_ : int) =
             Buffer.get read_buffer ~f:(fun buf ~off ~len ->
               H2.Server_connection.read_eof connection buf ~off ~len)
           in
           ());
        read_loop_step ()
      | `Yield ->
        let p, u = Promise.create () in
        H2.Server_connection.yield_reader connection (fun () -> Promise.resolve u ());
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
              (match !write_closed with
               | true -> ()
               | false -> H2.Server_connection.report_exn connection exn)))
    in
    match read_loop_step () with
    | () -> ()
    | exception exn -> H2.Server_connection.report_exn connection exn
  in
  let rec write_loop () =
    match H2.Server_connection.next_write_operation connection with
    | `Write iovecs ->
      (match IO.writev flow iovecs with
       | `Ok n ->
         H2.Server_connection.report_write_result connection (`Ok n);
         write_loop ()
       | `Closed ->
         H2.Server_connection.report_write_result connection `Closed;
         write_loop ())
    | `Yield ->
      let p, u = Promise.create () in
      H2.Server_connection.yield_writer connection (fun () -> Promise.resolve u ());
      Promise.await p;
      write_loop ()
    | `Close _ ->
      write_closed := true;
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
      ~sw
      client_addr
      (flow : _ Eio.Flow.two_way)
  =
  let connection =
    H2.Server_connection.create
      ~config
      ~error_handler:(error_handler client_addr)
      (request_handler client_addr)
  in
  start_server_loop
    ~read_buffer_size:config.H2.Config.read_buffer_size
    ~sw
    connection
    flow
;;

(** Start IO loop for H2 client connection *)
let start_client_loop
      ~read_buffer_size
      ~sw:_
      (connection : H2.Client_connection.t)
      (flow : _ Eio.Flow.two_way)
  =
  let read_closed_p, read_closed_u = Promise.create () in
  let write_closed = ref false in
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
      match H2.Client_connection.next_read_operation connection with
      | `Read ->
        (match read flow read_buffer with
         | _n ->
           let (_ : int) =
             Buffer.get read_buffer ~f:(fun buf ~off ~len ->
               H2.Client_connection.read connection buf ~off ~len)
           in
           ()
         | exception End_of_file ->
           let (_ : int) =
             Buffer.get read_buffer ~f:(fun buf ~off ~len ->
               H2.Client_connection.read_eof connection buf ~off ~len)
           in
           ());
        read_loop_step ()
      | `Yield ->
        let p, u = Promise.create () in
        H2.Client_connection.yield_reader connection (fun () -> Promise.resolve u ());
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
              (match !write_closed with
               | true -> ()
               | false -> H2.Client_connection.report_exn connection exn)))
    in
    match read_loop_step () with
    | () -> ()
    | exception exn -> H2.Client_connection.report_exn connection exn
  in
  let rec write_loop () =
    match H2.Client_connection.next_write_operation connection with
    | `Write iovecs ->
      (match IO.writev flow iovecs with
       | `Ok n ->
         H2.Client_connection.report_write_result connection (`Ok n);
         write_loop ()
       | `Closed ->
         H2.Client_connection.report_write_result connection `Closed;
         write_loop ())
    | `Yield ->
      let p, u = Promise.create () in
      H2.Client_connection.yield_writer connection (fun () -> Promise.resolve u ());
      Promise.await p;
      write_loop ()
    | `Close _ ->
      write_closed := true;
      IO.shutdown flow `Send
  in
  Fiber.both read_loop write_loop
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
  (* Start the IO loop in a background fiber *)
  Fiber.fork ~sw (fun () ->
    start_client_loop
      ~read_buffer_size:config.H2.Config.read_buffer_size
      ~sw
      connection
      flow);
  connection
;;
