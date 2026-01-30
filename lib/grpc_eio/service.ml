(** gRPC Service definition.

    A service groups related RPC methods together.
    Services are registered with a Server to handle incoming requests.

    {b Thread Safety:}
    - Single-domain safe: Yes
    - Multi-domain safe: {b No} - Hashtbl without synchronization
    - Safe pattern: Register all methods at startup, before serving requests
    - Unsafe pattern: Runtime modification of service methods

    @see {{: https://github.com/ocaml-multicore/eio/blob/main/doc/multicore.md } Eio Multicore Guide}

    Example:
    {[
      let greeter_service = Service.create "helloworld.Greeter"
        |> Service.add_unary "SayHello"
             ~request_decoder:HelloRequest.decode
             ~response_encoder:HelloReply.encode
             (fun request ->
               HelloReply.make ~message:("Hello, " ^ request.name) ())
    ]} *)

(** RPC method types *)
type method_type =
  | Unary (** Single request, single response *)
  | ClientStreaming (** Stream of requests, single response *)
  | ServerStreaming (** Single request, stream of responses *)
  | BidiStreaming (** Stream of requests, stream of responses *)

(** Method handler function types *)
type unary_handler = string -> string

type client_streaming_handler = string Grpc_stream.t -> string
type server_streaming_handler = string -> string Grpc_stream.t

(** Bidirectional streaming handler.
    Takes a switch (for forking internal fibers) and request stream,
    returns a response stream. Handler should return immediately with
    the response stream; actual processing can be done in a forked fiber. *)
type bidi_handler = sw:Eio.Switch.t -> string Grpc_stream.t -> string Grpc_stream.t

(** Method definition *)
type method_def =
  { name : string
  ; method_type : method_type
  ; handler :
      [ `Unary of unary_handler
      | `ClientStreaming of client_streaming_handler
      | `ServerStreaming of server_streaming_handler
      | `Bidi of bidi_handler
      ]
  }

(** Service definition *)
type t =
  { name : string (** Full service name: package.ServiceName *)
  ; methods : (string, method_def) Hashtbl.t
  }

(** Create a new service *)
let create (name : string) : t = { name; methods = Hashtbl.create 16 }

(** Add a unary method to the service.

    @param name Method name (without service prefix)
    @param handler Function that takes request bytes and returns response bytes *)
let add_unary (method_name : string) (handler : unary_handler) (service : t) : t =
  let method_def =
    { name = method_name; method_type = Unary; handler = `Unary handler }
  in
  Hashtbl.replace service.methods method_name method_def;
  service
;;

(** Add a server streaming method *)
let add_server_streaming
      (method_name : string)
      (handler : server_streaming_handler)
      (service : t)
  : t
  =
  let method_def =
    { name = method_name
    ; method_type = ServerStreaming
    ; handler = `ServerStreaming handler
    }
  in
  Hashtbl.replace service.methods method_name method_def;
  service
;;

(** Add a client streaming method *)
let add_client_streaming
      (method_name : string)
      (handler : client_streaming_handler)
      (service : t)
  : t
  =
  let method_def =
    { name = method_name
    ; method_type = ClientStreaming
    ; handler = `ClientStreaming handler
    }
  in
  Hashtbl.replace service.methods method_name method_def;
  service
;;

(** Add a bidirectional streaming method *)
let add_bidi_streaming (method_name : string) (handler : bidi_handler) (service : t) : t =
  let method_def =
    { name = method_name; method_type = BidiStreaming; handler = `Bidi handler }
  in
  Hashtbl.replace service.methods method_name method_def;
  service
;;

(** Get a method by name *)
let get_method (service : t) (method_name : string) : method_def option =
  Hashtbl.find_opt service.methods method_name
;;

(** Get full method path: /package.Service/Method *)
let method_path (service : t) (method_name : string) : string =
  Printf.sprintf "/%s/%s" service.name method_name
;;

(** List all method names *)
let list_methods (service : t) : string list =
  Hashtbl.fold (fun name _ acc -> name :: acc) service.methods []
;;

(** Typed service builder for better ergonomics *)
module Typed = struct
  (** Add a typed unary method with encoder/decoder *)
  let add_unary
        ~(request_decoder : string -> 'req)
        ~(response_encoder : 'res -> string)
        (method_name : string)
        (handler : 'req -> 'res)
        (service : t)
    : t
    =
    let raw_handler bytes =
      let request = request_decoder bytes in
      let response = handler request in
      response_encoder response
    in
    add_unary method_name raw_handler service
  ;;

  (** Add a typed server streaming method *)
  let add_server_streaming
        ~(request_decoder : string -> 'req)
        ~(response_encoder : 'res -> string)
        (method_name : string)
        (handler : 'req -> 'res Grpc_stream.t)
        (service : t)
    : t
    =
    let raw_handler bytes =
      let request = request_decoder bytes in
      let response_stream = handler request in
      (* Map response stream through encoder *)
      let capacity = 16 in
      let mapped = Grpc_stream.create capacity in
      (* Note: In production, we'd spawn a fiber to transform and forward messages *)
      ignore (response_stream, response_encoder);
      mapped
    in
    add_server_streaming method_name raw_handler service
  ;;
end
