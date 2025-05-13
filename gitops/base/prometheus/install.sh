#!/bin/bash
set -e

# Why pre-install CRDs? 
# ArgoCD can struggle with numerous large files, and CRDs tend to be large.
# Since these CRDs are not managed by ArgoCD, they can be installed separately.
# Thus, we pre-install them using Helm.

# Why is the CRD installation commented out? 
# Subsequent installations would conflict, and the resulting error would halt the script.

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
