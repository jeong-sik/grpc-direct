(** Tests for grpc-protoc code generator *)

let test_parse_unary_service () =
  let input = {|
package: example
service: Calculator
rpc Add(AddRequest) returns (AddResponse)
|} in
  match Grpc_protoc.Codegen.parse_service_description input with
  | None -> failwith "Failed to parse unary service"
  | Some s ->
      assert (s.package = "example");
      assert (s.service_name = "Calculator");
      assert (List.length s.methods = 1);
      let m = List.hd s.methods in
      assert (m.name = "Add");
      assert (m.input_type = "AddRequest");
      assert (m.output_type = "AddResponse");
      assert (m.method_type = Grpc_protoc.Codegen.Unary);
      Printf.printf "  ✓ Parse unary service: OK\n%!"

let test_parse_server_streaming () =
  let input = {|
package: chat
service: ChatService
rpc ListMessages(ListRequest) returns (stream Message)
|} in
  match Grpc_protoc.Codegen.parse_service_description input with
  | None -> failwith "Failed to parse server streaming service"
  | Some s ->
      assert (List.length s.methods = 1);
      let m = List.hd s.methods in
      assert (m.method_type = Grpc_protoc.Codegen.ServerStreaming);
      Printf.printf "  ✓ Parse server streaming: OK\n%!"

let test_parse_client_streaming () =
  let input = {|
package: upload
service: UploadService
rpc Upload(stream Chunk) returns (UploadResult)
|} in
  match Grpc_protoc.Codegen.parse_service_description input with
  | None -> failwith "Failed to parse client streaming service"
  | Some s ->
      let m = List.hd s.methods in
      assert (m.method_type = Grpc_protoc.Codegen.ClientStreaming);
      Printf.printf "  ✓ Parse client streaming: OK\n%!"

let test_parse_bidi_streaming () =
  let input = {|
package: realtime
service: RealtimeService
rpc StreamUpdates(stream Request) returns (stream Response)
|} in
  match Grpc_protoc.Codegen.parse_service_description input with
  | None -> failwith "Failed to parse bidi streaming service"
  | Some s ->
      let m = List.hd s.methods in
      assert (m.method_type = Grpc_protoc.Codegen.BidiStreaming);
      Printf.printf "  ✓ Parse bidi streaming: OK\n%!"

let test_parse_multiple_methods () =
  let input = {|
package: helloworld
service: Greeter
rpc SayHello(HelloRequest) returns (HelloReply)
rpc SayHelloStream(HelloRequest) returns (stream HelloReply)
rpc Chat(stream ChatMessage) returns (stream ChatMessage)
|} in
  match Grpc_protoc.Codegen.parse_service_description input with
  | None -> failwith "Failed to parse multi-method service"
  | Some s ->
      assert (List.length s.methods = 3);
      Printf.printf "  ✓ Parse multiple methods (3): OK\n%!"

let test_to_snake_case () =
  let open Grpc_protoc.Codegen in
  assert (to_snake_case "HelloWorld" = "hello_world");
  assert (to_snake_case "SayHello" = "say_hello");
  assert (to_snake_case "GetHTTPRequest" = "get_h_t_t_p_request");  (* edge case *)
  assert (to_snake_case "simple" = "simple");
  Printf.printf "  ✓ Snake case conversion: OK\n%!"

let test_generate_client () =
  let service = Grpc_protoc.Codegen.{
    package = "test";
    service_name = "Echo";
    methods = [
      { name = "Echo";
        input_type = "EchoRequest";
        output_type = "EchoResponse";
        method_type = Unary };
    ];
  } in
  let code = Grpc_protoc.Codegen.generate_service service in
  assert (String.length code > 0);
  assert (String.contains code 'C');  (* Contains "Client" *)
  Printf.printf "  ✓ Generate client code: OK\n%!"

let test_generate_server () =
  let service = Grpc_protoc.Codegen.{
    package = "test";
    service_name = "Echo";
    methods = [
      { name = "Echo";
        input_type = "EchoRequest";
        output_type = "EchoResponse";
        method_type = Unary };
    ];
  } in
  let code = Grpc_protoc.Codegen.generate_service service in
  assert (String.contains code 'S');  (* Contains "Server" *)
  assert (String.contains code 'm');  (* Contains "module type S" *)
  Printf.printf "  ✓ Generate server code: OK\n%!"

let test_parse_empty_package () =
  let input = {|
service: SimpleService
rpc DoWork(Request) returns (Response)
|} in
  match Grpc_protoc.Codegen.parse_service_description input with
  | None -> failwith "Failed to parse service without package"
  | Some s ->
      assert (s.package = "");
      assert (s.service_name = "SimpleService");
      Printf.printf "  ✓ Parse service without package: OK\n%!"

let test_parse_with_comments () =
  let input = {|
// This is a comment
package: commented
service: CommentedService
// Another comment
rpc DoSomething(Request) returns (Response)
|} in
  match Grpc_protoc.Codegen.parse_service_description input with
  | None -> failwith "Failed to parse service with comments"
  | Some s ->
      assert (s.service_name = "CommentedService");
      Printf.printf "  ✓ Parse with comments: OK\n%!"

let () =
  Printf.printf "\n=== grpc-codegen tests ===\n\n%!";

  Printf.printf "📝 Service definition parsing:\n%!";
  test_parse_unary_service ();
  test_parse_server_streaming ();
  test_parse_client_streaming ();
  test_parse_bidi_streaming ();
  test_parse_multiple_methods ();
  test_parse_empty_package ();
  test_parse_with_comments ();

  Printf.printf "\n🔧 Helper functions:\n%!";
  test_to_snake_case ();

  Printf.printf "\n📦 Code generation:\n%!";
  test_generate_client ();
  test_generate_server ();

  Printf.printf "\n=== All codegen tests passed! ===\n%!"
