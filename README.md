# SDV OTA Wave Switching — Research Environment

Race conditions in SDV OTA backend wave switching and the
**Hierarchical Safe Transition Protocol (HSTP)** on Kubernetes + Istio.

> **Status: Complete (Week 1–7)** — KCI paper submission ready.
> N=5 repeat experiments, mean±std statistics, 3-scenario comparison (no policy / external gate / HSTP + microsegmentation).

---

## Project Structure

```
sdv-ota-wave-research/
├── README.md
├── .gitignore
│
├── docs/
│   ├── eom-kyeongmun-paper.pdf   ← submitted paper
│   └── 참고자료.md                 ← references (선행연구 / 표준 / 사고사례)
│
├── k8s/                           ← Kubernetes & Istio manifests
│   ├── namespace.yaml
│   ├── configmap.yaml             ← shared Python app (stdlib only)
│   ├── auth.yaml | campaign.yaml | package.yaml | deploy.yaml
│   ├── serviceaccounts.yaml
│   ├── peer-auth.yaml             ← PERMISSIVE (baseline)
│   ├── peer-auth-strict.yaml      ← STRICT mTLS
│   ├── authpolicy-chain.yaml      ← Istio AuthorizationPolicy (chain)
│   ├── networkpolicy-chain.yaml   ← K8s NetworkPolicy (chain)
│   ├── otawave-crd.yaml           ← HSTP CRD (OTAWave)
│   ├── otawave-rbac.yaml          ← Controller RBAC
│   └── otawave-controller.yaml    ← HSTP controller
│
└── scripts/                       ← run-in-order PowerShell scripts (Week 1-7)
    ├── 01-setup-kind.ps1
    ├── 02-install-istio.ps1
    ├── 03-deploy-services.ps1
    ├── 04-verify-comms.ps1
    │
    ├── 05-activation-experiment.ps1        ← Week 2: A1/A2/A3 활성화 순서
    ├── 06-deactivation-experiment.ps1      ← Week 2: D1/D2/D3 비활성화 순서
    ├── 07-e2e-matrix.ps1                   ← Week 2: 3×3 = 9 조합
    ├── 08-lateral-movement.ps1             ← Week 3: 정상 상태 lateral movement
    ├── 09-lateral-movement-during-transition.ps1  ← Week 3: 전환 중 측정
    │
    ├── 10-deploy-hstp.ps1                  ← Week 4: HSTP CRD + controller 배포
    ├── 11-hstp-safe-deactivation.ps1       ← Week 4: 안전한 비활성화
    ├── 12-verify-hstp.ps1                  ← Week 4: HSTP 검증
    │
    ├── 13-deploy-microsegmentation.ps1     ← Week 5: NetworkPolicy + AuthPolicy
    ├── 14-verify-microsegmentation.ps1     ← Week 5: 정책 검증
    │
    ├── 15-compare-scenarios.ps1            ← Week 6: 3-시나리오 비교
    ├── 16-generate-report.ps1              ← Week 6: 표/CSV/TeX 생성
    ├── 17-security-hole-matrix.ps1         ← Week 2/3 보완: 9-조합 보안 홀
    ├── 18-readiness-probe-vs-hstp.ps1      ← Week 6 보완: 정책 전파 지연
    └── 19-repeat-experiments.ps1           ← KCI: N=5 반복 + mean±std
```

---

## Prerequisites

| Tool           | Install (Windows)                                    | Version tested |
|----------------|------------------------------------------------------|----------------|
| Docker Desktop | https://www.docker.com/products/docker-desktop       | ≥ 25.x         |
| kind           | `winget install Kubernetes.kind`                     | ≥ 0.22         |
| kubectl        | `winget install Kubernetes.kubectl`                  | ≥ 1.29         |
| PowerShell     | built into Windows 11 (or `pwsh` on Linux/macOS)     | ≥ 5.1 / 7.x    |

> All scripts are PowerShell (`.ps1`). Run from **PowerShell** (not bash).
> `istioctl` is downloaded by `02-install-istio.ps1` (not tracked in the repo).

---

## Quick Start — Full Pipeline

Run from the `scripts/` directory. Each script is idempotent.

```powershell
cd scripts

# ── Week 1: environment ───────────────────────────
.\01-setup-kind.ps1            # kind cluster
.\02-install-istio.ps1         # istioctl + Istio (default profile)
.\03-deploy-services.ps1       # auth → campaign → package → deploy
.\04-verify-comms.ps1          # baseline verification

# ── Week 2: activation / deactivation race ────────
.\05-activation-experiment.ps1   -Order A1   # also A2, A3
.\06-deactivation-experiment.ps1 -Order D1   # also D2, D3
.\07-e2e-matrix.ps1                          # 3×3 = 9 combos

# ── Week 3: lateral movement ──────────────────────
.\08-lateral-movement.ps1
.\09-lateral-movement-during-transition.ps1

# ── Week 4: HSTP (Hierarchical Safe Transition) ───
.\10-deploy-hstp.ps1
.\11-hstp-safe-deactivation.ps1
.\12-verify-hstp.ps1

# ── Week 5: microsegmentation ─────────────────────
.\13-deploy-microsegmentation.ps1
.\14-verify-microsegmentation.ps1

# ── Week 6: comparison + report ───────────────────
.\15-compare-scenarios.ps1
.\16-generate-report.ps1
.\17-security-hole-matrix.ps1
.\18-readiness-probe-vs-hstp.ps1

# ── KCI: repeat experiments (N=5, mean±std) ───────
.\19-repeat-experiments.ps1 -Runs 5
```

