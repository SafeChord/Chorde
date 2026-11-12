#!/usr/bin/env bash
set -uo pipefail

# SafeChord Infrastructure: public data plane rollout (Chorde#60)
# Purpose: Require that a change to the public data plane's pod template rolls
#          out with no manual step, and that the public route serves again once
#          it has; measure how long the route is down meanwhile
#          (Docs safechord.chorde.k3han.ingress.md §2.1, item 5).
#
#          The data plane is one replica bound to hostPorts 80/443 on the only
#          node it may run on. When NGF moved 2.6.3 -> 2.8.1 (Chorde#47) the
#          new pod sat Pending on the hostPorts the old pod held, and the
#          rollout finished only once the old pod was deleted by hand.
#
#          Steps:
#            1. the route answers ROLL_EXPECT and the Deployment is Available
#            2. `kubectl rollout restart`: a pod-template change, the same kind
#               of change an NGF version move or an NginxProxy edit makes
#            3. the rollout completes within ROLL_DEADLINE, with nothing done
#               by hand: every replica updated and available, no old pod left
#            4. the route answers ROLL_EXPECT again within ROLL_RECOVER of the
#               rollout completing
#            5. the longest window in which the route did not answer
#               ROLL_EXPECT is reported, and fails the run when ROLL_MAX_DOWN
#               is set and it is longer
#          The route is probed once a second from where this script runs,
#          throughout; a probe that has no answer within ROLL_PROBE_TIMEOUT
#          counts as down.
#
#          Mutates the cluster. Against the live data plane it takes the
#          public routes down for the measured window: run it only with the
#          Architect's approval. --fixture runs the same steps against a
#          scratch Deployment (namespace public-roll-test, deleted on exit)
#          that binds hostPort ROLL_FIXTURE_PORT on one node, with the given
#          strategy, so the test is shown to fail and pass without touching
#          the public routes. The fixture is probed on the node's ExternalIP
#          (the Tailscale address on K3han), so this machine must be on the
#          tailnet.
#
# Usage:   bash scripts/test/public-roll/rollout-test.sh
#          bash scripts/test/public-roll/rollout-test.sh --fixture RollingUpdate|Recreate
#          ROLL_NS=<ns>              (default nginx-gateway)
#          ROLL_DEPLOY=<name>        (default public-gateway-nginx)
#          ROLL_URL=<url>            (default https://www.omh.idv.tw/echo)
#          ROLL_EXPECT=<code>        status meaning "serving" (default 401: the
#                                    echo route's auth wall)
#          ROLL_DEADLINE=<s>         rollout must complete in (default 180)
#          ROLL_RECOVER=<s>          route must serve within, after it (default 60)
#          ROLL_MAX_DOWN=<s>         longest down window allowed (default: report only)
#          ROLL_PROBE_TIMEOUT=<s>    one probe's timeout (default 10)
#          ROLL_FIXTURE_NODE=<node>  (default acer-agent)
#          ROLL_FIXTURE_PORT=<port>  (default 18080)
# Needs:   bash, kubectl, curl, awk.
# Exit:    0 = all steps passed, 1 = a step failed.

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()   { echo -e "${GREEN}[INFO] $1${NC}"; }
warn()  { echo -e "${YELLOW}[WARN] $1${NC}"; }
error() { echo -e "${RED}[ERROR] $1${NC}"; }

FIXTURE=""
if [[ "${1:-}" == "--fixture" ]]; then
    FIXTURE="${2:-}"
    if [[ "${FIXTURE}" != "RollingUpdate" && "${FIXTURE}" != "Recreate" ]]; then
        error "--fixture takes RollingUpdate or Recreate"; exit 2
    fi
fi

DEADLINE="${ROLL_DEADLINE:-180}"
RECOVER="${ROLL_RECOVER:-60}"
MAX_DOWN="${ROLL_MAX_DOWN:-}"
PROBE_TIMEOUT="${ROLL_PROBE_TIMEOUT:-10}"
OUT=$(mktemp -d)
PROBER_PID=""

if [[ -n "${FIXTURE}" ]]; then
    NS="public-roll-test"
    DEPLOY="roll-fixture"
    FIXTURE_NODE="${ROLL_FIXTURE_NODE:-acer-agent}"
    FIXTURE_PORT="${ROLL_FIXTURE_PORT:-18080}"
    NODE_IP=$(kubectl get node "${FIXTURE_NODE}" \
        -o jsonpath='{.status.addresses[?(@.type=="ExternalIP")].address}')
    URL="http://${NODE_IP}:${FIXTURE_PORT}/"
    EXPECT="200"
