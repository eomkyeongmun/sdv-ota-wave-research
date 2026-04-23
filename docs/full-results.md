# SDV OTA 웨이브 전환 보안 — 전체 실험 결과 및 결론

> Kubernetes + Istio 기반 OTA 파이프라인에서 계층적 안전 전환 프로토콜(HSTP)의 유효성 검증
> 실험 일자: 2026-04-23

---

## 실험 환경

| 항목 | 값 |
|---|---|
| 플랫폼 | Kubernetes v1.30.0 (Kind: control-plane 1 + worker 2) |
| 서비스 메시 | Istio 1.21.2 (sidecar injection, mTLS) |
| 파이프라인 | auth → campaign → package → deploy (Python 3.11-slim) |
| 공격자 모델 | 파이프라인 내 pod 코드 실행 권한, K8s admin 권한 없음 |
| 실험 시나리오 | 비활성화 worst-case: D2 (auth-first 순서) |

---

## 기여 1 — 전환 시나리오별 보안 홀 및 가용성 분석

### 1-1. 활성화 순서 정의

| 순서 | 방향 | 설명 |
|---|---|---|
| A1 | auth → campaign → package → deploy | 순방향 (upstream-first) |
| A2 | deploy → package → campaign → auth | 역방향 (downstream-first) |
| A3 | campaign → package → auth → deploy | 중간부터 |

### 1-2. 비활성화 순서 정의

| 순서 | 방향 | 설명 |
|---|---|---|
| D1 | deploy → package → campaign → auth | 안전 (downstream-first) |
| D2 | auth → campaign → package → deploy | 위험 (upstream-first) |
| D3 | campaign → package → auth → deploy | 부분 위험 |

### 1-3. 비활성화 순서별 보안 홀 측정 (실험 17)

| 비활성화 순서 | 보안 홀 지속 시간 | 노출 서비스 | 공격자 접근 성공 |
|---|---|---|---|
| D1 (deploy→package→campaign→auth) | **0초** | 없음 | 0% |
| D2 (auth→campaign→package→deploy) | **50.9초** | campaign, package, deploy | 100% |
| D3 (campaign→package→auth→deploy) | **17.1초** | deploy | 100% |

**D2 세부 진행:**
```
t=0s    auth 제거    → campaign/package/deploy 즉시 노출 (보안 홀 시작)
t=17.9s campaign 제거 → package/deploy 노출 지속
t=33.7s package 제거  → deploy 노출 지속
t=50.9s deploy 제거   → 보안 홀 종료
```

**핵심 발견:** 비활성화 순서가 보안 홀 지속 시간을 결정한다.
D1(안전 순서)은 보안 홀 0초, D2(위험 순서)는 50.9초 차이.

### 1-4. 9가지 E2E 조합 가용성 분석 (실험 07)

| 조합 | 활성화 성공률 | 비활성화 성공률 | 보안 홀 |
|---|---|---|---|
| A1-D1 | 80% | 66.7% | **0초** |
| A1-D2 | 80% | 16.7% | **~51초** |
| A1-D3 | 80% | 33.3% | **~17초** |
| A2-D1 | 28.6% | 66.7% | **0초** |
| A2-D2 | 28.6% | 16.7% | **~51초** |
| A2-D3 | 28.6% | 33.3% | **~17초** |
| A3-D1 | 45.7% | 66.7% | **0초** |
| A3-D2 | 45.7% | 16.7% | **~51초** |
| A3-D3 | 45.7% | 31.4% | **~17초** |

> 보안 홀은 비활성화 순서에만 의존. 활성화 순서는 가용성에만 영향.

---

## 기여 2 — Readiness Probe 한계 실증 및 HSTP 다단계 게이트 (실험 18)

### 2-1. 실험 설계

```
kubectl apply DENY policy → 즉시 트래픽 측정
(readiness probe = OK, 하지만 Envoy에 policy 미전파)
→ DENY가 실제로 적용되기까지 요청이 통과 = 보안 취약 구간
```

### 2-2. Policy Propagation Gap 측정 결과

| 측정 항목 | 값 |
|---|---|
| `kubectl apply` 실행 후 readiness probe 상태 | **즉시 OK** |
| DENY policy 실제 적용까지 소요 시간 | **54.6초** |
| 그 동안 요청 통과 여부 | **통과됨 (depth=1~4)** |
| ALLOW 복구 전파 지연 | **~6초** |

