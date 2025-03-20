#!/bin/bash
# SafeZone PostgreSQL 安裝順序腳本

# 1️⃣ 透過 kubectl 生成 unsealed Secret
kubectl create secret generic postgredb-secret \
  --namespace database \
  --from-literal=postgres-password="SuperSecretPassword" \
  --from-literal=replication-password="AnotherSecret" \
  --dry-run=client -o yaml > unsealed-secret.yaml

echo "✅ 已生成 unsealed-secret.yaml"

# 2️⃣ 透過 Sealed Secrets Controller 加密 unsealed-secret.yaml
kubeseal --controller-name=sealed-secrets-controller --controller-namespace=kube-system --format yaml \
  < unsealed-secret.yaml > sealed-secret.yaml

echo "✅ 已加密 sealed-secret.yaml"

# 3️⃣ 將 sealed-secret.yaml 部署到 K3S
kubectl apply -f sealed-secret.yaml -n database

echo "✅ Sealed Secret 已部署至 K3S"

# 4️⃣ 部署 PostgreSQL 應用（Application.yaml）
kubectl apply -f gitops/base/postgresql/postgredb.yaml -n gitops

echo "✅ PostgreSQL ArgoCD Application 已部署"

# 5️⃣ 觸發 ArgoCD 同步（可選，確保立即部署）
argocd app sync postgredb

echo "🚀 PostgreSQL 部署完成，請檢查 `kubectl get pods -n database` 確認所有服務是否運行正常！"
