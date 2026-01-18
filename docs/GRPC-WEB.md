# gRPC-Web Support

grpc-eio provides a native gRPC-Web bridge over HTTP/1.1 with CORS support.
Both binary and text (base64) modes are supported.

## Server

```ocaml
let service =
  Grpc_eio.Service.create "web.Echo"
  |> Grpc_eio.Service.add_unary "Echo" (fun bytes -> bytes)
in
let server =
  Grpc_eio.Server.create ()
  |> Grpc_eio.Server.add_service service
in

let web_config =
  Grpc_eio.Grpc_web_server.{
    addr = `Tcp (Eio.Net.Ipaddr.V4.loopback, 8080);
    cors = Grpc_eio.Grpc_web_server.default_cors;
    tls = None;
    max_request_body = 8 * 1024 * 1024;
  }
in
Grpc_eio.Grpc_web_server.serve ~config:web_config ~sw ~env server
```

## Client

```ocaml
let client = Grpc_eio.Grpc_web_client.connect ~env "http://127.0.0.1:8080" in
let res =
  Grpc_eio.Grpc_web_client.call_unary ~sw ~env client
    ~service:"web.Echo" ~method_:"Echo" ~request:"hello"
in
match res with
| Ok bytes -> print_endline bytes
| Error status -> print_endline (Grpc_core.Status.to_string status)
```

## Notes

- Unary + server streaming are fully supported.
- Client streaming/bidi are available in **buffered request mode** (all request messages
  are collected before the HTTP/1.1 request is sent). This is a non-browser extension.
- Trailers are encoded in the response body with a 0x80 frame.
- For HTTPS, pass `Tls_config.t` in `Grpc_web_server.config.tls`.

## Browser streaming alternatives

Browser gRPC-Web cannot do client/bidi streaming. See `docs/GRPC-WEB-BROWSER.md`
for recommended proxy and WebSocket options.


## WebSocket gateway (browser client/bidi)

```ocaml
let ws_config =
  Grpc_eio.Grpc_web_ws_server.{
    addr = `Tcp (Eio.Net.Ipaddr.V4.loopback, 8082);
    tls = None;
    max_frame_size = 8 * 1024 * 1024;
    subprotocols = ["grpc-websockets"];
  }
in
Grpc_eio.Grpc_web_ws_server.serve ~config:ws_config ~sw ~env server
```

Notes:
- WebSocket payloads use gRPC-Web binary framing.
- Path is `/package.Service/Method` (same as gRPC).
- Request streaming is buffered until trailers/close.
