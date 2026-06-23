"""Locust load test for the OTel Collector's OTLP/HTTP ingestion endpoint.

The goal of this file is NOT to fire constant, identical traffic. It deliberately
mixes several *shapes* of request so we can see which characteristic stresses the
collector first -- raw request rate, payload size, attribute complexity, or bursts.

It does that with four weighted "user" classes (defined at the bottom):
  - SmallTraceUser   (weight 6) -> tiny, fast traces        -> tests pure throughput
  - LargeTraceUser   (weight 2) -> 200 spans + padding      -> tests serialization cost
  - ComplexTraceUser (weight 1) -> many attributes per span -> tests parsing cost
  - BurstyTraceUser  (weight 1) -> many requests in a burst -> tests spiky load

Every payload knob is overridable via env vars (e.g. LARGE_TRACE_SPANS) so the same
file can drive the different profiles documented in README.md. The process also
exposes its own Prometheus metrics on :9646 (latency, request counts, payload size)
so Grafana can correlate client-side behavior with collector-side metrics.
"""

import json
import os
import random
import string
import time
from typing import Any

from locust import HttpUser, between, constant_pacing, events, task
from prometheus_client import Counter, Gauge, Histogram, start_http_server


REQUESTS = Counter(
    "locust_requests_total",
    "Locust requests by method, name, and result.",
    ["method", "name", "result"],
)
REQUEST_LATENCY = Histogram(
    "locust_request_latency_seconds",
    "Locust request latency in seconds.",
    ["method", "name"],
    buckets=(0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10, 30),
)
REQUEST_PAYLOAD_BYTES = Histogram(
    "locust_request_payload_bytes",
    "Serialized request payload size in bytes.",
    ["profile"],
    buckets=(512, 1024, 4096, 16384, 65536, 262144, 1048576, 4194304),
)
ACTIVE_USERS = Gauge("locust_active_users", "Current Locust user count.")


def int_env(name: str, default: int) -> int:
    value = os.getenv(name)
    if value is None:
        return default
    return int(value)


def random_hex(byte_count: int) -> str:
    return f"{random.getrandbits(byte_count * 8):0{byte_count * 2}x}"


def random_string(length: int) -> str:
    return "".join(random.choices(string.ascii_letters + string.digits, k=length))


def otlp_value(value: Any) -> dict[str, Any]:
    if isinstance(value, bool):
        return {"boolValue": value}
    if isinstance(value, int):
        return {"intValue": str(value)}
    if isinstance(value, float):
        return {"doubleValue": value}
    return {"stringValue": str(value)}


def attributes(values: dict[str, Any]) -> list[dict[str, Any]]:
    return [{"key": key, "value": otlp_value(value)} for key, value in values.items()]


# Build one OTLP span as a dict. attr_count and pad_bytes are the levers we use to
# make a span "heavier" (more attributes to parse, more bytes to serialize/transfer).
def build_span(profile: str, index: int, attr_count: int, pad_bytes: int) -> dict[str, Any]:
    now = time.time_ns()
    duration_ns = random.randint(100_000, 50_000_000)
    attrs: dict[str, Any] = {
        "load.profile": profile,
        "span.index": index,
        "http.method": "POST",
        "http.route": "/v1/traces",
        "customer.tier": random.choice(["free", "pro", "enterprise"]),
        "payload.variant": random.choice(["small", "medium", "large", "complex"]),
    }

    for attr_index in range(attr_count):
        attrs[f"test.attr.{attr_index}"] = random_string(16)

    if pad_bytes > 0:
        attrs["test.payload.padding"] = random_string(pad_bytes)

    return {
        "traceId": random_hex(16),
        "spanId": random_hex(8),
        "parentSpanId": random_hex(8),
        "name": f"{profile}-span-{index}",
        "kind": 2,
        "startTimeUnixNano": str(now - duration_ns),
        "endTimeUnixNano": str(now),
        "attributes": attributes(attrs),
        "status": {"code": 1},
    }


def build_trace_payload(
    profile: str,
    span_count: int,
    attr_count: int,
    pad_bytes_per_span: int,
) -> dict[str, Any]:
    return {
        "resourceSpans": [
            {
                "resource": {
                    "attributes": attributes(
                        {
                            "service.name": "locust-otel-loadtest",
                            "service.namespace": "fde-onsite",
                            "deployment.environment": "loadtest",
                            "load.profile": profile,
                        }
                    )
                },
                "scopeSpans": [
                    {
                        "scope": {
                            "name": "locust.synthetic",
                            "version": "1.0.0",
                        },
                        "spans": [
                            build_span(profile, index, attr_count, pad_bytes_per_span)
                            for index in range(span_count)
                        ],
                    }
                ],
            }
        ]
    }


