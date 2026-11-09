#!/usr/bin/env bash
set -uo pipefail

# SafeChord Infrastructure: K3han pod data path — NetworkPolicy timing (Chorde#51)
# Purpose: Measure how long kube-router takes to act on a NetworkPolicy change,
#          on every node pair, and fail when a step takes longer than the limit.
#          netpol-matrix-test.sh checks verdicts at steady state only; the data
#          path before Chorde#16 was slow to enforce a policy and kept blocking
#          after one was removed (Docs safechord.chorde.k3han.network.md §2.6).
#
#          The steps, timed from inside the client pods:
#            hold     a policy is applied: the denied clients lose every server,
#                     and the allowed clients never lose one meanwhile. Timed
#                     from the moment the API server accepted the policy
#            new pod  under the policy, pods start with new addresses, as in a
#                     rolling update. A new allowed client reaches every server,
#                     timed from its container's start; a new server admits the
#                     allowed clients and refuses the denied ones, timed from
#                     its Ready (a Service sends it nothing before that)
#            release  the policy is deleted: the denied clients reach every
#                     server again. Timed as hold is
#
#          Fixture, generated below: per node one server (agnhost netexec) and
#          two clients, role=allowed and role=denied, pinned by nodeName; one
#          ingress policy on the servers admits role=allowed on the named
#          port http (8080). The port is named, as Argo CD's chart policies
#          name theirs: kube-router resolves a named port per pod, so every
#          new server's address is resolved afresh.
#
#          Mutates the cluster: creates namespace netpol-timing and deletes it
#          on exit.
#
# Usage:   bash scripts/test/pod-path/netpol-timing-test.sh
#          NETPOL_TIMING_LIMIT=<s>   longest a step may take (default 30)
#          NETPOL_TIMING_WINDOW=<s>  how long a step is watched (default 120)
# Needs:   bash, kubectl, jq, mkfifo.
# Exit:    0 = every step within the limit, 1 = a step was late or never came.

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

log()   { echo -e "${GREEN}[INFO] $1${NC}"; }
error() { echo -e "${RED}[ERROR] $1${NC}"; }

NS="netpol-timing"
NODES=(acer ct gce)
declare -A NODE_NAME=([acer]=acer-agent [ct]=ct-serv-jp [gce]=gce-agent-tw)
IMAGE="registry.k8s.io/e2e-test-images/agnhost:2.53"
LIMIT="${NETPOL_TIMING_LIMIT:-30}"
WINDOW="${NETPOL_TIMING_WINDOW:-120}"
OUT=$(mktemp -d)

PASS_COUNT=0
FAIL_COUNT=0
declare -a RESULTS=()

cleanup() {
    log "Deleting namespace ${NS}"
    kubectl delete ns "${NS}" --wait=true --timeout=120s >/dev/null 2>&1
    rm -rf "${OUT}"
}
trap cleanup EXIT

# The watcher, run by busybox sh in a client pod: <mode> <window> <sync> <ip...>
#   open    print each ip with the seconds until it first answers
#   closed  print each ip with the seconds until it first refuses
#   stay    probe until the window ends; print each ip with its refused probes
# With sync=1 it prints READY and starts its clock on a line from stdin;
# otherwise its clock starts when it does. A probe is one HTTP request with a
# 1 s timeout. An ip that never turns prints "never".
WATCH='
mode=$1; window=$2; sync=$3; shift 3
now() { cut -d" " -f1 /proc/uptime; }
if [ "$sync" = 1 ]; then echo READY; read -r go; fi
start=$(now); left="$*"; fails=""
while :; do
    el=$(awk -v a="$start" -v b="$(now)" "BEGIN{printf \"%.1f\", b-a}")
    awk -v e="$el" -v w="$window" "BEGIN{exit !(e>=w)}" && break
    next=""
    for ip in $left; do
        if curl -s -o /dev/null -m 1 "http://$ip:8080/"; then ok=1; else ok=0; fi
        case "$mode:$ok" in
            open:1|closed:0) echo "$ip $el" ;;
            stay:0) fails="$fails $ip"; next="$next $ip" ;;
            *) next="$next $ip" ;;
        esac
    done
    [ "$mode" = stay ] || left=$next
    [ -z "$left" ] && break
    sleep 0.5
done
if [ "$mode" = stay ]; then
    for ip in $*; do echo "$ip $(echo "$fails" | tr " " "\n" | grep -cx "$ip")"; done
else
    for ip in $left; do echo "$ip never"; done
fi
'

