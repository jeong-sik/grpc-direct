(** protoc-gen-grpc-direct: Protoc plugin for generating gRPC OCaml stubs.

    This executable is called by protoc when you run:
    protoc --grpc-direct_out=. --plugin=protoc-gen-grpc-direct myservice.proto

    For now, it also supports a simpler standalone mode:
    protoc-gen-grpc-direct < service_definition.txt > service_grpc.ml

    Service definition format:
    {v
    package: helloworld
    service: Greeter
    rpc SayHello(HelloRequest) returns (HelloReply)
    rpc SayHelloStream(HelloRequest) returns (stream HelloReply)
    v}
*)

module Protoc = struct
  module Reader = Ocaml_protoc_plugin.Reader
  module Writer = Ocaml_protoc_plugin.Writer
  module Field = Ocaml_protoc_plugin.Field
  module Descriptor = Google_types.Descriptor
  module Google = Descriptor.Google

  type request = {
    file_to_generate : string list;
    parameter : string option;
    proto_file : Google.Protobuf.FileDescriptorProto.t list;
  }

  let string_of_length_delimited (ld : Field.length_delimited) =
    let open Field in
    String.sub ld.data ld.offset ld.length

  let decode_request (input : string) : (request, string) result =
    let reader = Reader.create input in
    let fields = Reader.to_list reader in
    let file_to_generate = ref [] in
    let parameter = ref None in
    let proto_file = ref [] in
    let decode_proto_file (ld : Field.length_delimited) =
      let open Field in
      let r = Reader.create ~offset:ld.offset ~length:ld.length ld.data in
      Google.Protobuf.FileDescriptorProto.from_proto r
    in
    let error = ref None in
    List.iter (fun (num, field) ->
      match num, field with
      | 1, Field.Length_delimited ld ->
          file_to_generate := string_of_length_delimited ld :: !file_to_generate
      | 2, Field.Length_delimited ld ->
          parameter := Some (string_of_length_delimited ld)
      | 15, Field.Length_delimited ld ->
          (match decode_proto_file ld with
           | Ok file -> proto_file := file :: !proto_file
           | Error _ ->
               error := Some "Failed to decode FileDescriptorProto")
      | _ -> ()
    ) fields;
    match !error with
    | Some msg -> Error msg
    | None ->
        Ok {
          file_to_generate = List.rev !file_to_generate;
          parameter = !parameter;
          proto_file = List.rev !proto_file;
        }

  let normalize_type_name name =
    if String.length name > 0 && name.[0] = '.'
    then String.sub name 1 (String.length name - 1)
    else name

  let service_defs_of_file (file : Google.Protobuf.FileDescriptorProto.t) =
    let package = Option.value ~default:"" file.package in
    let to_method_def (m : Google.Protobuf.MethodDescriptorProto.t) =
      match m.name, m.input_type, m.output_type with
      | Some name, Some input_type, Some output_type ->
          let method_type =
            match m.client_streaming, m.server_streaming with
            | false, false -> Grpc_protoc.Codegen.Unary
            | true, false -> Grpc_protoc.Codegen.ClientStreaming
            | false, true -> Grpc_protoc.Codegen.ServerStreaming
            | true, true -> Grpc_protoc.Codegen.BidiStreaming
          in
          Some Grpc_protoc.Codegen.{
            name;
            input_type = normalize_type_name input_type;
            output_type = normalize_type_name output_type;
            method_type;
          }
      | _ -> None
    in
    file.service
    |> List.filter_map (fun (svc : Google.Protobuf.ServiceDescriptorProto.t) ->
      match svc.name with
      | None -> None
      | Some service_name ->
          let methods = List.filter_map to_method_def svc.method' in
          Some Grpc_protoc.Codegen.{ package; service_name; methods }
    )

  let output_name_of_proto name =
    if Filename.extension name = ".proto"
    then Filename.remove_extension name ^ "_grpc.ml"
    else name ^ "_grpc.ml"

  let generate_file_content services =
    services
    |> List.map Grpc_protoc.Codegen.generate_service
    |> String.concat "\n"

  let encode_file ~name ~content =
    let fields = [
      (1, Field.length_delimited name);
      (15, Field.length_delimited content);
    ] in
    let writer = Writer.of_list fields in
    Writer.contents writer

  let encode_response ?error files =
    let fields =
      match error with
      | Some msg -> [ (1, Field.length_delimited msg) ]
      | None -> []
    in
    let file_fields =
      List.map (fun (name, content) ->
        let payload = encode_file ~name ~content in
        (15, Field.length_delimited payload)
      ) files
    in
    let writer = Writer.of_list (fields @ file_fields) in
    Writer.contents writer

  let generate (req : request) : (string * string) list =
    let index =
      List.fold_left (fun acc (file : Google.Protobuf.FileDescriptorProto.t) ->
        match file.name with
        | Some name -> (name, file) :: acc
        | None -> acc
      ) [] req.proto_file
    in
    let file_targets =
      if req.file_to_generate = [] then List.map fst index else req.file_to_generate
    in
    let find_file name =
      List.assoc_opt name index
    in
    file_targets
    |> List.filter_map (fun name ->
      match find_file name with
      | None -> None
      | Some file ->
          let services = service_defs_of_file file in
          if services = [] then None
          else
            let content = generate_file_content services in
            Some (output_name_of_proto name, content)
    )
end

let read_all_stdin () =
  let buf = Buffer.create 1024 in
  try
    while true do
      let line = input_line stdin in
      Buffer.add_string buf line;
      Buffer.add_char buf '\n'
    done;
    Buffer.contents buf
  with End_of_file ->
    Buffer.contents buf

let () =
  let input = read_all_stdin () in

  (* Check if this looks like a protobuf CodeGeneratorRequest (binary) *)
  if String.length input > 0 && Char.code input.[0] < 32 then begin
    match Protoc.decode_request input with
    | Ok req ->
        let files = Protoc.generate req in
        print_string (Protoc.encode_response files)
    | Error msg ->
        print_string (Protoc.encode_response ~error:msg [])
  end else begin
    (* Text-based service definition *)
    match Grpc_protoc.Codegen.parse_service_description input with
    | None ->
        prerr_endline "Error: Failed to parse service definition.";
        prerr_endline "Expected format:";
        prerr_endline "";
        prerr_endline "  package: helloworld";
        prerr_endline "  service: Greeter";
        prerr_endline "  rpc SayHello(HelloRequest) returns (HelloReply)";
        exit 1
    | Some service ->
        let code = Grpc_protoc.Codegen.generate_service service in
        print_string code
  end
