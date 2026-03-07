set -e

echo "[PHASE 1] Sealing Secret..."
kubeseal --controller-name=sealed-secrets \
         --controller-namespace=kube-system \
         --format yaml \
         < unsealed-secret.yaml \
         > redis-sealed-secrets.yaml

echo "[INFO] Applying SealedSecret..."
kubectl apply -f redis-sealed-secrets.yaml

echo "[PHASE 2] Preclaim PersistentVolume..."
kubectl apply -f redis-pv.yaml

echo "[PHASE 3] Deploy redis via ArgoCD Application"
kubectl apply -f application.yaml

echo "[✅ DONE] redis deployment triggered."