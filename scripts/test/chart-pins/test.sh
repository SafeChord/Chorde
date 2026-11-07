#!/usr/bin/env bash
# Requirement tests for chart defaults and image pins (Chorde#45).
#
# Runs check.py against gitops/k3han, then against small trees built in a temp
# directory, each breaking or keeping the rule one way, so the check is shown
# to catch what it guards.
#
#   scripts/test/chart-pins/test.sh
#   CHART_PINS_CLUSTER=1 scripts/test/chart-pins/test.sh   # also compares each
#                       pinned digest with the one K3han runs (kubectl, jq)
#
# Needs: bash, python3 with PyYAML, helm with network access to the keda chart
# repository and to every chart gitops/k3han deploys.
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

# new_env <stage services...>: an env dir whose one stage lists the services.
new_env() {
  local dir; dir=$(mktemp -d "$TMP/env.XXXX")
  mkdir -p "$dir/stages" "$dir/manifests"
  {
    echo "apiVersion: argoproj.io/v1alpha1"
    echo "kind: ApplicationSet"
    echo "spec:"
    echo "  generators:"
    echo "    - list:"
    echo "        elements:"
    for s in "$@"; do echo "          - service: $s"; done
    [ $# -eq 0 ] && echo "          []"
  } > "$dir/stages/00-test.yaml"
  echo "$dir"
}

DIGEST=sha256:$(printf 'a%.0s' $(seq 64))

echo "== gitops/k3han"
expect "every deployed chart has its defaults; every own image is tag@digest" pass "$REPO/gitops/k3han"

echo "== chart defaults"
KEDA="$REPO/gitops/k3han/manifests/keda"
keda_env() { # keda_env <stage services...>: an env holding a copy of keda
  local dir; dir=$(new_env "$@")
  cp -r "$KEDA" "$dir/manifests/keda"
  echo "$dir"
}

d=$(keda_env keda)
expect "keda as committed" pass "$d"

d=$(keda_env keda)
sed -i '0,/^[a-z]/s/^\([a-zA-Z]*\):/\1_edited:/' "$d/manifests/keda/values.yaml"
expect "a default values.yaml edited by one line" fail "$d" "keda/values.yaml: differs"

d=$(keda_env keda)
rm "$d/manifests/keda/values.yaml"
expect "a missing default values.yaml" fail "$d" "keda/values.yaml: missing"

d=$(keda_env keda)
sed -i 's/targetRevision: 2\.17\.2/targetRevision: 2.17.1/' "$d/manifests/keda/application.yaml"
grep -q 'targetRevision: 2.17.1' "$d/manifests/keda/application.yaml" || fail "fixture: keda is no longer at 2.17.2"
expect "a version bump that keeps the old defaults" fail "$d" "keda/values.yaml: differs from keda 2.17.1"

helm show values --repo https://kedacore.github.io/charts keda --version 2.17.1 > "$d/manifests/keda/values.yaml"
expect "a version bump that regenerates the defaults" pass "$d"

d=$(keda_env)
rm "$d/manifests/keda/values.yaml"
expect "a chart application no stage deploys is not checked" pass "$d"

echo "== image pins"
# img_env <file> <yaml>: an env with no chart application and one manifest.
img_env() {
  local dir; dir=$(new_env)
  mkdir -p "$dir/manifests/svc"
  printf '%s\n' "$2" > "$dir/manifests/svc/$1"
  echo "$dir"
}

deploy() {
  cat <<EOF
apiVersion: apps/v1
kind: Deployment
spec:
  template:
    spec:
      initContainers:
        - name: init
          image: $2
      containers:
        - name: app
          image: $1
EOF
}

expect "Deployment image tag@digest" pass "$(img_env d.yaml "$(deploy "repo/app:1.0@$DIGEST" "busybox:1.36@$DIGEST")")"
expect "Deployment image tag only" fail "$(img_env d.yaml "$(deploy repo/app:1.0 "busybox:1.36@$DIGEST")")" "svc/d.yaml spec.template.spec.containers.0.image"
expect "init container image tag only" fail "$(img_env d.yaml "$(deploy "repo/app:1.0@$DIGEST" busybox:1.36)")" "initContainers.0.image"
expect "Deployment image digest without tag" fail "$(img_env d.yaml "$(deploy "repo/app@$DIGEST" "busybox:1.36@$DIGEST")")" "repo/app@"
expect "Deployment image with registry port, tag only" fail "$(img_env d.yaml "$(deploy reg:5000/app:1.0 "busybox:1.36@$DIGEST")")" "reg:5000/app:1.0"
expect "Deployment image with registry port, no tag, digest" fail "$(img_env d.yaml "$(deploy "reg:5000/app@$DIGEST" "busybox:1.36@$DIGEST")")" "reg:5000/app@"

cnpg() { printf 'apiVersion: postgresql.cnpg.io/v1\nkind: Cluster\nspec:\n  imageName: %s\n' "$1"; }
expect "CNPG imageName tag@digest" pass "$(img_env c.yaml "$(cnpg "ghcr.io/cloudnative-pg/postgresql:17.7@$DIGEST")")"
expect "CNPG imageName tag only" fail "$(img_env c.yaml "$(cnpg ghcr.io/cloudnative-pg/postgresql:17.7)")" "spec.imageName"

cm() { printf 'apiVersion: v1\nkind: ConfigMap\ndata:\n  SYSTEM_UPGRADE_JOB_KUBECTL_IMAGE: %s\n' "$1"; }
expect "ConfigMap *_IMAGE tag@digest" pass "$(img_env cm.yaml "$(cm "rancher/kubectl:v1.30.3@$DIGEST")")"
expect "ConfigMap *_IMAGE tag only" fail "$(img_env cm.yaml "$(cm rancher/kubectl:v1.30.3)")" "data.SYSTEM_UPGRADE_JOB_KUBECTL_IMAGE"

two_docs="$(deploy "repo/app:1.0@$DIGEST" "busybox:1.36@$DIGEST")
---
$(deploy repo/second:2.0 "busybox:1.36@$DIGEST")"
expect "the second document of a file, tag only" fail "$(img_env d.yaml "$two_docs")" "repo/second:2.0"

plan() { printf 'apiVersion: upgrade.cattle.io/v1\nkind: Plan\nspec:\n  upgrade:\n    image: %s\n  version: v1.34.3+k3s1\n' "$1"; }
expect "Plan image name only (the controller adds spec.version)" pass "$(img_env p.yaml "$(plan rancher/k3s-upgrade)")"
expect "Plan image tag only" fail "$(img_env p.yaml "$(plan rancher/k3s-upgrade:v1.34.3-k3s1)")" "spec.upgrade.image"
expect "Deployment image name only" fail "$(img_env d.yaml "$(deploy repo/app "busybox:1.36@$DIGEST")")" "repo/app\`"

overlay() { printf 'controller:\n  image:\n%s\n' "$1"; }
expect "overlay image.tag with digest" pass "$(img_env values-custom.yaml "$(overlay "    repository: repo/app
    tag: v1.0
    digest: $DIGEST")")"
expect "overlay image.tag with sha" pass "$(img_env values-custom.yaml "$(overlay "    repository: repo/app
    tag: v1.0
    sha: ${DIGEST#sha256:}")")"
expect "overlay image.tag without digest" fail "$(img_env values-custom.yaml "$(overlay "    repository: repo/app
    tag: v1.0")")" "controller.image.tag"
expect "overlay image.tag with an empty digest" fail "$(img_env values-custom.yaml "$(overlay "    repository: repo/app
    tag: v1.0
    digest: \"\"")")" "controller.image.tag"
expect "overlay image as one string, tag only" fail "$(img_env values-custom.yaml "$(printf 'sidecar:\n  image: repo/app:1.0\n')")" "sidecar.image"
expect "overlay image as one string, tag@digest" pass "$(img_env values-custom.yaml "$(printf 'sidecar:\n  image: repo/app:1.0@%s\n' "$DIGEST")")"

d=$(img_env values.yaml "$(deploy repo/app:1.0 busybox:1.36)")
expect "a chart's default values.yaml is not checked for pins" pass "$d"

if [ "${CHART_PINS_CLUSTER:-}" = 1 ]; then
  echo "== K3han runs the pinned digests"
  # Each self-pinned image whose repository runs must run at the pinned digest.
  # An image no pod runs (a Job image between runs) is listed, not compared.
  running=$(kubectl get pods -A -o json | jq -r '.items[].status
    | ((.containerStatuses // []) + (.initContainerStatuses // []))[] | .imageID' | sort -u)
  norm() { # docker.io/library/x, docker.io/x and x name the same repository
    sed -E 's#^docker\.io/##; s#^library/##' <<<"$1"
  }
  while IFS=$'\t' read -r ref where; do
    repo=$(norm "${ref%%@*}"); repo=${repo%:*}
    digest=${ref##*@}
    seen=$(while read -r id; do [ "$(norm "${id%%@*}")" = "$repo" ] && echo "${id##*@}"; done <<<"$running" | sort -u)
    if [ -z "$seen" ]; then
      echo "  --   $where: $repo runs nowhere; not compared"
    elif [ "$seen" = "$digest" ]; then
      ok "$where runs $repo@$digest"
    else
      fail "$where pins $digest" "running: $(tr '\n' ' ' <<<"$seen")"
    fi
  done < <(python3 "$CHECK" --list-pins "$REPO/gitops/k3han")
fi

echo
echo "passed $PASS, failed $FAIL"
[ $FAIL -eq 0 ]
