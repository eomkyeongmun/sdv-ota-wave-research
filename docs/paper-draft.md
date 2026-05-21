# SDV OTA 웨이브 전환에서의 레이스 컨디션과 계층적 안전 전환 프로토콜

> 초안 작성일: 2026-04-27
> 최종 실험일: 2026-04-29 (N=5 반복 실험)
> 플랫폼: Kubernetes v1.30.0 (Kind) + Istio 1.21.2

---

## 초록

SDV(Software Defined Vehicle) OTA 백엔드는 대규모 배포를 위해 웨이브(wave) 단위로 업데이트를 수행한다. Kubernetes + Istio 환경에서 워크로드 전환과 AuthorizationPolicy 전파는 비동기적으로 동작하므로, 웨이브 전환 시 일시적인 보안 홀(security hole)이나 서비스 중단이 발생할 수 있다. 본 논문은 OTA 파이프라인(auth → campaign → package → deploy)을 대상으로 전환 순서에 따른 보안 홀 지속 시간과 가용성을 정량적으로 측정하고, 계층적 안전 전환 프로토콜(HSTP: Hierarchical Safe Transition Protocol)을 설계·구현하여 그 효과를 실증한다. 실험 결과(N=5회 반복), 비활성화 순서 하나만으로 보안 홀이 0초(안전 순서)에서 52.06 ± 0.48초(위험 순서)까지 차이가 발생함을 확인하였다. 또한 Readiness Probe는 Istio AuthorizationPolicy 전파 완료 여부를 확인할 수 없어 최대 51.12 ± 0.18초의 정책 갭이 존재함을 실증하였다. HSTP + 마이크로세그멘테이션을 결합하면 보안 홀 0초, Lateral Movement 차단율 99.1 ± 2.01%, 전환 중 요청 성공률 85.6 ± 2.14%를 달성할 수 있다.

**키워드:** SDV OTA, Kubernetes, Istio, 웨이브 전환, 레이스 컨디션, 마이크로세그멘테이션, Zero Trust

---

## 1. 서론

차량 소프트웨어의 무선 업데이트(OTA)는 현대 SDV의 핵심 기능이다. 대규모 플릿에 대한 OTA 배포는 일반적으로 웨이브(wave) 단위로 순차 진행되며, 각 웨이브는 활성화(activation)와 비활성화(deactivation) 전환을 포함한다. Kubernetes + Istio 기반 OTA 백엔드에서 이 전환은 다음과 같은 문제를 유발한다.

1. **레이스 컨디션**: 워크로드 스케일 다운과 AuthorizationPolicy 전파가 비동기적으로 이루어져 일시적 과-허용(over-permission) 구간이 발생한다.
2. **내부 Lateral Movement**: 정책 없는 환경에서 단일 파드 침해만으로도 파이프라인 전체가 공격 대상이 된다.
3. **Readiness Probe 한계**: 컨테이너 헬스 체크는 Envoy 사이드카의 정책 적용 상태를 반영하지 않는다.

본 논문은 이 세 가지 문제를 체계적으로 측정하고, 외부 전환 게이트(OTAWave CRD/Controller)와 내부 마이크로세그멘테이션을 결합한 HSTP를 제안한다.

---

## 2. 위협 모델

- **공격자 가정**: OTA 파이프라인 내 임의의 파드에서 코드 실행 권한 보유
- **제약 조건**: Kubernetes API 관리자 권한 없음, 호스트 레벨 권한 없음
- **공격 목표**: 전환 시간 창(transition window)을 이용한 무단 서비스 접근, 파이프라인 내 Lateral Movement
- **파이프라인**: auth → campaign → package → deploy (4단계 체인)

---

## 3. 실험 환경

| 항목 | 값 |
|---|---|
| 플랫폼 | Kubernetes v1.30.0 (Kind: control-plane 1 + worker 2) |
| 서비스 메시 | Istio 1.21.2 (sidecar injection, mTLS STRICT) |
| 파이프라인 서비스 | auth / campaign / package / deploy (Python 3.11-slim) |
| 네트워크 정책 | Kubernetes NetworkPolicy + Istio AuthorizationPolicy |
| CRD | OTAWave (custom) + Python Controller |

