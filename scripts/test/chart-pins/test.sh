#!/usr/bin/env bash
# Requirement tests for chart applications, chart defaults and image pins
# (Chorde#45, Chorde#77, Chorde#69).
#
# Runs check.py against gitops/k3han, then against small trees built in a temp
# directory, each breaking or keeping the rule one way, so the check is shown
# to catch what it guards.
#
#   scripts/test/chart-pins/test.sh
#   CHART_PINS_CLUSTER=1 scripts/test/chart-pins/test.sh   # also compares each
#                       pinned digest with the one K3han runs in the pin's
#                       namespace (kubectl, jq; Chorde#69)
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

# new_env <stage services...>: an env dir whose one stage lists the services.
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
    echo "  generators:"
    echo "    - list:"
    echo "        elements:"
    for s in "$@"; do echo "          - service: $s"; done
    [ $# -eq 0 ] && echo "          []"
  } > "$dir/stages/00-test.yaml"
  echo "$dir"
}

# wrap <env> <service> <chart> <version> <repository> <defaults-file> [overlay]:
# the service as Chorde deploys a chart: its Application in manifests/<service>,
# pointing at the wrapper in charts/<service>, which names the chart as its one
# dependency, holds the overlay (default: an empty one) under the chart's name
# and the defaults file as upstream-values.yaml.
wrap() {
  local env=$1 svc=$2 chart=$3 version=$4 repo=$5 defaults=$6
  local empty="$chart: {}"; local overlay=${7-$empty}
  mkdir -p "$env/manifests/$svc" "$env/charts/$svc"
  cat > "$env/manifests/$svc/application.yaml" <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: $svc
  namespace: argocd
spec:
  project: chorde
  source:
    repoURL: https://github.com/SafeChord/Chorde.git
    targetRevision: main
    path: gitops/k3han/charts/$svc
  destination:
    server: https://kubernetes.default.svc
    namespace: $svc
EOF
  cat > "$env/charts/$svc/Chart.yaml" <<EOF
apiVersion: v2
name: $svc
version: 0.0.0
dependencies:
  - name: $chart
    version: $version
    repository: $repo
EOF
  printf '%s\n' "$overlay" > "$env/charts/$svc/values.yaml"
  cp "$defaults" "$env/charts/$svc/upstream-values.yaml"
}

DIGEST=sha256:$(printf 'a%.0s' $(seq 64))

# A stand-in for helm on PATH: its first FAKE_HELM_FAILS runs print FAKE_HELM_ERR
# (%n: the run's number) and exit 1, after FAKE_HELM_SLEEP seconds if set; later
# runs print FAKE_HELM_OUT, by default the demo chart's defaults. FAKE_HELM_STATE
# counts the runs.
FAKEBIN="$TMP/fakebin"; mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/helm" <<'EOF'
#!/usr/bin/env bash
n=$(( $(cat "$FAKE_HELM_STATE" 2>/dev/null || echo 0) + 1 ))
echo "$n" > "$FAKE_HELM_STATE"
if [ "$n" -le "${FAKE_HELM_FAILS:-0}" ]; then sleep "${FAKE_HELM_SLEEP:-0}"; echo "Error: ${FAKE_HELM_ERR//%n/$n}" >&2; exit 1; fi
printf '%s\n' "${FAKE_HELM_OUT:-demo: true}"
EOF
chmod +x "$FAKEBIN/helm"
DEMO_DEFAULTS="$TMP/demo-defaults.yaml"; printf 'demo: true\n' > "$DEMO_DEFAULTS"
# fake <command...>: run it with the stand-in helm, serving the demo chart.
fake() { PATH="$FAKEBIN:$PATH" FAKE_HELM_STATE="$TMP/helm-runs.$RANDOM" "$@"; }
# demo_env [overlay]: an env deploying the demo chart as svc, through a wrapper.
demo_env() {
  local dir; dir=$(new_env svc)
  local empty='demo: {}'
  wrap "$dir" svc demo 1.0.0 https://charts.example.test "$DEMO_DEFAULTS" "${1-$empty}"
  echo "$dir"
}

