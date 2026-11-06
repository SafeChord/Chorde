#!/usr/bin/env bash
# Requirement tests for the vuln-scan CronJob (Chorde#40).
#
# Runs gitops/k3han/manifests/vuln-scan/scan.sh against stubbed trivy and curl,
# fed with real trivy output trimmed into fixtures/, and checks the rendered
# manifests with `kubectl kustomize`.
#
#   scripts/test/vuln-scan/test.sh            # stubbed, no network
#   VULN_SCAN_IT=1 scripts/test/vuln-scan/test.sh   # also runs the real trivy (network)
#
# Needs: bash, jq, openssl, gzip, base64, kubectl (for kustomize).
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../../.." && pwd)
MANIFESTS="$REPO/gitops/k3han/manifests/vuln-scan"
FIX="$HERE/fixtures"

PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); echo "  ok   $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL $1"; [ $# -gt 1 ] && echo "       $2"; }
check() { # check <name> <command...>
  local name=$1; shift
  if "$@"; then ok "$name"; else fail "$name"; fi
}

# ---------------------------------------------------------------------------
# Stubs
# ---------------------------------------------------------------------------
# Each case runs in a fresh directory. The stubs read their behaviour from
# environment variables and record what they were asked in $STUB_DIR.

new_case() {
  CASE=$(mktemp -d)
  export STUB_DIR="$CASE/stub"
  mkdir -p "$STUB_DIR" "$CASE/bin" "$CASE/sa" "$CASE/app" "$CASE/work"
  echo "sa-token" > "$CASE/sa/token"
  echo "ca" > "$CASE/sa/ca.crt"
  echo "12345" > "$CASE/app/app-id"
  echo "178044532" > "$CASE/app/installation-id"
  openssl genrsa -out "$CASE/app/private-key" 2048 2>/dev/null

  cat > "$CASE/bin/trivy" <<'EOF'
#!/usr/bin/env bash
# trivy stub. `image --download-db-only` exits STUB_DB_RC. `image ... -o OUT REF`
# picks a fixture by the first STUB_MAP pattern REF contains ("pattern=fixture",
# space separated; fixture FAIL exits 1 the way an unpullable image does).
# `convert --format sarif -o OUT IN` copies the SARIF of the fixture IN came from.
echo "$*" >> "$STUB_DIR/trivy.calls"
cmd=$1; shift
out=""; last=""
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  case ${args[$i]} in
    -o|--output) out=${args[$((i + 1))]} ;;
  esac
  last=${args[$i]}
done
case $cmd in
  image)
    for a in "$@"; do
      if [ "$a" = "--download-db-only" ]; then exit "${STUB_DB_RC:-0}"; fi
    done
    fixture=clean
    for pair in ${STUB_MAP:-}; do
      case $last in *"${pair%%=*}"*) fixture=${pair#*=}; break ;; esac
    done
    if [ "$fixture" = FAIL ]; then
      echo "FATAL unable to pull $last" >&2
      exit 1
    fi
    cp "$FIX/$fixture.json" "$out"
    echo "$fixture" > "$out.fixture"
    ;;
  convert)
    fixture=$(cat "$last.fixture")
    cp "$FIX/$fixture.sarif" "$out"
    ;;
  *) echo "trivy stub: unexpected $cmd" >&2; exit 2 ;;
esac
EOF

  cat > "$CASE/bin/curl" <<'EOF'
#!/usr/bin/env bash
# curl stub, dispatching on the URL. Honours -o, -d @file, --data-binary @file
# and -f (an HTTP error then exits 22, as curl does).
echo "$*" >> "$STUB_DIR/curl.calls"
url=""; out=""; body=""; method=GET; failflag=0
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  a=${args[$i]}
  case $a in
    -o) out=${args[$((i + 1))]} ;;
    -X) method=${args[$((i + 1))]} ;;
    -d|--data|--data-binary) body=${args[$((i + 1))]}; [ "$method" = GET ] && method=POST ;;
    -f|--fail|-sf|-fs|-sSf|-fsS|-sfS|-Sf|-fS) failflag=1 ;;
    http://*|https://*) url=$a ;;
  esac
