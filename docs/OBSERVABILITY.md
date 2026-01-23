# Observability (Prometheus)

This document defines a minimal Prometheus-based observability and alerting setup for grpc-direct.

## Quickstart

```ocaml
let metrics = Grpc_eio.Metrics.create () in

let server =
  Grpc_eio.Server.create ()
  |> Grpc_eio.Server.with_metrics metrics
in

Grpc_eio.Metrics.serve_prometheus ~sw ~env metrics
```

- Default bind: 127.0.0.1:9464
- Default path: /metrics

To bind to a different interface/port, pass an explicit sockaddr:

```ocaml
let addr = `Tcp (Eio.Net.Ipaddr.V4.any, 9464) in
Grpc_eio.Metrics.serve_prometheus ~addr ~sw ~env metrics
```

## Metrics

All metrics are prefixed with `grpc_server_`.

- `grpc_server_uptime_seconds` (gauge)
- `grpc_server_calls_total` (counter, also per-method)
- `grpc_server_calls_failed_total` (counter, also per-method)
- `grpc_server_active_calls` (gauge, per-method)
- `grpc_server_call_duration_seconds` (histogram, per-method)
- `grpc_server_request_bytes` (histogram, per-method)
- `grpc_server_response_bytes` (histogram, per-method)

## Alerting (examples)

These are conservative defaults. Tune thresholds to your traffic profile.

```yaml
groups:
  - name: grpc_direct
    rules:
      - alert: GrpcHighErrorRate
        expr: |
          (sum(rate(grpc_server_calls_failed_total[5m]))
           / sum(rate(grpc_server_calls_total[5m]))) > 0.01
        for: 5m
        labels:
          severity: page
        annotations:
          summary: "gRPC error rate > 1%"
          description: "Error ratio exceeded 1% over 5m."

      - alert: GrpcHighLatencyP95
        expr: |
          histogram_quantile(0.95,
            sum by (le) (rate(grpc_server_call_duration_seconds_bucket[5m]))
          ) > 0.5
        for: 10m
        labels:
          severity: warn
        annotations:
          summary: "gRPC p95 latency > 500ms"
          description: "p95 latency above 500ms over 10m."

      - alert: GrpcNoTraffic
        expr: sum(rate(grpc_server_calls_total[5m])) == 0
        for: 10m
        labels:
          severity: warn
        annotations:
          summary: "gRPC traffic halted"
          description: "No calls observed in the last 10m."
```

## Ops template (Prometheus)

For a minimal deployment, see `ops/prometheus/`.

- `ops/prometheus/prometheus.yml` (scrape config)
- `ops/prometheus/alerts.yml` (alert rules)
- `ops/prometheus/docker-compose.yml` (Prometheus container)

Update the scrape target in `ops/prometheus/prometheus.yml` to match your metrics
endpoint (default is `:9464`). Example:

```yaml
scrape_configs:
  - job_name: grpc_direct
    metrics_path: /metrics
    static_configs:
      - targets:
          - grpc-direct:9464
```

Start Prometheus:

```sh
cd grpc-direct/ops/prometheus
docker compose up -d
```

## Notes

- Avoid attaching `Metrics.server_interceptor` to the same registry when using `Server.with_metrics` to prevent double counting.
- For per-method alerts, add `by (method)` to the aggregations above.
- If you run multiple instances, also add `by (instance)` or `by (job)`.
- Request/response size histograms are useful for payload spikes and quota tuning.

## Verification (local)

Run the interop server with metrics enabled:

```sh
cd grpc-direct
dune exec --profile=release bench/interop_streaming_server.exe -- \
  --metrics --metrics-port 9464
```

Fetch `/metrics`:

```sh
curl -s http://127.0.0.1:9464/metrics | rg "grpc_server_calls_total"
```
