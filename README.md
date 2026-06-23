# FDE Infra Onsite: OTEL Collector On EKS

This repo is a minimal, repeatable implementation for provisioning, deploying, observing, and load testing OpenTelemetry Collector on AWS EKS.

## Architecture

Terraform creates:

- a VPC across two AZs
- public subnets for the internet-facing load balancer
- private subnets for EKS worker nodes
- one NAT gateway to keep the exercise cost controlled
- an EKS managed control plane and managed node group
- EKS add-ons for CoreDNS, kube-proxy, VPC CNI, and pod identity support

Argo CD deploys:

- OpenTelemetry Collector from `k8s/otel-collector`
- `kube-prometheus-stack` for Prometheus, Grafana, node exporter, and kube-state-metrics
- `metrics-server` so the collector HPA can scale from CPU utilization

Public traffic enters through a Kubernetes `LoadBalancer` Service annotated for an AWS NLB. The collector exposes OTLP HTTP on `4318` and OTLP gRPC on `4317`. Collector metrics stay internal on `8888` and are scraped by Prometheus through a `ServiceMonitor`.

## Why NLB

I chose NLB because OTEL Collector is an ingestion service and OTLP maps cleanly to TCP-style load balancing. It avoids the AWS Load Balancer Controller and ALB ingress setup, which is useful in a time-boxed exercise. For a production internet-facing HTTP API with host/path routing, WAF, or richer L7 controls, I would reconsider ALB.

## Prerequisites

- AWS credentials for the target account
- Terraform
- AWS CLI
- `kubectl`
- Helm
- Python 3.11+

## Provision Infrastructure

```bash
cd infra
cp terraform.tfvars.example terraform.tfvars
terraform init
terraform apply
```

Configure `kubectl`:

```bash
aws eks update-kubeconfig \
  --region "$(terraform output -raw aws_region)" \
  --name "$(terraform output -raw cluster_name)"
```

Destroy everything when finished:

```bash
cd infra
terraform destroy
```

## Install Argo CD

```bash
kubectl create namespace argocd
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update
helm upgrade --install argocd argo/argo-cd --namespace argocd
```

The OTEL Collector Argo CD Application points at `https://github.com/abdullahw1/otel-fde-onsite.git` and deploys the `k8s/otel-collector` path.

```bash
kubectl apply -f argocd/metrics-server-application.yaml
kubectl apply -f argocd/monitoring-application.yaml
kubectl apply -f argocd/otel-collector-application.yaml
```

The GitOps flow is: edit manifests in Git, push to the repository, Argo CD detects the change, applies it to the cluster, prunes removed objects, and self-heals drift.

## Verify The Deployment

```bash
kubectl -n otel get pods
kubectl -n otel get svc otel-collector-nlb
kubectl -n otel get hpa otel-collector
```

Get the public OTLP HTTP endpoint:

```bash
export OTEL_NLB_HOST="$(kubectl -n otel get svc otel-collector-nlb -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')"
export OTEL_HOST="http://${OTEL_NLB_HOST}:4318"
```

## Grafana

Grafana is intentionally private:

```bash
kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80
```

Open `http://localhost:3000` and log in with `admin` / `admin`. Import `dashboards/otel-load-test-dashboard.json`.

The dashboard is built around the question: when traffic increases, what fails first? It correlates Locust request rate, client latency and errors, collector accepted/refused spans, collector CPU and memory, restarts, HPA replicas, node saturation, and network throughput.

## Load Testing

```bash
cd loadtest
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
mkdir -p results
locust -f locustfile.py --host "$OTEL_HOST" --headless -u 25 -r 5 --run-time 5m --csv results/small
```

Additional profiles are documented in `loadtest/README.md`.

## Expected Bottleneck Hypotheses

Likely first failures for this intentionally small cluster:

- collector CPU saturation: p95/p99 latency rises, HPA scales, refused spans or client timeouts may follow
- memory pressure: working set approaches limit, `memory_limiter` starts refusing data, or pods OOM/restart
- serialization and payload complexity: large/complex payloads degrade earlier than small payloads at the same request count
- node saturation: multiple collector pods contend for node CPU, memory, or network
- load balancer or client limits: client connection errors rise while pods still look healthy

## AI Usage Notes

AI was used to accelerate boilerplate for Terraform, Kubernetes manifests, dashboard PromQL, and Locust test generation. The generated output should be reviewed by checking which AWS resources are created, validating Kubernetes objects with `kubectl`, confirming the NLB endpoint, running the Locust profiles, and correlating client and cluster metrics in Grafana. The important review point is understanding the generated configuration rather than treating it as a black box.
