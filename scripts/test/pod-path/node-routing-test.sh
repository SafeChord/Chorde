#!/usr/bin/env bash
set -uo pipefail

# SafeChord Infrastructure: K3han pod data path — node state gates (Chorde#16)
# Purpose: Assert the outcome the Tailscale-routed pod network depends on, on
#          every node, without deploying anything.
#
#          Cross-node pod traffic rides Tailscale subnet routes, not flannel's
#          VXLAN backend: Tailscale's `ip rule` (table 52) is consulted before
#          the main table and claims each remote pod CIDR ahead of flannel's
#          `via flannel.1` route. If any precondition breaks -- the route is not
#          advertised, not approved, not accepted, or the rule order changes --
#          traffic falls back to VXLAN-inside-WireGuard. Nothing errors. Gate 4
#          therefore asks the kernel for its final routing decision rather than
#          checking each precondition separately.
#
#          Read-only. Remote nodes are reached over ssh by node name; the node
#          this runs on is checked locally.
#
# Usage:   bash scripts/test/pod-path/node-routing-test.sh
# Exit:    0 = all gates passed, 1 = at least one gate failed.

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()   { echo -e "${GREEN}[INFO] $1${NC}"; }
error() { echo -e "${RED}[ERROR] $1${NC}"; }

PASS_COUNT=0
FAIL_COUNT=0
declare -a GATE_RESULTS=()

gate_pass() {
    GATE_RESULTS+=("  ${GREEN}PASS${NC}  $1")
    PASS_COUNT=$(( PASS_COUNT + 1 ))
}

gate_fail() {
    GATE_RESULTS+=("  ${RED}FAIL${NC}  $1${2:+ — $2}")
    FAIL_COUNT=$(( FAIL_COUNT + 1 ))
}

# Run a command on a node: locally if it is this host, otherwise over ssh.
on_node() {
    local node="$1"; shift
    if [[ "$node" == "$(hostname)" ]]; then
        bash -c "$*"
    else
        ssh -o BatchMode=yes -o ConnectTimeout=10 "$node" "$*" </dev/null
    fi
}

# `tailscale debug prefs` works unprivileged for the tailscale operator user;
# fall back to non-interactive sudo elsewhere.
prefs_json() {
    on_node "$1" 'tailscale debug prefs 2>/dev/null || sudo -n tailscale debug prefs'
}

# ---------------------------------------------------------------------------
# Discover nodes and their allocated pod CIDRs (the authoritative source)
# ---------------------------------------------------------------------------
declare -A POD_CIDR=()
while read -r name cidr; do
    [[ -n "$name" && -n "$cidr" ]] && POD_CIDR["$name"]="$cidr"
done < <(kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name} {.spec.podCIDR}{"\n"}{end}')

if (( ${#POD_CIDR[@]} == 0 )); then
    error "No nodes with a podCIDR returned by kubectl"
    exit 1
fi

for node in $(printf '%s\n' "${!POD_CIDR[@]}" | sort); do
    log "--- ${node} (podCIDR ${POD_CIDR[$node]}) ---"

    if ! PREFS=$(prefs_json "$node"); then
        gate_fail "${node}: read tailscaled prefs" "ssh or tailscale unavailable"
        continue
    fi
    pref() { python3 -c "import json,sys; print(json.dumps(json.load(sys.stdin).get('$1')))" <<<"$PREFS"; }

    # Gate 1: subnet SNAT is off. With it on, source identity depends on
    # whether ts-forward or kube-router's ACCEPT comes first in FORWARD.
    if [[ "$(pref NoSNAT)" == "true" ]]; then
        gate_pass "${node}: NoSNAT"
    else
        gate_fail "${node}: NoSNAT" "got $(pref NoSNAT)"
    fi

    # Gate 2: accepts the other nodes' routes into table 52.
    if [[ "$(pref RouteAll)" == "true" ]]; then
        gate_pass "${node}: accept-routes"
    else
        gate_fail "${node}: accept-routes" "got $(pref RouteAll)"
    fi

    # Gate 3: advertises exactly its own allocated pod CIDR.
    ADV=$(pref AdvertiseRoutes)
    if [[ "$ADV" == "[\"${POD_CIDR[$node]}\"]" ]]; then
        gate_pass "${node}: advertises own podCIDR"
    else
        gate_fail "${node}: advertises own podCIDR" "want [\"${POD_CIDR[$node]}\"], got ${ADV}"
    fi

    # Gate 4: the kernel routes every other node's pod CIDR into the tunnel.
    for peer in "${!POD_CIDR[@]}"; do
        [[ "$peer" == "$node" ]] && continue
        probe="${POD_CIDR[$peer]%.*/*}.1"
        ROUTE=$(on_node "$node" "ip route get ${probe}" | head -1)
        if [[ "$ROUTE" == *"dev tailscale0 table 52"* ]]; then
            gate_pass "${node}: route to ${peer} (${probe}) via tailscale0 table 52"
        else
            gate_fail "${node}: route to ${peer} (${probe}) via tailscale0 table 52" "got: ${ROUTE}"
        fi
    done

    # Gate 5: bridged same-node traffic is passed to iptables, which is what
    # lets NetworkPolicy see it.
    BNF=$(on_node "$node" 'cat /proc/sys/net/bridge/bridge-nf-call-iptables 2>/dev/null')
    if [[ "$BNF" == "1" ]]; then
        gate_pass "${node}: bridge-nf-call-iptables = 1"
    else
        gate_fail "${node}: bridge-nf-call-iptables = 1" "got '${BNF}'"
    fi

    # Gate 6: nothing has ever arrived over the VXLAN overlay. RX only: TX
    # carries tailscaled's own disco probes and is expected to be nonzero.
    RX=$(on_node "$node" 'cat /sys/class/net/flannel.1/statistics/rx_bytes 2>/dev/null')
    if [[ "$RX" == "0" ]]; then
        gate_pass "${node}: flannel.1 rx_bytes = 0"
    else
        gate_fail "${node}: flannel.1 rx_bytes = 0" "got '${RX}' — traffic has used the VXLAN fallback"
    fi
done

echo
echo "================ Pod data path: node state ================"
printf '%b\n' "${GATE_RESULTS[@]}"
echo "Passed: ${PASS_COUNT}  Failed: ${FAIL_COUNT}"
(( FAIL_COUNT == 0 ))
