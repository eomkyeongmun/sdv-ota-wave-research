# Week 2 Results

실험일: 2026-04-23
실험 환경: Kind (1 control + 2 workers) + Istio 1.21.2 PERMISSIVE mTLS

---

## 요약 테이블

### Activation (서비스 켜는 순서)

| 순서 | 설명 | Success Rate | Attack Window |
|------|------|:------------:|:-------------:|
| **A1** | auth → campaign → package → deploy | **80%** | **0s** |
| **A2** | deploy → package → campaign → auth | **28.6%** | **~50s** |
| **A3** | campaign → deploy → auth → package | **45.7%** | **~17s** |

### Deactivation (서비스 끄는 순서)

| 순서 | 설명 | Success Rate | Security Hole |
|------|------|:------------:|:-------------:|
| **D1** | deploy → package → campaign → auth | **66.7%** | **0s** |
| **D2** | auth → campaign → package → deploy | **16.7%** | **~51s** |
| **D3** | package → auth → deploy → campaign | **33.3%** | **~17s** |

### E2E Matrix (9가지 조합)

| | D1 (drain 정상) | D2 (upstream first) | D3 (임의) |
|---|:---:|:---:|:---:|
| **A1** | Act 80% / Deact 66.7% | Act 80% / Deact 16.7% | Act 80% / Deact 33.3% |
| **A2** | Act 28.6% / Deact 66.7% | Act 28.6% / Deact 16.7% | Act 28.6% / Deact 33.3% |
| **A3** | Act 45.7% / Deact 66.7% | Act 45.7% / Deact 16.7% | Act 45.7% / Deact 31.4% |

---

## 핵심 발견

### 1. Activation Attack Window

**A2 (deploy 먼저)** 에서 `deploy` 서비스가 `auth` 없이 **약 50초** 동안 노출됨.

- deploy가 올라오는 순간부터 auth가 올라오기까지 클러스터 내부에서 직접 접근 가능
- Istio PERMISSIVE 모드 + NetworkPolicy 없음 → 어떤 pod에서든 `deploy:8080` 호출 가능
- A1은 auth 먼저 올라오므로 attack window = 0

```
A1: [auth] → [campaign] → [package] → [deploy]   window = 0s
A2: [deploy] → [package] → [campaign] → [auth]   window = ~50s  ← 위험
A3: [campaign] → [deploy] → [auth] → [package]   window = ~17s
```

### 2. Deactivation Security Hole

**D2 (auth 먼저)** 에서 `auth`가 제거된 후 `deploy`가 **약 51초** 동안 잔존.

- auth가 내려간 순간부터 내부 서비스들은 정책 없이 접근 가능한 상태
- D1은 downstream부터 제거하므로 security hole = 0

```
D1: [deploy] → [package] → [campaign] → [auth]   hole = 0s      ← 안전
D2: [auth] → [campaign] → [package] → [deploy]   hole = ~51s    ← 위험
D3: [package] → [auth] → [deploy] → [campaign]   hole = ~17s
```

### 3. 최악 vs 최선

| 시나리오 | Attack Window | Security Hole | 총 노출 시간 |
|----------|:-------------:|:-------------:|:------------:|
| **A2-D2** (최악) | ~50s | ~51s | **~101s** |
| **A1-D1** (최선) | 0s | 0s | **0s** |
| **A2-D1** | ~50s | 0s | ~50s |
| **A1-D2** | 0s | ~51s | ~51s |

---

## 논문용 수치

```
Metric                          A1      A2      A3
-----------------------------------------------------
Activation Success Rate (%)     80.0    28.6    45.7
Attack Window (sec)              0      50.0    17.2

Metric                          D1      D2      D3
-----------------------------------------------------
Deactivation Success Rate (%)   66.7    16.7    32.7
Security Hole Duration (sec)     0      51.2    17.4
```

---

## Week 3에서 할 일

D2 실행 중 Security Hole 구간(auth 제거 ~ deploy 제거, ~51초)에서:
- 공격자가 임의 pod 안에서 `deploy:8080`에 **직접 접근** 가능한지 재현
- NetworkPolicy / AuthorizationPolicy 없는 상태에서 lateral movement 증명
- 접근 성공/실패 및 소요 시간 측정
