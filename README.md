# SDV OTA Wave Switching — Research Environment

Race conditions in SDV OTA backend wave switching and
Hierarchical Safe Transition Protocol on Kubernetes + Istio.

> **Current phase: Week 1** — Environment setup and baseline communication.

---

## Project Structure

```
Kind/
├── README.md                    ← this file
├── CLAUDE.md                    ← project instructions for Claude Code
├── paper_context.md             ← research background and motivation
│
├── k8s/                         ← Kubernetes manifests
│   ├── namespace.yaml           ← ota-pipeline namespace (istio-injection: enabled)
│   ├── configmap.yaml           ← shared Python app (stdlib only, no pip)
│   ├── auth.yaml                ← auth Deployment + Service
│   ├── campaign.yaml            ← campaign Deployment + Service
│   ├── package.yaml             ← package Deployment + Service
│   ├── deploy.yaml              ← deploy Deployment + Service
│   └── peer-auth.yaml           ← Istio PeerAuthentication (PERMISSIVE, Week 1)
│
├── scripts/                     ← numbered run-in-order scripts
│   ├── 01-setup-kind.sh         ← create kind cluster
│   ├── 02-install-istio.sh      ← download istioctl + install Istio
│   ├── 03-deploy-services.sh    ← deploy 4 dummy services
│   └── 04-verify-comms.sh       ← verify service-to-service communication
│
└── docs/
    └── reference-summary-template.md  ← template for paper references
```

---

## Prerequisites

| Tool      | Install (Windows)                         | Version tested |
|-----------|-------------------------------------------|----------------|
| Docker Desktop | https://www.docker.com/products/docker-desktop | ≥ 25.x |
| kind      | `winget install Kubernetes.kind`          | ≥ 0.22         |
| kubectl   | `winget install Kubernetes.kubectl`       | ≥ 1.29         |
| curl      | built into Windows 11                     | any            |
| bash      | Git Bash or WSL2                          | any            |

> All scripts use `bash`. Run them from Git Bash or WSL2 on Windows.

---

## Week 1 — Quick Start

Run each script in order. Each script is idempotent (safe to re-run).

```bash
# 1. Create kind cluster  (~2 min)
bash scripts/01-setup-kind.sh

# 2. Install Istio  (~3 min, downloads ~50 MB)
bash scripts/02-install-istio.sh

# 3. Deploy 4 dummy services  (~2 min for images to pull)
bash scripts/03-deploy-services.sh

# 4. Verify communication
bash scripts/04-verify-comms.sh

# Save verify output for the paper
mkdir -p logs
bash scripts/04-verify-comms.sh 2>&1 | tee logs/week1-verify.log
```

---

## Service Architecture

```
 [external request]
        |
        v
   ┌─────────┐    HTTP    ┌──────────┐    HTTP    ┌─────────┐    HTTP    ┌────────┐
   │  auth   │ ────────> │ campaign │ ────────> │ package │ ────────> │ deploy │
   │  :8080  │           │  :8080   │           │  :8080  │           │  :8080 │
   └─────────┘           └──────────┘           └─────────┘           └────────┘
        |                      |                      |                     |
   [Envoy proxy]          [Envoy proxy]          [Envoy proxy]        [Envoy proxy]
        |_________________________|________________________|_________________|
                                        |
                                   istio-system
                                    (istiod)
```

Each service exposes:
- `GET /health` — liveness/readiness probe, returns `ok`
- `GET /info`   — returns service name and next-service env var
- `GET /call`   — calls the next service in the chain, returns nested JSON

---

## Useful kubectl Commands

```bash
# Watch all pods
kubectl get pods -n ota-pipeline -w

# Check logs for a service
kubectl logs -n ota-pipeline -l app=auth -c auth -f

# Check Envoy sidecar logs
kubectl logs -n ota-pipeline -l app=auth -c istio-proxy --tail=20

# Exec into a pod and make a chain call manually
kubectl exec -n ota-pipeline -it deploy/auth -- \
  python3 -c "import urllib.request; print(urllib.request.urlopen('http://auth:8080/call').read())"

# Check Istio proxy status
kubectl exec -n ota-pipeline deploy/auth -c istio-proxy -- pilot-agent request GET /config_dump | head -50

# Delete everything and start fresh
kind delete cluster --name ota-research
```

---

## Weekly Plan

| Week | Goal | Status |
|------|------|--------|
| 1 | Environment setup, 4 services, communication baseline | **In progress** |
| 2 | 3 activation × 3 deactivation = 9 combos, measure security hole | Pending |
| 3 | Deactivation + lateral movement without policies | Pending |
| 4 | Hierarchical Safe Transition Protocol + OTAWave CRD | Pending |
| 5 | Least-privilege NetworkPolicy + AuthorizationPolicy | Pending |
| 6 | Metrics comparison (no policy / external gate / full protocol) | Pending |
| 7 | Paper writing | Pending |

---

## Metrics to Track (Week 6)

- **Security Hole Duration** — time window where traffic is allowed but policy blocks it (or vice versa)
- **Attack Window** — time an attacker can exploit the transition gap
- **Transition Risk Window** — total unsafe duration per wave switch
- **Request Success/Failure Rate** — during transitions
- **Policy Propagation Delay** — istiod → Envoy sync latency
- **Lateral Movement Blocking Rate** — % of unauthorized cross-service calls blocked