echo "== gitops/k3han"
# Run from manifests/, where each chart name is also a directory name.
RUN_IN="$REPO/gitops/k3han/manifests" \
  expect "every chart is wrapped; every wrapper has its defaults; every own image is tag@digest" pass "$REPO/gitops/k3han"

echo "== chart version and values at one revision (Chorde#77)"
APP_OF() { echo "$1/manifests/svc/application.yaml"; }

d=$(demo_env)
fake expect "a chart in its wrapper, its Application pointing at it" pass "$d"

# The layout before Chorde#77: the overlay through a ref source at main, the
# version in the Application.
d=$(demo_env); rm "$d/manifests/svc/application.yaml"
cat > "$(APP_OF "$d")" <<'EOF'
apiVersion: argoproj.io/v1alpha1
kind: Application
spec:
  sources:
    - repoURL: https://github.com/SafeChord/Chorde.git
      targetRevision: main
      ref: chorde-repo
    - repoURL: https://charts.example.test
      chart: demo
      targetRevision: 1.0.0
      helm:
        valueFiles:
          - $chorde-repo/gitops/k3han/charts/svc/values.yaml
EOF
fake expect "a ref source carrying the overlay, the version in the Application" fail "$d" "source \`ref: chorde-repo\` reaches the application apart"
grep -qF "names chart demo 1.0.0 itself" <<<"$LAST_OUT" && ok "  ... and the upstream chart it names itself" || fail "  ... and the upstream chart it names itself" "$LAST_OUT"
grep -qF "helm.valueFiles carries values" <<<"$LAST_OUT" && ok "  ... and the values file it adds" || fail "  ... and the values file it adds" "$LAST_OUT"

d=$(demo_env)
cat > "$(APP_OF "$d")" <<'EOF'
apiVersion: argoproj.io/v1alpha1
kind: Application
spec:
  source:
    repoURL: https://charts.example.test
    chart: demo
    targetRevision: 1.0.0
    helm:
      valuesObject:
        demo: false
EOF
fake expect "the upstream chart with its values inline in the Application" fail "$d" "manifests/svc/application.yaml: names chart demo 1.0.0 itself"

for key in values valuesObject parameters fileParameters valueFiles; do
  d=$(demo_env)
  printf '    helm:\n      %s: {}\n' "$key" > "$TMP/helm-key"
  sed -i "/path: gitops\/k3han\/charts\/svc/r $TMP/helm-key" "$(APP_OF "$d")"
  fake expect "the wrapper with helm.$key in its Application" fail "$d" "helm.$key carries values apart"
done

d=$(demo_env)
printf '    helm:\n      releaseName: other\n' > "$TMP/helm-key"
sed -i "/path: gitops\/k3han\/charts\/svc/r $TMP/helm-key" "$(APP_OF "$d")"
fake expect "the wrapper with a helm option that carries no values" pass "$d"

d=$(demo_env)
wrap "$d" other demo 1.0.0 https://charts.example.test "$DEMO_DEFAULTS"
sed -i 's#charts/svc$#charts/other#' "$(APP_OF "$d")"
fake expect "an Application pointing at another service's wrapper" fail "$d" "is not this service's wrapper, charts/svc"

d=$(demo_env); rm -r "$d/charts/svc"
fake expect "an Application pointing at a wrapper that is not there" fail "$d" "holds no Chart.yaml"

d=$(demo_env); printf 'demo: {}\n' > "$d/manifests/svc/values-custom.yaml"
fake expect "an overlay left in the stage directory" fail "$d" "manifests/svc/values-custom.yaml: chart values in a directory 00-test.yaml renders"

