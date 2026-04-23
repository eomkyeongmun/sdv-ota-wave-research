# 실험 실행 순서

---

## 환경 구축 (1회만)

| 순서 | 스크립트 | 내용 |
|---|---|---|
| 1 | `01-setup-kind.ps1` | Kind 클러스터 생성 (control-plane 1 + worker 2) |
| 2 | `02-install-istio.ps1` | Istio 1.21.2 설치 + sidecar injection 활성화 |
| 3 | `03-deploy-services.ps1` | auth/campaign/package/deploy 4개 서비스 배포 |
| 4 | `04-verify-comms.ps1` | 서비스 간 통신 확인 |

---

## Week 2~3 — 시나리오 측정

| 순서 | 스크립트 | 내용 |
|---|---|---|
| 5 | `05-activation-experiment.ps1` | A1/A2/A3 활성화 순서 실험 |
| 6 | `06-deactivation-experiment.ps1` | D1/D2/D3 비활성화 순서 실험 |
| 7 | `07-e2e-matrix.ps1` | 9가지 E2E 조합 가용성 측정 |
| 8 | `08-lateral-movement.ps1` | No-policy 기준 lateral movement 측정 |
| 9 | `09-lateral-movement-during-transition.ps1` | D2 전환 중 lateral movement 측정 |

---

## Week 4~5 — HSTP + 마이크로세그멘테이션

| 순서 | 스크립트 | 내용 |
|---|---|---|
| 10 | `10-deploy-hstp.ps1` | OTAWave CRD + Controller 배포 |
| 11 | `11-hstp-safe-deactivation.ps1` | HSTP 안전 비활성화 실행 |
| 12 | `12-verify-hstp.ps1` | HSTP 동작 검증 |
| 13 | `13-deploy-microsegmentation.ps1` | SA + NetworkPolicy + AuthorizationPolicy + STRICT mTLS 배포 |
| 14 | `14-verify-microsegmentation.ps1` | 마이크로세그멘테이션 검증 (13에서 자동 호출됨) |

---

## Week 6~7 — 비교 및 추가 실험

| 순서 | 스크립트 | 내용 |
|---|---|---|
| 15 | `15-compare-scenarios.ps1` | No-Policy vs HSTP vs HSTP+Microseg 3-시나리오 비교 |
| 16 | `16-generate-report.ps1` | 모든 CSV → paper-results.md + paper-tables.tex 생성 |
| 17 | `17-security-hole-matrix.ps1` | D1/D2/D3 보안 홀 지속 시간 측정 |
| 18 | `18-readiness-probe-vs-hstp.ps1` | Policy propagation gap 측정 (readiness probe 한계 실증) |

---

## 주의사항

- **13 실행 후 15 실행 시** microseg 정책이 남아있는 상태 → `15`는 no-policy 기준선을 먼저 초기화하므로 순서대로 실행하면 됨
- **17, 18은 독립 실행 가능** — 환경만 살아있으면 언제든 재실행 가능
- **클러스터 재시작 후**라면 `03` → `04` 확인 후 원하는 실험부터 실행