@events.init_command_line_parser.add_listener
def add_prometheus_options(parser) -> None:
    parser.add_argument(
        "--prometheus-port",
        type=int,
        default=int_env("LOCUST_PROMETHEUS_PORT", 9646),
        help="Port where this Locust process exposes Prometheus metrics.",
    )


@events.init.add_listener
def start_prometheus_exporter(environment, **_kwargs) -> None:
    port = getattr(environment.parsed_options, "prometheus_port", 9646)
    start_http_server(port)


@events.request.add_listener
def record_request_metrics(
    request_type,
    name,
    response_time,
    response_length,
    exception,
    **_kwargs,
) -> None:
    result = "failure" if exception else "success"
    REQUESTS.labels(method=request_type, name=name, result=result).inc()
    REQUEST_LATENCY.labels(method=request_type, name=name).observe(response_time / 1000)


@events.spawning_complete.add_listener
def record_active_users(user_count, **_kwargs) -> None:
    ACTIVE_USERS.set(user_count)


# Base class shared by every user profile. abstract=True means Locust won't run it
# directly -- only its subclasses. post_trace() builds a payload, POSTs it to the
# collector's /v1/traces, records the payload size, and flags HTTP 4xx/5xx as failures.
class OtlpTraceUser(HttpUser):
    abstract = True
    endpoint_path = os.getenv("OTEL_ENDPOINT_PATH", "/v1/traces")
    request_timeout = int_env("OTEL_REQUEST_TIMEOUT_SECONDS", 15)

    def post_trace(
        self,
        profile: str,
        span_count: int,
        attr_count: int,
        pad_bytes_per_span: int,
    ) -> None:
        payload = build_trace_payload(profile, span_count, attr_count, pad_bytes_per_span)
        body = json.dumps(payload, separators=(",", ":")).encode("utf-8")
        REQUEST_PAYLOAD_BYTES.labels(profile=profile).observe(len(body))

        with self.client.post(
            self.endpoint_path,
            data=body,
            headers={"Content-Type": "application/json"},
            name=profile,
            catch_response=True,
            timeout=self.request_timeout,
        ) as response:
            if response.status_code >= 400:
                response.failure(f"collector returned HTTP {response.status_code}")


# weight = relative share of simulated users. With weights 6/2/1/1, most traffic is
# small+fast, with a minority of large, complex, and bursty senders -- a realistic mix.
# wait_time = how long each user pauses between tasks (controls per-user request rate).
class SmallTraceUser(OtlpTraceUser):
    weight = 6
    wait_time = between(0.1, 0.5)

    @task
    def send_small_trace(self) -> None:
        self.post_trace(
            profile="small_trace",
            span_count=int_env("SMALL_TRACE_SPANS", 4),
            attr_count=int_env("SMALL_TRACE_ATTRS", 4),
            pad_bytes_per_span=int_env("SMALL_TRACE_PAD_BYTES", 0),
        )


class LargeTraceUser(OtlpTraceUser):
    weight = 2
    wait_time = between(0.5, 1.5)

    @task
    def send_large_trace(self) -> None:
        self.post_trace(
            profile="large_trace",
            span_count=int_env("LARGE_TRACE_SPANS", 200),
            attr_count=int_env("LARGE_TRACE_ATTRS", 8),
            pad_bytes_per_span=int_env("LARGE_TRACE_PAD_BYTES", 64),
        )


class ComplexTraceUser(OtlpTraceUser):
    weight = 1
    wait_time = between(0.75, 2.0)

    @task
    def send_complex_trace(self) -> None:
        self.post_trace(
            profile="complex_trace",
            span_count=int_env("COMPLEX_TRACE_SPANS", 40),
            attr_count=int_env("COMPLEX_TRACE_ATTRS", 30),
            pad_bytes_per_span=int_env("COMPLEX_TRACE_PAD_BYTES", 128),
        )


class BurstyTraceUser(OtlpTraceUser):
    weight = 1
    wait_time = constant_pacing(3)

    @task
    def send_burst(self) -> None:
        burst_size = int_env("BURST_REQUESTS", 10)
        for _ in range(burst_size):
            self.post_trace(
                profile="bursty_trace",
                span_count=int_env("BURST_TRACE_SPANS", 8),
                attr_count=int_env("BURST_TRACE_ATTRS", 6),
                pad_bytes_per_span=int_env("BURST_TRACE_PAD_BYTES", 32),
            )