done
respond() { # respond <http status> <body>
  if [ "$1" -ge 400 ]; then
    [ $failflag = 1 ] && { echo "curl: (22) The requested URL returned error: $1" >&2; exit 22; }
  fi
  if [ -n "$out" ]; then printf '%s' "$2" > "$out"; else printf '%s' "$2"; fi
}
case $url in
  */api/v1/pods*)
    [ -n "${STUB_PODS_HTTP:-}" ] && respond "$STUB_PODS_HTTP" '{"kind":"Status"}'
    respond 200 "$(cat "${STUB_PODS:-$FIX/pods.json}")" ;;
  */app/installations/*/access_tokens)
    respond 201 '{"token":"ghs_stub","expires_at":"2099-01-01T00:00:00Z"}' ;;
  */commits/main)
    respond 200 '{"sha":"0123456789abcdef0123456789abcdef01234567"}' ;;
  */code-scanning/sarifs)
    case $body in @*) cp "${body#@}" "$STUB_DIR/upload.json" ;; *) printf '%s' "$body" > "$STUB_DIR/upload.json" ;; esac
    respond "${STUB_UPLOAD_HTTP:-202}" '{"id":"sarif-1","url":"https://api.github.com/x"}' ;;
  */code-scanning/sarifs/*)
    n=$(cat "$STUB_DIR/polls" 2>/dev/null || echo 0); echo $((n + 1)) > "$STUB_DIR/polls"
    if [ "$n" -lt "${STUB_PENDING_POLLS:-1}" ]; then
      respond 200 '{"processing_status":"pending"}'
    else
      respond 200 "{\"processing_status\":\"${STUB_STATUS:-complete}\",\"errors\":${STUB_ERRORS:-null}}"
    fi ;;
  *) echo "curl stub: unexpected URL $url" >&2; exit 7 ;;
esac
EOF
  chmod +x "$CASE/bin/trivy" "$CASE/bin/curl"
}

run_scan() {
  (
    export PATH="$CASE/bin:$PATH" STUB_DIR FIX
    export VULN_SCAN_HOME="$MANIFESTS"
    export WORK_DIR="$CASE/work"
    export SA_DIR="$CASE/sa"
    export APP_DIR="$CASE/app"
    # The VEX statements are sealed in the cluster (Chorde#43); the scan reads
    # whatever file VEX_FILE names, here one with no statement.
    export VEX_FILE="$FIX/empty.openvex.json"
    export KUBE_API="https://kube.test"
    export GITHUB_API="https://api.github.test"
    export POLL_INTERVAL=0
    sh "$MANIFESTS/scan.sh"
  ) > "$CASE/out.log" 2>&1
  RC=$?
}

uploaded_sarif() { jq -r .sarif "$STUB_DIR/upload.json" | base64 -d | gunzip; }
export -f uploaded_sarif

# The (ruleId, location) pairs of the uploaded SARIF, one "rule uri" per line, sorted.
uploaded_alerts() {
  uploaded_sarif | jq -r '.runs[].results[] | "\(.ruleId) \(.locations[0].physicalLocation.artifactLocation.uri)"' | sort
}

STD_MAP="docker.io/kiwigrid/k8s-sidecar=sidecar-1.30.10 quay.io/kiwigrid/k8s-sidecar=sidecar-2.2.1 dexidp/dex=dex argoproj/argocd=FAIL cloudnative-pg/postgresql=busybox"

# ---------------------------------------------------------------------------
echo "images: which images are scanned"
# ---------------------------------------------------------------------------
new_case
STUB_MAP=$STD_MAP run_scan
images=$(grep '^image ' "$STUB_DIR/trivy.calls" | grep -v -- --download-db-only | awk '{print $NF}' | sort)

check "the scan completes on the fixture cluster" test "$RC" = 0
[ "$RC" = 0 ] || sed 's/^/       | /' "$CASE/out.log" | tail -20
check "no image from the safezone namespace is scanned" \
  bash -c '! grep -q "rebodutch\|valkey/valkey" <<<"$1"' _ "$images"
check "an image running only as an init container is scanned (cloudnative-pg operator image)" \
  grep -q '^ghcr.io/cloudnative-pg/cloudnative-pg@sha256:' <<<"$images"
check "every image is scanned by the digest that runs, not by its tag" \
  bash -c '! grep -v "@sha256:[0-9a-f]\{64\}$" <<<"$1"' _ "$images"
check "each running digest is scanned once" \
  test "$(sort <<<"$images" | uniq -d | wc -l)" = 0
expected_count=$(jq -r '.items[] | select(.metadata.namespace != "safezone") | .status | (.containerStatuses + .initContainerStatuses)[] | .imageID' "$FIX/pods.json" | sort -u | wc -l)
check "every running image outside safezone is scanned ($expected_count)" \
  test "$(wc -l <<<"$images")" = "$expected_count"

echo "trivy: VEX, severity and pinned behaviour"
check "every image scan applies the VEX file VEX_FILE names" \
  bash -c '! grep "^image " "$1" | grep -v -- --download-db-only | grep -v -q -- "--vex $2"' _ "$STUB_DIR/trivy.calls" "$FIX/empty.openvex.json"
check "every image scan keeps HIGH and CRITICAL, unfixed included" \
  bash -c '! grep "^image " "$1" | grep -v -- --download-db-only | grep -v -q -- "--severity HIGH,CRITICAL"; ! grep -q -- --ignore-unfixed "$1"' _ "$STUB_DIR/trivy.calls"
check "the database is fetched once, before the images are scanned" \
  bash -c 'head -1 "$1" | grep -q -- --download-db-only && test "$(grep -c -- --download-db-only "$1")" = 1' _ "$STUB_DIR/trivy.calls"

# ---------------------------------------------------------------------------
echo "identity: one alert is one CVE in one package of one image repository"
# ---------------------------------------------------------------------------
alerts=$(uploaded_alerts)
cves=$(grep '^CVE-' <<<"$alerts")
expected_cves=$(cat <<'EOF'
CVE-2026-23490 kiwigrid/k8s-sidecar/pyasn1
CVE-2026-31789 dexidp/dex/libcrypto3
CVE-2026-31789 dexidp/dex/libssl3
CVE-2026-31789 kiwigrid/k8s-sidecar/libcrypto3
CVE-2026-31789 kiwigrid/k8s-sidecar/libssl3
CVE-2026-78669 dexidp/dex/golang.org/x/net
CVE-2026-78669 dexidp/dex/stdlib
EOF
)
if [ "$cves" = "$expected_cves" ]; then ok "alerts are exactly CVE x <image repo>/<package>"
else fail "alerts are exactly CVE x <image repo>/<package>" "got: $(tr '\n' ';' <<<"$cves")"; fi
check "no location carries a registry" \
  bash -c '! grep -E " [^/ ]*[.:][^/ ]*/" <<<"$1"' _ "$cves"
