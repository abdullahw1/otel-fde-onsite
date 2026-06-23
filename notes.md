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

## Load Test Results

Small baseline:

- users: 25
- spawn rate: 5/s
- duration: 2m
- achieved RPS: ~60
- p95: 61 ms aggregated
- p99: 270 ms aggregated
- error percentage: 0%
- first degradation signal: none; collector CPU was only ~12% of HPA target

Sustained mixed:

- users: 100
- spawn rate: 20/s
- duration: 5m
- achieved RPS: ~232
- p95: 96 ms aggregated
- p99: 600 ms aggregated
- error percentage: 0%
- first degradation signal: large and complex payloads had much higher tail latency than small payloads

Large payload:

- users: 150
- spawn rate: 30/s
- duration: 5m
- achieved RPS: ~326
- p95: 140 ms aggregated
- p99: 410 ms aggregated; large payload p99 reached ~5s
- error percentage: 0%
- first degradation signal: collector CPU crossed the HPA target at ~110%/70%

Heavy large-payload ramp:

- users: 300
- spawn rate: 60/s
- duration: 6m before HPA/GitOps fix, 4m after fix
- achieved RPS: ~428 before fix, ~444 after fix
- p95: 2.2s before fix, 1.7s after fix
- p99: 3.6s before fix, 3.6s after fix; large payload p99 reached ~13s
- error percentage: ~0.04% after fix
- first degradation signal: large payload timeouts and high tail latency

## Bottleneck Finding

Maximum load tested: ~444 RPS with 300 users, bursty traffic, and large/complex OTLP trace payloads.

Failure or degradation threshold: degradation became clear between ~326 RPS and ~444 RPS. At ~326 RPS there were no errors but large payload p99 was already ~5s and CPU crossed the HPA target. At ~444 RPS the run produced large payload timeouts and aggregated p95 was ~1.7s.

Primary bottleneck hypothesis: CPU-bound collector processing and serialization cost for large/complex OTLP payloads. The first bug found under load was a GitOps/HPA ownership conflict: Argo CD self-heal initially forced the Deployment back to 2 replicas while HPA was scaling it up, causing pod churn and connection resets. After fixing replica ownership, the remaining bottleneck was high tail latency and timeouts on large payloads while HPA scaled to 4 replicas.

Evidence:

- client latency and error behavior: baseline p95 was 61 ms with 0 failures; sustained 100-user run p95 was 96 ms with 0 failures; heavy 300-user run after the fix reached ~444 RPS with aggregated p95 ~1.7s, p99 ~3.6s, and 10 large-payload timeouts.
- collector accepted/refused/dropped telemetry: collector remained available and returned successful responses for nearly all requests; no broad refusal pattern was observed in Locust.
- collector CPU and memory: CPU crossed the HPA target during large-payload load; memory remained low and there were no OOM signals.
- pod restarts or OOMKilled events: no pod restarts or OOMKilled events were observed.
- HPA behavior: scaled from 2 to 4 after the Argo CD replica ownership fix. Before the fix, HPA attempted to scale but Argo CD/self-heal forced replicas back down, causing churn.
- node CPU, memory, or network: nodes stayed below saturation, around ~30% CPU and ~20% memory in the observed post-test snapshot.
- load balancer or connection behavior: before the fix, Locust saw connection resets/refusals during pod churn. After the fix, failures were large-payload timeouts rather than broad connection refusal.

What changed first: tail latency on large and complex payloads increased before broad errors appeared.

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

Load testing: varied users, spawn rate, run duration, span count, attribute count, padding, and burst size. The key comparison was small payloads versus large and complex payloads.

Finding: the first signal was tail latency on large and complex payloads. Evidence was p95 rising from 61 ms at ~60 RPS to ~1.7s at ~444 RPS, with large-payload timeouts and HPA scaling from 2 to 4 replicas. The next scalability improvement would be tuning collector batching/memory behavior and autoscaling on latency or collector-specific metrics, not only CPU.

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
