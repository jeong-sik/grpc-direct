# gRPC-Web in Browsers (Streaming)

## Why client/bidi streaming does not work in browsers

gRPC-Web (the standard browser protocol) only supports unary and
server streaming. Client streaming and bidirectional streaming are not
supported by the browser transport (fetch/XHR) and trailer handling.
This limitation applies to all language implementations.

## What other implementations do

- Unary + server streaming: gRPC-Web over HTTP/1.1 via Envoy or grpcwebproxy.
- Client/bidi streaming: use a different transport (usually WebSocket), e.g.
  Connect-Web, or a custom WS bridge.

## Recommended path for grpc-eio

1) Run grpc-eio as a normal gRPC (HTTP/2) server.
2) Use Envoy for gRPC-Web (unary + server streaming) in the browser.
3) If you need client/bidi streaming in browsers, add a WebSocket gateway.
   grpc-eio provides `Grpc_web_ws_server` for this.

The Envoy config in `examples/grpc-web/envoy.yaml` provides the standard
grpc-web proxy path.

## Envoy quickstart (unary + server streaming)

```sh
# Terminal 1: run grpc-eio server on 50051

# Terminal 2: run Envoy (grpc-web proxy)
# docker run --rm -p 8081:8081 \
#   -v $(pwd)/examples/grpc-web/envoy.yaml:/etc/envoy/envoy.yaml \
#   envoyproxy/envoy:v1.30-latest
```

Your browser client points to `http://localhost:8081`.

## If you need browser client/bidi streaming

Use a WebSocket gateway (Connect-Web or a custom WS bridge). That is a
separate protocol from gRPC-Web and must be implemented explicitly.


## grpc-eio WebSocket gateway

`Grpc_web_ws_server` implements a simple gRPC-Web-over-WebSocket bridge:
- WebSocket subprotocol: `grpc-websockets` (optional).
- Payloads: gRPC-Web binary framing.
- Path: `/package.Service/Method` (same as gRPC).
- Request streaming: buffered until trailers/close.

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