d=$(demo_env); cp "$DEMO_DEFAULTS" "$d/manifests/svc/values.yaml"
fake expect "chart defaults left in the stage directory" fail "$d" "manifests/svc/values.yaml: chart values"

d=$(new_env); wrap "$d" svc demo 1.0.0 https://charts.example.test "$DEMO_DEFAULTS"
mv "$d/manifests/svc" "$d/manifests/argocd"
fake expect "argocd, applied outside the stages, is checked too" fail "$d" "manifests/argocd/application.yaml: source path gitops/k3han/charts/svc is not this service's wrapper"

d=$(new_env)
mkdir -p "$d/manifests/unlisted"
printf 'apiVersion: argoproj.io/v1alpha1\nkind: Application\nspec:\n  sources:\n    - ref: chorde-repo\n' > "$d/manifests/unlisted/application.yaml"
printf 'x: 1\n' > "$d/manifests/unlisted/values-custom.yaml"
fake expect "an Application no stage deploys is not checked" pass "$d"

echo "== wrapper charts"
d=$(demo_env); sed -i 's/version: 1.0.0/version: ^1.0.0/' "$d/charts/svc/Chart.yaml"
fake expect "a dependency version range" fail "$d" "charts/svc/Chart.yaml: dependency demo version \`^1.0.0\` is not an exact version"

d=$(demo_env); sed -i 's/version: 1.0.0/version: "1.0.x"/' "$d/charts/svc/Chart.yaml"
fake expect "a dependency version with a wildcard" fail "$d" "is not an exact version"

d=$(demo_env); printf '  - name: extra\n    version: 1.0.0\n    repository: https://charts.example.test\n' >> "$d/charts/svc/Chart.yaml"
fake expect "a wrapper with two dependencies" fail "$d" "charts/svc/Chart.yaml: declares 2 dependencies"

d=$(demo_env); printf 'apiVersion: v2\nname: svc\nversion: 0.0.0\n' > "$d/charts/svc/Chart.yaml"
fake expect "a wrapper with no dependency" fail "$d" "declares 0 dependencies"

d=$(demo_env); printf 'dependencies: []\n' > "$d/charts/svc/Chart.lock"
fake expect "a committed Chart.lock" fail "$d" "charts/svc/Chart.lock: pins the dependency apart from Chart.yaml"

d=$(demo_env); mkdir -p "$d/charts/svc/charts"; : > "$d/charts/svc/charts/demo-1.0.0.tgz"
fake expect "a committed charts/ directory" fail "$d" "charts/svc/charts: pins the dependency apart"

d=$(demo_env); rm "$d/charts/svc/Chart.yaml"
fake expect "a wrapper directory without Chart.yaml" fail "$d" "charts/svc: a wrapper directory without Chart.yaml"

d=$(demo_env "$(printf 'demo:\n  replicas: 2\nreplicas: 3\n')")
fake expect "an overlay key outside the chart's name, which helm ignores" fail "$d" "charts/svc/values.yaml: top-level key \`replicas\` reaches no chart"

d=$(demo_env "$(printf 'global:\n  imageRegistry: reg.example\ndemo:\n  replicas: 2\n')")
fake expect "an overlay with global values" pass "$d"

d=$(demo_env "$(printf 'd:\n  replicas: 2\n')"); sed -i 's/  - name: demo/  - name: demo\n    alias: d/' "$d/charts/svc/Chart.yaml"
fake expect "an overlay under the dependency's alias" pass "$d"

d=$(demo_env "$(printf 'demo:\n  replicas: 2\n')"); sed -i 's/  - name: demo/  - name: demo\n    alias: d/' "$d/charts/svc/Chart.yaml"
fake expect "an overlay under the name of an aliased dependency" fail "$d" "top-level key \`demo\` reaches no chart; values for demo go under \`d\`"

d=$(demo_env); rm "$d/charts/svc/values.yaml"
fake expect "a wrapper without values.yaml" fail "$d" "charts/svc/values.yaml: missing"