else
    NS="${ROLL_NS:-nginx-gateway}"
    DEPLOY="${ROLL_DEPLOY:-public-gateway-nginx}"
    URL="${ROLL_URL:-https://www.omh.idv.tw/echo}"
    EXPECT="${ROLL_EXPECT:-401}"
fi

cleanup() {
    [[ -n "${PROBER_PID}" ]] && kill "${PROBER_PID}" 2>/dev/null
    if [[ -n "${FIXTURE}" ]]; then
        log "Deleting namespace ${NS}"
        kubectl delete ns "${NS}" --wait=true --timeout=120s >/dev/null 2>&1
    fi
    rm -rf "${OUT}"
}
trap cleanup EXIT

PASS_COUNT=0
FAIL_COUNT=0
declare -a RESULTS=()
step_pass() { RESULTS+=("  ${GREEN}PASS${NC}  $1"); PASS_COUNT=$(( PASS_COUNT + 1 )); }
step_fail() { RESULTS+=("  ${RED}FAIL${NC}  $1${2:+ — $2}"); FAIL_COUNT=$(( FAIL_COUNT + 1 )); }

summary() {
    echo
    echo "=== public data plane rollout: ${NS}/${DEPLOY} ==="
    for r in "${RESULTS[@]}"; do echo -e "$r"; done
    echo "passed ${PASS_COUNT}, failed ${FAIL_COUNT}"
    [[ ${FAIL_COUNT} -eq 0 ]]
}

now() { date +%s.%N; }
code_of() {
    local c
    c=$(curl -s -o /dev/null -w '%{http_code}' --max-time "${PROBE_TIMEOUT}" "$1" 2>/dev/null)
    echo "${c:-000}"
}

# ---------------------------------------------------------------------------
# Fixture: one replica holding a hostPort on one node, as the public data
# plane holds 80/443 on gce-agent-tw.
# ---------------------------------------------------------------------------
if [[ -n "${FIXTURE}" ]]; then
    log "Creating fixture ${NS}/${DEPLOY}: strategy ${FIXTURE}, hostPort ${FIXTURE_PORT} on ${FIXTURE_NODE}"
    kubectl create ns "${NS}" >/dev/null 2>&1
    kubectl apply -f - >/dev/null <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${DEPLOY}
  namespace: ${NS}
spec:
  replicas: 1
  strategy:
    type: ${FIXTURE}
  selector:
    matchLabels: { app: ${DEPLOY} }
  template:
    metadata:
      labels: { app: ${DEPLOY} }
    spec:
      nodeSelector:
        kubernetes.io/hostname: ${FIXTURE_NODE}
      terminationGracePeriodSeconds: 30
      containers:
        - name: server
          image: registry.k8s.io/e2e-test-images/agnhost:2.53
          args: ["netexec", "--http-port=8080"]
          ports:
            - containerPort: 8080
              hostPort: ${FIXTURE_PORT}
          readinessProbe:
            httpGet: { path: /healthz, port: 8080 }
            initialDelaySeconds: 3
            periodSeconds: 10
EOF
    if ! kubectl -n "${NS}" rollout status "deploy/${DEPLOY}" --timeout=180s >/dev/null; then
        error "fixture never became Available"; exit 1
    fi
fi

# ---------------------------------------------------------------------------
# Step 1: steady state
# ---------------------------------------------------------------------------
log "--- Step 1: ${URL} answers ${EXPECT}, ${NS}/${DEPLOY} Available ---"
PRE=""
for _ in 1 2 3 4 5 6 7 8 9 10; do
    PRE=$(code_of "${URL}")
    [[ "${PRE}" == "${EXPECT}" ]] && break
    sleep 3
done
AVAIL=$(kubectl -n "${NS}" get deploy "${DEPLOY}" \
    -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null)
STRATEGY=$(kubectl -n "${NS}" get deploy "${DEPLOY}" -o jsonpath='{.spec.strategy.type}' 2>/dev/null)
log "route=${PRE} available=${AVAIL:-none} strategy=${STRATEGY:-none}"
if [[ "${PRE}" == "${EXPECT}" && "${AVAIL}" == "True" ]]; then
    step_pass "steady state (route ${PRE}, Available, strategy ${STRATEGY})"
else
    step_fail "steady state" "route ${PRE}, Available ${AVAIL:-none}"
    summary; exit 1
fi

# ---------------------------------------------------------------------------
# Prober: one probe a second, "<start epoch> <code>" per line
# ---------------------------------------------------------------------------
PROBES="${OUT}/probes"
(
    while :; do
        t=$(now)
        echo "${t} $(code_of "${URL}")" >> "${PROBES}"
        sleep 1
    done
) &
PROBER_PID=$!
sleep 3