**시계열 상세:**
```
t=0s    kubectl apply DENY 실행 (즉시 리턴)
         → readiness probe: OK
         → 실제 차단: 아직 안됨

t=0.5s  HTTP 200, depth=4  [통과]  ← 보안 홀 시작
t=3.4s  HTTP 200, depth=1  [통과]  ← campaign DENY 부분 적용
t=6.4s  HTTP 200, depth=1  [통과]
...
t=54.6s HTTP 200, depth=1  [통과]  ← 여전히 auth는 응답

(DENY 완전 적용: 54.6초 이후)
```

### 2-3. Readiness Probe vs HSTP 비교

| 게이트 방식 | 정책 전파 확인 | 보안 갭 | 방법 |
|---|---|---|---|
| Readiness probe only | 불가능 (HTTP 헬스만 확인) | **최대 54.6초** | kubectl rollout status |
| HSTP 다단계 게이트 | 명시적 대기 후 확인 | **0초** | rollout + 60s sync wait + 검증 |

**핵심 발견:**
Readiness probe는 컨테이너의 HTTP 응답만 확인하므로 Istio의 Envoy 사이드카 인증서 발급 완료 및 AuthorizationPolicy 전파 완료 여부를 알 수 없다. DENY policy 적용 후 실제 차단까지 54.6초의 갭이 존재하며, readiness-only 게이트는 이 갭을 전혀 인지하지 못한다.

---

## 기여 3 — 계층적 안전 전환 프로토콜 (HSTP) 설계 및 비교

### 3-1. HSTP 구성 요소

```
[외부 전환 게이트]          [내부 마이크로세그멘테이션]
OTAWave CRD               ServiceAccount per service
     +                          +
컨트롤러 (Python)           NetworkPolicy chain (L4)
     +                          +
안전 비활성화 순서            AuthorizationPolicy (L7, SA-based)
(downstream-first)               +
     +                      STRICT mTLS
drain gate (8s/step)
     +
policy sync 대기 (60s)
```

### 3-2. 3-시나리오 비교 결과 (실험 15)

| 지표 | No-Policy | HSTP only | HSTP + Microseg |
|---|---|---|---|
| 보안 홀 지속 시간 (s) | **50.9** | **0** | **0** |
| 공격 시간 창 Attack Window (s) | **50.9** | **0** | **0** |
| Lateral Movement 차단율 (%) | **25** | **85.7** | **100** |
| 요청 성공률 (%) | **0** | **85.7** | **85.7** |
| 전환 위험 구간 Transition Risk Window (s) | N/A | **66** | **66** |

### 3-3. 방어 계층별 역할

| 계층 | 구성 요소 | 차단 대상 |
|---|---|---|
| L4 | NetworkPolicy | 허가되지 않은 pod-to-pod 통신 |
| L7 | AuthorizationPolicy (SA-principal) | SA 기반 허가되지 않은 서비스 호출 |
| mTLS | PeerAuthentication STRICT | 평문 통신 및 비인증 연결 |
| 전환 제어 | OTAWave CRD + Controller | 비안전 순서 실행 방지 |

---

## 기여 4 — 정책 전파 지연 및 내부 우회 차단율 실증 (실험 14, 18)

### 4-1. 정책 전파 지연 측정

| 정책 변경 | kubectl 리턴 시간 | 실제 적용 시간 | 전파 지연 |
|---|---|---|---|
| DENY policy 적용 | 즉시 (< 1s) | 54.6s 이후 | **~54초** |
| ALLOW 복구 | 즉시 (< 1s) | ~6s 이후 | **~6초** |
| SA 변경 + cert 재발급 | 즉시 (< 1s) | ~60s 이후 | **~60초** |

### 4-2. 내부 우회 차단 성공률 (실험 14)

| 공격 유형 | 차단 성공 | 비고 |
|---|---|---|
| Same-NS lateral move (deploy/package/campaign) | 3/3 (100%) | 403 Forbidden |
| Same-NS auth 접근 | 0/1 (허용) | 의도된 진입점 |
| Cross-NS (default NS → ota-pipeline) | 4/4 (100%) | HTTP 000 (네트워크 차단) |

---

## 종합 결론

### 결론 1. 비활성화 순서가 보안의 핵심 변수다

