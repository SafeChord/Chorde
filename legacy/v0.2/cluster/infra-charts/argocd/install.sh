# Define Helm chart variables
CHART_VERSION=8.2.7         # ArgoCD chart version
CHART_NAME=argo/argo-cd      # Chart repo/name
RELEASE_NAME=argocd          # Helm release name
NAMESPACE=gitops             # Target namespace

# Install/upgrade ArgoCD with Helm
helm upgrade --install "$RELEASE_NAME" "$CHART_NAME" \
  --version "$CHART_VERSION" \
  -n "$NAMESPACE" \
  --create-namespace \
  -f values.yaml \
  -f values-custom.yaml 

# Get the initial ArgoCD admin password
kubectl -n gitops get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d && echo