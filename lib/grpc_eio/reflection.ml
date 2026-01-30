(** gRPC Server Reflection v1 implementation.

    Implements the gRPC Server Reflection protocol for service discovery:
    https://github.com/grpc/grpc/blob/master/doc/server-reflection.md

    This allows tools like grpcurl to discover available services and methods
    without needing proto files.

    Usage:
    {[
      let server = Server.create ()
        |> Server.add_service my_service
        |> Server.add_service (Reflection.to_service server)
      in
      Server.serve ~sw ~env server
    ]}

    Note: This is a simplified implementation that only supports:
    - ListServices: Returns list of registered service names
    - FileContainingSymbol: Returns basic service info (no FileDescriptor)

    Full FileDescriptor support would require proto file registration. *)

(** Service info for reflection *)
type service_info =
  { name : string
  ; methods : string list
  }

(** Reflection request types *)
type request =
  | ListServices
  | FileContainingSymbol of string
  | FileByFilename of string
  | Unknown

(** Reflection response types (reserved for future use)
    [@warning "-34"] suppresses unused type warning
    [@warning "-37"] suppresses unused constructor warnings *)
type response =
  | ServiceList of string list
  | ServiceInfo of service_info
  | ErrorResponse of int * string
[@@warning "-34-37"]

(** Wire format constants *)
module Wire = struct
  (* Field numbers for ServerReflectionRequest *)
  let[@warning "-32"] _req_host = 1
  let req_file_by_filename = 3
  let req_file_containing_symbol = 4
  let req_list_services = 7

  (* Field numbers for ServerReflectionResponse *)
  let[@warning "-32"] _resp_valid_host = 1
  let[@warning "-32"] _resp_original_request = 2
  let[@warning "-32"] _resp_file_descriptor_response = 4
  let resp_list_services_response = 6
  let resp_error_response = 7

  (* Field numbers for ListServiceResponse *)
  let list_service_service = 1

  (* Field numbers for ServiceResponse (within ListServiceResponse) *)
  let service_name = 1

  (* Field numbers for ErrorResponse *)
  let error_code = 1
  let error_message = 2
end

(** Decode a varint from bytes - returns value directly without raising exceptions *)
let decode_varint (bytes : string) (pos : int ref) : int =
  let result = ref 0 in
  let shift = ref 0 in
  let done_ = ref false in
  while !pos < String.length bytes && not !done_ do
    let byte = Char.code bytes.[!pos] in
    incr pos;
    result := !result lor ((byte land 0x7f) lsl !shift);
    shift := !shift + 7;
    if byte land 0x80 = 0 then done_ := true
  done;
  !result
;;

(** Encode a varint to bytes *)
let encode_varint (n : int) : string =
  if n = 0
  then "\x00"
  else (
    let buf = Buffer.create 10 in
    let n = ref n in
    while !n > 0 do
      let byte = !n land 0x7f in
      n := !n lsr 7;
      if !n > 0
      then Buffer.add_char buf (Char.chr (byte lor 0x80))
      else Buffer.add_char buf (Char.chr byte)
    done;
    Buffer.contents buf)
;;

(** Encode a length-delimited field *)
let encode_length_delimited (field_num : int) (data : string) : string =
  let tag = (field_num lsl 3) lor 2 in
  (* wire type 2 = length-delimited *)
  encode_varint tag ^ encode_varint (String.length data) ^ data
;;

(** Encode a string field *)
let encode_string_field (field_num : int) (s : string) : string =
  encode_length_delimited field_num s
;;

(** Parse ServerReflectionRequest *)
let parse_request (data : string) : request =
  if String.length data = 0
  then ListServices
  else (
    let pos = ref 0 in
    let result = ref Unknown in
    while !pos < String.length data do
      let tag = decode_varint data pos in
      let field_num = tag lsr 3 in
      let wire_type = tag land 7 in
      match wire_type with
      | 2 ->
        (* length-delimited *)
        let len = decode_varint data pos in
        let value = String.sub data !pos len in
        pos := !pos + len;
        (match field_num with
         | n when n = Wire.req_file_by_filename -> result := FileByFilename value
         | n when n = Wire.req_file_containing_symbol -> result := FileContainingSymbol value
         | n when n = Wire.req_list_services -> result := ListServices
         | _ -> ())
      | 0 ->
        (* varint - skip *)
        let _ = decode_varint data pos in ()
      | _ ->
        (* Skip unknown wire types *)
        pos := String.length data
    done;
    !result)
