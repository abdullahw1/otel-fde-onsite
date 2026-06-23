# Onsite Notes

## Architecture Summary

- Terraform provisions VPC, two public subnets, two private subnets, NAT, EKS, managed nodes, and EKS add-ons.
- Argo CD reconciles the collector and platform add-ons from declarative manifests.
- OTEL Collector receives OTLP HTTP on `4318` and optional OTLP gRPC on `4317`.
- A public AWS NLB exposes only the ingestion ports.
- Prometheus scrapes Kubernetes, node, and collector metrics.
- Grafana dashboard correlates client load, collector health, pod resources, node resources, and scaling.
- Locust generates small, large, complex, and bursty OTLP HTTP trace traffic.

## Tradeoffs

- NLB over ALB: simpler OTLP ingestion path and less controller/IAM setup for the time box.
- Managed EKS: reduces control plane operational burden and keeps the Terraform explainable.
- Two nodes: enough to test scheduling and basic HA while keeping AWS cost low.
- Single NAT gateway: cheaper and simpler; production multi-AZ NAT would improve AZ resilience.
- Private Grafana: safer default for the exercise; use SSO/VPN/private admin access in production.
- Debug exporter: validates a complete collector pipeline without needing a downstream backend, but a real backend would be needed for end-to-end telemetry delivery testing.

## Load Test Results Template

Small baseline:

- users:
- spawn rate:
- duration:
- achieved RPS:
- p95:
- p99:
- error percentage:
- first degradation signal:

Sustained mixed:

- users:
- spawn rate:
- duration:
- achieved RPS:
- p95:
- p99:
- error percentage:
- first degradation signal:

Large payload:

- users:
- spawn rate:
- duration:
- achieved RPS:
- p95:
- p99:
- error percentage:
- first degradation signal:

Bursty ramp:

- users:
- spawn rate:
- duration:
- achieved RPS:
- p95:
- p99:
- error percentage:
- first degradation signal:

## Bottleneck Finding Template

Maximum load tested:

Failure or degradation threshold:

Primary bottleneck hypothesis:

Evidence:

- client latency and error behavior:
- collector accepted/refused/dropped telemetry:
- collector CPU and memory:
- pod restarts or OOMKilled events:
- HPA behavior:
- node CPU, memory, or network:
- load balancer or connection behavior:

What changed first:

What I would change next:

- tune collector `memory_limiter` and `batch` processors
- scale collector replicas or node size based on measured CPU/memory pressure
- add HPA custom metrics for queue depth, refused spans, or p95 latency
- test with a real downstream exporter to identify backend bottlenecks
- add alerts for refused spans, OOMKills, restart loops, CPU throttling, and HPA max replicas
- tighten EKS API CIDR, IAM policies, and public ingress controls

## Five-Minute Presentation Outline

Goal: provision a production-like OTEL Collector path on EKS, expose it publicly, observe it, load test it, and identify the first bottleneck under scale.

Architecture: Terraform creates VPC and EKS. Argo CD deploys OTEL Collector, Prometheus/Grafana, and metrics-server. NLB exposes OTLP HTTP/gRPC. Locust generates OTLP HTTP traffic.

Tradeoffs: NLB is simpler for ingestion, managed EKS keeps operations focused, two nodes keep cost low, Grafana stays private, and the debug exporter avoids adding a backend before the ingestion path is understood.

Load testing: vary users, spawn rate, run duration, span count, attribute count, padding, and burst size. Compare small payloads against large and complex payloads.

Finding: the first signal was `TBD`. The evidence was `TBD`. The next scalability improvement would be `TBD`.

AI usage: AI helped generate initial Terraform, Kubernetes, dashboard, and Locust boilerplate. I reviewed the resources, validated manifests, ran tests, and used metrics to revise the bottleneck hypothesis.

## Customer Debugging Framework

Start by separating blast radius, timeline, and symptom type:

- when did latency start?
- who is affected?
- are errors rising or only latency?
- did traffic volume, payload size, or request mix change?
- was there a recent deploy or config change?
- do p50, p95, and p99 move together?
- are pods CPU or memory saturated?
- are there restarts, OOMKills, throttling, or node pressure?
- is queue depth or downstream latency increasing?
- do load balancer target health or connection errors change?

Communicate with this structure:

Current hypothesis:

Validation metric or query:

Short-term mitigation:

Long-term fix:
