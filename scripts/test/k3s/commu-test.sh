#!/usr/bin/env bash
set -e

echo "--- 1. 部屬 simple-pod for testing ---"
kubectl apply -f $(dirname $0)/simple-pod.yaml

sleep 5

echo -e "\n--- 2. 檢查 simple-pod 部屬狀態 ---"
kubectl get pods -l app=soak-test -o wide

echo -e "\n--- 3. 測試跨節點網路 (Tailscale 隧道檢查) ---"
POD_IPS=$(kubectl get pods -l app=soak-test -o jsonpath='{.items[*].status.podIP}')
FIRST_POD=$(kubectl get pods -l app=soak-test -o name | head -n 1)

for ip in $POD_IPS; do
  echo "Testing connectivity to $ip..."
  kubectl exec $FIRST_POD -- ping -c 2 $ip > /dev/null
  if [ $? -eq 0 ]; then echo "OK"; else echo "FAILED"; fi
done

echo -e "\n--- 4. 清除測試部屬  ---"
kubectl delete -f $(dirname $0)/simple-pod.yaml