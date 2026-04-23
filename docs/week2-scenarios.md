# Week 2 — Scenario Definitions

## Overview

OTA 웨이브 전환 시 서비스 활성화/비활성화 **순서**가 보안 홀 및 가용성에 미치는 영향을 측정한다.

- **Activation Order (A1~A3)**: 서비스를 어떤 순서로 켜는가
- **Deactivation Order (D1~D3)**: 서비스를 어떤 순서로 끄는가
- **End-to-End Matrix**: 9가지 (Ax × Dx) 조합

---

## Service Pipeline

```
auth (8080) → campaign (8080) → package (8080) → deploy (8080)
```

요청은 `auth /call` 엔드포인트로 진입해 체인을 따라 흐른다.
`auth`가 없으면 진입 자체가 불가, `deploy`가 없으면 체인 끝에서 실패한다.

---

## Activation Orders

| ID | 순서 | 설명 | 예상 위험 |
|----|------|------|-----------|
| **A1** | auth → campaign → package → deploy | 정상 (upstream first) | 낮음: upstream이 먼저 올라와 정책 경로가 선행 확보 |
| **A2** | deploy → package → campaign → auth | 역순 (downstream first) | **높음**: downstream이 먼저 노출, auth 없이 내부 접근 가능 |
| **A3** | campaign → deploy → auth → package | 임의 순서 | 중간: 체인 중간부터 부분 노출 |

### 측정 포인트
- **Attack Window**: deploy가 올라온 시점 ~ auth가 올라오기까지의 시간 (A2 최대)
- **Transition Risk Window**: 첫 번째 서비스 scale-up ~ 전체 pipeline 안정화까지

---

## Deactivation Orders

| ID | 순서 | 설명 | 예상 위험 |
|----|------|------|-----------|
| **D1** | deploy → package → campaign → auth | 정상 drain (downstream first) | 낮음: tail부터 제거해 upstream이 마지막까지 요청 차단 |
| **D2** | auth → campaign → package → deploy | 역순 (upstream first) | **높음**: auth 먼저 제거 시 내부에서 deploy에 직접 접근 가능 |
| **D3** | package → auth → deploy → campaign | 임의 순서 | 중간: 체인 중간 단절로 부분 노출 발생 |

### 측정 포인트
- **Security Hole Duration**: auth 제거 후 ~ deploy 제거 전 구간 (D2 최대)
- **Request Drop**: 체인이 끊기는 시점의 요청 실패율

---

## End-to-End Matrix (9가지 조합)

| | **D1** (drain 정상) | **D2** (upstream first) | **D3** (임의) |
|---|---|---|---|
| **A1** (upstream first) | A1-D1 ← 이상적 기준선 | A1-D2 | A1-D3 |
| **A2** (downstream first) | A2-D1 | A2-D2 ← 최악 시나리오 | A2-D3 |
| **A3** (임의) | A3-D1 | A3-D2 | A3-D3 |

### 각 조합에서 수집하는 메트릭

| 메트릭 | 설명 |
|--------|------|
| `activation_attack_window_sec` | Activation 중 첫 downstream 노출 ~ auth 완성 시간 |
| `deactivation_security_hole_sec` | Deactivation 중 auth 제거 ~ 마지막 서비스 제거 시간 |
| `request_success_rate_pct` | 전환 구간 전체 요청 중 HTTP 200 비율 |
| `pipeline_depth_avg` | 응답에 포함된 서비스 수 평균 (0~4) |
| `transition_risk_window_sec` | 전환 시작 ~ 완전 안정화 시간 |

---

## CSV 스키마

실험 스크립트가 출력하는 CSV 공통 포맷:

```
experiment_id, phase, order, step, step_service, elapsed_sec,
http_status, response_time_ms, pipeline_depth, services_up, error
```

- `experiment_id`: `ACT-A1-20260423-120000` 형식
- `phase`: `baseline` / `step1`~`step4` / `post`
- `services_up`: 현재 running 상태인 서비스 목록 (`auth+campaign` 등)

---

## 실험 실행 방법

```powershell
# 단일 activation 실험
.\scripts\05-activation-experiment.ps1 -Order A1

# 단일 deactivation 실험
.\scripts\06-deactivation-experiment.ps1 -Order D1

# 9가지 전체 매트릭스 (자동)
.\scripts\07-e2e-matrix.ps1
```

결과 CSV는 `logs/` 디렉터리에 저장된다.
