# Scripts 설명 가이드

> 모든 스크립트는 `scripts/` 폴더에 위치. `Kind/scripts/` 디렉토리에서 실행.
> 출력 CSV는 `logs/`, 문서는 `docs/`에 저장됨.

---

## KCI 논문 전체 실행 순서 (처음부터 다시 할 때)

```powershell
cd scripts

# ── 환경 구축 (1회) ──────────────────────────────────────
.\01-setup-kind.ps1          # Kind 클러스터 생성
.\02-install-istio.ps1       # Istio 설치
.\03-deploy-services.ps1     # 4개 서비스 배포
.\04-verify-comms.ps1        # 통신 확인 (depth=4 확인)

# ── Week 2~3: 시나리오 측정 (1회) ───────────────────────
.\05-activation-experiment.ps1
.\06-deactivation-experiment.ps1
.\07-e2e-matrix.ps1
.\08-lateral-movement.ps1
.\09-lateral-movement-during-transition.ps1

# ── Week 4~5: HSTP + 마이크로세그멘테이션 (1회) ─────────
.\10-deploy-hstp.ps1
.\11-hstp-safe-deactivation.ps1
.\12-verify-hstp.ps1
.\13-deploy-microsegmentation.ps1   # 실행 후 60초 자동 대기
.\14-verify-microsegmentation.ps1

# ── Week 6 단독 실험 (1회, 결과 확인용) ─────────────────
.\15-compare-scenarios.ps1
.\17-security-hole-matrix.ps1
.\18-readiness-probe-vs-hstp.ps1

# ── KCI 반복 실험 (5회 통계) ────────────────────────────
.\19-repeat-experiments.ps1         # 약 50~75분 소요

# ── 논문 보고서 생성 ─────────────────────────────────────
.\16-generate-report.ps1
```

> **주의**: 01~14는 환경 구축이므로 1회만 실행. 통계 목적의 반복은 19번이 전담.
> 04번에서 `depth=4` 확인 안 되면 02~03을 다시 실행할 것.

---

## 환경 구축 (1회만 실행)

### `01-setup-kind.ps1`
- **역할**: Kind 클러스터 생성
- **내용**: control-plane 1개 + worker 2개 구성. Docker 위에서 Kubernetes 로컬 클러스터 실행
- **실행 후**: `kubectl get nodes`로 3개 노드 확인 가능

### `02-install-istio.ps1`
- **역할**: Istio 설치
- **내용**: istioctl 다운로드 → `default` 프로파일로 Istio 설치 → `ota-pipeline` 네임스페이스에 sidecar injection 활성화
- **실행 후**: 모든 Pod에 Envoy 사이드카(istio-proxy) 자동 주입됨

### `03-deploy-services.ps1`
- **역할**: 4개 더미 서비스 배포
- **내용**: namespace → configmap → auth/campaign/package/deploy Deployment + Service 순서로 배포
- **실행 후**: `auth → campaign → package → deploy` 체인 구성 완료

### `04-verify-comms.ps1`
- **역할**: 서비스 간 통신 확인
- **내용**: load-gen Pod 생성 후 `http://auth:8080/call` 호출 → 체인 depth=4 확인
- **실행 후**: 모든 서비스가 정상 연결되었는지 검증

---

## Week 2~3 — 시나리오 측정

### `05-activation-experiment.ps1`
- **역할**: 활성화 순서 실험
- **내용**: A1(auth→campaign→package→deploy), A2(deploy→package→campaign→auth), A3(campaign→package→auth→deploy) 3가지 순서로 scale-up 하면서 Attack Window 측정
- **출력**: `logs/activation-*.csv`

### `06-deactivation-experiment.ps1`
- **역할**: 비활성화 순서 실험
- **내용**: D1(deploy→package→campaign→auth), D2(auth→campaign→package→deploy), D3(campaign→package→auth→deploy) 3가지 순서로 scale-down 하면서 Security Hole Duration 측정
- **출력**: `logs/deactivation-*.csv`