check "no location carries a tag, digest or version" \
  bash -c '! grep -E "(:|@|[0-9]+\.[0-9]+\.[0-9]+|dist-info|python3)" <<<"$1"' _ "$cves"
check "two tags of one repository share an alert (k8s-sidecar 1.30.10 and 2.2.1)" \
  test "$(grep -c '^CVE-2026-23490 ' <<<"$cves")" = 1
check "a CVE in two packages of one image is two alerts (libssl3, libcrypto3)" \
  test "$(grep -c '^CVE-2026-31789 dexidp/dex/' <<<"$cves")" = 2
check "a package in several binaries of one image is one alert (stdlib in dex, docker-entrypoint, gomplate)" \
  test "$(grep -c '^CVE-2026-78669 dexidp/dex/stdlib$' <<<"$cves")" = 1
check "the upload is one run, every result's rule is declared in it" \
  bash -c 'uploaded_sarif | jq -e "(.runs | length == 1) and ([.runs[0].tool.driver.rules[].id] as \$r | all(.runs[0].results[]; .ruleId as \$id | \$r | index(\$id)))" >/dev/null'
check "no result carries a ruleIndex that could point at the wrong rule" \
  bash -c 'uploaded_sarif | jq -e "all(.runs[0].results[]; has(\"ruleIndex\") | not)" >/dev/null'
check "each merged result still says which tags and paths it was seen at" \
  bash -c 'uploaded_sarif | jq -e "[.runs[0].results[] | select(.ruleId == \"CVE-2026-23490\") | .message.text] | .[0] | (contains(\"1.30.10\") or contains(\"sha256\")) and contains(\"python3.14\") and contains(\"python3.13\")" >/dev/null'