Outputs land in `../logs/` (CSV + per-run logs). `19-repeat-experiments.ps1`
produces `kci-stats-*.csv` (aggregated) and `kci-raw-*.csv` (per-run).

---

## Service Architecture

```
 [external request]
        |
        v
   ┌─────────┐    HTTP    ┌──────────┐    HTTP    ┌─────────┐    HTTP    ┌────────┐
   │  auth   │ ─────────▶│ campaign │ ─────────▶│ package │ ─────────▶│ deploy │
   │  :8080  │           │  :8080   │           │  :8080  │           │  :8080 │
   └─────────┘           └──────────┘           └─────────┘           └────────┘
        │                      │                      │                     │
   [Envoy proxy]          [Envoy proxy]          [Envoy proxy]        [Envoy proxy]
        └──────────────────────┴──────────────────────┴─────────────────────┘
                                        │
                                   istio-system
                                    (istiod)
```

Each service exposes:
- `GET /health` — liveness/readiness probe
- `GET /info`   — service name + next-service env
- `GET /call`   — calls the next service, returns nested JSON

4-service abstraction maps 1:1 to **OTA Community Edition** CLI
(`ota init` / `campaign create` / `package add` / `campaign launch`),
justified by the Uptane standard. See `docs/참고자료.md`.

---

## Hierarchical Safe Transition Protocol (HSTP)

Defined via a Kubernetes Custom Resource (`OTAWave`) and reconciled by a
lightweight controller. Coordinates **policy propagation** and **pod
lifecycle** so that the transition gap — where traffic is allowed but
policy still blocks (or vice versa) — is eliminated.

- CRD:           `k8s/otawave-crd.yaml`
- RBAC:          `k8s/otawave-rbac.yaml`
- Controller:    `k8s/otawave-controller.yaml`
- Safe order:    downstream-first deactivation (D1)
- Verification:  `scripts/12-verify-hstp.ps1`

---

## Useful kubectl Commands

```powershell
# Watch pods
kubectl get pods -n ota-pipeline -w

# App logs / Envoy sidecar logs
kubectl logs -n ota-pipeline -l app=auth -c auth -f
kubectl logs -n ota-pipeline -l app=auth -c istio-proxy --tail=20

# Manual chain call
kubectl exec -n ota-pipeline -it deploy/auth -- `
  python3 -c "import urllib.request; print(urllib.request.urlopen('http://auth:8080/call').read())"

# Inspect OTAWave CRs
kubectl get otawaves -A
kubectl describe otawave <name> -n ota-pipeline

# Tear down
kind delete cluster --name ota-research
```

---

## Weekly Plan / Status

| Week | Goal                                                                | Status |
|------|---------------------------------------------------------------------|--------|
| 1    | Kind + Istio + 4 services, baseline communication                   | Done   |
| 2    | 3 activation × 3 deactivation = 9 combos, security hole measurement | Done   |
| 3    | Lateral movement (steady-state & during transition)                 | Done   |
| 4    | Hierarchical Safe Transition Protocol + `OTAWave` CRD               | Done   |
| 5    | Least-privilege `NetworkPolicy` + `AuthorizationPolicy`             | Done   |
| 6    | 3-scenario metrics (no policy / external gate / HSTP+micro)         | Done   |
| 7    | Paper writing (`docs/eom-kyeongmun-paper.pdf`)                      | Done   |
| KCI  | N=5 repeat experiments, mean±std statistics                          | Done   |

---

## Metrics Measured

- **Security Hole Duration** — window where traffic is allowed but policy blocks (or vice versa)
- **Attack Window** — exploitable transition gap
- **Transition Risk Window** — total unsafe duration per wave switch
- **Request Success / Failure Rate** — during transitions
- **Policy Propagation Delay** — istiod → Envoy sync latency
- **Lateral Movement Blocking Rate** — % of unauthorized cross-service calls blocked

All metrics are reported as **mean ± std (N = 5)** in the paper.

---

## Paper & References

- Paper PDF: [`docs/eom-kyeongmun-paper.pdf`](docs/eom-kyeongmun-paper.pdf)
- References (선행연구, Uptane, K8s/Istio, Zero Trust, OTA 사고 사례):
  [`docs/참고자료.md`](docs/참고자료.md)
