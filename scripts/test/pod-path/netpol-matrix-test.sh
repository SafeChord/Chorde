#!/usr/bin/env bash
set -uo pipefail

# SafeChord Infrastructure: K3han pod data path — NetworkPolicy matrix (Chorde#16)
# Purpose: Prove that k3s's embedded kube-router NetworkPolicy still holds, and
#          that pods see real client source IPs, on every node pair.
#
#          Tailscale and kube-router both write FORWARD and neither arbitrates
#          the order. When Tailscale's ts-forward ran first on a node, its
#          subnet SNAT rewrote every cross-node client to that node's cni0
#          address. Policy verdicts survived, because FORWARD runs before the
#          POSTROUTING masquerade, but the application saw one address for
#          everyone. This test checks both halves on every pair.
#
#          Fixture (netpol-probe.yaml): per node, one server (agnhost netexec,
#          /clientip echoes the source it sees) and three clients:
#            allowed  role=allowed                   -> may reach every server
#            denied   role=denied                    -> reaches no server
#            egress   role=allowed, egress=limited   -> may reach srv-ct only
#
#          Mutates the cluster: creates namespace netpol-probe and deletes it
#          on exit.
#
# Usage:   bash scripts/test/pod-path/netpol-matrix-test.sh
# Exit:    0 = matrix as expected, 1 = at least one probe diverged.

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

log()   { echo -e "${GREEN}[INFO] $1${NC}"; }
error() { echo -e "${RED}[ERROR] $1${NC}"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIXTURE="${SCRIPT_DIR}/netpol-probe.yaml"
NS="netpol-probe"
NODES=(acer ct gce)

PASS_COUNT=0
FAIL_COUNT=0
declare -a RESULTS=()

cleanup() {
    log "Deleting namespace ${NS}"
    kubectl delete ns "${NS}" --wait=true --timeout=120s >/dev/null 2>&1
}
trap cleanup EXIT

log "Applying fixture"
kubectl apply -f "${FIXTURE}" >/dev/null || { error "apply failed"; exit 1; }
if ! kubectl wait -n "${NS}" --for=condition=Ready pod --all --timeout=180s >/dev/null; then
    error "fixture pods not Ready"; exit 1
fi
# kube-router programs policy asynchronously after pods start.
sleep 20

ip_of() { kubectl get pod -n "${NS}" "$1" -o jsonpath='{.status.podIP}'; }

declare -A SRV_IP=()
for s in "${NODES[@]}"; do SRV_IP[$s]=$(ip_of "srv-$s"); done

expect_allowed() {
    local role="$1" server="$2"
    case "$role" in
        allowed) return 0 ;;
        denied)  return 1 ;;
        egress)  [[ "$server" == "ct" ]] ;;
    esac
}

for c in "${NODES[@]}"; do
    for role in allowed denied egress; do
        client="cli-${c}-${role}"
        client_ip=$(ip_of "$client")
        for s in "${NODES[@]}"; do
            label="${client} -> srv-${s}"
            out=$(kubectl exec -n "${NS}" "$client" -- \
                curl -s -m 4 "http://${SRV_IP[$s]}:8080/clientip" 2>/dev/null)
            rc=$?
            seen="${out%:*}"
            if expect_allowed "$role" "$s"; then
                if (( rc != 0 )); then
                    RESULTS+=("  ${RED}FAIL${NC}  ${label} — expected allow, curl rc=${rc}")
                    FAIL_COUNT=$(( FAIL_COUNT + 1 ))
                elif [[ "$seen" != "$client_ip" ]]; then
                    RESULTS+=("  ${RED}FAIL${NC}  ${label} — source rewritten: server saw ${seen}, client is ${client_ip}")
                    FAIL_COUNT=$(( FAIL_COUNT + 1 ))
                else
                    RESULTS+=("  ${GREEN}PASS${NC}  ${label} — allowed, source ${seen}")
                    PASS_COUNT=$(( PASS_COUNT + 1 ))
                fi
            else
                if (( rc == 0 )); then
                    RESULTS+=("  ${RED}FAIL${NC}  ${label} — expected deny, got through")
                    FAIL_COUNT=$(( FAIL_COUNT + 1 ))
                else
                    RESULTS+=("  ${GREEN}PASS${NC}  ${label} — denied (curl rc=${rc})")
                    PASS_COUNT=$(( PASS_COUNT + 1 ))
                fi
            fi
        done
    done
done

echo
echo "================ Pod data path: NetworkPolicy matrix ================"
printf '%b\n' "${RESULTS[@]}"
echo "Passed: ${PASS_COUNT}  Failed: ${FAIL_COUNT}"
(( FAIL_COUNT == 0 ))