;;

(** Encode ListServicesResponse *)
let encode_list_services_response (services : string list) : string =
  let service_msgs =
    List.map
      (fun name ->
         (* ServiceResponse message: field 1 = name *)
         encode_string_field Wire.service_name name)
      services
  in
  (* ListServiceResponse: repeated field 1 = service *)
  let list_response =
    String.concat
      ""
      (List.map
         (fun msg -> encode_length_delimited Wire.list_service_service msg)
         service_msgs)
  in
  (* ServerReflectionResponse: field 6 = list_services_response *)
  encode_length_delimited Wire.resp_list_services_response list_response
;;

(** Encode ErrorResponse *)
let encode_error_response (code : int) (message : string) : string =
  let error_msg =
    encode_varint ((Wire.error_code lsl 3) lor 0)
    (* varint field *)
    ^ encode_varint code
    ^ encode_string_field Wire.error_message message
  in
  encode_length_delimited Wire.resp_error_response error_msg
;;

(** Get service info from server *)
let get_service_info (server : Server.t) (symbol : string) : service_info option =
  (* Symbol can be "package.Service" or "package.Service.Method" *)
  let service_name =
    match String.rindex_opt symbol '/' with
    | Some idx -> String.sub symbol 0 idx
    | None -> symbol
  in
  (* Try to find the service *)
  let services = Server.list_services server in
  if List.mem service_name services
  then
    (* For now, just return the service name without methods *)
    Some { name = service_name; methods = [] }
  else if List.exists (fun s -> String.equal s symbol) services
  then Some { name = symbol; methods = [] }
  else None
;;

(** Create the ServerReflection service.

    Note: The server parameter creates a circular dependency.
    The service needs to be added to the server after creation,
    so we use a ref to break the cycle.

    @param server_ref Reference to the server for service discovery *)
let to_service (server_ref : Server.t ref) : Service.t =
  (* Bidirectional streaming handler for gRPC Server Reflection v1.
     Takes sw parameter to fork process_loop in separate fiber,
     allowing handler to return immediately with response_stream. *)
  let handle_reflection_bidi ~sw (request_stream : string Grpc_stream.t) : string Grpc_stream.t =
    let response_stream = Grpc_stream.create 16 in
    let server = !server_ref in
    let services = Server.list_services server in
    (* Process each request and send response - runs in separate fiber *)
    let process_loop () =
      let rec loop () =
        try
          let request_bytes = Grpc_stream.take request_stream in
          let response =
            match parse_request request_bytes with
            | ListServices ->
              encode_list_services_response services
            | FileContainingSymbol symbol ->
              (match get_service_info server symbol with
               | Some _info -> encode_list_services_response [ symbol ]
               | None -> encode_error_response 5 (Printf.sprintf "Symbol not found: %s" symbol))
            | FileByFilename filename ->
              encode_error_response 5 (Printf.sprintf "FileDescriptor not available for: %s" filename)
            | Unknown ->
              encode_error_response 3 "Unknown request type"
          in
          Grpc_stream.add response_stream response;
          loop ()
        with End_of_file ->
          Grpc_stream.close response_stream
      in
      loop ()
    in
    Eio.Fiber.fork ~sw process_loop;
    response_stream
  in
  Service.create "grpc.reflection.v1.ServerReflection"
  |> Service.add_bidi_streaming "ServerReflectionInfo" handle_reflection_bidi
;;

(** Helper to create server with reflection enabled.

    Usage:
    {[
      let server = Reflection.create_server_with_reflection ()
        |> Server.add_service my_service
      in
      Server.serve ~sw ~env server
    ]} *)
let create_server_with_reflection ?config () : Server.t =
  let server = Server.create ?config () in
  let server_ref = ref server in
  let reflection_service = to_service server_ref in
  let server = Server.add_service reflection_service server in
  server_ref := server;
  server
;;

(** Check if a server has reflection enabled *)
let is_enabled (server : Server.t) : bool =
  let services = Server.list_services server in
  List.mem "grpc.reflection.v1.ServerReflection" services
;;

(** Reflection service name constant *)
let service_name = "grpc.reflection.v1.ServerReflection"
