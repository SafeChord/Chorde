# the script is used to install the sealed-secrets helm chart

CHART_VERSION=2.17.2 # the version of the chart to install

helm install sealed-secrets sealed-secrets/sealed-secrets \
  --namespace kube-system \
  --version $CHART_VERSION \
  -f values.yaml \
  -f values-custom.yaml 