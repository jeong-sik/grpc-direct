(** gRPC Service Code Generator.

    Generates OCaml client and server stubs for gRPC services.
    Works in conjunction with ocaml-protoc-plugin for message types.

    Example usage:
    {[
      let service = {
        package = "helloworld";
        service_name = "Greeter";
        methods = [
          { name = "SayHello";
            input_type = "HelloRequest";
            output_type = "HelloReply";
            client_streaming = false;
            server_streaming = false; }
        ];
      }
      in
      let code = Codegen.generate_service service in
      print_endline code
    ]} *)

(** Method type *)
type method_type =
  | Unary
  | ClientStreaming
  | ServerStreaming
  | BidiStreaming

(** Method definition *)
type method_def = {
  name : string;
  input_type : string;
  output_type : string;
  method_type : method_type;
}

(** Service definition *)
type service_def = {
  package : string;
  service_name : string;
  methods : method_def list;
}

(** Convert method name to OCaml style (snake_case) *)
let to_snake_case name =
  let buf = Buffer.create (String.length name * 2) in
  String.iteri (fun i c ->
    if Char.uppercase_ascii c = c && c <> '_' && i > 0 then begin
      Buffer.add_char buf '_';
      Buffer.add_char buf (Char.lowercase_ascii c)
    end else
      Buffer.add_char buf (Char.lowercase_ascii c)
  ) name;
  Buffer.contents buf

(** Convert type name to OCaml module path *)
let to_module_path type_name =
  (* Handle fully-qualified names like ".pkg.Message" *)
  let trimmed =
    if String.length type_name > 0 && type_name.[0] = '.'
    then String.sub type_name 1 (String.length type_name - 1)
    else type_name
  in
  let parts = String.split_on_char '.' trimmed in
  parts
  |> List.map (fun part -> to_snake_case part |> String.capitalize_ascii)
  |> String.concat "."

