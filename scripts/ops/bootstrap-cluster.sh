#!/usr/bin/env bash
set -e

# Bootstrap Macro

# deploy root app to k3han
kubectl apply -f gitops/k3han/root.yaml

#!/usr/bin/env bash
set -e

# Bootstrap Macro
CLUSTER_NAME=$1 

if [[ -z "$CLUSTER_NAME" ]]; then
    echo "Usage: $0 <cluster-name>"
    exit 1
fi

if [[ ! -f "gitops/$CLUSTER_NAME/root.yaml" ]]; then
    echo "Error: The file gitops/$CLUSTER_NAME/root.yaml not found."
    exit 1
fi

echo "checking ArgoCD Server..."
if ! kubectl wait --for=condition=available deployment/argocd-server -n argocd --timeout=60s &> /dev/null; then
    echo "❌ Error: ArgoCD Server is not ready."
    exit 1
fi

echo " $CLUSTER_NAME cluster bootstrapping..."
kubectl apply -f gitops/$CLUSTER_NAME/root.yaml