#!/bin/bash

set -e

echo "[PHASE 2] Preclaim PersistentVolume..."
kubectl apply -f pv.yaml

echo "[PHASE 3] Deploy postgredb via ArgoCD Application"
kubectl apply -f application.yaml

echo "[✅ DONE] kafka deployment triggered."