(** Generate client module code *)
let generate_client (service : service_def) : string =
  let full_service_name =
    if service.package = "" then service.service_name
    else service.package ^ "." ^ service.service_name
  in

  let method_impls = List.map (fun m ->
    let method_name = to_snake_case m.name in
    match m.method_type with
    | Unary ->
        Printf.sprintf {|
    (** Call %s RPC *)
    let %s ~sw ~env (t : t) (request : %s.t) : (%s.t, Grpc_core.Status.t) result =
      let request_bytes = %s.to_proto request |> Pbrt.Encoder.to_string in
      match Grpc_eio.Client.call_unary ~sw ~env t.client
        ~service:"%s"
        ~method_:"%s"
        ~request:request_bytes
      with
      | Ok bytes ->
          let decoder = Pbrt.Decoder.of_string bytes in
          Ok (%s.from_proto decoder)
      | Error e -> Error e
|}
          m.name
          method_name
          (to_module_path m.input_type)
          (to_module_path m.output_type)
          (to_module_path m.input_type)
          full_service_name
          m.name
          (to_module_path m.output_type)

    | ServerStreaming ->
        Printf.sprintf {|
    (** Call %s server streaming RPC *)
    let %s ~sw ~env (t : t) (request : %s.t)
      : (%s.t, Grpc_core.Status.t) result Grpc_eio.Stream.t =
      let request_bytes = %s.to_proto request |> Pbrt.Encoder.to_string in
      let raw_stream = Grpc_eio.Client.call_server_streaming ~sw ~env t.client
        ~service:"%s"
        ~method_:"%s"
        ~request:request_bytes
      in
      let decoded = Grpc_eio.Stream.create 16 in
      Eio.Fiber.fork ~sw (fun () ->
        let rec loop () =
          match Grpc_eio.Stream.take raw_stream with
          | Ok bytes ->
              let decoder = Pbrt.Decoder.of_string bytes in
              Grpc_eio.Stream.add decoded (Ok (%s.from_proto decoder));
              loop ()
          | Error status as err ->
              Grpc_eio.Stream.add decoded err;
              Grpc_eio.Stream.close decoded
          | exception End_of_file ->
              Grpc_eio.Stream.close decoded
        in
        loop ()
      );
      decoded
|}
          m.name
          method_name
          (to_module_path m.input_type)
          (to_module_path m.output_type)
          (to_module_path m.input_type)
          full_service_name
          m.name
          (to_module_path m.output_type)

    | ClientStreaming ->
        Printf.sprintf {|
    (** Call %s client streaming RPC *)
    let %s ~sw ~env (t : t) (requests : %s.t Grpc_eio.Stream.t)
      : (%s.t, Grpc_core.Status.t) result =
      let raw_requests = Grpc_eio.Stream.create 16 in
      Eio.Fiber.fork ~sw (fun () ->
        let rec loop () =
          match Grpc_eio.Stream.take requests with
          | req ->
              let encoded = %s.to_proto req |> Pbrt.Encoder.to_string in
              Grpc_eio.Stream.add raw_requests encoded;
              loop ()
          | exception End_of_file ->
              Grpc_eio.Stream.close raw_requests
        in
        loop ()
      );
      match Grpc_eio.Client.call_client_streaming ~sw ~env t.client
        ~service:"%s"
        ~method_:"%s"
        ~requests:raw_requests
      with
      | Ok bytes ->
          let decoder = Pbrt.Decoder.of_string bytes in
          Ok (%s.from_proto decoder)
      | Error e -> Error e
|}
          m.name
          method_name
          (to_module_path m.input_type)
          (to_module_path m.output_type)
          (to_module_path m.input_type)
          full_service_name
          m.name
          (to_module_path m.output_type)

    | BidiStreaming ->
        Printf.sprintf {|
    (** Call %s bidirectional streaming RPC *)
    let %s ~sw ~env (t : t) (requests : %s.t Grpc_eio.Stream.t)
      : (%s.t, Grpc_core.Status.t) result Grpc_eio.Stream.t =
      let raw_requests = Grpc_eio.Stream.create 16 in
      Eio.Fiber.fork ~sw (fun () ->
        let rec loop () =
          match Grpc_eio.Stream.take requests with
          | req ->
              let encoded = %s.to_proto req |> Pbrt.Encoder.to_string in
              Grpc_eio.Stream.add raw_requests encoded;
              loop ()
          | exception End_of_file ->
              Grpc_eio.Stream.close raw_requests
        in
        loop ()
      );
      let raw_stream = Grpc_eio.Client.call_bidi ~sw ~env t.client
        ~service:"%s"
        ~method_:"%s"
        ~requests:raw_requests
      in
      let decoded = Grpc_eio.Stream.create 16 in
      Eio.Fiber.fork ~sw (fun () ->
        let rec loop () =
          match Grpc_eio.Stream.take raw_stream with
          | Ok bytes ->
              let decoder = Pbrt.Decoder.of_string bytes in
              Grpc_eio.Stream.add decoded (Ok (%s.from_proto decoder));
              loop ()
          | Error status as err ->
              Grpc_eio.Stream.add decoded err;
              Grpc_eio.Stream.close decoded
          | exception End_of_file ->
              Grpc_eio.Stream.close decoded
        in
        loop ()
      );
      decoded
|}
          m.name
          method_name
          (to_module_path m.input_type)
          (to_module_path m.output_type)
          (to_module_path m.input_type)
          full_service_name
          m.name
          (to_module_path m.output_type)
  ) service.methods
  in

  Printf.sprintf {|(** Generated gRPC client for %s.%s *)
module Client = struct
  type t = {
    client : Grpc_eio.Client.t;
  }

  (** Create a new client *)
  let create (client : Grpc_eio.Client.t) : t =
    { client }
%s
end
|}
    service.package
    service.service_name
    (String.concat "\n" method_impls)

