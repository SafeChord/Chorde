#!/usr/bin/env bash
# Requirement tests for stage directories (Chorde#54).
#
# Runs check.py against gitops/k3han, then against small trees built in a temp
# directory, each breaking or keeping the rule one way, so the check is shown
# to catch what it guards.
#
#   scripts/test/stage-dirs/test.sh
#
# Needs: bash, python3 with PyYAML.
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../../.." && pwd)
CHECK="$HERE/check.py"

PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); echo "  ok   $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL $1"; [ $# -gt 1 ] && echo "$2" | sed 's/^/       /'; }

# expect <name> pass|fail <env-dir> [pattern the output must hold]
expect() {
  local name=$1 want=$2 dir=$3 pattern=${4:-} out rc
  out=$(python3 "$CHECK" "$dir" 2>&1); rc=$?
  if [ "$want" = pass ] && [ $rc -eq 0 ]; then ok "$name"
  elif [ "$want" = fail ] && [ $rc -eq 1 ] && { [ -z "$pattern" ] || grep -qF -- "$pattern" <<<"$out"; }; then ok "$name"
  else fail "$name (want $want, rc $rc)" "$out"
  fi
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# new_env <stage services...>: an env dir whose one stage lists the services,
# excluding values.yaml from their directories (EXCLUDE overrides it; empty
# sets no directory option), each service directory holding one plain manifest.
new_env() {
  local dir s; dir=$(mktemp -d "$TMP/env.XXXX")
  mkdir -p "$dir/stages" "$dir/manifests" "$dir/kustomize"
  {
    echo "apiVersion: argoproj.io/v1alpha1"
    echo "kind: ApplicationSet"
    echo "spec:"
    echo "  template:"
    echo "    spec:"
    echo "      source:"
    echo "        path: 'gitops/k3han/manifests/{{service}}'"
    if [ -n "${EXCLUDE-values.yaml}" ]; then
      echo "        directory:"
      echo "          exclude: '${EXCLUDE-values.yaml}'"
    fi
    echo "  generators:"
    echo "    - list:"
    echo "        elements:"
    for s in "$@"; do echo "          - service: $s"; done
    [ $# -eq 0 ] && echo "          []"
  } > "$dir/stages/00-test.yaml"
  for s in "$@"; do
    mkdir -p "$dir/manifests/$s"
    printf 'apiVersion: v1\nkind: Namespace\nmetadata:\n  name: %s\n' "$s" > "$dir/manifests/$s/namespace.yaml"
  done
  echo "$dir"
}

KUSTOMIZATION='apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - namespace.yaml'

APPLICATION='apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: svc
  namespace: argocd
spec:
  project: chorde
  source:
    repoURL: https://github.com/SafeChord/Chorde.git
    targetRevision: main
    path: gitops/k3han/kustomize/svc
  destination:
    server: https://kubernetes.default.svc
    namespace: svc'

echo "== gitops/k3han"
expect "no stage directory holds a tool's source" pass "$REPO/gitops/k3han"

echo "== kustomizations"
d=$(new_env svc)
printf '%s\n' "$APPLICATION" > "$d/manifests/svc/application.yaml"
expect "plain manifests and an Application" pass "$d"

d=$(new_env svc)
printf '%s\n' "$KUSTOMIZATION" > "$d/manifests/svc/kustomization.yaml"
expect "kustomization.yaml in a stage directory" fail "$d" "svc/kustomization.yaml: a kustomization"

d=$(new_env svc)
printf '%s\n' "$KUSTOMIZATION" > "$d/manifests/svc/kustomization.yml"
expect "kustomization.yml in a stage directory" fail "$d" "svc/kustomization.yml: a kustomization"

d=$(new_env svc)
printf '%s\n' "$KUSTOMIZATION" > "$d/manifests/svc/Kustomization"
expect "Kustomization in a stage directory" fail "$d" "svc/Kustomization: a kustomization"

d=$(new_env svc)
mkdir -p "$d/manifests/svc/base"
printf '%s\n' "$KUSTOMIZATION" > "$d/manifests/svc/base/kustomization.yaml"
expect "a kustomization in a subdirectory of a stage directory" fail "$d" "svc/base/kustomization.yaml"

d=$(new_env svc)
printf '%s\n' "$KUSTOMIZATION" > "$d/manifests/svc/scan.yaml"
expect "a Kustomization document under another file name" fail "$d" "svc/scan.yaml: a Kustomization document"

d=$(new_env svc)
printf 'apiVersion: kustomize.config.k8s.io/v1alpha1\nkind: Component\n' > "$d/manifests/svc/component.yaml"
expect "a kustomize Component" fail "$d" "svc/component.yaml: a Component document"

d=$(EXCLUDE= new_env svc)
printf '%s\n' "$KUSTOMIZATION" > "$d/manifests/svc/kustomization.yaml"
expect "a stage that sets no directory option is checked too" fail "$d" "svc/kustomization.yaml"

d=$(new_env svc)
mkdir -p "$d/kustomize/svc"
printf '%s\n' "$KUSTOMIZATION" > "$d/kustomize/svc/kustomization.yaml"
printf '%s\n' "$APPLICATION" > "$d/manifests/svc/application.yaml"
expect "a kustomization outside the stage directories, its Application in one" pass "$d"

d=$(new_env svc)
mkdir -p "$d/manifests/unlisted"
printf '%s\n' "$KUSTOMIZATION" > "$d/manifests/unlisted/kustomization.yaml"
expect "a directory no stage lists is not checked" pass "$d"

echo "== other tools"
d=$(new_env svc)
mkdir -p "$d/manifests/svc/chart/templates"
printf 'apiVersion: v2\nname: svc\nversion: 0.1.0\n' > "$d/manifests/svc/chart/Chart.yaml"
expect "a Helm chart in a stage directory" fail "$d" "svc/chart/Chart.yaml: a Helm chart"

d=$(new_env svc)
mkdir -p "$d/manifests/svc/templates"
printf 'apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: {{ .Release.Name }}\n{{- if .Values.x }}\ndata: {}\n{{- end }}\n' > "$d/manifests/svc/templates/cm.yaml"
expect "a chart template in a stage directory" fail "$d" "svc/templates/cm.yaml: does not parse as YAML"

d=$(new_env svc)
printf '{ apiVersion: "v1", kind: "Namespace" }\n' > "$d/manifests/svc/ns.jsonnet"
expect "Jsonnet in a stage directory" fail "$d" "svc/ns.jsonnet: Jsonnet"

d=$(new_env svc)
printf 'controller:\n  replicas: 1\n' > "$d/manifests/svc/values-custom.yaml"
printf 'x: {{ broken\n' > "$d/manifests/svc/values.yaml"
expect "an overlay, and an excluded file that does not parse" pass "$d"

echo
echo "passed $PASS, failed $FAIL"
[ $FAIL -eq 0 ]
