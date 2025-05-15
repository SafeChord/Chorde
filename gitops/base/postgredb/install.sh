#!/bin/bash

set -e

echo "[PHASE 1] Sealing Secret..."
kubeseal --controller-name=sealed-secrets \
         --controller-namespace=kube-system \
         --format yaml \
         < unsealed-secret.yaml \
         > postgredb-sealed-secrets.yaml

echo "[INFO] Applying SealedSecret..."
kubectl apply -f postgredb-sealed-secrets.yaml

echo "[PHASE 2] Preclaim PersistentVolume..."
kubectl apply -f postgredb-pv.yaml

echo "[PHASE 3] Deploy postgredb via ArgoCD Application"
kubectl apply -f application.yaml

echo "[✅ DONE] postgredb deployment triggered."
