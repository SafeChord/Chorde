# deencrypt the secret file
sops -d values-secret.enc.yaml > values-secret.yaml

# install argocd
# helm repo add argo https://argoproj.github.io/argo-helm
# vlaues.yaml for default configuration for k3han cluster
# values-custom.yaml for custom configuration (like affinity or nodeSelector)
# values-secret.yaml for secret configuration (like password or token for authentication)
helm install argocd argo/argo-cd -n gitops \
    -f values.yaml \
    -f values-custom.yaml \
    -f values-secret.yaml
