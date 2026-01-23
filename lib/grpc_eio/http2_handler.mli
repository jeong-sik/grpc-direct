(** HTTP/2 request handling for gRPC.

    Internal module that handles HTTP/2 request/response framing for gRPC.
    Supports all RPC types: unary, server streaming, client streaming,
    and bidirectional streaming.

    {b Thread Safety:}
    - Single-domain safe: Yes
    - Multi-domain safe: Yes (no shared mutable state)

    {b Note:} This is an internal module. Users should interact with
    [Server] module instead. *)

(** {1 Path Parsing} *)

(** Parse gRPC path: /package.Service/Method -> (service_name, method_name) *)
val parse_path : string -> (string * string) option

(** Percent-encode a string for grpc-message header (RFC 3986) *)
val percent_encode : string -> string

(** {1 Response Sending} *)

(** Send error response with trailers.
    @param reqd H2 request descriptor
    @param encodings Supported encodings string
    @param status gRPC status to send *)
val send_error : reqd:H2.Reqd.t -> encodings:string -> Grpc_core.Status.t -> unit

(** Send success response with body and trailers.
    @param reqd H2 request descriptor
    @param encodings Supported encodings string
    @param codec Compression codec to use
    @param body Response body bytes
    @param trailers Trailing metadata *)
val send_response
  :  reqd:H2.Reqd.t
  -> encodings:string
  -> codec:Grpc_core.Codec.t
  -> body:string
  -> trailers:(string * string) list
  -> unit

(** {1 Streaming Handlers} *)

(** Handle server streaming RPC.
    Single request, stream of responses. *)
val handle_server_streaming
  :  sw:Eio.Switch.t
  -> clock:_ Eio.Time.clock
  -> timeout:float option
  -> reqd:H2.Reqd.t
  -> response_codec:Grpc_core.Codec.t
  -> handler:(string -> string Grpc_stream.t)
  -> request_data:string
  -> encodings:string
  -> method_:string
  -> metrics:Metrics.t option
  -> unit

(** Handle client streaming RPC.
    Stream of requests, single response. *)
val handle_client_streaming
  :  sw:Eio.Switch.t
  -> clock:_ Eio.Time.clock
  -> timeout:float option
  -> reqd:H2.Reqd.t
  -> request_codec:Grpc_core.Codec.t
  -> response_codec:Grpc_core.Codec.t
  -> handler:(string Grpc_stream.t -> string)
  -> encodings:string
  -> method_:string
  -> metrics:Metrics.t option
  -> unit

(** Handle bidirectional streaming RPC.
    Stream of requests, stream of responses.

    Uses Promise-based termination signal instead of busy-wait polling.
    @param sw Eio switch for spawning writer fiber *)
val handle_bidi_streaming
  :  sw:Eio.Switch.t
  -> clock:_ Eio.Time.clock
  -> timeout:float option
  -> reqd:H2.Reqd.t
  -> request_codec:Grpc_core.Codec.t
  -> response_codec:Grpc_core.Codec.t
  -> handler:(string Grpc_stream.t -> string Grpc_stream.t)
  -> encodings:string
  -> method_:string
  -> metrics:Metrics.t option
  -> unit
