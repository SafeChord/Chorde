#!/usr/bin/env bash
set -e

# Bootstrap Macro: step 4 of a from-scratch bootstrap (Docs safechord.chorde.md
# section 2). Applies the cluster's root.yaml once argocd-server is ready, and
# nothing if a check fails. Run from the repository root.
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