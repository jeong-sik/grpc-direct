# Production Example

This example demonstrates a production-style setup:

- Logging interceptor
- Health check service
- Reflection enabled
- Prometheus metrics endpoint
- Optional TLS

## Run server

```bash
cd lib/grpc-eio-next

dune exec examples/production/production_server.exe
```

Metrics endpoint:

- http://127.0.0.1:9464/metrics

## Run client

```bash
cd lib/grpc-eio-next

dune exec examples/production/production_client.exe
```

## TLS (optional)

```bash
TLS=1 CERT=./server.pem KEY=./server.key \
  dune exec examples/production/production_server.exe
```

Generate a self-signed cert if needed:

```bash
openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout server.key -out server.pem -days 365 \
  -subj "/CN=localhost"
```

## Notes

This example uses raw string payloads for simplicity. For protobuf types,
use the code generator:

```bash
protoc --ocaml_out=. --grpc-eio_out=. \
  --plugin=protoc-gen-grpc-eio=$(which protoc-gen-grpc-eio) \
  your/service.proto
```
