# Soak Test

Runs a long-duration ghz workload against the local grpc-direct bench server.

## Usage

```bash
cd grpc-direct/ops/soak

# 24h soak (default)
./run_soak.sh

# Custom duration / concurrency
DURATION_SECONDS=3600 CONCURRENCY=100 DURATION_PER_RUN=60s ./run_soak.sh
```

## Logs

- Server: `grpc-direct/tmp/soak_server.log`
- Client: `grpc-direct/tmp/soak_client.log`

## Notes

This soak script targets `bench/bench_server.exe` (echo service on :50099).
If you want streaming/cancel coverage, use the interop suites in
`docs/INTEROP-SUITE.md`.
