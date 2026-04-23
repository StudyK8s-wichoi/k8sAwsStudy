#!/bin/bash
set -e

CLUSTER_NAME="backend"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
K8S_DIR="$ROOT_DIR/k8s"

echo "=========================================="
echo " Helm 배포 시작"
echo "=========================================="

# 1. kind 클러스터 생성 (없을 때만)
echo ""
echo "=== [1/4] kind 클러스터 확인/생성 ==="
if kind get clusters | grep -q "^${CLUSTER_NAME}$"; then
  echo "클러스터 '${CLUSTER_NAME}' 이미 존재 - 생성 건너뜀"
  kubectl config use-context "kind-${CLUSTER_NAME}"
else
  kind create cluster --config "$K8S_DIR/common/kind-config.yaml" --name $CLUSTER_NAME
fi

# 2. Gradle 빌드
echo ""
echo "=== [2/4] Gradle 빌드 ==="
cd "$ROOT_DIR"
./gradlew :gateway:bootJar :user:bootJar :chapter:bootJar :problem:bootJar :flyway:bootJar

# 3. Docker 이미지 빌드 및 kind 로드
echo ""
echo "=== [3/4] Docker 이미지 빌드 및 kind 로드 ==="
docker build -t gateway:latest ./gateway
docker build -t user_manage:latest ./user
docker build -t chapter:latest ./chapter
docker build -t problem:latest ./problem
docker build -t flyway:latest ./flyway

kind load docker-image gateway:latest --name $CLUSTER_NAME
kind load docker-image user_manage:latest --name $CLUSTER_NAME
kind load docker-image chapter:latest --name $CLUSTER_NAME
kind load docker-image problem:latest --name $CLUSTER_NAME
kind load docker-image flyway:latest --name $CLUSTER_NAME

# 4. HOST_IP 감지 후 Helm 배포
echo ""
echo "=== [4/4] Helm 배포 ==="
HOST_IP=$(docker run --rm --network kind alpine sh -c \
  "getent hosts host.docker.internal 2>/dev/null | awk '{print \$1; exit}'" 2>/dev/null || true)

if ! echo "$HOST_IP" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; then
  HOST_IP=$(docker network inspect kind \
    --format '{{range .IPAM.Config}}{{println .Gateway}}{{end}}' \
    | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' \
    | head -1)
fi

if [ -z "$HOST_IP" ]; then
  echo "ERROR: 호스트 IPv4 주소를 찾지 못함" >&2
  exit 1
fi
echo "Host IP: $HOST_IP"

helm upgrade --install study "$SCRIPT_DIR" \
  -n backend --create-namespace \
  --set externalDb.hostIp="$HOST_IP"
# --create-namespace 는 namespace.yaml 이 적용되기 전 helm 자체가 네임스페이스를
# 필요로 하는 경우를 대비한 안전장치. namespace 관리는 templates/namespace.yaml 이 담당.

echo "ingress-nginx 컨트롤러 준비 대기 중..."
kubectl rollout status deployment study-ingress-nginx-controller \
  -n backend --timeout=120s

echo "마이그레이션 완료 대기 중..."
kubectl wait --for=condition=complete job/flyway-migration \
  -n backend --timeout=120s

echo ""
echo "=========================================="
echo " 완료!"
echo "=========================================="
echo ""
echo "/etc/hosts에 아래 항목이 없으면 추가하세요:"
echo "  127.0.0.1 api.local"
echo ""
echo "접근 URL: http://api.local"
kubectl get pods -n backend