---

## 4. 실험 결과

### 4.1 전환 시나리오 정의

#### 활성화 순서 (3가지)

| 순서 | 방향 | 설명 |
|---|---|---|
| A1 | auth → campaign → package → deploy | 순방향 (upstream-first) |
| A2 | deploy → package → campaign → auth | 역방향 (downstream-first) |
| A3 | campaign → package → auth → deploy | 중간부터 |

#### 비활성화 순서 (3가지)

| 순서 | 방향 | 설명 |
|---|---|---|
| D1 | deploy → package → campaign → auth | 안전 (downstream-first) |
| D2 | auth → campaign → package → deploy | 위험 (upstream-first) |
| D3 | campaign → package → auth → deploy | 부분 위험 |

---

### 4.2 비활성화 순서별 보안 홀 측정

비활성화 순서가 보안 홀 지속 시간을 결정하는 핵심 변수임을 실증하였다.

**Table 1. 비활성화 순서별 보안 홀**

| 비활성화 순서 | 보안 홀 mean ± std (초) | 노출 서비스 수 | 공격 접근 성공률 | 권장 여부 |
|---|:---:|:---:|:---:|:---:|
| D1 (downstream-first) | **0 ± 0** | 0 | 0% | 권장 |
| D3 (혼합) | **16.87 ± 0.30** | 1 | 100% | 비권장 |
| D2 (upstream-first) | **52.06 ± 0.48** | 3 | 100% | 금지 |

(N=5회 반복 실험, 단위: 초)

**D2 세부 진행 (위험 순서 예시):**

```
t=0s    auth 제거    → campaign/package/deploy 즉시 노출 (보안 홀 시작)
t=17.9s campaign 제거 → package/deploy 노출 지속
t=33.7s package 제거  → deploy 노출 지속
t=52.1s deploy 제거   → 보안 홀 종료
```

> **발견**: 비활성화 순서 하나만으로 보안 홀이 0초 ↔ 52.06 ± 0.48초로 결정된다. 추가 기술 없이 순서 설계만으로 위협의 대부분을 제거할 수 있다.

---

### 4.3 9가지 E2E 조합 가용성 분석

**Table 2. 활성화 × 비활성화 조합별 가용성 및 보안 홀**

| 조합 | 활성화 성공률 | 비활성화 성공률 | 보안 홀 |
|---|:---:|:---:|:---:|
| A1-D1 | 80% | 66.7% | 0초 |
| A1-D2 | 80% | 16.7% | ~51초 |
| A1-D3 | 80% | 33.3% | ~17초 |
| A2-D1 | 28.6% | 66.7% | 0초 |
| A2-D2 | 28.6% | 16.7% | ~51초 |
| A2-D3 | 28.6% | 33.3% | ~17초 |
| A3-D1 | 45.7% | 66.7% | 0초 |
| A3-D2 | 45.7% | 16.7% | ~51초 |
| A3-D3 | 45.7% | 31.4% | ~17초 |

> **발견**: 보안 홀은 비활성화 순서에만 의존하고, 활성화 순서는 서비스 가용성에만 영향을 미친다.

---

### 4.4 Readiness Probe의 한계 — Policy Propagation Gap

`kubectl apply`로 DENY AuthorizationPolicy를 적용해도, Envoy 사이드카에 실제로 전파되기까지 지연이 존재한다. Readiness Probe는 이 지연을 감지하지 못한다.

**Table 3. Policy Propagation Delay 측정**

| 정책 작업 | kubectl 리턴 시간 | 실제 적용 완료 (mean ± std) | 전파 지연 |
|---|:---:|:---:|:---:|
| DENY policy 적용 | < 1초 | 51.12 ± 0.18초 이후 | **~51초** |
| ALLOW 복구 | < 1초 | 0.62 ± 1.28초 이후 | **~1초** |
| SA 변경 + cert 재발급 | < 1초 | ~60초 이후 | **~60초** |

(N=5회 반복 실험)

**시계열 상세 (DENY 적용 후):**

