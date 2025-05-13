#!/bin/bash
set -e

CERT_MANAGER_VERSION="v1.17.2"

helm upgrade --install cert-manager jetstack/cert-manager \
  --version ${CERT_MANAGER_VERSION} \
  -n kube-system \
  -f values.yaml \
  -f values-custom.yaml 

kubectl apply -f cert-issuer.yaml