# pod <name> <node> <labels as k: v, ...> server|client|watcher [<watcher args...>]
# A server is Ready once it answers, so that a refusal a watcher sees is the
# policy's and not a server still starting. A watcher pod runs the watcher as
# its command, from its container's start, and its log is the result.
pod() {
    local name=$1 node=$2 labels=$3 kind=$4; shift 4
    local cmd='args: ["pause"]' extra="" restart=Always arg
    case "$kind" in
        server)
            cmd='args: ["netexec", "--http-port=8080"]'
            extra="    ports: [{name: http, containerPort: 8080}]
    readinessProbe: {httpGet: {port: http, path: /}, periodSeconds: 1}" ;;
        watcher)
            restart=Never
            cmd="command: [\"sh\", \"-c\", $(printf '%s' "$WATCH" | jq -Rs .), \"sh\""
            for arg in "$@"; do cmd+=", \"$arg\""; done
            cmd+="]" ;;
    esac
    cat <<EOF
---
apiVersion: v1
kind: Pod
metadata:
  name: ${name}
  namespace: ${NS}
  labels: {${labels}}
spec:
  nodeName: ${NODE_NAME[$node]}
  restartPolicy: ${restart}
  tolerations: [{operator: Exists}]
  terminationGracePeriodSeconds: 1
  containers:
  - name: c
    image: ${IMAGE}
    ${cmd}
    resources: {requests: {cpu: 5m, memory: 16Mi}, limits: {memory: 64Mi}}
${extra}
EOF
}

POLICY=$(cat <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: srv-ingress, namespace: ${NS}}
spec:
  podSelector: {matchLabels: {app: srv}}
  policyTypes: [Ingress]
  ingress:
  - from: [{podSelector: {matchLabels: {role: allowed}}}]
    ports: [{port: http, protocol: TCP}]
EOF
)

declare -A IP=()
ip_of() { kubectl get pod -n "${NS}" "$1" -o jsonpath='{.status.podIP}'; }
ready() {
    kubectl wait -n "${NS}" --for=condition=Ready pod "$@" --timeout=180s >/dev/null \
        || { error "fixture pods not Ready: $*"; exit 1; }
    local p; for p in "$@"; do IP[$p]=$(ip_of "$p"); done
}
ips() { local s; for s in "$@"; do echo -n "${IP[$s]} "; done; }

# watch_bg <client> <mode> <window> <sync> <server pods...>: run a watcher in a
# client pod in the background; its output lands in ${OUT}/<step>.<client>.
# With sync=1 its stdin is a fifo, held open on an fd listed in GO_FDS.
STEP=""
GO_FDS=()
watch_bg() {
    local client=$1 mode=$2 window=$3 sync=$4; shift 4
    local raw="${OUT}/${STEP}.${client}"
    # shellcheck disable=SC2046
    if [[ "$sync" == 1 ]]; then
        mkfifo "${raw}.in"
        kubectl exec -i -n "${NS}" "$client" -- sh -c "$WATCH" sh "$mode" "$window" 1 $(ips "$@") \
            < "${raw}.in" > "$raw" 2>&1 &
        local fd; exec {fd}> "${raw}.in"; GO_FDS+=("$fd")
    else
        kubectl exec -n "${NS}" "$client" -- sh -c "$WATCH" sh "$mode" "$window" 0 $(ips "$@") \
            > "$raw" 2>&1 &
    fi
}

# await_ready <clients...>: wait until every synced watcher of the step is in place
await_ready() {
    local c i
    for c in "$@"; do
        for (( i = 0; i < 60; i++ )); do
            grep -q '^READY$' "${OUT}/${STEP}.${c}" 2>/dev/null && continue 2
            sleep 0.5
        done
        error "watcher in ${c} did not start: $(head -c 200 "${OUT}/${STEP}.${c}")"; exit 1
    done
}

# go_all: start the clocks of every synced watcher
go_all() {
    local fd; for fd in "${GO_FDS[@]}"; do echo go >&"$fd"; exec {fd}>&-; done
    GO_FDS=()
}

# judge <label> <client> <mode> [<file>]: score a watcher's output
judge() {
    local label=$1 client=$2 mode=$3 file=${4:-${OUT}/${STEP}.$2} ip v s server n=0
    while read -r ip v; do
        [[ "$ip" == READY ]] && continue
        server=$ip
        for s in "${!IP[@]}"; do [[ "${IP[$s]}" == "$ip" ]] && server=$s; done
        n=$(( n + 1 ))
        local what="${label}: ${client} -> ${server}"
        if [[ "$mode" == stay ]]; then
            if [[ "$v" == 0 ]]; then
                RESULTS+=("  ${GREEN}PASS${NC}  ${what} — never refused")
                PASS_COUNT=$(( PASS_COUNT + 1 ))
            else
                RESULTS+=("  ${RED}FAIL${NC}  ${what} — refused ${v} probe(s), allowed throughout")
                FAIL_COUNT=$(( FAIL_COUNT + 1 ))
            fi
        elif [[ "$v" != never ]] && awk -v v="$v" -v l="$LIMIT" 'BEGIN{exit !(v<=l)}'; then
            RESULTS+=("  ${GREEN}PASS${NC}  ${what} — ${mode} after ${v} s")
            PASS_COUNT=$(( PASS_COUNT + 1 ))
        else
            RESULTS+=("  ${RED}FAIL${NC}  ${what} — ${mode} after ${v} s, limit ${LIMIT} s")
            FAIL_COUNT=$(( FAIL_COUNT + 1 ))
        fi
    done < "$file"
    if (( n == 0 )); then
        RESULTS+=("  ${RED}FAIL${NC}  ${label}: ${client} — watcher gave no result: $(head -c 200 "$file")")
        FAIL_COUNT=$(( FAIL_COUNT + 1 ))
    fi
}

