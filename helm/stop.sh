#!/bin/bash

CLUSTER_NAME="backend"

echo "=========================================="
echo " Helm 배포 종료"
echo "=========================================="
helm uninstall study -n backend 2>/dev/null || true
kind delete cluster --name $CLUSTER_NAME
echo "완료!"
