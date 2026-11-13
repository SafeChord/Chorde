#!/usr/bin/env bash
# Requirement tests for scripts/ops/bootstrap-cluster.sh (Chorde#94).
#
# Docs safechord.chorde.md section 2, step 4 of a from-scratch bootstrap: the
# script waits for argocd-server and applies the cluster's root.yaml, and
# applies nothing if its argument check or that wait fails.
#
# Runs the script from the repository root against a kubectl stub that logs
# every call, so no cluster is touched.
#
#   scripts/test/bootstrap/test.sh
#
# Needs: bash.
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../../.." && pwd)
SCRIPT="$REPO/scripts/ops/bootstrap-cluster.sh"

PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); echo "  ok   $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL $1"; [ $# -gt 1 ] && echo "$2" | sed 's/^/       /'; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# The stub logs its arguments to $KUBECTL_LOG; `kubectl wait` exits with
# $KUBECTL_WAIT_RC, every other call with 0.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$KUBECTL_LOG"
[ "${1:-}" = wait ] && exit "${KUBECTL_WAIT_RC:-0}"
exit 0
EOF
chmod +x "$TMP/bin/kubectl"

# run <name> <wait rc> <want: ok|refused> <want applies> [args...]
run() {
  local name=$1 wait_rc=$2 want=$3 want_applies=$4; shift 4
  local log="$TMP/$PASS.$FAIL.log" rc applies
  : > "$log"
  (cd "$REPO" && PATH="$TMP/bin:$PATH" KUBECTL_LOG="$log" KUBECTL_WAIT_RC="$wait_rc" \
    bash "$SCRIPT" "$@" >/dev/null 2>&1); rc=$?
  applies=$(grep '^apply' "$log" || true)
  if [ "$want" = ok ] && [ $rc -ne 0 ]; then
    fail "$name" "exited $rc; kubectl calls: $(tr '\n' ';' < "$log")"
  elif [ "$want" = refused ] && [ $rc -eq 0 ]; then
    fail "$name" "exited 0; kubectl calls: $(tr '\n' ';' < "$log")"
  elif [ "$applies" != "$want_applies" ]; then
    fail "$name" "applied [${applies//$'\n'/; }], want [$want_applies]"
  else
    ok "$name"
  fi
}

echo "== bootstrap-cluster.sh"
run "k3han with argocd-server ready applies its root.yaml once" 0 ok "apply -f gitops/k3han/root.yaml" k3han
run "no cluster name applies nothing" 0 refused ""
run "a cluster with no root.yaml applies nothing" 0 refused "" no-such-cluster
run "argocd-server not ready applies nothing" 1 refused "" k3han

echo
echo "passed $PASS, failed $FAIL"
[ $FAIL -eq 0 ]