```
t=0s    kubectl apply DENY 실행
         → readiness probe: OK (즉시)
         → 실제 차단: 아직 안됨

t=0.3s  HTTP 200, depth=4  [통과] ← 보안 갭 시작
t=3.4s  HTTP 200, depth=1  [통과]
...
t=51.1s 이후 실제 DENY 적용 완료 (mean 기준)
```

**Table 4. Readiness Probe vs HSTP 게이트 비교**

| 게이트 방식 | 정책 전파 확인 가능 | 보안 갭 |
|---|:---:|:---:|
| Readiness probe only | 불가 (HTTP 헬스만 확인) | **최대 51.12 ± 0.18초** |
| HSTP 다단계 게이트 | 가능 (명시적 60초 sync 대기) | **0초** |

---

### 4.5 3-시나리오 비교 — HSTP 효과 검증

worst-case(D2: auth-first 비활성화)를 기준으로 세 가지 시나리오를 비교하였다.

**Table 5. 시나리오별 핵심 지표 비교**

| 지표 | No-Policy | HSTP only | HSTP + Microseg |
|---|:---:|:---:|:---:|
| 보안 홀 지속 시간 mean ± std (초) | **52.06 ± 0.48** | **0** | **0** |
| Attack Window (초) | **52.06 ± 0.48** | **0** | **0** |
| Lateral Movement 차단율 mean ± std (%) | **25 ± 0** | **81.34 ± 2.40** | **99.1 ± 2.01** |
| 전환 중 요청 성공률 mean ± std (%) | **0 ± 0** | **83.9 ± 1.76** | **85.6 ± 2.14** |
| Transition Risk Window mean ± std (초) | N/A | **66.4 ± 1.82** | **63.0 ± 1.22** |

(N=5회 반복 실험, D2 worst-case 기준)

---

### 4.6 마이크로세그멘테이션 검증

서비스별 ServiceAccount + NetworkPolicy + AuthorizationPolicy(SA-principal) + STRICT mTLS 적용 결과.

Same-NS 테스트는 비-진입점 3개 서비스(campaign/package/deploy)를 대상으로 하며, auth는 설계상 진입점이므로 별도 행으로 분리하여 표기하였다. Cross-NS 테스트는 4개 서비스 전체를 대상으로 한다.

**Table 6. 마이크로세그멘테이션 차단 검증**

| 공격 유형 | 차단 결과 | HTTP 응답 |
|---|:---:|:---:|
| 파이프라인 정상 체인 (depth=4) | PASS | 200 |
| Same-NS lateral move (deploy/package/campaign) | 3/3 차단 (비-진입점 100%) | 403 Forbidden |
| Same-NS auth 접근 (설계상 진입점, 의도적 허용) | 허용 | 200 |
| Cross-NS 접근 (default NS → ota-pipeline) | 4/4 차단 (100%) | 000 (NP drop) |

---

## 5. HSTP 설계

### 5.1 구성 요소

```
[외부 전환 게이트]              [내부 마이크로세그멘테이션]
OTAWave CRD                   ServiceAccount per service
      +                               +
컨트롤러 (Python, polling 5s)     NetworkPolicy chain (L4)
      +                               +
안전 비활성화 순서                  AuthorizationPolicy (L7, SA-based)
(downstream-first)                    +
      +                           STRICT mTLS
drain gate (8초/step)
      +
policy sync 대기 (60초)
```

### 5.2 방어 계층별 역할

**Table 7. HSTP 방어 계층 구성**

| 계층 | 구성 요소 | 차단 대상 |
|---|---|---|
| L4 | NetworkPolicy | 허가되지 않은 pod-to-pod 통신 |
| L7 | AuthorizationPolicy (SA-principal) | SA 기반 미허가 서비스 호출 |
| mTLS | PeerAuthentication STRICT | 평문 통신 및 비인증 연결 |
| 전환 제어 | OTAWave CRD + Controller | 비안전 순서 실행 방지 |

### 5.3 안전 비활성화 절차 (per service)

