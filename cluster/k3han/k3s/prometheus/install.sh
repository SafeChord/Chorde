# mount the local disk to pesistent volume
kubectl apply -f pv.yaml

# claim the persistent volume for prometheus
kubectl apply -f pvc.yaml

# deencrypt the secret file
sops -d values-secret.enc.yaml > values-secret.yaml

# install prometheus
# helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
# vlaues.yaml for default configuration for k3han cluster
# values-custom.yaml for custom configuration (like affinity or nodeSelector)
# values-secret.yaml for secret configuration (like password or token for authentication)
helm install prometheus prometheus-community/prometheus -n monitoring \
    -f values.yaml \
    -f values-custom.yaml \
    -f values-secret.yaml