echo "== chart defaults"
# keda's defaults at two published releases whose defaults differ, read once through check.py, so
# the fixture rides out a passing outage as the check does.
keda_defaults() {
  python3 -B -c 'import sys; sys.path.insert(0, sys.argv[1]); from check import helm_show_values
out, err = helm_show_values(*sys.argv[2:]); sys.exit(err) if err else sys.stdout.write(out)' \
    "$HERE" https://kedacore.github.io/charts keda "$1" > "$TMP/keda-$1.yaml" \
    || fail "fixture: keda $1's defaults could not be read"
}
keda_defaults 2.17.1; keda_defaults 2.18.0
keda_env() { # keda_env <version> <defaults version>
  local dir; dir=$(new_env keda)
  wrap "$dir" keda keda "$1" https://kedacore.github.io/charts "$TMP/keda-$2.yaml"
  echo "$dir"
}

expect "keda 2.17.1 with its defaults" pass "$(keda_env 2.17.1 2.17.1)"

d=$(keda_env 2.17.1 2.17.1)
sed -i '0,/^[a-z]/s/^\([a-zA-Z]*\):/\1_edited:/' "$d/charts/keda/upstream-values.yaml"
expect "upstream-values.yaml edited by one line" fail "$d" "charts/keda/upstream-values.yaml: differs"

d=$(keda_env 2.17.1 2.17.1); rm "$d/charts/keda/upstream-values.yaml"
expect "a missing upstream-values.yaml" fail "$d" "charts/keda/upstream-values.yaml: missing"

expect "a version bump that keeps the old defaults" fail "$(keda_env 2.18.0 2.17.1)" "charts/keda/upstream-values.yaml: differs from keda 2.18.0"

d=$(new_env)
wrap "$d" keda keda 2.17.1 https://kedacore.github.io/charts "$TMP/keda-2.17.1.yaml"
rm "$d/charts/keda/upstream-values.yaml"
expect "a wrapper no stage deploys is checked too" fail "$d" "charts/keda/upstream-values.yaml: missing"

echo "== chart downloads that fail (Chorde#63)"
DEMO=$(demo_env)

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

printf 'demo: false\n' > "$DEMO/charts/svc/upstream-values.yaml"
flaky "504 once, then served, against a wrong values.yaml" 1 "$E504" fail "charts/svc/upstream-values.yaml: differs from demo 1.0.0 defaults"
printf 'demo: true\n' > "$DEMO/charts/svc/upstream-values.yaml"

WINDOW=2 flaky "504 on every run fails, naming the chart, its version and the last error" 999 "$E504" fail \
  "charts/svc/upstream-values.yaml: cannot read the chart's defaults: helm show values --repo https://charts.example.test demo --version 1.0.0: Error: failed to fetch $FETCH : 504 Gateway Timeout"
runs "  ... after more than one run" '[ "$RUNS" -gt 1 ]'
runs "  ... and the error it names is the last run's" 'grep -qF "(run $RUNS)" <<<"$LAST_OUT"'
runs "  ... within the 2 s window and one more run" 'awk -v t="$TOOK" "BEGIN { exit !(t < 4) }"'
WINDOW=1 FAKE_HELM_SLEEP=1.5 flaky "a run that hangs past the window is not run again" 999 "$ETIMEOUT" fail "Client.Timeout"
runs "  ... with one helm run" '[ "$RUNS" -eq 1 ]'
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

# overlay <yaml under the chart's key>: an env deploying the demo chart with that
# overlay, in its wrapper's values.yaml.
overlay() { demo_env "$(printf 'demo:\n  controller:\n    image:\n%s\n' "$1")"; }
fake expect "overlay image.tag with digest" pass "$(overlay "      repository: repo/app
      tag: v1.0
      digest: $DIGEST")"
