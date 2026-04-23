# Week 4 Results — HSTP (Hierarchical Safe Transition Protocol)

실험일: 2026-04-23
구현: OTAWave CRD + Python Controller (3단계 condition gate)

---

## HSTP 구조

```
OTAWave CR (action: deactivate, order: [deploy, package, campaign, auth])
      |
      v
HSTP Controller (polling loop, 5s interval)
      |
      +-- for each service in order:
          Gate 1: drain    (10s - in-flight 요청 완료 대기)
          Gate 2: scale    (replicas: 0)
          Gate 3: policy   (DENY AuthorizationPolicy 적용 + 5s Envoy sync)
```

---

## 실험 결과

### 11 — HSTP Safe Deactivation

| 시간 | depth | Wave Step | HTTP |
|------|:-----:|:---------:|------|
| 1s   | 4     | step 1    | 200 — 전체 파이프라인 정상 |
| 17s  | 3     | step 1    | 200 — deploy 제거됨, 나머지 정상 |
| 33s  | 2     | step 2    | 200 — package 제거됨 |
| 48s  | 1     | step 3    | 200 — campaign 제거됨, auth만 남음 |
| 64s  | 0     | step 4    | 503 — auth 제거됨, 전체 차단 |

```
Wave status     : Completed
Success rate    : 74.1% (transition 중 요청은 계속 성공)
Post-HSTP blocked: 4 / 4 services
```

**HSTP 적용 후 attacker pod → 모든 서비스 접근 시도 결과:**

| 타겟 | HTTP | 결과 |
|------|------|------|
| deploy   | 503 | NO (blocked) |
| package  | 503 | NO (blocked) |
| campaign | 503 | NO (blocked) |
| auth     | 503 | NO (blocked) |

---

## Week 3 vs Week 4 비교

| 메트릭 | No-Policy (Week 3) | HSTP (Week 4) |
|--------|:-----------------:|:-------------:|
| 내부 lateral movement | **YES 100%** | **NO 0%** |
| cross-namespace 접근 | **YES 100%** | **NO 0%** |
| deploy access window | **60.9s** | **0s** |
| Security Hole (D2) | **51s** | **0s** |
| Transition 중 요청 성공률 | 16.7% (D2) | **74.1%** |

---

## 핵심 발견

**HSTP가 해결한 문제:**
1. drain gate → 서비스 제거 전 in-flight 요청 완료 → success rate 향상
2. safe order → deploy 먼저 제거 → auth가 마지막까지 요청 차단 유지
3. DENY policy gate → 제거된 서비스에 대한 정책 기반 차단 → lateral movement 불가

**HSTP가 적용한 안전 순서 (deactivation):**
```
deploy -> package -> campaign -> auth
(tail first, upstream last)
```
각 단계: drain(10s) → scale(0) → DENY AP → Envoy sync(5s)

---

## 논문용 수치

```
Metric                  No-Policy    HSTP
------------------------------------------
Lateral move success    100% (15/15) 0% (0/4)
deploy access window    60.9s        0s
Security hole (D2)      51s          0s
Transition success rate 16.7%        74.1%
```

---

## 다음 단계 (Week 5)

HSTP는 전환 구간을 안전하게 만들었지만, **평상시 운영 중** 접근 제어는 없음.
Week 5: least-privilege NetworkPolicy + AuthorizationPolicy 적용
- 서비스 간 최소 권한 (auth→campaign만 허용, 임의 접근 차단)
- 영구적인 microsegmentation
