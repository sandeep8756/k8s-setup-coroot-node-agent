# Kubernetes Coroot Node Agent Stack — Help Guide

Install the **APM observability stack** into the `apm` namespace on a Kubernetes cluster. The stack deploys Coroot cluster and node agents plus a local Prometheus instance that receives remote-write metrics and forwards a filtered subset to Fluent Bit.

## Overview

| Item | Value |
|------|-------|
| Target namespace | `apm` |
| Installer script | `install.sh` |
| Cluster agent | `coroot-cluster-agent` (Deployment, 1 replica) |
| Node agent | `coroot-node-agent` (DaemonSet, one pod per node) |
| Metrics relay | `prometheus` (Deployment + NodePort Service) |
| Remote-write receiver | `http://prometheus.apm.svc.cluster.local:9090/api/v1/write` |
| Prometheus retention | 2 hours (local TSDB) |

## Architecture

```
┌─────────────────────┐     remote write      ┌──────────────┐
│ coroot-cluster-agent│ ────────────────────► │              │
│ (kube_* metrics)    │                       │  Prometheus  │
└─────────────────────┘                       │  (apm ns)    │
                                              │              │
┌─────────────────────┐     remote write      │              │──► Fluent Bit
│ coroot-node-agent   │ ────────────────────► │              │    (remote_write)
│ (container metrics) │   (per node)          └──────────────┘
└─────────────────────┘
```

1. **Coroot cluster agent** watches Kubernetes API resources and emits cluster-level metrics.
2. **Coroot node agent** runs on every node (privileged, `hostPID`) and collects container metrics for workloads matching the allowlist regex.
3. **Prometheus** accepts remote write from both agents, applies relabel rules, and forwards selected metrics to Fluent Bit with `technologyCategoryId` and `CloudXP_CustomerID` labels.
4. **Fluent Bit** *(optional, `--install-fluentbit`)* receives Prometheus remote_write on port `9882` and forwards metrics to `https://sitazure.hcmp.jio.com/metrics` with TLS certificate verification disabled (internal CA).

## Folder contents

```
k8s-setup-coroot-node-agent/
├── install.sh                          # Main installer (applies all steps)
├── step1-coroot-cluster-agent-rbac.yaml   # Pull secret + ServiceAccount + RBAC
├── step2-coroot-cluster-agent.yaml        # Cluster agent Deployment
├── step3-coroot-node-agent-ds.yaml        # Node agent DaemonSet
├── step4-prometheus-configmap.yaml        # Prometheus scrape + remote_write config
├── step4-prometheus-deployment.yaml       # Prometheus Deployment
├── step4-prometheus-service.yaml          # Prometheus NodePort Service
├── step5-fluent-bit-configmap.yaml        # Fluent Bit config (optional step)
├── step5-fluent-bit-deployment.yaml       # Fluent Bit Deployment
├── step5-fluent-bit-service.yaml          # Fluent Bit ClusterIP Service
└── HELP.md                             # This guide
```

Do **not** apply the `step*.yaml` files directly — they contain placeholders (`__IMAGE_REPO__`, etc.) that `install.sh` substitutes at runtime.

## Prerequisites

- **kubectl** configured with cluster-admin or sufficient permissions to create:
  - Namespace `apm`
  - ClusterRole / ClusterRoleBinding
  - Deployments, DaemonSets, Services, ConfigMaps, Secrets
- Network access to the container image registry (Nexus)
- A reachable **Fluent Bit** remote-write endpoint (in-cluster via `--install-fluentbit`, or an existing service you pass to `--fluentbit-endpoint`)
- Nodes must support privileged containers and host path mounts (`/sys/fs/cgroup`, `/sys/kernel/tracing`, `/sys/kernel/debug`)

## Quick start

```bash
cd k8s-setup-coroot-node-agent
chmod +x install.sh

./install.sh \
  --image-repo devopsartifact.jio.com/tps-jio_cloud_management_platform__sit__dcr/apm \
  --k8s-cluster-name my-cluster-prod \
  --container-allowlist '/k8s/(deeptrace|coroot)/.*' \
  --technology-category-id '12345' \
  --cloudxp-customer-id 'CUST-001' \
  --application-id '12345' \
  --application-name 'my-app' \
  --fluentbit-endpoint 'http://fluent-bit.apm.svc.cluster.local:9882/api/v1/metrics' \
  --jwt-token '<JWT_TOKEN>'
```