fake expect "overlay image.tag with sha" pass "$(overlay "      repository: repo/app
      tag: v1.0
      sha: ${DIGEST#sha256:}")"
fake expect "overlay image.tag without digest" fail "$(overlay "      repository: repo/app
      tag: v1.0")" "charts/svc/values.yaml demo.controller.image.tag"
fake expect "overlay image.tag with an empty digest" fail "$(overlay "      repository: repo/app
      tag: v1.0
      digest: \"\"")" "demo.controller.image.tag"
fake expect "overlay image as one string, tag only" fail "$(demo_env "$(printf 'demo:\n  sidecar:\n    image: repo/app:1.0\n')")" "demo.sidecar.image"
fake expect "overlay image as one string, tag@digest" pass "$(demo_env "$(printf 'demo:\n  sidecar:\n    image: repo/app:1.0@%s\n' "$DIGEST")")"

expect "a kustomization's manifest under kustomize/, tag@digest" pass "$(TREE=kustomize img_env cronjob.yaml "$(deploy "repo/app:1.0@$DIGEST" "busybox:1.36@$DIGEST")")"
expect "a kustomization's manifest under kustomize/, tag only" fail "$(TREE=kustomize img_env cronjob.yaml "$(deploy repo/app:1.0 "busybox:1.36@$DIGEST")")" "kustomize/svc/cronjob.yaml"

d=$(demo_env)
deploy repo/app:1.0 busybox:1.36 > "$d/charts/svc/upstream-values.yaml"
FAKE_HELM_OUT=$(cat "$d/charts/svc/upstream-values.yaml") \
  fake expect "a chart's default upstream-values.yaml is not checked for pins" pass "$d"

echo "== rendered images (Chorde#53)"
# Every image a wrapper renders carries a digest, and a pin's tag is the one its
# chart's version renders by default. check.py --rendered renders each wrapper with
# helm template. The fixture is a local chart (a file:// dependency, as Helm and
# Argo CD read one), shaped after the charts K3han runs: a container image built
# from repository and tag, an image a controller is handed through env
# (cnpg's OPERATOR_IMAGE_NAME, strimzi's STRIMZI_DEFAULT_*_IMAGE) or a flag
# (kube-prometheus-stack's --prometheus-config-reloader=), an env var not named
# for one (strimzi's STRIMZI_DEFAULT_MAVEN_BUILDER), a resource holding
# repository and tag apart (NGF's NginxProxy), a hook Job, and an operand
# version map an operator reads (strimzi's STRIMZI_KAFKA_IMAGES), which is left
# to the operator by tag. Its helper's default tag is set in values.yaml and is
# not the chart's appVersion.
FIX="$TMP/fixture-chart"; mkdir -p "$FIX/templates"
cat > "$FIX/Chart.yaml" <<'EOF'
apiVersion: v2
name: fixture
version: 1.0.0
appVersion: 1.0.0
EOF
cat > "$FIX/values.yaml" <<'EOF'
image:
  repository: reg.example/app
  tag: ""
  digest: ""
helper:
  image:
    repository: reg.example/helper
    tag: 2.0.0
proxy:
  image:
    repository: reg.example/proxy
    tag: ""
job:
  image:
    repository: reg.example/job
    tag: 3.0.0
builder:
  image:
    repository: reg.example/builder
    tag: 5.0.0
operandImages: |
  4.0.0=reg.example/operand:1.0.0-4.0.0