### `07-e2e-matrix.ps1`
- **역할**: 9가지 E2E 조합 가용성 측정
- **내용**: A1/A2/A3 × D1/D2/D3 = 9가지 조합을 순서대로 실행하여 활성화 성공률, 비활성화 성공률, 보안 홀 측정
- **출력**: `logs/e2e-matrix-*.csv`

### `08-lateral-movement.ps1`
- **역할**: No-policy 상태에서 lateral movement 기준선 측정
- **내용**: NetworkPolicy/AuthorizationPolicy 없는 상태에서 attacker Pod가 campaign/package/deploy에 직접 접근 시도. 동일 네임스페이스 + 크로스 네임스페이스 접근 모두 측정
- **출력**: `logs/lateral-movement-baseline-*.csv`

### `09-lateral-movement-during-transition.ps1`
- **역할**: D2 전환 중 lateral movement 측정
- **내용**: D2(auth-first) 비활성화 진행 중 공격자가 노출된 서비스에 접근 시도. 보안 홀 구간 동안 실제로 얼마나 접근 성공하는지 측정
- **출력**: `logs/lateral-movement-transition-*.csv`

---

## Week 4~5 — HSTP + 마이크로세그멘테이션

### `10-deploy-hstp.ps1`
- **역할**: HSTP 배포
- **내용**: OTAWave CRD(`otawave-crd.yaml`) + RBAC(`otawave-rbac.yaml`) + Controller(`otawave-controller.yaml`) 순서로 클러스터에 배포
- **실행 후**: `kubectl get otawaves -n ota-pipeline`으로 CRD 확인 가능

### `11-hstp-safe-deactivation.ps1`
- **역할**: HSTP 안전 비활성화 테스트
- **내용**: OTAWave CR 생성 → 컨트롤러가 drain(8s) → scale down → DENY policy 순서로 실행하는지 검증. 보안 홀 0초 확인
- **출력**: `logs/hstp-deactivation-*.csv`

### `12-verify-hstp.ps1`
- **역할**: HSTP 적용 전후 비교
- **내용**: HSTP 없는 D2 비활성화 vs HSTP 있는 D1 비활성화를 비교하여 lateral movement 차단 효과 측정

### `13-deploy-microsegmentation.ps1`
- **역할**: 마이크로세그멘테이션 배포 (자동으로 14 호출)
- **내용**: ServiceAccount 생성 → SA 할당 + rollout → STRICT mTLS 적용 → NetworkPolicy 적용 → AuthorizationPolicy 적용 → 60s 동기화 대기 → 체인 확인 → `14-verify` 자동 실행
- **주의**: 실행 후 60초 대기 필요 (Envoy cert 재발급)

### `14-verify-microsegmentation.ps1`
- **역할**: 마이크로세그멘테이션 검증
- **내용**: 3가지 시나리오 검증
  - 파이프라인 체인 정상 동작 (depth=4)
  - Same-NS attacker가 campaign/package/deploy 직접 접근 차단 확인 (403)
  - Cross-NS attacker가 ota-pipeline 서비스 접근 차단 확인 (HTTP 000)
- **출력**: `logs/microseg-verify-*.csv`

---

## Week 6~7 — 비교 및 추가 실험

### `15-compare-scenarios.ps1`
- **역할**: 3-시나리오 비교 (핵심 실험)
- **내용**: D2 worst-case 기준으로 No-Policy / HSTP only / HSTP+Microseg 3가지 비교. Attack Window, Transition Risk Window, lateral block rate, request success rate 측정
- **출력**: `logs/week6-comparison-*.csv`
- **결과 요약**:
  - No-Policy: 보안 홀 50.9s, lateral 차단 25%, 요청 성공 0%
  - HSTP only: 보안 홀 0s, lateral 차단 85.7%, 요청 성공 85.7%
  - HSTP+Microseg: 보안 홀 0s, lateral 차단 100%, 요청 성공 85.7%

