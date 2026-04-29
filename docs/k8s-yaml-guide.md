# k8s YAML 파일 설명

---

## 기반 인프라

| 파일 | 역할 |
|---|---|
| `namespace.yaml` | `ota-pipeline` 네임스페이스 생성. `istio-injection: enabled` 라벨로 모든 Pod에 Envoy 사이드카 자동 주입 |
| `configmap.yaml` | 4개 서비스가 공통으로 사용하는 Python 앱 코드 저장. `/health`, `/call`, `/info` 엔드포인트 제공 |

---

## 4개 더미 서비스

| 파일 | 역할 |
|---|---|
| `auth.yaml` | auth Deployment + Service. 파이프라인 진입점 |
| `campaign.yaml` | campaign Deployment + Service |
| `package.yaml` | package Deployment + Service |
| `deploy.yaml` | deploy Deployment + Service. 파이프라인 말단 |

> 4개 모두 동일한 Python 코드(`configmap.yaml`)를 사용하고 `NEXT_SERVICE` 환경변수로 다음 서비스를 호출하는 체인 구조
> 체인: auth → campaign → package → deploy

---

## mTLS 인증

| 파일 | 역할 |
|---|---|
| `peer-auth.yaml` | **PERMISSIVE** 모드 — 평문 HTTP + mTLS 둘 다 허용 (Week 1~4 기본값) |
| `peer-auth-strict.yaml` | **STRICT** 모드 — mTLS만 허용, 평문 차단 (Week 5 이후 적용) |

> 두 파일은 같은 이름(`default`)의 PeerAuthentication을 덮어쓰는 방식으로 전환

---

## 마이크로세그멘테이션 정책

| 파일 | 역할 |
|---|---|
| `serviceaccounts.yaml` | auth-sa / campaign-sa / package-sa / deploy-sa 4개 SA 생성. L7 정책의 신원(identity) 기반 |
| `networkpolicy-chain.yaml` | **L4 차단** — auth→campaign→package→deploy 체인만 허용. 네임스페이스 외부 및 체인 외 Pod-to-Pod 통신 차단 |
| `authpolicy-chain.yaml` | **L7 차단** — SA principal 기반. `campaign-sa`만 campaign에 접근 가능, 공격자(default SA)는 auth만 접근 가능 |

---

## HSTP (계층적 안전 전환 프로토콜)

| 파일 | 역할 |
|---|---|
| `otawave-crd.yaml` | `OTAWave` Custom Resource 정의. `spec.action`(activate/deactivate), `spec.services`, `spec.drainSeconds` 등 필드 포함 |
| `otawave-rbac.yaml` | HSTP 컨트롤러용 ServiceAccount + ClusterRole. Deployment scale, AuthorizationPolicy 생성/삭제, Pod 상태 조회 권한 부여 |
| `otawave-controller.yaml` | HSTP 컨트롤러 Pod. OTAWave CR을 감시하여 drain → scale → policy 순서로 안전 전환 실행 |

---

## 적용 순서 요약

```
namespace.yaml                                      # 네임스페이스
configmap.yaml                                      # 앱 코드
auth.yaml / campaign.yaml / package.yaml / deploy.yaml  # 서비스 배포
peer-auth.yaml                                      # 초기 mTLS PERMISSIVE
serviceaccounts.yaml                                # SA 생성
peer-auth-strict.yaml                               # mTLS STRICT으로 전환
networkpolicy-chain.yaml + authpolicy-chain.yaml    # L4+L7 마이크로세그멘테이션
otawave-crd.yaml + otawave-rbac.yaml + otawave-controller.yaml  # HSTP 자동화
```

---

## 방어 계층 정리

| 계층 | 파일 | 차단 대상 |
|---|---|---|
| L4 | `networkpolicy-chain.yaml` | 허가되지 않은 Pod-to-Pod 네트워크 통신 |
| L7 | `authpolicy-chain.yaml` | SA 기반 허가되지 않은 서비스 호출 |
| mTLS | `peer-auth-strict.yaml` | 평문 통신 및 비인증 연결 |
| 전환 제어 | `otawave-crd.yaml` + `otawave-controller.yaml` | 비안전 순서 실행 방지 |