비활성화 순서 하나로 보안 홀 지속 시간이 0초(D1)에서 50.9초(D2)까지 벌어진다.
기술적 추가 없이 순서 설계만으로 가장 큰 위협을 제거할 수 있다.

```
D1 (downstream-first): 보안 홀 0초   ← 안전
D2 (upstream-first):   보안 홀 50.9초 ← 위험
D3 (혼합):             보안 홀 17.1초 ← 부분 위험
```

### 결론 2. Readiness Probe는 전환 안전성 보장에 불충분하다

Readiness probe는 HTTP 헬스만 확인한다. DENY policy를 kubectl apply 해도
Envoy에 실제 전파되기까지 최대 54.6초가 걸리며, 이 동안 readiness probe는
"정상"을 반환한다. 이는 전환 과정에서 policy-기반 보안 게이트가 필요함을 의미한다.

```
kubectl apply DENY  →  readiness probe: OK (즉시)
                    →  실제 차단: 54.6초 후
                    →  갭 동안 공격 트래픽 통과
```

### 결론 3. 외부 게이트 + 내부 정책 = 완전 방어 (Defense-in-Depth)

HSTP(외부 전환 제어)만으로는 lateral movement 85.7% 차단.
마이크로세그멘테이션(내부 정책) 추가 시 100% 차단.
두 계층은 서로 다른 위협을 담당하며 보완 관계다.

```
HSTP only:           보안 홀 0초, lateral 85.7% 차단
HSTP + Microseg:     보안 홀 0초, lateral 100% 차단
```

### 결론 4. 안전한 전환이 오히려 가용성을 높인다

No-policy 상태에서 D2 비활성화 시 요청 성공률은 0%.
HSTP 적용 후 85.7%로 상승. 보안과 가용성이 트레이드오프가 아님을 보인다.

```
No-Policy:  요청 성공률 0%  (서비스 체인 붕괴)
HSTP:       요청 성공률 85.7% (drain 중에도 유지)
```

---

## 수치 요약 (논문 테이블용)

### Table A. 시나리오 비교

| 지표 | No-Policy | HSTP only | HSTP + Microseg |
|---|---|---|---|
| 보안 홀 (s) | 50.9 | 0 | 0 |
| Attack Window (s) | 50.9 | 0 | 0 |
| Lateral 차단율 (%) | 25 | 85.7 | **100** |
| 요청 성공률 (%) | 0 | 85.7 | 85.7 |
| Transition Risk Window (s) | N/A | 66 | 66 |

### Table B. 비활성화 순서별 보안 홀

| 순서 | 보안 홀 (s) | 노출 서비스 수 | 권장 여부 |
|---|---|---|---|
| D1 (downstream-first) | **0** | 0 | 권장 |
| D3 (혼합) | 17.1 | 1 | 비권장 |
| D2 (upstream-first) | 50.9 | 3 | 금지 |

### Table C. Policy Propagation Delay

| 정책 작업 | kubectl 리턴 | 실제 적용 | 전파 지연 |
|---|---|---|---|
| DENY 적용 | < 1s | 54.6s | **~54초** |
| ALLOW 복구 | < 1s | ~6s | **~6초** |
| SA 변경 + cert | < 1s | ~60s | **~60초** |

### Table D. 마이크로세그멘테이션 검증

| 테스트 | 결과 | HTTP 상태 |
|---|---|---|
| 파이프라인 체인 (depth=4) | PASS | 200 |
| Same-NS lateral move 차단 | 3/3 | 403 |
| Cross-NS 접근 차단 | 4/4 | 000 (NP drop) |

---

## 실험 파일 목록

| 파일 | 내용 |
|---|---|
| `logs/e2e-matrix-*.csv` | 9가지 E2E 조합 가용성 |
| `logs/lateral-movement-baseline-*.csv` | No-policy 기준 lateral movement |
| `logs/lateral-movement-transition-*.csv` | D2 전환 중 lateral movement |
| `logs/hstp-deactivation-*.csv` | HSTP safe deactivation 측정 |
| `logs/microseg-verify-*.csv` | 마이크로세그멘테이션 검증 |
| `logs/week6-comparison-*.csv` | 3-시나리오 비교 |
| `logs/security-hole-matrix-*.csv` | D1/D2/D3 보안 홀 측정 |
| `logs/readiness-vs-hstp-*.csv` | Policy propagation gap 측정 |
