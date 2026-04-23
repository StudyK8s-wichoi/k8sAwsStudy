#!/bin/bash
set -e

CLUSTER_NAME="backend"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "=========================================="
echo " K8s 클러스터 시작"
echo "=========================================="

# 1. kind 클러스터 생성 (없을 때만)
echo ""
echo "=== [1/7] kind 클러스터 확인/생성 ==="
if kind get clusters | grep -q "^${CLUSTER_NAME}$"; then
  echo "클러스터 '${CLUSTER_NAME}' 이미 존재 - 생성 건너뜀"
  kubectl config use-context "kind-${CLUSTER_NAME}"
else
  kind create cluster --config "$SCRIPT_DIR/common/kind-config.yaml" --name $CLUSTER_NAME
fi

# 2. 공통 리소스 + External DB (호스트 MySQL/Redis 연결) 등록
#    - Service (selector 없음) + EndpointSlice 패턴으로 클러스터 밖 DB 를 감싼다.
#    - 이전 방식(host.docker.internal + CoreDNS hosts 블록 패치)은 제거.
#    - 나중에 EKS + RDS/ElastiCache 로 갈 때는 external-db.yaml 을
#      ExternalName 타입으로 교체하고 아래 EndpointSlice 주입 블록을 삭제하면 됨.
echo ""
echo "=== [2/7] 공통 리소스 + External DB EndpointSlice 주입 ==="
kubectl apply -f "$SCRIPT_DIR/common/namespace.yaml"
kubectl apply -f "$SCRIPT_DIR/common/secret.yaml"
kubectl apply -f "$SCRIPT_DIR/common/external-db.yaml"

# 파드에서 "호스트 맥북" 으로 가는 실제 IP 를 찾는다.
# - Docker Desktop (Mac/Win): kind 네트워크 내부에서 host.docker.internal 이
#   자동 주입돼 있음 (예: 192.168.65.254). 이게 진짜 호스트로 라우팅되는 IP.
# - Linux docker: 그 이름이 없어서 kind 네트워크의 IPv4 게이트웨이로 fallback.
#   (kind 게이트웨이가 호스트 브릿지 역할을 함)
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
echo "Host IP (mysql/redis EndpointSlice 에 주입): $HOST_IP"

# 템플릿의 __HOST_IP__ 를 실제 IP 로 sed 치환 후 apply
sed "s|__HOST_IP__|${HOST_IP}|g" \
  "$SCRIPT_DIR/common/external-db-endpoints.template.yaml" \
  | kubectl apply -f -

# 3. NGINX Ingress Controller 설치
echo ""
echo "=== [3/7] NGINX Ingress Controller 설치 ==="
kubectl apply -f "$SCRIPT_DIR/nginx-ingress/deploy.yaml"
echo "Ingress Controller 준비 대기 중..."
kubectl rollout status deployment -n ingress-nginx ingress-nginx-controller --timeout=120s

# 4. Gradle 빌드
echo ""
echo "=== [4/7] Gradle 빌드 ==="
cd "$ROOT_DIR"
./gradlew :gateway:bootJar :user:bootJar :chapter:bootJar :problem:bootJar :flyway:bootJar

# 5. Docker 이미지 빌드 및 kind 로드
echo ""
echo "=== [5/7] Docker 이미지 빌드 및 kind 로드 ==="
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

# 6. DB 마이그레이션
echo ""
echo "=== [6/7] DB 마이그레이션 (Flyway) ==="
kubectl apply -f "$SCRIPT_DIR/flyway/job.yaml"
echo "마이그레이션 완료 대기 중..."
kubectl wait --for=condition=complete job/flyway-migration -n backend --timeout=120s

# 7. 서비스 배포
echo ""
echo "=== [7/7] 서비스 배포 ==="
kubectl apply -f "$SCRIPT_DIR/gateway/"
kubectl apply -f "$SCRIPT_DIR/user/"
kubectl apply -f "$SCRIPT_DIR/chapter/"
kubectl apply -f "$SCRIPT_DIR/problem/"
kubectl apply -f "$SCRIPT_DIR/nginx-ingress/ingress.yaml"

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
