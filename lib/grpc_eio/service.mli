(** gRPC Service definition.

    A service groups related RPC methods together.
    Services are registered with a Server to handle incoming requests.

    {b Thread Safety:}
    - Single-domain safe: Yes
    - Multi-domain safe: {b No} - Hashtbl without synchronization
    - Safe pattern: Register all methods at startup, before serving requests
    - Unsafe pattern: Runtime modification of service methods

    Example:
    {[
      let greeter_service = Service.create "helloworld.Greeter"
        |> Service.add_unary "SayHello" handler
        |> Service.add_server_streaming "SayHelloMany" stream_handler
    ]} *)

(** {1 Types} *)

(** RPC method types *)
type method_type =
  | Unary           (** Single request, single response *)
  | ClientStreaming (** Stream of requests, single response *)
  | ServerStreaming (** Single request, stream of responses *)
  | BidiStreaming   (** Stream of requests, stream of responses *)

(** Method handler function types *)
type unary_handler = string -> string
type client_streaming_handler = string Grpc_stream.t -> string
type server_streaming_handler = string -> string Grpc_stream.t
(* Response stream must be closed to end the RPC. *)
type bidi_handler = string Grpc_stream.t -> string Grpc_stream.t
(* Response stream must be closed to end the RPC. *)

(** Method definition *)
type method_def = {
  name : string;
  method_type : method_type;
  handler : [ `Unary of unary_handler
            | `ClientStreaming of client_streaming_handler
            | `ServerStreaming of server_streaming_handler
            | `Bidi of bidi_handler ];
}

(** Service definition *)
type t = {
  name : string;  (** Full service name: package.ServiceName *)
  methods : (string, method_def) Hashtbl.t;
}

(** {1 Service Creation} *)

(** Create a new service.
    @param name Full service name: package.ServiceName *)
val create : string -> t

(** {1 Method Registration} *)

(** Add a unary method to the service.
    @param name Method name (without service prefix)
    @param handler Function that takes request bytes and returns response bytes *)
val add_unary : string -> unary_handler -> t -> t

(** Add a server streaming method *)
val add_server_streaming : string -> server_streaming_handler -> t -> t

(** Add a client streaming method *)
val add_client_streaming : string -> client_streaming_handler -> t -> t

(** Add a bidirectional streaming method *)
val add_bidi_streaming : string -> bidi_handler -> t -> t

(** {1 Query} *)

(** Get a method by name *)
val get_method : t -> string -> method_def option

(** Get full method path: /package.Service/Method *)
val method_path : t -> string -> string

(** List all method names *)
val list_methods : t -> string list

(** {1 Typed Service Builder} *)

(** Typed service builder for better ergonomics with encoder/decoder *)
module Typed : sig
  (** Add a typed unary method with encoder/decoder *)
  val add_unary :
    request_decoder:(string -> 'req) ->
    response_encoder:('res -> string) ->
    string ->
    ('req -> 'res) ->
    t -> t

  (** Add a typed server streaming method *)
  val add_server_streaming :
    request_decoder:(string -> 'req) ->
    response_encoder:('res -> string) ->
    string ->
    ('req -> 'res Grpc_stream.t) ->
    t -> t
end