# ---------------------------------------------------------------------------
echo "not covered: an image trivy cannot analyse is never clean"
# ---------------------------------------------------------------------------
nc=$(grep '^vuln-scan/not-covered ' <<<"$alerts")
expected_nc=$(cat <<'EOF'
vuln-scan/not-covered argoproj/argocd
vuln-scan/not-covered cloudnative-pg/postgresql
EOF
)
if [ "$nc" = "$expected_nc" ]; then ok "a failed analysis and an empty one are both reported not covered, and nothing else is"
else fail "a failed analysis and an empty one are both reported not covered, and nothing else is" "got: $(tr '\n' ';' <<<"$nc")"; fi
check "the not-covered rule is declared" \
  bash -c 'uploaded_sarif | jq -e "any(.runs[0].tool.driver.rules[]; .id == \"vuln-scan/not-covered\")" >/dev/null'
check "a not-covered result says why" \
  bash -c 'uploaded_sarif | jq -e "[.runs[0].results[] | select(.ruleId == \"vuln-scan/not-covered\") | .message.text] | (any(test(\"scan failed\"))) and (any(test(\"no OS or package\")))" >/dev/null'

# ---------------------------------------------------------------------------
echo "upload: Code Scanning on Chorde main"
# ---------------------------------------------------------------------------
check "uploads against main's head commit" \
  jq -e '.commit_sha == "0123456789abcdef0123456789abcdef01234567" and .ref == "refs/heads/main"' "$STUB_DIR/upload.json"
check "uploads to SafeChord/Chorde" \
  grep -q 'repos/SafeChord/Chorde/code-scanning/sarifs ' "$STUB_DIR/curl.calls"
check "authenticates with an installation token minted from the App key" \
  bash -c 'grep "code-scanning/sarifs" "$1" | grep -q "Bearer ghs_stub"' _ "$STUB_DIR/curl.calls"
check "waits for processing to finish" \
  test "$(cat "$STUB_DIR/polls")" -ge 2
check "the analysis has a fixed category, so each upload replaces the last" \
  bash -c 'uploaded_sarif | jq -e ".runs[0].automationDetails.id == \"vuln-scan/\"" >/dev/null'

# ---------------------------------------------------------------------------
echo "failure: a failed scan or a rejected upload exits non-zero (KubeJobFailed -> Slack)"
# ---------------------------------------------------------------------------
new_case; STUB_MAP=$STD_MAP STUB_STATUS=failed STUB_ERRORS='["invalid SARIF"]' run_scan
check "processing failed on GitHub's side -> non-zero" test "$RC" != 0
check "  ... and the log carries GitHub's error" grep -q 'invalid SARIF' "$CASE/out.log"

new_case; STUB_MAP=$STD_MAP STUB_UPLOAD_HTTP=413 run_scan
check "upload refused by the API (HTTP 413) -> non-zero" test "$RC" != 0

new_case; STUB_MAP=$STD_MAP STUB_PODS_HTTP=403 run_scan
check "listing pods refused -> non-zero, nothing uploaded" \
  bash -c 'test "$1" != 0 && test ! -e "$2/upload.json"' _ "$RC" "$STUB_DIR"

new_case; STUB_MAP=$STD_MAP STUB_DB_RC=1 run_scan
check "vulnerability database fetch failed -> non-zero, nothing uploaded" \
  bash -c 'test "$1" != 0 && test ! -e "$2/upload.json"' _ "$RC" "$STUB_DIR"

new_case; echo '{"kind":"PodList","items":[]}' > "$CASE/empty-pods.json"
STUB_MAP=$STD_MAP STUB_PODS="$CASE/empty-pods.json" run_scan
check "no image listed -> non-zero, nothing uploaded (an empty list is not a clean cluster)" \
  bash -c 'test "$1" != 0 && test ! -e "$2/upload.json"' _ "$RC" "$STUB_DIR"

new_case; STUB_MAP=$STD_MAP STUB_PENDING_POLLS=1000 run_scan
check "processing never finishes -> non-zero" test "$RC" != 0