# ---------------------------------------------------------------------------
# Step 2 + 3: a pod-template change, and the rollout finishing on its own
# ---------------------------------------------------------------------------
SELECTOR=$(kubectl -n "${NS}" get deploy "${DEPLOY}" \
    -o go-template='{{range $k,$v := .spec.selector.matchLabels}}{{$k}}={{$v}},{{end}}' | sed 's/,$//')
OLD_PODS=$(kubectl -n "${NS}" get pods -o name -l "${SELECTOR}")
log "--- Step 2: rollout restart ${NS}/${DEPLOY} (old: $(echo ${OLD_PODS})) ---"
T_RESTART=$(now)
if ! kubectl -n "${NS}" rollout restart "deploy/${DEPLOY}" >/dev/null; then
    step_fail "rollout restart" "kubectl refused"; summary; exit 1
fi

log "--- Step 3: rollout completes within ${DEADLINE}s, nothing done by hand ---"
if kubectl -n "${NS}" rollout status "deploy/${DEPLOY}" --timeout="${DEADLINE}s" >/dev/null 2>&1; then
    # rollout status returns once the new ReplicaSet is available and old
    # replicas are scaled down; wait for the old pods themselves to be gone.
    for p in ${OLD_PODS}; do
        kubectl -n "${NS}" wait --for=delete "$p" --timeout=60s >/dev/null 2>&1
    done
    T_DONE=$(now)
    ROLL_S=$(awk -v a="${T_RESTART}" -v b="${T_DONE}" 'BEGIN{printf "%.1f", b-a}')
    step_pass "rollout completed in ${ROLL_S}s"
else
    T_DONE=$(now)
    error "rollout did not complete within ${DEADLINE}s"
    kubectl -n "${NS}" get pods -o wide 2>&1 | sed 's/^/       /'
    kubectl -n "${NS}" get events --sort-by=.lastTimestamp 2>/dev/null \
        | grep -E 'FailedScheduling|free ports' | tail -3 | sed 's/^/       /'
    step_fail "rollout completed" "not within ${DEADLINE}s"
fi

# ---------------------------------------------------------------------------
# Step 4: the route serves again
# ---------------------------------------------------------------------------
log "--- Step 4: route answers ${EXPECT} within ${RECOVER}s of the rollout ---"
RECOVERED=""
END=$(awk -v a="$(now)" -v r="${RECOVER}" 'BEGIN{printf "%d", a+r}')
while [[ $(date +%s) -lt ${END} ]]; do
    last=$(tail -1 "${PROBES}" 2>/dev/null | awk '{print $2}')
    if [[ "${last}" == "${EXPECT}" ]] && \
       awk -v t="$(tail -1 "${PROBES}" | awk '{print $1}')" -v d="${T_DONE}" 'BEGIN{exit !(t>=d)}'; then
        RECOVERED=1; break
    fi
    sleep 1
done
sleep 2
kill "${PROBER_PID}" 2>/dev/null; wait "${PROBER_PID}" 2>/dev/null; PROBER_PID=""
if [[ -n "${RECOVERED}" ]]; then
    step_pass "route serves again"
else
    step_fail "route serves again" "not ${EXPECT} within ${RECOVER}s"
fi

# ---------------------------------------------------------------------------
# Step 5: longest down window. A window runs from the last probe that answered
# EXPECT before a failure to the first probe after it that did, so it bounds
# the outage from above by up to one probe interval; an unclosed window runs
# to the last probe.
# ---------------------------------------------------------------------------
read -r DOWN_S DOWN_CODES N_PROBES <<< "$(awk -v e="${EXPECT}" '
    { t=$1; c=$2; n++
      if (c != e) { if (start == "") start = (ok != "" ? ok : t); codes[c]++ }
      else { if (start != "") { d = t - start; if (d > max) max = d; start = "" }; ok = t }
      last = t }
    END { if (start != "") { d = last - start; if (d > max) max = d }
          s = ""; for (k in codes) s = s k "x" codes[k] ","
          sub(/,$/, "", s); if (s == "") s = "none"
          printf "%.1f %s %d\n", max, s, n }' "${PROBES}")"
log "longest down window ${DOWN_S}s over ${N_PROBES} probes (non-${EXPECT}: ${DOWN_CODES})"
if [[ -n "${MAX_DOWN}" ]] && awk -v d="${DOWN_S}" -v m="${MAX_DOWN}" 'BEGIN{exit !(d>m)}'; then
    step_fail "down window" "${DOWN_S}s > ${MAX_DOWN}s"
else
    step_pass "down window ${DOWN_S}s${MAX_DOWN:+ (max ${MAX_DOWN}s)} — non-${EXPECT}: ${DOWN_CODES}"
fi

summary