EOF
cat > "$FIX/templates/_image.tpl" <<'EOF'
{{- define "fixture.image" -}}
{{ .repository }}:{{ .tag | default $.appVersion }}{{ with .digest }}@{{ . }}{{ end }}
{{- end -}}
{{- define "fixture.app" -}}
{{ include "fixture.image" (merge (dict "appVersion" .Chart.AppVersion) .Values.image) }}
{{- end -}}
EOF
cat > "$FIX/templates/deployment.yaml" <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: fixture
spec:
  template:
    spec:
      containers:
        - name: app
          image: {{ include "fixture.app" . }}
          args:
            - --config-reloader={{ .Values.helper.image.repository }}:{{ .Values.helper.image.tag }}
          env:
            - name: OPERATOR_IMAGE_NAME
              value: {{ include "fixture.app" . }}
            - name: BUILDER
              value: {{ .Values.builder.image.repository }}:{{ .Values.builder.image.tag }}
            - name: STRIMZI_KAFKA_IMAGES
              value: |
{{ .Values.operandImages | indent 16 }}
---
apiVersion: gateway.nginx.org/v1alpha2
kind: NginxProxy
metadata:
  name: fixture
spec:
  kubernetes:
    deployment:
      container:
        image:
          repository: {{ .Values.proxy.image.repository }}
          tag: {{ .Values.proxy.image.tag | default .Chart.AppVersion }}
---
apiVersion: batch/v1
kind: Job
metadata:
  name: fixture-hook
  annotations:
    helm.sh/hook: pre-install,pre-upgrade
spec:
  template:
    spec:
      containers:
        - name: job
          image: {{ .Values.job.image.repository }}:{{ .Values.job.image.tag }}
EOF
DEFAULTS_FIX="$FIX/values.yaml"

# fixture_env <overlay under `fixture:`>: an env deploying the fixture chart through
# a wrapper whose dependency is the local chart.
fixture_env() {
  local dir; dir=$(new_env svc)
  wrap "$dir" svc fixture 1.0.0 "file://$FIX" "$DEFAULTS_FIX" "$(printf 'fixture:\n%s\n' "$1")"
  echo "$dir"
}
# expect_rendered <name> pass|fail <env-dir> [pattern]: as expect, for --rendered.
expect_rendered() {
  local out rc; out=$(python3 "$CHECK" --rendered "$3" 2>&1); rc=$?; LAST_OUT=$out
  if [ "$2" = pass ] && [ $rc -eq 0 ]; then ok "$1"
  elif [ "$2" = fail ] && [ $rc -eq 1 ] && { [ -z "${4:-}" ] || grep -qF -- "$4" <<<"$out"; }; then ok "$1"
  else fail "$1 (want $2, rc $rc)" "$out"
  fi
}

APP="  image:
    tag: 1.0.0@$DIGEST"
HELPER="  helper:
    image:
      tag: 2.0.0@$DIGEST"
PROXY="  proxy:
    image:
      tag: 1.0.0@$DIGEST"
JOB="  job:
    image:
      tag: 3.0.0@$DIGEST
  builder:
    image:
      tag: 5.0.0@$DIGEST"

expect_rendered "every image the chart renders pinned at its default tag" pass "$(fixture_env "$APP
$HELPER
$PROXY
$JOB")"
expect_rendered "an image pinned through a digest key, its tag left to the chart" pass "$(fixture_env "  image:
    digest: $DIGEST
$HELPER
$PROXY
$JOB")"
expect_rendered "the container image and the env that hands it on, unpinned" fail "$(fixture_env "$HELPER
$PROXY
$JOB")" "Deployment/fixture spec.template.spec.containers.0.image renders reg.example/app:1.0.0 without a digest"
grep -qF "containers.0.env.0.value renders reg.example/app:1.0.0 without a digest" <<<"$LAST_OUT" \
  && ok "  ... and the env value" || fail "  ... and the env value" "$LAST_OUT"
expect_rendered "an image a flag hands on, unpinned" fail "$(fixture_env "$APP
$PROXY
$JOB")" "containers.0.args.0 renders reg.example/helper:2.0.0 without a digest"
expect_rendered "an image handed on through an env var not named for one, unpinned" fail "$(fixture_env "$APP
$HELPER
$PROXY
  job:
    image:
      tag: 3.0.0@$DIGEST")" "containers.0.env.1.value renders reg.example/builder:5.0.0 without a digest"
