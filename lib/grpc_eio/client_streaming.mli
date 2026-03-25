(** RPC call implementations: unary, server streaming, client streaming, bidi. *)

open Client_connection

(** Call a unary RPC method.

    Single request, single response.

    @param sw Eio switch
    @param env Eio environment
    @param deadline Optional per-call deadline in seconds (overrides config timeout)
    @param client The gRPC client
    @param service Service name (e.g., "helloworld.Greeter")
    @param method_ Method name (e.g., "SayHello")
    @param request Request bytes (protobuf-encoded)
    @return Response bytes or error status *)
val call_unary
  :  sw:Eio.Switch.t
  -> env:Eio_unix.Stdenv.base
  -> ?deadline:float
  -> t
  -> service:string
  -> method_:string
  -> request:string
  -> (string, Grpc_core.Status.t) result

(** Call a server streaming RPC method.

    Single request, stream of responses.

    @param sw Eio switch
    @param env Eio environment
    @param deadline Optional per-call deadline in seconds (overrides config timeout)
    @param client The gRPC client
    @param service Service name
    @param method_ Method name
    @param request Request bytes
    @return Stream of response messages. Stream ends with [Error Status.ok] on success. *)
val call_server_streaming
  :  sw:Eio.Switch.t
  -> env:Eio_unix.Stdenv.base
  -> ?deadline:float
  -> t
  -> service:string
  -> method_:string
  -> request:string
  -> (string, Grpc_core.Status.t) result Grpc_stream.t

(** Call a client streaming RPC method.

    Stream of requests, single response.
    Caller must close [requests] with [Grpc_eio.Stream.close] to finish the stream.

    @param sw Eio switch
    @param env Eio environment
    @param deadline Optional per-call deadline in seconds (overrides config timeout)
    @param client The gRPC client
    @param service Service name
    @param method_ Method name
    @param requests Stream of request bytes to send
    @return Single response or error status *)
val call_client_streaming
  :  sw:Eio.Switch.t
  -> env:Eio_unix.Stdenv.base
  -> ?deadline:float
  -> t
  -> service:string
  -> method_:string
  -> requests:string Grpc_stream.t
  -> (string, Grpc_core.Status.t) result

(** Call a bidirectional streaming RPC method.

    Stream of requests, stream of responses. Both can be sent/received
    concurrently. Caller must close [requests] with [Grpc_eio.Stream.close]
    to half-close the stream.

    @param sw Eio switch
    @param env Eio environment
    @param deadline Optional per-call deadline in seconds (overrides config timeout)
    @param client The gRPC client
    @param service Service name
    @param method_ Method name
    @param requests Stream of request bytes to send
    @return Stream of response messages *)
val call_bidi
  :  sw:Eio.Switch.t
  -> env:Eio_unix.Stdenv.base
  -> ?deadline:float
  -> t
  -> service:string
  -> method_:string
  -> requests:string Grpc_stream.t
  -> (string, Grpc_core.Status.t) result Grpc_stream.t
