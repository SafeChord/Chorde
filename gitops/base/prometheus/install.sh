#!/bin/bash
set -e

echo "[PHASE 1] Sealing Secret..."
kubeseal --controller-name=sealed-secrets \
         --controller-namespace=kube-system \
         --format yaml \
         < unsealed-secret.yaml \
         > prometheus-sealed-secrets.yaml

echo "[INFO] Applying SealedSecret..."
kubectl apply -f prometheus-sealed-secrets.yaml

echo "[PHASE 2] Preclaim PersistentVolume..."
kubectl apply -f prometheus-pv.yaml

echo "[PHASE 3] Deploy Prometheus via ArgoCD Application"
kubectl apply -f application.yaml

echo "[INFO] Waiting for Prometheus to sync in ArgoCD..."
kubectl wait --for=condition=Synced application prometheus --timeout=60s -n gitops || true

echo "[✅ DONE] Prometheus deployment triggered."
