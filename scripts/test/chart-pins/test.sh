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
  out=$(cd "${RUN_IN:-.}" && python3 "$CHECK" "$dir" 2>&1); rc=$?; LAST_OUT=$out
  if [ "$want" = pass ] && [ $rc -eq 0 ]; then ok "$name"
  elif [ "$want" = fail ] && [ $rc -eq 1 ] && { [ -z "$pattern" ] || grep -qF -- "$pattern" <<<"$out"; }; then ok "$name"
  else fail "$name (want $want, rc $rc)" "$out"
  fi
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# new_env <stage services...>: an env dir whose one stage lists the services
# and excludes values.yaml from their directories (EXCLUDE overrides it).
new_env() {
  local dir; dir=$(mktemp -d "$TMP/env.XXXX")
  mkdir -p "$dir/stages" "$dir/manifests"
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
  echo "$dir"
}

DIGEST=sha256:$(printf 'a%.0s' $(seq 64))

echo "== gitops/k3han"
# Run from manifests/, where each chart name is also a directory name.
RUN_IN="$REPO/gitops/k3han/manifests" \
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
# Move keda to another published release, whatever release it pins now.
KEDA_AT=$(awk '/chart: keda/ {c=1; next} c && /targetRevision:/ {print $2; exit}' "$KEDA/application.yaml")
KEDA_TO=2.17.1; [ "$KEDA_AT" = "$KEDA_TO" ] && KEDA_TO=2.17.0
sed -i "s/targetRevision: ${KEDA_AT//./\\.}\$/targetRevision: $KEDA_TO/" "$d/manifests/keda/application.yaml"
grep -q "targetRevision: $KEDA_TO\$" "$d/manifests/keda/application.yaml" || fail "fixture: keda's chart version ($KEDA_AT) was not found to move"
expect "a version bump that keeps the old defaults" fail "$d" "keda/values.yaml: differs from keda $KEDA_TO"

# Through check.py, so the fixture rides out a passing outage as the check does.
python3 -B -c 'import sys; sys.path.insert(0, sys.argv[1]); from check import helm_show_values
out, err = helm_show_values(*sys.argv[2:]); sys.exit(err) if err else sys.stdout.write(out)' \
  "$HERE" https://kedacore.github.io/charts keda "$KEDA_TO" > "$d/manifests/keda/values.yaml" \
  || fail "fixture: keda $KEDA_TO's defaults could not be read"
expect "a version bump that regenerates the defaults" pass "$d"

d=$(keda_env)
rm "$d/manifests/keda/values.yaml"
expect "a chart application no stage deploys is not checked" pass "$d"

d=$(new_env)
cp -r "$KEDA" "$d/manifests/argocd"
rm "$d/manifests/argocd/values.yaml"
expect "argocd, applied outside the stages, is checked too" fail "$d" "argocd/values.yaml: missing"

d=$(EXCLUDE= keda_env keda)
expect "a stage that renders values.yaml as a manifest" fail "$d" "keda/values.yaml: rendered as a manifest"

d=$(EXCLUDE='{values.yaml,README.md}' keda_env keda)
expect "a stage that excludes values.yaml among others" pass "$d"

d=$(EXCLUDE='*/values.yaml' keda_env keda)
expect "a stage whose exclude misses values.yaml at the directory root" fail "$d" "rendered as a manifest"

echo "== chart downloads that fail (Chorde#63)"
# A stand-in for helm on PATH: its first FAKE_HELM_FAILS runs print FAKE_HELM_ERR
# (%n: the run's number) and exit 1, later runs print the demo chart's defaults.
# FAKE_HELM_STATE counts the runs.
FAKEBIN="$TMP/fakebin"; mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/helm" <<'EOF'
#!/usr/bin/env bash
n=$(( $(cat "$FAKE_HELM_STATE" 2>/dev/null || echo 0) + 1 ))
echo "$n" > "$FAKE_HELM_STATE"
if [ "$n" -le "${FAKE_HELM_FAILS:-0}" ]; then echo "Error: ${FAKE_HELM_ERR//%n/$n}" >&2; exit 1; fi
printf 'demo: true\n'
EOF
chmod +x "$FAKEBIN/helm"

DEMO=$(new_env demo)
mkdir -p "$DEMO/manifests/demo"
cat > "$DEMO/manifests/demo/application.yaml" <<'EOF'
apiVersion: argoproj.io/v1alpha1
kind: Application
spec:
  sources:
    - repoURL: https://charts.example.test
      chart: demo
      targetRevision: 1.0.0
EOF
printf 'demo: true\n' > "$DEMO/manifests/demo/values.yaml"