SRV=() ALLOWED=() DENIED=() NEW_SRV=() NEW_CLI=()
for n in "${NODES[@]}"; do
    SRV+=("srv-$n"); ALLOWED+=("cli-$n-allowed"); DENIED+=("cli-$n-denied")
    NEW_SRV+=("srv-$n-new"); NEW_CLI+=("cli-$n-new")
done

log "Applying fixture"
{
    echo "apiVersion: v1"; echo "kind: Namespace"; echo "metadata: {name: ${NS}}"
    for n in "${NODES[@]}"; do
        pod "srv-$n" "$n" "app: srv" server
        pod "cli-$n-allowed" "$n" "app: cli, role: allowed" client
        pod "cli-$n-denied" "$n" "app: cli, role: denied" client
    done
} | kubectl apply -f - >/dev/null || { error "apply failed"; exit 1; }
ready "${SRV[@]}" "${ALLOWED[@]}" "${DENIED[@]}"

log "Baseline: no policy, every client reaches every server"
STEP=baseline
for c in "${ALLOWED[@]}" "${DENIED[@]}"; do watch_bg "$c" open 30 0 "${SRV[@]}"; done
wait
for c in "${ALLOWED[@]}" "${DENIED[@]}"; do judge baseline "$c" open; done
if (( FAIL_COUNT > 0 )); then
    printf '%b\n' "${RESULTS[@]}"; error "baseline failed: the data path is broken before any policy"; exit 1
fi

log "Hold: applying the policy, watching ${WINDOW} s at most"
STEP=hold
for c in "${DENIED[@]}"; do watch_bg "$c" closed "$WINDOW" 1 "${SRV[@]}"; done
for c in "${ALLOWED[@]}"; do watch_bg "$c" stay "$LIMIT" 1 "${SRV[@]}"; done
await_ready "${DENIED[@]}" "${ALLOWED[@]}"
echo "$POLICY" | kubectl apply -f - >/dev/null || { error "policy apply failed"; exit 1; }
go_all
wait
for c in "${DENIED[@]}"; do judge hold "$c" closed; done
for c in "${ALLOWED[@]}"; do judge hold "$c" stay; done

log "New pods: starting a server and an allowed client per node under the policy"
{
    for n in "${NODES[@]}"; do pod "srv-$n-new" "$n" "app: srv" server; done
} | kubectl apply -f - >/dev/null || { error "apply failed"; exit 1; }
ready "${NEW_SRV[@]}"
STEP=new
for c in "${ALLOWED[@]}"; do watch_bg "$c" open "$WINDOW" 0 "${NEW_SRV[@]}"; done
for c in "${DENIED[@]}"; do watch_bg "$c" closed "$WINDOW" 0 "${NEW_SRV[@]}"; done
# shellcheck disable=SC2046
{
    for n in "${NODES[@]}"; do
        pod "cli-$n-new" "$n" "app: cli, role: allowed" watcher open "$WINDOW" 0 \
            $(ips "${SRV[@]}" "${NEW_SRV[@]}")
    done
} | kubectl apply -f - >/dev/null || { error "apply failed"; exit 1; }
wait
kubectl wait -n "${NS}" --for=jsonpath='{.status.phase}'=Succeeded pod "${NEW_CLI[@]}" \
    --timeout="$(( WINDOW + 120 ))s" >/dev/null || error "a new client did not finish"
for c in "${NEW_CLI[@]}"; do
    kubectl logs -n "${NS}" "$c" > "${OUT}/new.${c}" 2>&1
    judge "new pod (from container start)" "$c" open
done
for c in "${ALLOWED[@]}"; do judge "new pod (from server Ready)" "$c" open; done
for c in "${DENIED[@]}"; do judge "new pod (from server Ready)" "$c" closed; done

log "Release: deleting the policy, watching ${WINDOW} s at most"
STEP=release
for c in "${DENIED[@]}"; do watch_bg "$c" open "$WINDOW" 1 "${SRV[@]}" "${NEW_SRV[@]}"; done
await_ready "${DENIED[@]}"
kubectl delete networkpolicy -n "${NS}" srv-ingress >/dev/null || { error "policy delete failed"; exit 1; }
go_all
wait
for c in "${DENIED[@]}"; do judge release "$c" open; done

echo
echo "================ Pod data path: NetworkPolicy timing ================"
printf '%b\n' "${RESULTS[@]}"
echo "Passed: ${PASS_COUNT}  Failed: ${FAIL_COUNT}  (limit ${LIMIT} s)"
(( FAIL_COUNT == 0 ))
