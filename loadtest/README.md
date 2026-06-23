# Locust Load Tests

The load test sends OTLP HTTP JSON to `/v1/traces`. It includes weighted user classes for small, large, complex, and bursty trace payloads so the collector is stressed by request rate, serialization cost, payload size, and burst behavior.

## Install

```bash
cd loadtest
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

## Endpoint

```bash
export OTEL_NLB_HOST="$(kubectl -n otel get svc otel-collector-nlb -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')"
export OTEL_HOST="http://${OTEL_NLB_HOST}:4318"
```

## Profiles

Small baseline:

```bash
mkdir -p results
locust -f locustfile.py --host "$OTEL_HOST" --headless -u 25 -r 5 --run-time 5m --csv results/small
```

Sustained mixed traffic:

```bash
locust -f locustfile.py --host "$OTEL_HOST" --headless -u 100 -r 10 --run-time 15m --csv results/sustained
```

Large payload stress:

```bash
LARGE_TRACE_SPANS=500 LARGE_TRACE_PAD_BYTES=256 COMPLEX_TRACE_PAD_BYTES=512 \
locust -f locustfile.py --host "$OTEL_HOST" --headless -u 75 -r 10 --run-time 10m --csv results/large-payload
```

Bursty ramp:

```bash
BURST_REQUESTS=25 locust -f locustfile.py --host "$OTEL_HOST" --headless -u 150 -r 50 --run-time 8m --csv results/bursty
```

## Prometheus Metrics

Each Locust process exposes Prometheus metrics on `:9646` by default:

```bash
locust -f locustfile.py --host "$OTEL_HOST" --prometheus-port 9646
```

If Locust runs outside the cluster, use the CSV output for client-side evidence. If it runs inside the cluster, scrape the `/metrics` endpoint so the Grafana dashboard can show `locust_request_latency_seconds` and `locust_requests_total`.

## What To Capture

For each run, record:

- user count, spawn rate, and run duration
- achieved RPS
- p50, p95, and p99 latency
- failure percentage and dominant status codes
- collector CPU and memory
- pod restarts or OOMKilled events
- HPA replica changes
- node CPU, memory, and network saturation