Install with in-cluster Fluent Bit (forwards to HCMP SIT):

```bash
./install.sh \
  --install-fluentbit \
  --image-repo devopsartifact.jio.com/tps-jio_cloud_management_platform__sit__dcr/apm \
  --k8s-cluster-name my-cluster-prod \
  --container-allowlist '/k8s/(deeptrace|coroot)/.*' \
  --technology-category-id '12345' \
  --cloudxp-customer-id 'CUST-001' \
  --application-id '12345' \
  --application-name 'my-app' \
  --jwt-token '<JWT_TOKEN>'
```

`--install-fluentbit` auto-sets `--fluentbit-endpoint` to `http://fluent-bit.apm.svc.cluster.local:9882/api/v1/metrics`. Override HCMP destination with `--hcmp-metrics-host`, `--hcmp-metrics-port`, and `--hcmp-metrics-uri` if needed.

Preview rendered YAML without applying:

```bash
./install.sh --dry-run \
  --image-repo ... \
  --k8s-cluster-name ... \
  # ... (all required flags)
```

Show inline help:

```bash
./install.sh --help
```

## Install steps

`install.sh` applies resources in this order:

| Step | File(s) | Resources created |
|------|---------|-------------------|
| 0 | *(script)* | Ensures namespace `apm` exists |
| 1 | `step1-coroot-cluster-agent-rbac.yaml` | ServiceAccount, ClusterRole, ClusterRoleBinding (optional docker-registry Secret only if pull-secret flags are set) |
| 2 | `step2-coroot-cluster-agent.yaml` | `coroot-cluster-agent` Deployment |
| 3 | `step3-coroot-node-agent-ds.yaml` | `coroot-node-agent` DaemonSet |
| 4 | `step5-fluent-bit-*.yaml` *(optional)* | Fluent Bit ConfigMap, Deployment, ClusterIP Service |
| 5 | `step4-prometheus-*.yaml` | Prometheus ConfigMap, Deployment, NodePort Service |

## CLI options

### Required

| Option | Description | Example |
|--------|-------------|---------|
| `--image-repo` | Container registry prefix (no trailing slash) | `registry.example.com/apm` |
| `--k8s-cluster-name` | Cluster identifier; used as `INSTANCE_TYPE` on node agent and `external_labels.cluster` in Prometheus | `prod-k8s-east` |
| `--container-allowlist` | Regex for containers the node agent should instrument | `'/k8s/(deeptrace\|coroot)/.*'` |
| `--technology-category-id` | Value for `technologyCategoryId` label on forwarded metrics | `12345` |
| `--cloudxp-customer-id` | Value for `CloudXP_CustomerID` label on forwarded metrics | `CUST-001` |
| `--fluentbit-endpoint` | Fluent Bit Prometheus remote-write URL (auto-set when `--install-fluentbit`) | `http://fluent-bit.apm.svc.cluster.local:9882/api/v1/metrics` |
| `--jwt-token` | JWT Bearer token for Fluent Bit HCMP remote_write authentication | — |

### Optional

| Option | Description |
|--------|-------------|
| `--application-id` | Application ID label on forwarded metrics |
| `--application-name` | Application name label on forwarded metrics |
| `--install-fluentbit` | Deploy Fluent Bit in `apm`; receives Prometheus remote_write on `:9882` and forwards to HCMP (`sitazure.hcmp.jio.com/metrics` by default) with `tls.verify: off` |
| `--hcmp-metrics-host` | HCMP metrics hostname for Fluent Bit output (default: `sitazure.hcmp.jio.com`) |
| `--hcmp-metrics-port` | HCMP metrics port for Fluent Bit output (default: `443`) |
| `--hcmp-metrics-uri` | HCMP metrics path for Fluent Bit output (default: `/metrics`) |
| `--pull-secret-name` | Existing docker-registry Secret name for `imagePullSecrets` (omit to use cluster default pull creds) |
| `--nexus-username` | Nexus username (only if creating/updating the pull Secret) |
| `--nexus-password` | Nexus password (only if creating/updating the pull Secret) |
| `--dry-run` | Print rendered YAML to stdout; do not call `kubectl apply` |
| `--kubeconfig PATH` | Path to kubeconfig file (overrides `KUBECONFIG` env var) |
| `--context CONTEXT` | kubectl context to use |
| `--help` | Show usage and exit |

