(** Tests for TLS configuration module *)

let test_tls_config_record () =
  (* Use the helper function for basic TLS *)
  let config =
    Grpc_eio.Tls_config.create ~cert_file:"/path/to/cert.pem" ~key_file:"/path/to/key.pem"
  in
  assert (config.cert_file = "/path/to/cert.pem");
  assert (config.key_file = "/path/to/key.pem");
  assert (config.ca_file = None);
  assert (config.client_auth = NoClientCert);
  Printf.printf "  ✓ TLS config record creation\n%!"
;;

let test_mtls_config () =
  (* Test mTLS configuration *)
  let config =
    Grpc_eio.Tls_config.create_mtls
      ~cert_file:"/path/to/cert.pem"
      ~key_file:"/path/to/key.pem"
      ~ca_file:"/path/to/ca.pem"
  in
  assert (config.ca_file = Some "/path/to/ca.pem");
  assert (config.client_auth = RequireAndVerify);
  assert (Grpc_eio.Tls_config.is_mtls config);
  Printf.printf "  ✓ mTLS config creation\n%!"
;;

let test_tls_config_invalid_paths () =
  let config =
    Grpc_eio.Tls_config.create
      ~cert_file:"/nonexistent/cert.pem"
      ~key_file:"/nonexistent/key.pem"
  in
  try
    match Grpc_eio.Tls_config.validate config with
    | Ok _ -> failwith "Should have returned Error for invalid paths"
    | Error msg -> Printf.printf "  ✓ Invalid paths rejected: %s\n%!" msg
  with
  | Sys_error msg -> Printf.printf "  ✓ Invalid paths rejected (Sys_error): %s\n%!" msg
;;

let test_tls_alpn_configuration () =
  (* Test that ALPN is set to "h2" in the module *)
  (* We can't easily test the actual Tls.Config without valid certs,
     but we verify the API exists and types check *)
  let config = Grpc_eio.Tls_config.create ~cert_file:"test.pem" ~key_file:"test.key" in
  ignore config;
  Printf.printf "  ✓ TLS config API exists with correct types\n%!"
;;

let create_test_certs () =
  (* Create self-signed test certificates using openssl *)
  let cert_file = Filename.temp_file "test_cert" ".pem" in
  let key_file = Filename.temp_file "test_key" ".pem" in
  let cleanup () =
    (try Sys.remove cert_file with
     | _ -> ());
    try Sys.remove key_file with
    | _ -> ()
  in
  let argv =
    [| "openssl"
     ; "req"
     ; "-x509"
     ; "-newkey"
     ; "rsa:2048"
     ; "-keyout"
     ; key_file
     ; "-out"
     ; cert_file
     ; "-days"
     ; "1"
     ; "-nodes"
     ; "-subj"
     ; "/CN=localhost"
    |]
  in
  try
    let devnull = Unix.openfile "/dev/null" [ Unix.O_WRONLY ] 0o666 in
    let pid = Unix.create_process "openssl" argv Unix.stdin devnull devnull in
    Unix.close devnull;
    let _pid, status = Unix.waitpid [] pid in
    match status with
    | Unix.WEXITED 0 -> Some (cert_file, key_file)
    | _ ->
      cleanup ();
      None
  with
  | Unix.Unix_error (Unix.ENOENT, _, _) ->
    cleanup ();
    None
  | _ ->
    cleanup ();
    None
;;

let cleanup_test_certs cert_file key_file =
  (try Sys.remove cert_file with
   | _ -> ());
  try Sys.remove key_file with
  | _ -> ()
;;

let test_tls_config_with_real_certs () =
  match create_test_certs () with
  | None -> Printf.printf "  ⚠ Skipped (openssl not available)\n%!"
  | Some (cert_file, key_file) ->
    let config = Grpc_eio.Tls_config.create ~cert_file ~key_file in
    (match Grpc_eio.Tls_config.validate config with
     | Ok valid ->
       assert valid;
       Printf.printf "  ✓ Valid certs accepted\n%!"
     | Error msg ->
       Printf.printf "  ✗ Unexpected error: %s\n%!" msg;
       failwith "TLS validation failed with valid certs");
    cleanup_test_certs cert_file key_file
;;

let test_tls_load_with_real_certs () =
  match create_test_certs () with
  | None -> Printf.printf "  ⚠ Skipped (openssl not available)\n%!"
  | Some (cert_file, key_file) ->
    let config = Grpc_eio.Tls_config.create ~cert_file ~key_file in
    (match Grpc_eio.Tls_config.load config with
     | Ok _tls_config -> Printf.printf "  ✓ TLS config loaded successfully\n%!"
     | Error msg ->
       Printf.printf "  ✗ Load failed: %s\n%!" msg;
       failwith "TLS load failed with valid certs");
    cleanup_test_certs cert_file key_file
;;

let test_client_tls_config () =
  (* Test client TLS helpers *)
  let insecure = Grpc_eio.Client.tls_insecure () in
  assert (insecure.ca_file = None);
  assert (insecure.cert_file = None);
  assert (not insecure.verify_peer);
  Printf.printf "  ✓ Client TLS insecure config\n%!";
  let with_ca = Grpc_eio.Client.tls_with_ca ~ca_file:"/path/to/ca.pem" in
  assert (with_ca.ca_file = Some "/path/to/ca.pem");
  assert (with_ca.cert_file = None);
  assert with_ca.verify_peer;
  Printf.printf "  ✓ Client TLS with CA config\n%!";
  let mtls =
    Grpc_eio.Client.tls_mtls
      ~ca_file:"/path/to/ca.pem"
      ~cert_file:"/path/to/client.pem"
      ~key_file:"/path/to/client.key"
  in
  assert (mtls.ca_file = Some "/path/to/ca.pem");
  assert (mtls.cert_file = Some "/path/to/client.pem");
  assert (mtls.key_file = Some "/path/to/client.key");
  assert mtls.verify_peer;
  Printf.printf "  ✓ Client mTLS config\n%!"
