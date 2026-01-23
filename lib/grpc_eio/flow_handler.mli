(** Flow-based H2 handler for TLS support.

    This module provides H2 connection handling that works with any
    [Eio.Flow.two_way] type, enabling TLS support via [Tls_eio].

    The standard h2-eio/gluten-eio APIs restrict socket types to
    [Eio.Net.stream_socket], but the underlying IO operations only
    require read/write capabilities. This module exposes a more
    permissive API.

    {b Thread Safety:}
    - Single-domain safe: Yes
    - Multi-domain safe: Yes (no shared mutable state)

    {b Usage:}
    {[
      (* For TLS connections *)
      let tls_flow = Tls_eio.server_of_flow tls_config sock in
      Flow_handler.create_server_handler
        ~request_handler
        ~error_handler
        ~sw
        addr
        tls_flow
    ]} *)

(** IO operations for any two-way flow.
    Internal module exposed for testing. *)
module IO : sig
  (** Read data into buffer *)
  val read : _ Eio.Flow.two_way -> Gluten.Buffer.t -> int

  (** Shutdown flow direction *)
  val shutdown : _ Eio.Flow.two_way -> Eio.Flow.shutdown_command -> unit
end

(** {1 Server} *)

(** Create H2 server connection handler for any [Eio.Flow.two_way].

    This function provides the same functionality as
    [H2_eio.Server.create_connection_handler] but accepts any two-way
    flow, enabling TLS support via [Tls_eio.server_of_flow].

    @param config H2 configuration (default: H2.Config.default)
    @param request_handler Handler for incoming requests
    @param error_handler Handler for connection errors
    @param sw Eio switch for resource management
    @param client_addr Client address for logging
    @param flow Any two-way flow (socket or TLS-wrapped) *)
val create_server_handler
  :  ?config:H2.Config.t
  -> request_handler:(Eio.Net.Sockaddr.stream -> H2.Reqd.t -> unit)
  -> error_handler:
       (Eio.Net.Sockaddr.stream
        -> ?request:H2.Request.t
        -> H2.Server_connection.error
        -> (H2.Headers.t -> H2.Body.Writer.t)
        -> unit)
  -> sw:Eio.Switch.t
  -> Eio.Net.Sockaddr.stream
  -> _ Eio.Flow.two_way
  -> unit

(** {1 Client} *)

(** Create H2 client connection for any [Eio.Flow.two_way].

    This function provides the same functionality as
    [H2_eio.Client.create_connection] but accepts any two-way
    flow, enabling TLS support via [Tls_eio.client_of_flow].

    {b Usage:}
    {[
      (* For TLS connections *)
      let tls_flow = Tls_eio.client_of_flow tls_config sock in
      let connection = Flow_handler.create_client_connection
        ~sw ~error_handler tls_flow
      in
      (* Make requests using H2.Client_connection.request *)
    ]}

    @param config H2 configuration (default: H2.Config.default)
    @param sw Eio switch for resource management
    @param error_handler Handler for connection errors
    @param flow Any two-way flow (socket or TLS-wrapped)
    @return H2 client connection that can be used for requests *)
val create_client_connection
  :  ?config:H2.Config.t
  -> sw:Eio.Switch.t
  -> error_handler:(H2.Client_connection.error -> unit)
  -> _ Eio.Flow.two_way
  -> H2.Client_connection.t