expect_rendered "an image held as repository and tag apart, unpinned" fail "$(fixture_env "$APP
$HELPER
$JOB")" "NginxProxy/fixture spec.kubernetes.deployment.container.image renders reg.example/proxy:1.0.0 without a digest"
expect_rendered "a hook Job's image, unpinned" fail "$(fixture_env "$APP
$HELPER
$PROXY")" "Job/fixture-hook spec.template.spec.containers.0.image renders reg.example/job:3.0.0 without a digest"
grep -qF "reg.example/operand" <<<"$LAST_OUT" \
  && fail "  ... and the operand version map is left to its operator" "$LAST_OUT" \
  || ok "  ... and the operand version map is left to its operator"

expect_rendered "a pin whose tag is not the chart's default" fail "$(fixture_env "  image:
    tag: 1.0.1@$DIGEST
$HELPER
$PROXY
$JOB")" "renders reg.example/app:1.0.1@$DIGEST from its pin; fixture 1.0.0 renders reg.example/app:1.0.0 there by default"
expect_rendered "a pin whose tag is the appVersion where the chart's default is another tag" fail "$(fixture_env "$APP
  helper:
    image:
      tag: 1.0.0@$DIGEST
$PROXY
$JOB")" "renders reg.example/helper:1.0.0@$DIGEST from its pin; fixture 1.0.0 renders reg.example/helper:2.0.0 there by default"
expect_rendered "a pin held as repository and tag apart, at another tag" fail "$(fixture_env "$APP
$HELPER
  proxy:
    image:
      tag: 0.9.0@$DIGEST
$JOB")" "NginxProxy/fixture spec.kubernetes.deployment.container.image renders reg.example/proxy:0.9.0@$DIGEST from its pin"