(** Generate server module code *)
let generate_server (service : service_def) : string =
  let full_service_name =
    if service.package = "" then service.service_name
    else service.package ^ "." ^ service.service_name
  in

  let sig_methods = List.map (fun m ->
    let method_name = to_snake_case m.name in
    match m.method_type with
    | Unary ->
        Printf.sprintf "    (** %s: %s -> %s *)\n    val %s : %s.t -> %s.t"
          m.name
          m.input_type
          m.output_type
          method_name
          (to_module_path m.input_type)
          (to_module_path m.output_type)
    | ServerStreaming ->
        (* Server streaming returns encoded bytes stream *)
        Printf.sprintf "    (** %s: %s -> stream %s *)\n    val %s : %s.t -> string Grpc_eio.Stream.t"
          m.name
          m.input_type
          m.output_type
          method_name
          (to_module_path m.input_type)
    | ClientStreaming ->
        (* Client streaming receives encoded bytes stream *)
        Printf.sprintf "    (** %s: stream %s -> %s *)\n    val %s : string Grpc_eio.Stream.t -> string"
          m.name
          m.input_type
          m.output_type
          method_name
    | BidiStreaming ->
        (* Bidi streaming: both input and output are encoded bytes *)
        Printf.sprintf "    (** %s: stream %s -> stream %s *)\n    val %s : string Grpc_eio.Stream.t -> string Grpc_eio.Stream.t"
          m.name
          m.input_type
          m.output_type
          method_name
  ) service.methods
  in

  let handler_registrations = List.map (fun m ->
    match m.method_type with
    | Unary ->
        Printf.sprintf {|      |> Grpc_eio.Service.add_unary "%s" (fun bytes ->
            let decoder = Pbrt.Decoder.of_string bytes in
            let request = %s.from_proto decoder in
            let response = Impl.%s request in
            %s.to_proto response |> Pbrt.Encoder.to_string
          )|}
          m.name
          (to_module_path m.input_type)
          (to_snake_case m.name)
          (to_module_path m.output_type)
    | ServerStreaming ->
        Printf.sprintf {|      |> Grpc_eio.Service.add_server_streaming "%s" (fun bytes ->
            let decoder = Pbrt.Decoder.of_string bytes in
            let request = %s.from_proto decoder in
            Impl.%s request
          )|}
          m.name
          (to_module_path m.input_type)
          (to_snake_case m.name)
    | ClientStreaming ->
        Printf.sprintf {|      |> Grpc_eio.Service.add_client_streaming "%s" (fun request_stream ->
            Impl.%s request_stream
          )|}
          m.name
          (to_snake_case m.name)
    | BidiStreaming ->
        Printf.sprintf {|      |> Grpc_eio.Service.add_bidi_streaming "%s" (fun request_stream ->
            Impl.%s request_stream
          )|}
          m.name
          (to_snake_case m.name)
  ) service.methods
  in

  Printf.sprintf {|(** Generated gRPC server for %s.%s *)
module Server = struct
  (** Server implementation signature *)
  module type S = sig
%s
  end

  (** Create a service from an implementation *)
  let make (module Impl : S) : Grpc_eio.Service.t =
    Grpc_eio.Service.create "%s"
%s
end
|}
    service.package
    service.service_name
    (String.concat "\n" sig_methods)
    full_service_name
    (String.concat "\n" handler_registrations)

(** Generate complete module for a service *)
let generate_service (service : service_def) : string =
  let module_name = service.service_name in
  Printf.sprintf {|(** Generated gRPC stubs for %s.%s

    This file was auto-generated by protoc-gen-grpc-eio.
    Do not edit manually.

    Usage:
    - Client: let client = %s.Client.create grpc_client
    - Server: let service = %s.Server.make (module MyImpl)
*)

module %s = struct
%s

%s
end
|}
    service.package
    service.service_name
    module_name
    module_name
    module_name
    (generate_client service)
    (generate_server service)

(** Parse a simple service description from string format.
    Format:
    package: helloworld
    service: Greeter
    rpc SayHello(HelloRequest) returns (HelloReply)
    rpc SayHelloStream(HelloRequest) returns (stream HelloReply)
*)
let parse_service_description (input : string) : service_def option =
  let lines = String.split_on_char '\n' input
    |> List.map String.trim
    |> List.filter (fun s -> s <> "" && not (String.starts_with ~prefix:"//" s))
  in

  let package = ref "" in
  let service_name = ref "" in
  let methods = ref [] in

  let rpc_regex = Str.regexp {|rpc[ ]+\([A-Za-z0-9_]+\)[ ]*([ ]*\(stream[ ]+\)?\([A-Za-z0-9_.]+\)[ ]*)[ ]*returns[ ]*([ ]*\(stream[ ]+\)?\([A-Za-z0-9_.]+\)[ ]*)|}
  in

  List.iter (fun line ->
    if String.starts_with ~prefix:"package:" line then
      package := String.trim (String.sub line 8 (String.length line - 8))
    else if String.starts_with ~prefix:"service:" line then
      service_name := String.trim (String.sub line 8 (String.length line - 8))
    else if Str.string_match rpc_regex line 0 then begin
      let name = Str.matched_group 1 line in
      let client_stream = try Str.matched_group 2 line <> "" with Not_found -> false in
      let input_type = Str.matched_group 3 line in
      let server_stream = try Str.matched_group 4 line <> "" with Not_found -> false in
      let output_type = Str.matched_group 5 line in

      let method_type = match client_stream, server_stream with
        | false, false -> Unary
        | false, true -> ServerStreaming
        | true, false -> ClientStreaming
        | true, true -> BidiStreaming
      in

      methods := { name; input_type; output_type; method_type } :: !methods
    end
  ) lines;

  if !service_name = "" then None
  else Some {
    package = !package;
    service_name = !service_name;
    methods = List.rev !methods;
  }