;;

let test_channel_credentials () =
  (* Test Credentials module - insecure *)
  let creds = Grpc_eio.Client.Credentials.insecure () in
  assert (not (Grpc_eio.Client.Credentials.requires_tls creds));
  assert (Grpc_eio.Client.Credentials.to_tls_config creds = None);
  Printf.printf "  ✓ Credentials.insecure()\n%!";
  (* Test Credentials module - TLS with CA *)
  let creds = Grpc_eio.Client.Credentials.tls ~ca_file:"/path/to/ca.pem" () in
  assert (Grpc_eio.Client.Credentials.requires_tls creds);
  (match Grpc_eio.Client.Credentials.to_tls_config creds with
   | Some cfg ->
     assert (cfg.ca_file = Some "/path/to/ca.pem");
     assert cfg.verify_peer
   | None -> failwith "Expected TLS config");
  Printf.printf "  ✓ Credentials.tls()\n%!";
  (* Test Credentials module - mTLS *)
  let creds =
    Grpc_eio.Client.Credentials.mtls
      ~ca_file:"/path/to/ca.pem"
      ~cert_file:"/path/to/client.pem"
      ~key_file:"/path/to/client.key"
      ()
  in
  assert (Grpc_eio.Client.Credentials.requires_tls creds);
  (match Grpc_eio.Client.Credentials.to_tls_config creds with
   | Some cfg ->
     assert (cfg.ca_file = Some "/path/to/ca.pem");
     assert (cfg.cert_file = Some "/path/to/client.pem");
     assert (cfg.key_file = Some "/path/to/client.key");
     assert cfg.verify_peer
   | None -> failwith "Expected TLS config");
  Printf.printf "  ✓ Credentials.mtls()\n%!";
  (* Test Credentials module - with_token *)
  let creds = Grpc_eio.Client.Credentials.with_token ~token:"my-jwt-token" () in
  assert (Grpc_eio.Client.Credentials.requires_tls creds);
  let headers = Grpc_eio.Client.Credentials.get_call_headers creds in
  assert (List.assoc "authorization" headers = "Bearer my-jwt-token");
  Printf.printf "  ✓ Credentials.with_token()\n%!";
  (* Test Credentials module - with_headers *)
  let creds =
    Grpc_eio.Client.Credentials.with_headers
      ~headers:[ "x-api-key", "secret123"; "x-custom", "value" ]
      ()
  in
  let headers = Grpc_eio.Client.Credentials.get_call_headers creds in
  assert (List.assoc "x-api-key" headers = "secret123");
  assert (List.assoc "x-custom" headers = "value");
  Printf.printf "  ✓ Credentials.with_headers()\n%!";
  (* Test Credentials module - with_compute_creds (dynamic) *)
  let counter = ref 0 in
  let creds =
    Grpc_eio.Client.Credentials.with_compute_creds
      ~f:(fun () ->
        incr counter;
        [ "x-request-id", string_of_int !counter ])
      ()
  in
  let headers1 = Grpc_eio.Client.Credentials.get_call_headers creds in
  let headers2 = Grpc_eio.Client.Credentials.get_call_headers creds in
  assert (List.assoc "x-request-id" headers1 = "1");
  assert (List.assoc "x-request-id" headers2 = "2");
  Printf.printf "  ✓ Credentials.with_compute_creds()\n%!"
;;

let test_config_with_credentials () =
  (* Test config_with_credentials helper *)
  let creds =
    Grpc_eio.Client.Credentials.mtls
      ~ca_file:"/path/to/ca.pem"
      ~cert_file:"/path/to/client.pem"
      ~key_file:"/path/to/client.key"
      ()
  in
  let config =
    Grpc_eio.Client.config_with_credentials
      ~target:"https://localhost:50051"
      ~credentials:creds
  in
  assert (config.target = "https://localhost:50051");
  assert (config.credentials = Some creds);
  (* Should also set legacy tls field for backward compatibility *)
  (match config.tls with
   | Some cfg ->
     assert (cfg.ca_file = Some "/path/to/ca.pem");
     assert (cfg.cert_file = Some "/path/to/client.pem")
   | None -> failwith "Expected TLS config in legacy field");
  Printf.printf "  ✓ config_with_credentials()\n%!"
;;

let () =
  Printf.printf "\n=== TLS Configuration Tests ===\n\n%!";
  Printf.printf "Basic tests:\n%!";
  test_tls_config_record ();
  test_mtls_config ();
  test_tls_alpn_configuration ();
  Printf.printf "\nValidation tests:\n%!";
  test_tls_config_invalid_paths ();
  Printf.printf "\nClient TLS tests:\n%!";
  test_client_tls_config ();
  Printf.printf "\nChannel Credentials tests:\n%!";
  test_channel_credentials ();
  test_config_with_credentials ();
  Printf.printf "\nIntegration tests (require openssl):\n%!";
  test_tls_config_with_real_certs ();
  test_tls_load_with_real_certs ();
  Printf.printf "\n=== All TLS tests passed! ===\n%!"
;;