d=$(fixture_env "$APP
$HELPER
$PROXY
$JOB"); sed -i "s#file://$FIX#file://$TMP/no-such-chart#" "$d/charts/svc/Chart.yaml"
expect_rendered "a wrapper that cannot be rendered" fail "$d" "charts/svc: cannot render the wrapper"

expect_rendered "gitops/k3han: every rendered image pinned at its chart's default tag" pass "$REPO/gitops/k3han"

if [ "${CHART_PINS_CLUSTER:-}" = 1 ]; then
  echo "== K3han runs the pinned digests (Chorde#69)"
  # Each self-pinned image, a tag-only pin in a wrapper as its chart renders it,
  # must run at the pinned digest in the namespace its service deploys to; what
  # another owner runs elsewhere does not count. An image no pod there runs (a
  # Job image between runs) is listed, not compared.
  running=$(kubectl get pods -A -o json | jq -r '.items[] | .metadata.namespace as $ns | .status
    | ((.containerStatuses // []) + (.initContainerStatuses // []))[] | "\($ns)\t\(.imageID)"' | sort -u)
  norm() { # docker.io/library/x, docker.io/x and x name the same repository
    sed -E 's#^docker\.io/##; s#^library/##' <<<"$1"
  }
  # compare_cluster <env-dir>: one ok, FAIL or -- line per pin of the env.
  compare_cluster() {
    local pins rc ref where ns repo digest seen
    pins=$(python3 "$CHECK" --list-pins "$1" 2>&1); rc=$?
    if [ $rc -ne 0 ]; then fail "check.py --list-pins $1 (rc $rc)" "$pins"; return; fi
    while IFS=$'\t' read -r ref where ns; do
      repo=$(norm "${ref%%@*}"); repo=${repo%:*}
      digest=${ref##*@}
      if [ -z "$ns" ]; then
        fail "$where: names no namespace its image runs in"; continue
      elif [ -z "$repo" ]; then
        echo "  --   $where: renders into no image of its chart; not compared"; continue
      fi
      seen=$(while IFS=$'\t' read -r pod_ns id; do
        [ "$pod_ns" = "$ns" ] && [ "$(norm "${id%%@*}")" = "$repo" ] && echo "${id##*@}"
      done <<<"$running" | sort -u)
      if [ -z "$seen" ]; then
        echo "  --   $where: $repo runs nowhere in $ns; not compared"
      elif [ "$seen" = "$digest" ]; then
        ok "$where runs $repo@$digest in $ns"
      else
        fail "$where pins $digest" "running in $ns: $(tr '\n' ' ' <<<"$seen")"
      fi
    done <<<"$pins"
  }
  K3HAN_PINS=$(compare_cluster "$REPO/gitops/k3han"); echo "$K3HAN_PINS"
  PASS=$((PASS + $(grep -c '^  ok ' <<<"$K3HAN_PINS"))); FAIL=$((FAIL + $(grep -c '^  FAIL ' <<<"$K3HAN_PINS")))
  # A pin set through a chart's digest key alone, and one its chart renders as
  # repository and tag apart, are compared too (Chorde#53).
  for where in "charts/prometheus/values.yaml kube-prometheus-stack.prometheus.prometheusSpec.image" \
               "charts/nginx-gateway-fabric/values.yaml nginx-gateway-fabric.nginx.image"; do
    grep -qF "  ok   $where runs " <<<"$K3HAN_PINS" && ok "  ... $where is compared" \
      || fail "  ... $where is compared" "$(grep -F "$where" <<<"$K3HAN_PINS")"
  done

  echo "== the comparison catches what it guards (Chorde#69)"
  # cluster_case <name> <sed expression> <file under gitops/k3han> <pattern>: a copy of
  # gitops/k3han with the file edited must fail with a line holding the pattern.
  cluster_case() {
    local d out; d=$(mktemp -d "$TMP/k3han.XXXX"); cp -r "$REPO/gitops/k3han/." "$d"
    sed -i "$2" "$d/$3"
    out=$( (FAIL=0; compare_cluster "$d"; exit $((FAIL > 0))) ); local rc=$?
    if [ $rc -eq 1 ] && grep -qF -- "$4" <<<"$out"; then ok "$1"; else fail "$1 (rc $rc)" "$out"; fi
  }
  OTHER=sha256:$(printf '0%.0s' $(seq 64))
  # A bare digest of digits alone reads as a YAML integer; a sha key takes letters.
  OTHER_HEX=sha256:$(printf 'b%.0s' $(seq 64))
  cluster_case "a tag-only pin whose digest K3han does not run" \
    "/^  loki:/,/^  [a-z]/s/\(tag: 3\.7\.9@\)sha256:[0-9a-f]*/\1$OTHER/" charts/loki/values.yaml \
    "FAIL charts/loki/values.yaml loki.loki.image pins $OTHER"
  cluster_case "a pin compared in a namespace that runs another digest of its repository" \
    "0,/namespace: redis/s//namespace: safezone/" manifests/valkey/statefulset.yaml \
    "FAIL manifests/valkey/statefulset.yaml spec.template.spec.containers.0.image pins"
  cluster_case "a pin through a digest key whose digest K3han does not run" \
    "/^    prometheusSpec:/,/^    [a-z]/s/\(sha: \)[0-9a-f]\{64\}/\1${OTHER_HEX#sha256:}/" charts/prometheus/values.yaml \
    "FAIL charts/prometheus/values.yaml kube-prometheus-stack.prometheus.prometheusSpec.image pins $OTHER_HEX"
  cluster_case "a pin held as repository and tag apart whose digest K3han does not run" \
    "/^  nginx:/,\$s/\(tag: 2\.8\.1@\)sha256:[0-9a-f]*/\1$OTHER/" charts/nginx-gateway-fabric/values.yaml \
    "FAIL charts/nginx-gateway-fabric/values.yaml nginx-gateway-fabric.nginx.image pins $OTHER"
fi

echo
echo "passed $PASS, failed $FAIL"
[ $FAIL -eq 0 ]
