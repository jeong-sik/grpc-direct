(** TLS configuration for gRPC server.

    Uses tls-eio for pure OCaml TLS with ALPN "h2" negotiation.

    {b Features:}
    - Server TLS: Basic HTTPS-style encryption
    - mTLS: Mutual TLS with client certificate verification

    {b mTLS Usage:}
    {[
      let tls = Tls_config.{
        cert_file = "./server.pem";
        key_file = "./server.key";
        ca_file = Some "./ca.pem";  (* Enable mTLS *)
        client_auth = RequireAndVerify;
      } in
      let server = Server.create ~config:{ default_config with tls = Some tls } ()
    ]} *)

(** Client authentication mode for mTLS *)
type client_auth =
  | NoClientCert (** Don't request client certificate (default TLS) *)
  | RequestClientCert (** Request but don't require client certificate *)
  | RequireAndVerify (** Require and verify client certificate (mTLS) *)

(** TLS configuration *)
type t =
  { cert_file : string (** Path to PEM certificate file *)
  ; key_file : string (** Path to PEM private key file *)
  ; ca_file : string option (** Optional CA cert for client verification (mTLS) *)
  ; client_auth : client_auth (** Client authentication mode *)
  }

(** Create a basic TLS config (server-only auth) *)
let create ~cert_file ~key_file : t =
  { cert_file; key_file; ca_file = None; client_auth = NoClientCert }
;;

(** Create mTLS config (mutual authentication) *)
let create_mtls ~cert_file ~key_file ~ca_file : t =
  { cert_file; key_file; ca_file = Some ca_file; client_auth = RequireAndVerify }
;;

let read_file = File_util.read_file

(** Load CA certificates for client verification *)
let load_ca_store (ca_file : string) : (X509.Authenticator.t, string) result =
  let ca_pem = read_file ca_file in
  match X509.Certificate.decode_pem_multiple ca_pem with
  | Error (`Msg msg) -> Error ("CA certificate error: " ^ msg)
  | Ok ca_certs ->
    (* Create authenticator that validates against these CAs *)
    let time () = Some (Ptime_clock.now ()) in
    Ok (X509.Authenticator.chain_of_trust ~time ca_certs)
;;

(** Load TLS server configuration from files with custom ALPN. *)
let load_with_alpn ~(alpn_protocols : string list) (tls : t)
  : (Tls.Config.server, string) result
  =
  let cert_pem = read_file tls.cert_file in
  let key_pem = read_file tls.key_file in
  let cert = X509.Certificate.decode_pem_multiple cert_pem in
  let key = X509.Private_key.decode_pem key_pem in
  match cert, key with
  | Ok certs, Ok key ->
    (* Build authenticator for mTLS if CA provided *)
    let authenticator_result =
      match tls.ca_file, tls.client_auth with
      | Some ca_file, RequireAndVerify -> Result.map Option.some (load_ca_store ca_file)
      | Some ca_file, RequestClientCert -> Result.map Option.some (load_ca_store ca_file)
      | _ -> Ok None
    in
    (match authenticator_result with
     | Error msg -> Error msg
     | Ok authenticator ->
       (match
          Tls.Config.server
            ~certificates:(`Single (certs, key))
            ~alpn_protocols
            ?authenticator
            ()
        with
        | Ok config -> Ok config
        | Error (`Msg msg) -> Error ("TLS config error: " ^ msg)))
  | Error (`Msg msg), _ -> Error ("Certificate error: " ^ msg)
  | _, Error (`Msg msg) -> Error ("Private key error: " ^ msg)
;;

(** Load TLS server configuration from files.
    Returns Tls.Config.server with ALPN set to "h2".

    For mTLS, set [ca_file] and [client_auth = RequireAndVerify]. *)
let load (tls : t) : (Tls.Config.server, string) result =
  load_with_alpn ~alpn_protocols:[ "h2" ] tls
;;

(** Load TLS server configuration for HTTP/1.1 (gRPC-Web). *)
let load_http1 (tls : t) : (Tls.Config.server, string) result =
  load_with_alpn ~alpn_protocols:[ "http/1.1" ] tls
;;

(** Validate TLS files can be loaded *)
let validate (tls : t) : (bool, string) result =
  match load tls with
  | Ok _ -> Ok true
  | Error msg -> Error msg
;;

(** Check if mTLS is enabled *)
let is_mtls (tls : t) : bool =
  match tls.client_auth with
  | RequireAndVerify -> true
  | _ -> false
;;
