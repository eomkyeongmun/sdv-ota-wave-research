# kubectl 기본 명령어 치트시트

## Context / 클러스터 전환

```bash
kubectl config get-contexts                    # 전체 context 목록
kubectl config current-context                 # 현재 context 확인
kubectl config use-context kind-ota-research   # context 전환
```

---

## 리소스 조회 (get)

```bash
# 기본 형태
kubectl get <리소스> -n <namespace>

# Pod
kubectl get pods -n ota-pipeline               # pod 목록
kubectl get pods -n ota-pipeline -w            # 실시간 watch
kubectl get pods -A                            # 전체 namespace pod
kubectl get pods -n ota-pipeline -o wide       # IP, 노드 포함 상세

# Deployment
kubectl get deployments -n ota-pipeline

# Service
kubectl get services -n ota-pipeline

# 전부 한번에
kubectl get all -n ota-pipeline

# Node
kubectl get nodes
```

---

## 리소스 상세 (describe)

```bash
kubectl describe pod <pod이름> -n ota-pipeline
kubectl describe deployment auth -n ota-pipeline
kubectl describe service auth -n ota-pipeline
```

> 에러 원인 찾을 때 `describe pod` 맨 아래 Events 섹션 확인

---

## 로그 (logs)

```bash
kubectl logs <pod이름> -n ota-pipeline                      # 로그 출력
kubectl logs <pod이름> -n ota-pipeline -f                   # 실시간 follow
kubectl logs <pod이름> -n ota-pipeline --tail=50            # 마지막 50줄
kubectl logs <pod이름> -n ota-pipeline -c istio-proxy       # 특정 컨테이너

# 라벨로 조회 (pod 이름 모를 때)
kubectl logs -n ota-pipeline -l app=auth -c auth
```

---

## Pod 내부 접속 (exec)

```bash
kubectl exec -it <pod이름> -n ota-pipeline -- bash
kubectl exec -it <pod이름> -n ota-pipeline -- sh            # bash 없으면

# 명령어 바로 실행
kubectl exec <pod이름> -n ota-pipeline -- curl http://campaign:8080/health
```

---

## 적용 / 삭제 (apply / delete)

```bash
# yaml 적용
kubectl apply -f k8s/auth.yaml
kubectl apply -f k8s/                          # 폴더 전체

# 삭제
kubectl delete -f k8s/auth.yaml
kubectl delete -f k8s/                         # 폴더 전체

# 리소스 직접 삭제
kubectl delete pod <pod이름> -n ota-pipeline   # pod 삭제 (Deployment가 자동 재생성)
kubectl delete deployment auth -n ota-pipeline
```

---

## 스케일 (replicas 조정)

```bash
kubectl scale deployment auth --replicas=3 -n ota-pipeline   # 3개로 늘리기
kubectl scale deployment auth --replicas=0 -n ota-pipeline   # 0개 = 서비스 중단
```

---

## 재시작

```bash
kubectl rollout restart deployment auth -n ota-pipeline       # pod 재시작
kubectl rollout status deployment auth -n ota-pipeline        # 재시작 상태 확인
```

---

## Namespace

```bash
kubectl get namespaces                         # namespace 목록
kubectl create namespace ota-pipeline          # namespace 생성
```

---

## Istio 관련

```bash
# Envoy 설정 덤프
kubectl exec <pod이름> -n ota-pipeline -c istio-proxy -- pilot-agent request GET /config_dump

# AuthorizationPolicy 조회
kubectl get authorizationpolicy -n ota-pipeline

# PeerAuthentication 조회
kubectl get peerauthentication -n ota-pipeline
```

---

## 자주 쓰는 패턴

```bash
# 특정 pod 이름 빠르게 찾기
kubectl get pods -n ota-pipeline | grep auth

# pod 상태 문제 진단 순서
kubectl get pods -n ota-pipeline          # STATUS 확인
kubectl describe pod <이름> -n ota-pipeline   # Events 확인
kubectl logs <이름> -n ota-pipeline           # 앱 로그 확인

# 전체 리셋
kind delete cluster --name ota-research
```

---

## STATUS 의미

| STATUS | 의미 |
|---|---|
| `Pending` | 스케줄링 대기 (노드 자원 부족 등) |
| `ContainerCreating` | 이미지 pull 중 |
| `Running` | 정상 |
| `CrashLoopBackOff` | 앱이 계속 죽음 — 로그 확인 필요 |
| `ImagePullBackOff` | 이미지 못 찾음 — 이미지 이름 확인 |
| `Terminating` | 삭제 중 |