## Template placeholders

`install.sh` replaces these tokens in every YAML file before applying:

| Placeholder | Source |
|-------------|--------|
| `__IMAGE_REPO__` | `--image-repo` |
| `__K8S_CLUSTER_NAME__` | `--k8s-cluster-name` |
| `__CONTAINER_ALLOWLIST__` | `--container-allowlist` |
| `__technologyCategoryId__` | `--technology-category-id` |
| `__CloudXP_CustomerID__` | `--cloudxp-customer-id` |
| `__FLUENTBIT_ENDPOINT__` | `--fluentbit-endpoint` (or in-cluster default with `--install-fluentbit`) |
| `__JWT_TOKEN__` | `--jwt-token` |
| `__APPLICATION_ID__` | `--application-id` |
| `__APPLICATION_NAME__` | `--application-name` |
| `__HCMP_METRICS_HOST__` | `--hcmp-metrics-host` |
| `__HCMP_METRICS_PORT__` | `--hcmp-metrics-port` |
| `__HCMP_METRICS_URI__` | `--hcmp-metrics-uri` |
| `__PULL_SECRET_NAME__` | `--pull-secret-name` (optional) |
| `__NEXUS_USERNAME__` | `--nexus-username` (optional) |
| `__NEXUS_PASSWORD__` | `--nexus-password` (optional) |
| `__NEXUS_AUTH__` | Base64 of `username:password` (computed by script when credentials are provided) |

## Deployed images

| Component | Image tag (in templates) |
|-----------|--------------------------|
| coroot-cluster-agent | `__IMAGE_REPO__/coroot-cluster-agent-main:Release-1.30.1.5` |
| coroot-node-agent | `__IMAGE_REPO__/coroot-node-agent-main:Release-1.33.1.1` |
| prometheus | `__IMAGE_REPO__/prometheus:latest` |
| fluent-bit | `__IMAGE_REPO__/fluent-bit:latest` |

## Post-install verification

```bash
# All pods in apm namespace
kubectl get pods -n apm

# DaemonSet rolled out on all nodes
kubectl get ds coroot-node-agent -n apm

# Prometheus service (NodePort)
kubectl get svc prometheus -n apm

# Cluster agent logs
kubectl logs -n apm -l app=coroot-cluster-agent --tail=50

# Node agent logs (pick a node)
kubectl logs -n apm -l app=coroot-node-agent --tail=50
```

Expected workloads:

```
NAME                                    READY   STATUS
coroot-cluster-agent-xxxxxxxxxx-xxxxx   1/1     Running
coroot-node-agent-xxxxxxxxxx            1/1     Running   (one per node)
fluent-bit-xxxxxxxxxx-xxxxx               1/1     Running   (when --install-fluentbit)
prometheus-xxxxxxxxxx-xxxxx               1/1     Running
```

## Prometheus metric forwarding

Prometheus `remote_write` to Fluent Bit keeps only metrics matching this regex:

```
kube_endpoint_address|kube_service_info|kube_pod_info|kube_pod_container_info|container.*|node.*|up|ip_to_fqdn
```

Additional labels applied before forwarding:

- `technologyCategoryId` — from `--technology-category-id`
- `CloudXP_CustomerID` — from `--cloudxp-customer-id`
- `cluster_name` — copied from `instance_type` label when present

## Node agent configuration

Key environment variables set on the DaemonSet:

