# =============================================================================
# 01-setup-kind.ps1 (Multi-Node for Paper Research)
# Create a kind (Kubernetes-in-Docker) cluster with 1 Master and 2 Workers.
# =============================================================================
$ErrorActionPreference = "Stop" # 에러 발생 시 즉시 중단

$CLUSTER_NAME = "ota-research"
$K8S_VERSION  = "v1.30.0"

Write-Host "=== [01] Setting up MULTI-NODE kind cluster: $CLUSTER_NAME ===" -ForegroundColor Cyan

# 1. 기존 클러스터 존재 여부 확인 및 삭제
$existing = kind get clusters
if ($existing -contains $CLUSTER_NAME) {
    Write-Host "Existing cluster '$CLUSTER_NAME' found. Deleting to apply multi-node config..." -ForegroundColor Yellow
    kind delete cluster --name $CLUSTER_NAME
}

# 2. 멀티 노드 설정 정의 (1 Master + 2 Workers)
$config = @"
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: $CLUSTER_NAME
nodes:
  # Control Plane (Master)
  - role: control-plane
    extraPortMappings:
      - containerPort: 30080
        hostPort: 8080
        protocol: TCP
      - containerPort: 30443
        hostPort: 8443
        protocol: TCP
  # Worker Node 1
  - role: worker
  # Worker Node 2
  - role: worker
"@

# 3. 클러스터 생성
Write-Host "Creating cluster with 1 Control-plane and 2 Worker nodes..." -ForegroundColor White
$config | kind create cluster --name $CLUSTER_NAME --image "kindest/node:${K8S_VERSION}" --config -

Write-Host "Cluster created successfully." -ForegroundColor Green

# 4. 노드 상태 확인 (Ready가 될 때까지 잠시 대기)
Write-Host ""
Write-Host "=== Verifying cluster nodes ===" -ForegroundColor Cyan
kubectl get nodes -o wide

Write-Host ""
Write-Host "=== [01] DONE ===" -ForegroundColor Green
Write-Host "Next step: .\scripts\02-install-istio.ps1"