### `16-generate-report.ps1`
- **역할**: 논문용 보고서 자동 생성
- **내용**: 모든 최신 CSV를 읽어 `docs/paper-results.md`(Markdown)와 `docs/paper-tables.tex`(LaTeX) 생성
- **출력**: `docs/paper-results.md`, `docs/paper-tables.tex`

### `17-security-hole-matrix.ps1`
- **역할**: D1/D2/D3 보안 홀 지속 시간 측정
- **내용**: 각 비활성화 순서별로 attacker Pod가 노출된 서비스에 접근할 수 있는 시간 측정. auth 제거 시점부터 모든 downstream 제거까지의 구간을 보안 홀로 정의
- **출력**: `logs/security-hole-matrix-*.csv`
- **결과**: D1=0s, D2=50.9s, D3=17.1s

### `18-readiness-probe-vs-hstp.ps1`
- **역할**: Readiness Probe 한계 실증 (기여 2 핵심 실험)
- **내용**: DENY policy를 `kubectl apply` 후 즉시 트래픽 측정 → readiness probe는 OK이지만 실제 차단까지 54.6s 걸림을 측정. ALLOW 복구 지연(~6s)도 측정
- **출력**: `logs/readiness-vs-hstp-*.csv`
- **결과**: DENY propagation gap = 54.6s, ALLOW propagation gap = ~6s

### `19-repeat-experiments.ps1`
- **역할**: KCI 논문용 반복 실험 통계 산출
- **내용**: 스크립트 17 → 18 → 15 순서로 N회 반복 실행. 각 run 사이 15초 안정화 대기. 완료 후 mean ± std 자동 계산
- **파라미터**: `-Runs N` (기본값 5)
- **출력**: `logs/kci-raw-*.csv` (run별 원시값), `logs/kci-stats-*.csv` (mean/std/min/max, 논문 직접 사용)
- **소요 시간**: 약 50~75분 (5회 기준)

---

## 주요 kubectl 명령어 모음

```powershell
# 클러스터 상태 확인
kubectl get nodes
kubectl get pods -n ota-pipeline
kubectl get svc -n ota-pipeline

# Istio 사이드카 확인 (READY 2/2 이어야 함)
kubectl get pods -n ota-pipeline

# 정책 확인
kubectl get authorizationpolicy -n ota-pipeline
kubectl get networkpolicy -n ota-pipeline
kubectl get peerauthentication -n ota-pipeline

# OTAWave CR 확인
kubectl get otawaves -n ota-pipeline

# 로그 확인 (Envoy 사이드카)
kubectl logs -n ota-pipeline -l app=campaign -c istio-proxy --tail=20

# 체인 테스트 (수동)
kubectl exec -n ota-pipeline <load-gen-pod> -- curl -s http://auth:8080/call

# 서비스 scale 조작
kubectl scale deployment auth -n ota-pipeline --replicas=0
kubectl scale deployment auth -n ota-pipeline --replicas=1
```

---

## 로그 파일 구조

| 패턴 | 생성 스크립트 | 내용 |
|---|---|---|
| `logs/activation-*.csv` | 05 | 활성화 순서별 성공률 |
| `logs/deactivation-*.csv` | 06 | 비활성화 순서별 보안 홀 |
| `logs/e2e-matrix-*.csv` | 07 | 9가지 E2E 조합 |
| `logs/lateral-movement-baseline-*.csv` | 08 | No-policy lateral movement |
| `logs/lateral-movement-transition-*.csv` | 09 | D2 전환 중 lateral movement |
| `logs/hstp-deactivation-*.csv` | 11 | HSTP 안전 비활성화 |
| `logs/microseg-verify-*.csv` | 14 | 마이크로세그멘테이션 검증 |
| `logs/week6-comparison-*.csv` | 15 | 3-시나리오 비교 |
| `logs/security-hole-matrix-*.csv` | 17 | D1/D2/D3 보안 홀 |
| `logs/readiness-vs-hstp-*.csv` | 18 | Policy propagation gap |
