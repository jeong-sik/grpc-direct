# gRPC-Web Proxy (Envoy)

This proxy enables browser gRPC-Web (unary + server streaming) to a grpc-direct
backend. Client/bidi streaming is not supported by the gRPC-Web browser spec.

## Run

1) Start grpc-direct gRPC server on 50051 (HTTP/2).
2) Run Envoy with the config below:

```sh
cd grpc-direct/examples/grpc-web

docker run --rm -p 8081:8081 \
  -v $(pwd)/envoy.yaml:/etc/envoy/envoy.yaml \
  envoyproxy/envoy:v1.30-latest
```

3) Point your browser gRPC-Web client to `http://localhost:8081`.

## Notes

- For client/bidi streaming in browsers, use a WebSocket gateway.
- See `docs/GRPC-WEB-BROWSER.md` for alternatives.


## WebSocket gateway (client/bidi)

Use `Grpc_web_ws_server` to enable browser client/bidi streaming via WebSocket.
The browser sends gRPC-Web binary frames over WS, optionally with the
`grpc-websockets` subprotocol. Use the gRPC method path (e.g.
`/streaming.Echo/EchoBidi`) as the WebSocket URL path.
