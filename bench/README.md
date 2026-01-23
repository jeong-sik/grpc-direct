# Bench Comparison

Minimal echo servers used for cross-language comparison.
All servers implement the same proto: `bench/go-comparison/echo.proto`.

## Results

Public benchmark results are **not published yet**. The scripts below are for
local experiments only.

## Common

Start a server on `:50051` or `:50099` (plaintext), then run:

```bash
# Standard test (50 concurrent, 100k requests)
ghz --insecure --proto bench/go-comparison/echo.proto \
  --call echo.EchoService/Echo \
  -d '{"message":"hello"}' -c 50 -n 100000 \
  127.0.0.1:50051

# High concurrency test
ghz --insecure --proto bench/go-comparison/echo.proto \
  --call echo.EchoService/Echo \
  -d '{"message":"hello"}' -c 200 -n 50000 \
  127.0.0.1:50051
```

## grpc-eio (OCaml) - h2_lite backend ⭐

**Recommended for benchmarking** - Uses custom h2_lite HTTP/2 stack:

```bash
# h2_lite echo server (fastest, port 50051)
dune exec lib/grpc_eio/h2_lite/echo_server.exe

# Or with custom port
dune exec lib/grpc_eio/h2_lite/echo_server.exe -- 50099
```

## grpc-eio (OCaml) - H2-eio backend

Uses external H2 library (slower than h2_lite):

```bash
dune exec --profile=release bench/bench_server.exe
```

## grpc-go

```bash
(cd bench/go-comparison && go run .)
```

## tonic (Rust)

```bash
(cd bench/rust-comparison && cargo run --release)
```

## grpc-cpp (C++)

Requires `grpc`, `protobuf`, `cmake` (Homebrew recommended).

```bash
cd bench/cpp-comparison
cmake -S . -B build
cmake --build build -j
./build/echo_server
```

## grpc-java

Requires JDK 21. Use the wrapper for reproducibility.

```bash
(cd bench/java-comparison && ./gradlew run --no-daemon)
```

## grpc-dotnet

Uses Docker for a reproducible .NET 8 runtime.

```bash
cd bench/dotnet-comparison
docker build -t grpc-dotnet-echo .
docker run --rm -p 50099:50099 grpc-dotnet-echo
```

## grpc-js (Node)

```bash
cd bench/node-comparison
npm ci
node server.js
```

## grpcio (Python)

```bash
cd bench/python-comparison
python3 -m venv .venv
. .venv/bin/activate
pip install -r requirements.txt
python server.py
```

If you need to regenerate proto stubs:

```bash
python -m grpc_tools.protoc -I ../go-comparison \
  --python_out=. --grpc_python_out=. \
  ../go-comparison/echo.proto
```