# ---------------------------------------------------------------------------
echo "manifests: kubectl kustomize $MANIFESTS"
# ---------------------------------------------------------------------------
if rendered=$(kubectl kustomize "$MANIFESTS" 2>"$CASE/kustomize.err"); then
  ok "the directory renders"
  docs=$(printf '%s\n' "$rendered" | kubectl create --dry-run=client -o json -f - 2>/dev/null | jq -c 'if .kind == "List" then .items[] else . end')
  cj=$(jq -c 'select(.kind == "CronJob")' <<<"$docs")
  pod='.spec.jobTemplate.spec.template.spec'
  check "one CronJob" test "$(jq -s 'length' <<<"$cj")" = 1
  check "runs once a week (a single day-of-week, every month, any day-of-month)" \
    bash -c 'jq -r .spec.schedule <<<"$1" | awk "{exit !(NF==5 && \$3==\"*\" && \$4==\"*\" && \$5 ~ /^[0-6]$/)}"' _ "$cj"
  check "trivy is pinned to 0.76.1 by tag and digest" \
    bash -c 'jq -r "$2.containers[].image" <<<"$1" | grep -qE "^(docker\.io/)?aquasec/trivy:0\.76\.1@sha256:[0-9a-f]{64}$"' _ "$cj" "$pod"
  check "never on gce-agent-tw: required node affinity excludes it" \
    bash -c 'jq -e "[$2.affinity.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution.nodeSelectorTerms[].matchExpressions[] | select(.key == \"kubernetes.io/hostname\" and .operator == \"NotIn\") | .values[]] | index(\"gce-agent-tw\")" <<<"$1" >/dev/null' _ "$cj" "$pod"
  check "never on gce-agent-tw: does not tolerate its proxy-only taint" \
    bash -c 'jq -e "all(($2.tolerations // [])[]; .key != \"chorde.io/purpose\" and (.operator != \"Exists\" or .key != null))" <<<"$1" >/dev/null' _ "$cj" "$pod"
  check "a failed run is not retried and does not overlap the next" \
    bash -c 'jq -e ".spec.concurrencyPolicy == \"Forbid\" and .spec.jobTemplate.spec.backoffLimit == 0" <<<"$1" >/dev/null' _ "$cj"
  check "a finished Job is removed, so KubeJobFailed resolves instead of firing for a week" \
    bash -c 'jq -e ".spec.jobTemplate.spec.ttlSecondsAfterFinished > 0 and .spec.jobTemplate.spec.ttlSecondsAfterFinished <= 172800" <<<"$1" >/dev/null' _ "$cj"
  check "scan.sh, images.jq and sarif.jq reach the pod from ConfigMaps" \
    bash -c 'for f in scan.sh images.jq sarif.jq; do jq -s -e --arg f "$f" "any(.[]; .kind == \"ConfigMap\" and (.data | has(\$f)))" <<<"$1" >/dev/null || exit 1; done' _ "$docs"
  # Chorde#43: Chorde is public, so the statements are sealed. The file VEX_FILE
  # names must come from a Secret volume whose SealedSecret carries that file
  # as a key, and no ConfigMap may carry a VEX document.
  check "the VEX file VEX_FILE names reaches the pod from a SealedSecret" \
    bash -c '
      c=$(jq -c "$2.containers[] | select(.name == \"trivy\")" <<<"$1")
      vex=$(jq -r ".env[] | select(.name == \"VEX_FILE\") | .value" <<<"$c")
      dir=${vex%/*}; key=${vex##*/}
      vol=$(jq -r --arg d "$dir" ".volumeMounts[] | select(.mountPath == \$d) | .name" <<<"$c")
      secret=$(jq -r --arg v "$vol" "$2.volumes[] | select(.name == \$v) | select(.secret.items == null) | .secret.secretName // empty" <<<"$1")
      test -n "$vex" && test -n "$secret" &&
        jq -e -s --arg s "$secret" --arg k "$key" "any(.[]; .kind == \"SealedSecret\" and (.spec.template.metadata.name // .metadata.name) == \$s and (.spec.encryptedData | has(\$k)))" <<<"$3" >/dev/null' \
      _ "$cj" "$pod" "$docs"
  check "no ConfigMap carries a VEX document" \
    bash -c '! jq -e -s "any(.[] | select(.kind == \"ConfigMap\") | .data // {} | .[]; test(\"openvex\\\\.dev/ns\"))" <<<"$1" >/dev/null' _ "$docs"
  check "the App key reaches the pod from the github-app SealedSecret" \
    bash -c 'jq -e "select(.kind == \"SealedSecret\" and .metadata.name == \"github-app\")" <<<"$1" >/dev/null && jq -e "any($2.volumes[]; .secret.secretName == \"github-app\")" <<<"$3" >/dev/null' _ "$docs" "$pod" "$cj"
  check "every namespaced object lives in vuln-scan" \
    bash -c 'jq -e -s "all(.[] | select(.kind | IN(\"Namespace\", \"ClusterRole\", \"ClusterRoleBinding\") | not); .metadata.namespace == \"vuln-scan\")" <<<"$1" >/dev/null' _ "$docs"
  check "the service account may only get and list pods" \
    bash -c 'jq -e -s "[.[] | select(.kind == \"ClusterRole\" or .kind == \"Role\") | .rules[]] | all(.resources == [\"pods\"] and (.verbs - [\"get\", \"list\"] | length == 0))" <<<"$1" >/dev/null' _ "$docs"