| Variable | Value | Purpose |
|----------|-------|---------|
| `CONTAINER_ALLOWLIST` | `--container-allowlist` | Limit which containers are instrumented |
| `INSTANCE_TYPE` | `--k8s-cluster-name` | Cluster identifier on emitted metrics |
| `METRICS_ENDPOINT` | Prometheus remote-write URL | Where node metrics are sent |
| `EBPF_PROFILING` | `false` | eBPF profiling disabled |
| `METRICS_TTL` | `2d` | Metric retention in agent WAL |
| `LISTEN` | `0.0.0.0:8080` | Agent HTTP listen address |

The node agent runs **privileged** with `hostPID: true` and mounts host cgroup, tracefs, and debugfs paths.

## Examples

### Install with explicit kubeconfig and context

```bash
./install.sh \
  --kubeconfig ~/.kube/prod-config \
  --context prod-cluster \
  --image-repo devopsartifact.jio.com/.../apm \
  --k8s-cluster-name prod-east-01 \
  --container-allowlist '/k8s/deeptrace/.*' \
  --technology-category-id '99001' \
  --cloudxp-customer-id 'CLOUDXP-42' \
  --application-id '12345' \
  --application-name 'my-app' \
  --fluentbit-endpoint 'http://fluent-bit.apm.svc.cluster.local:9882/api/v1/metrics' \
  --jwt-token "$JWT_TOKEN"
```

### Dry-run a single step's output

Dry-run prints all four steps concatenated. To inspect one file in isolation, substitute placeholders manually or pipe through `grep`:

```bash
./install.sh --dry-run ... 2>/dev/null | less
```

## Uninstall

There is no bundled uninstall script. To remove the stack:

```bash
kubectl delete namespace apm
# Or delete individual resources:
kubectl delete clusterrole,clusterrolebinding coroot-cluster-agent
```

Deleting the namespace also removes the cluster-scoped binding subject reference; the ClusterRole and ClusterRoleBinding themselves must be deleted separately if you want a full cleanup.

## Troubleshooting

| Symptom | Check |
|---------|-------|
| `Missing required option(s)` | Pass all required flags; run `./install.sh --help` |
| Image pull errors (`ImagePullBackOff`) | Verify `--image-repo` and cluster default pull credentials (or optionally pass `--pull-secret-name` if using a pre-created Secret) |
| Node agent not collecting metrics | Confirm workload container names match `--container-allowlist` regex |
| No metrics in Fluent Bit | Check Prometheus logs; verify `--fluentbit-endpoint` is reachable from the Prometheus pod (or pass `--install-fluentbit`) |
| Fluent Bit TLS errors to HCMP | SIT uses an internal CA; the bundled config sets `tls.verify: false`. For production, mount the CA cert instead |
| Node agent pods pending | Ensure nodes allow privileged pods; check tolerations if using tainted nodes |
| Cluster agent not starting | Check RBAC: ServiceAccount `coroot-cluster-agent` must be bound to ClusterRole |
| Agents cannot reach Prometheus | Agent templates reference `prometheus.coroot.svc.cluster.local`; Prometheus is deployed in `apm` as `prometheus.apm.svc.cluster.local`. Align the `METRICS_ENDPOINT` / `--metrics-endpoint` values in `step2` and `step3` if remote write fails with DNS errors |

Useful debug commands:

```bash
# Events in apm namespace
kubectl get events -n apm --sort-by='.lastTimestamp'

# Describe failing pod
kubectl describe pod -n apm -l app=coroot-node-agent

# Test Prometheus remote-write receiver from inside cluster
kubectl run -n apm curl-test --rm -it --image=curlimages/curl -- \
  curl -s -o /dev/null -w '%{http_code}' \
  http://prometheus.apm.svc.cluster.local:9090/-/healthy

# Port-forward Prometheus UI locally
kubectl port-forward -n apm svc/prometheus 9090:9090
```

## Security notes

- Nexus credentials are stored in a Kubernetes Secret (`kubernetes.io/dockerconfigjson`) in the `apm` namespace.
- Cluster agent and node agent containers run with `privileged: true` — required for eBPF/cgroup access but increases the security footprint.
- ClusterRole grants read-only (`get`, `list`, `watch`) access to core workloads and storage resources cluster-wide.