```
1. drain gate     — 8초 대기 (in-flight 요청 완료)
2. scale down     — replicas: 0
3. DENY policy    — AuthorizationPolicy DENY 적용
4. Envoy sync     — 60초 대기 (정책 전파 시간 기반 보수적 게이트)
```

Envoy sync 단계는 실측한 worst-case 전파 시간 51.12 ± 0.18초(N=5)에 약 9초의 안전 마진을 더한 **시간 기반 휴리스틱**이다. Envoy `/config_dump` 또는 istiod push status를 능동적으로 폴링하는 방식은 본 연구의 후속 작업으로 둔다.

---

## 6. 고찰

### 6.1 비활성화 순서가 보안의 핵심 변수

기술적 추가 없이 순서 설계만으로 보안 홀이 0초(D1) ↔ 52.06 ± 0.48초(D2) 로 결정된다(N=5). 가장 간단하고 효과적인 1차 방어선이다.

### 6.2 Readiness Probe는 전환 안전성 보장에 불충분

Readiness Probe는 컨테이너 HTTP 헬스만 확인한다. Istio AuthorizationPolicy의 Envoy 전파 지연(평균 51.12 ± 0.18초)을 인지하지 못하므로, 전환 게이트로 사용하면 안 된다. HSTP의 명시적 sync 대기가 필요하다.

### 6.3 Defense-in-Depth: 외부 게이트 + 내부 정책

- HSTP(외부)만 적용: 보안 홀 0초, Lateral Movement 81.34 ± 2.40% 차단
- HSTP + 마이크로세그멘테이션: 보안 홀 0초, Lateral Movement 99.1 ± 2.01% 차단
- 두 계층은 서로 다른 위협(전환 시 레이스 컨디션 vs. 상시 내부 이동)을 담당하는 보완 관계다.

### 6.4 보안과 가용성은 트레이드오프가 아니다

No-Policy 상태에서 D2 비활성화 시 요청 성공률은 0%(서비스 체인 붕괴). HSTP 적용 후 83.9 ± 1.76%로 상승. 안전한 전환이 오히려 가용성을 높인다.

---

## 7. 결론

본 논문은 SDV OTA 파이프라인의 웨이브 전환 보안을 계층적 문제로 접근하였다. 주요 기여는 다음과 같다.

1. **비활성화 순서에 따른 보안 홀 정량화**: D2(upstream-first) 순서에서 52.06 ± 0.48초 보안 홀 발생(N=5), D1(downstream-first)에서 0초.
2. **Readiness Probe 한계 실증**: DENY policy 적용 후 실제 Envoy 전파까지 51.12 ± 0.18초 갭 존재(N=5), readiness probe는 이를 인지 불가.
3. **HSTP 설계 및 효과 검증**: OTAWave CRD + Controller + 마이크로세그멘테이션 결합으로 보안 홀 0초, Lateral Movement 99.1 ± 2.01% 차단, 요청 성공률 85.6 ± 2.14% 달성(N=5).
4. **보안-가용성 양립**: 안전한 전환 프로토콜 적용 시 가용성도 동시에 향상됨을 실증.

---

## 부록: 핵심 수치 요약 (논문 테이블 참조용)

| 지표 | No-Policy | HSTP only | HSTP + Microseg |
|---|:---:|:---:|:---:|
| 보안 홀 mean ± std (초) | 52.06 ± 0.48 | 0 | 0 |
| Attack Window mean ± std (초) | 52.06 ± 0.48 | 0 | 0 |
| Lateral 차단율 mean ± std (%) | 25 ± 0 | 81.34 ± 2.40 | **99.1 ± 2.01** |
| 요청 성공률 mean ± std (%) | 0 ± 0 | 83.9 ± 1.76 | **85.6 ± 2.14** |
| Transition Risk Window mean ± std (초) | N/A | 66.4 ± 1.82 | **63.0 ± 1.22** |
| Policy 전파 지연 DENY mean ± std (초) | — | 51.12 ± 0.18 (readiness-only) | 0 (HSTP gate) |

(N=5회 반복 실험)

---

*실험 로그: `logs/` 디렉토리 참조*
*통계 결과: `logs/kci-stats-*.csv` 참조*
