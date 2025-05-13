#!/bin/bash
set -e

# the second time installation will conflict because the CRDs are already installed.
# echo "[PHASE 0] INSTALLING PROMETHEUS-OPERATOR-CRD"
# helm upgrade --install prometheus-crds prometheus-community/prometheus-operator-crds \
#      --version 20.0.0

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

echo "[✅ DONE] Prometheus deployment triggered."
