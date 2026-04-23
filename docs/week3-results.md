# Week 3 Results — Lateral Movement (No Policy)

실험일: 2026-04-23
조건: NetworkPolicy 없음 / AuthorizationPolicy 없음 / Istio PERMISSIVE mTLS

---

## 08 — Baseline: 정상 운영 중 lateral movement

| 공격자 위치 | 타겟 | 접근 결과 | 응답시간 |
|------------|------|:---------:|---------|
| ota-pipeline pod | auth /health /info /call | **YES** | ~300ms |
| ota-pipeline pod | campaign /health /info /call | **YES** | ~310ms |
| ota-pipeline pod | package /health /info /call | **YES** | ~320ms |
| ota-pipeline pod | deploy /health /info /call | **YES** | ~310ms |
| **default namespace** | auth /health | **YES** | ~280ms |
| **default namespace** | campaign /health | **YES** | ~305ms |
| **default namespace** | package /health | **YES** | ~317ms |
| **default namespace** | deploy /health | **YES** | ~269ms |

```
Total: 15/15 ACCESSIBLE  |  BLOCKED: 0
```

**결론**: 정책 없는 상태에서는 **같은 네임스페이스는 물론 다른 네임스페이스에서도** 모든 내부 서비스에 직접 접근 가능.

---

## 09 — D2 전환 중 실시간 lateral movement

D2 deactivation 순서: auth → campaign → package → deploy

| 단계 | 제거 서비스 | 공격자 접근 타겟 | 결과 |
|------|------------|----------------|------|
| pre | (모두 실행 중) | deploy, package, campaign | **YES** (9/9) |
| step1 | **auth 제거** | campaign, package, **deploy** | **YES** (9/9) |
| step2 | campaign 제거 | package, **deploy** | **YES** (6/6) |
| step3 | package 제거 | **deploy** | **YES** (3/3) |
| step4 | deploy 제거 | (없음) | - |

```
Total: 55/55 ACCESSIBLE  |  BLOCKED: 0
deploy access window: 60.9s
```

**결론**: auth가 제거된 후 deploy가 제거되기까지 **60.9초 동안** 공격자가 `deploy`에 직접 접근 가능.

---

## 핵심 수치 정리

| 메트릭 | 값 | 의미 |
|--------|-----|------|
| Baseline 접근 성공률 | **100% (15/15)** | 정책 없으면 모든 서비스 노출 |
| Cross-namespace 접근 | **가능** | 네임스페이스 격리 없음 |
| D2 전환 중 접근 성공률 | **100% (55/55)** | 전환 중에도 완전 노출 |
| deploy access window | **60.9s** | auth 제거 후 deploy 직접 접근 가능 시간 |

---

## Week 2 vs Week 3 비교

| 측정 방법 | Security Hole 수치 |
|----------|-------------------|
| Week 2 (load-gen → auth /call) | ~51s |
| Week 3 (attacker → deploy 직접) | **60.9s** |

Week 2는 auth를 통한 외부 관점 측정이고, Week 3는 내부 공격자 관점의 직접 접근 측정.
실제 공격 창은 더 넓다 — **auth가 제거되자마자 바로 접근 가능**.

---

## 논문용 핵심 발견

```
Finding 1: No-Policy Baseline
  - 모든 서비스 (4/4) 직접 접근 가능
  - 다른 네임스페이스에서도 접근 가능
  - 응답시간: 269~335ms (즉시 접근)

Finding 2: Lateral Movement During Wave Transition (D2)
  - auth 제거 직후부터 deploy 직접 접근 가능
  - deploy access window: 60.9s
  - 100% 성공률 (차단 0건)

Finding 3: Attack Surface
  - 진입점: 임의 pod (같은 NS 또는 다른 NS)
  - 도달 가능: 모든 downstream 서비스
  - 필요 권한: pod 내 code execution만 (K8s admin 불필요)
```

---

## 다음 단계 (Week 4)

위 취약점을 막기 위한 **Hierarchical Safe Transition Protocol** 구현:

1. OTAWave CRD 정의
2. Readiness gate (파드 준비 확인 후 전환)
3. Envoy 초기화 확인
4. AuthorizationPolicy 동기화
5. 안전한 deactivation 순서 강제: drain → pod 제거 → policy 차단