else
  fail "the directory renders" "$(cat "$CASE/kustomize.err")"
fi

check "no file under gitops/ holds a VEX document in plaintext (Chorde#43)" \
  bash -c '! git -C "$1" ls-files -z -- gitops | xargs -0 grep -l "openvex\.dev/ns" 2>/dev/null | grep -q .' _ "$REPO"

check "the platform stage lists vuln-scan" \
  grep -qE '^\s*-\s*service:\s*vuln-scan\s*$' "$REPO/gitops/k3han/stages/01-platform.yaml"

# ---------------------------------------------------------------------------
if [ "${VULN_SCAN_IT:-0}" = 1 ]; then
  echo "integration: the real trivy (network)"
  IT=$(mktemp -d)
  img=quay.io/kiwigrid/k8s-sidecar:2.2.1
  trivy image --quiet --scanners vuln --severity HIGH,CRITICAL --format json -o "$IT/before.json" "$img"
  cve=$(jq -r '[.Results[].Vulnerabilities[]? | select(.PkgName == "pyasn1")][0].VulnerabilityID' "$IT/before.json")
  purl=$(jq -r '[.Results[].Vulnerabilities[]? | select(.PkgName == "pyasn1")][0].PkgIdentifier.PURL' "$IT/before.json")
  jq --arg cve "$cve" --arg purl "$purl" '.statements += [{vulnerability: {name: $cve}, products: [{"@id": $purl}], status: "not_affected", justification: "vulnerable_code_not_in_execute_path"}]' \
    "$FIX/empty.openvex.json" > "$IT/vex.json"
  trivy image --quiet --scanners vuln --severity HIGH,CRITICAL --vex "$FIX/empty.openvex.json" --format json -o "$IT/empty.json" "$img"
  check "a VEX file with no statement is accepted by trivy 0.76.1" test -s "$IT/empty.json"
  trivy image --quiet --scanners vuln --severity HIGH,CRITICAL --vex "$IT/vex.json" --format json -o "$IT/after.json" "$img"
  check "a VEX statement removes its finding ($cve on $purl)" \
    bash -c 'jq -e --arg c "$2" "any(.Results[].Vulnerabilities[]?; .VulnerabilityID == \$c and .PkgName == \"pyasn1\")" "$1" >/dev/null && ! jq -e --arg c "$2" "any(.Results[].Vulnerabilities[]?; .VulnerabilityID == \$c and .PkgName == \"pyasn1\")" "$3" >/dev/null' _ "$IT/before.json" "$cve" "$IT/after.json"
  trivy image --quiet --scanners vuln --format json -o "$IT/busybox.json" busybox:1.33
  check "busybox:1.33 still yields no OS and no package (the not-covered case is real)" \
    bash -c 'jq -e "(.Metadata.OS == null) and ((.Results // []) | length == 0)" "$1" >/dev/null' _ "$IT/busybox.json"
fi

echo
echo "passed $PASS, failed $FAIL"
[ "$FAIL" = 0 ]