FETCH=https://github.com/example/charts/releases/download/demo-1.0.0/demo-1.0.0.tgz
E504="failed to fetch $FETCH : 504 Gateway Timeout (run %n)"
E503_OCI='failed to perform "FetchReference" on source: GET "https://ghcr.io/v2/example/charts/demo/manifests/1.0.0": response status code 503: Service Unavailable'
E429="failed to fetch $FETCH : 429 Too Many Requests"
EREFUSED='looks like "https://charts.example.test" is not a valid chart repository or cannot be reached: Get "https://charts.example.test/index.yaml": dial tcp 192.0.2.1:443: connect: connection refused'
ETIMEOUT='looks like "https://charts.example.test" is not a valid chart repository or cannot be reached: Get "https://charts.example.test/index.yaml": context deadline exceeded (Client.Timeout exceeded while awaiting headers)'
ENOTFOUND='chart "demo" version "1.0.0" not found in https://charts.example.test repository'
E404='looks like "https://charts.example.test" is not a valid chart repository or cannot be reached: failed to fetch https://charts.example.test/index.yaml : 404 Not Found'

# flaky <name> <fails> <error> pass|fail [pattern]: check the demo env with the
# stand-in helm, failing <fails> times with <error>. Retries wait 0.1 s, doubling,
# for up to WINDOW (default 3) seconds. Sets RUNS to how often helm ran, and
# TOOK to the check's wall time in seconds.
flaky() {
  local state start; state="$TMP/helm-runs.$RANDOM"; start=$(date +%s.%N)
  PATH="$FAKEBIN:$PATH" FAKE_HELM_STATE=$state FAKE_HELM_FAILS=$2 FAKE_HELM_ERR=$3 \
    CHART_PINS_RETRY_WINDOW=${WINDOW:-3} CHART_PINS_RETRY_FIRST_WAIT=0.1 \
    expect "$1" "$4" "$DEMO" "${5:-}"
  RUNS=$(cat "$state" 2>/dev/null || echo 0)
  TOOK=$(awk -v a="$start" -v b="$(date +%s.%N)" 'BEGIN { printf "%.1f", b - a }')
}
runs() { # runs <name> <test expression on $RUNS, $TOOK, $LAST_OUT>
  if eval "$2"; then ok "$1"; else fail "$1 (helm ran $RUNS times in ${TOOK}s)" "$LAST_OUT"; fi
}

flaky "the demo chart, served at once" 0 "" pass
runs "  ... read with one helm run" '[ "$RUNS" -eq 1 ]'
flaky "504 twice, then served: compared as usual" 2 "$E504" pass
runs "  ... read on the third run" '[ "$RUNS" -eq 3 ]'
flaky "an OCI registry's 503, then served" 1 "$E503_OCI" pass
flaky "429, then served" 1 "$E429" pass
flaky "connection refused, then served" 1 "$EREFUSED" pass
flaky "a client timeout, then served" 1 "$ETIMEOUT" pass

printf 'demo: false\n' > "$DEMO/manifests/demo/values.yaml"
flaky "504 once, then served, against a wrong values.yaml" 1 "$E504" fail "demo/values.yaml: differs from demo 1.0.0 defaults"
printf 'demo: true\n' > "$DEMO/manifests/demo/values.yaml"

WINDOW=2 flaky "504 on every run fails, naming the chart, its version and the last error" 999 "$E504" fail \
  "demo/values.yaml: cannot read the chart's defaults: helm show values --repo https://charts.example.test demo --version 1.0.0: Error: failed to fetch $FETCH : 504 Gateway Timeout"
runs "  ... after more than one run" '[ "$RUNS" -gt 1 ]'
runs "  ... and the error it names is the last run's" 'grep -qF "(run $RUNS)" <<<"$LAST_OUT"'
runs "  ... within the 2 s window and one more run" 'awk -v t="$TOOK" "BEGIN { exit !(t < 4) }"'
flaky "a chart version the repository does not hold fails at once" 999 "$ENOTFOUND" fail "version \"1.0.0\" not found"
runs "  ... with one helm run" '[ "$RUNS" -eq 1 ]'
flaky "a repository that answers 404 fails at once" 999 "$E404" fail "404 Not Found"
runs "  ... with one helm run" '[ "$RUNS" -eq 1 ]'

echo "== image pins"
# img_env <file> <yaml>: an env with no chart application and one manifest.
# TREE=kustomize puts it under kustomize/ instead of manifests/.
img_env() {
  local dir; dir=$(new_env)
  mkdir -p "$dir/${TREE:-manifests}/svc"
  printf '%s\n' "$2" > "$dir/${TREE:-manifests}/svc/$1"
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

expect "a kustomization's manifest under kustomize/, tag@digest" pass "$(TREE=kustomize img_env cronjob.yaml "$(deploy "repo/app:1.0@$DIGEST" "busybox:1.36@$DIGEST")")"
expect "a kustomization's manifest under kustomize/, tag only" fail "$(TREE=kustomize img_env cronjob.yaml "$(deploy repo/app:1.0 "busybox:1.36@$DIGEST")")" "../kustomize/svc/cronjob.yaml"

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
