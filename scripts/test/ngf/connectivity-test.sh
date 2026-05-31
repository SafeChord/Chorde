#!/usr/bin/env bash
set -euo pipefail

# SafeChord Infrastructure: NGF Private Gateway Connectivity Test
# Purpose: Verify NGINX Gateway Fabric private-gateway is Accepted, Programmed,
#          HTTPRoutes are resolved, all routes are reachable in-cluster, and the
#          in-cluster cloudflared tunnel pod (the component the cutover added) is
#          healthy. (The external chain incl. CF Access/OAuth needs a browser.)
# Usage: bash scripts/test/ngf/connectivity-test.sh

# ---------------------------------------------------------------------------
# Colors & log helpers (match repo convention)
# ---------------------------------------------------------------------------
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()   { echo -e "${GREEN}[INFO] $1${NC}"; }
warn()  { echo -e "${YELLOW}[WARN] $1${NC}"; }
error() { echo -e "${RED}[ERROR] $1${NC}"; }

# ---------------------------------------------------------------------------
# Static config
# ---------------------------------------------------------------------------
NGF_NAMESPACE="nginx-gateway"
GATEWAY_NAME="private-gateway"
GATEWAYCLASS_NAME="nginx"
CURL_IMAGE="curlimages/curl:8.11.1"

# ---------------------------------------------------------------------------
# Route table  (host | path | expected-final-http-code | follow-redirects)
# Add a new row here to extend coverage — no other edits required.
# Fields: HOST  PATH  EXPECTED_CODE  FOLLOW_REDIRECTS(true|false)
# Use empty string for HOST to send no Host header override.
# ---------------------------------------------------------------------------
ROUTES=(
    # host                  path      code  follow_redirects
    "k3han.omh.idv.tw|/argocd|200|true"
    "k3han.omh.idv.tw|/grafana|200|true"
)

# ---------------------------------------------------------------------------
# HTTPRoutes to verify (name | namespace)
# ---------------------------------------------------------------------------
HTTPROUTES=(
    "argocd|argocd"
    "grafana|monitoring"
)

# ---------------------------------------------------------------------------
# Per-gate pass/fail tracking
# ---------------------------------------------------------------------------
PASS_COUNT=0
FAIL_COUNT=0
declare -a GATE_RESULTS=()

gate_pass() {
    local label="$1"
    GATE_RESULTS+=("  ${GREEN}PASS${NC}  $label")
    PASS_COUNT=$(( PASS_COUNT + 1 ))
}

gate_fail() {
    local label="$1"
    local detail="${2:-}"
    GATE_RESULTS+=("  ${RED}FAIL${NC}  $label${detail:+ — $detail}")
    FAIL_COUNT=$(( FAIL_COUNT + 1 ))
}

# ---------------------------------------------------------------------------
# Gate 1: GatewayClass Accepted
# ---------------------------------------------------------------------------
log "--- Gate 1: GatewayClass '${GATEWAYCLASS_NAME}' Accepted=True ---"
GC_STATUS=$(kubectl get gatewayclass "${GATEWAYCLASS_NAME}" \
    -o jsonpath='{.status.conditions[?(@.type=="Accepted")].status}' 2>/dev/null || true)
if [[ "${GC_STATUS}" == "True" ]]; then
    log "GatewayClass '${GATEWAYCLASS_NAME}' Accepted=True ✅"
    gate_pass "GatewayClass '${GATEWAYCLASS_NAME}' Accepted=True"
else
    error "GatewayClass '${GATEWAYCLASS_NAME}' Accepted status: '${GC_STATUS}'"
    gate_fail "GatewayClass '${GATEWAYCLASS_NAME}' Accepted" "got '${GC_STATUS}'"
fi

# ---------------------------------------------------------------------------
# Gate 2: Gateway Programmed
# ---------------------------------------------------------------------------
log "--- Gate 2: Gateway '${GATEWAY_NAME}' (ns ${NGF_NAMESPACE}) Programmed=True ---"
GW_STATUS=$(kubectl -n "${NGF_NAMESPACE}" get gateway "${GATEWAY_NAME}" \
    -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}' 2>/dev/null || true)
if [[ "${GW_STATUS}" == "True" ]]; then
    log "Gateway '${GATEWAY_NAME}' Programmed=True ✅"
    gate_pass "Gateway '${GATEWAY_NAME}' Programmed=True"
else
    error "Gateway '${GATEWAY_NAME}' Programmed status: '${GW_STATUS}'"
    gate_fail "Gateway '${GATEWAY_NAME}' Programmed" "got '${GW_STATUS}'"
fi

# ---------------------------------------------------------------------------
# Gate 3: Data-plane pod Running + Ready
# ---------------------------------------------------------------------------
log "--- Gate 3: Data-plane pod Running+Ready ---"
DP_POD=$(kubectl -n "${NGF_NAMESPACE}" get pods \
    -l "gateway.networking.k8s.io/gateway-name=${GATEWAY_NAME}" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

if [[ -z "${DP_POD}" ]]; then
    error "No data-plane pod found for gateway '${GATEWAY_NAME}'"
    gate_fail "Data-plane pod exists" "no pod found"
else
    DP_PHASE=$(kubectl -n "${NGF_NAMESPACE}" get pod "${DP_POD}" \
        -o jsonpath='{.status.phase}' 2>/dev/null || true)
    DP_READY=$(kubectl -n "${NGF_NAMESPACE}" get pod "${DP_POD}" \
        -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
    if [[ "${DP_PHASE}" == "Running" && "${DP_READY}" == "True" ]]; then
        log "Data-plane pod '${DP_POD}' is Running+Ready ✅"
        gate_pass "Data-plane pod '${DP_POD}' Running+Ready"
    else
        error "Data-plane pod '${DP_POD}': phase=${DP_PHASE}, ready=${DP_READY}"
        gate_fail "Data-plane pod '${DP_POD}' Running+Ready" "phase=${DP_PHASE} ready=${DP_READY}"
    fi
fi

# ---------------------------------------------------------------------------
# Gate 4: HTTPRoutes Accepted=True AND ResolvedRefs=True
# ---------------------------------------------------------------------------
log "--- Gate 4: HTTPRoute conditions ---"
for ROUTE_ENTRY in "${HTTPROUTES[@]}"; do
    ROUTE_NAME="${ROUTE_ENTRY%%|*}"
    ROUTE_NS="${ROUTE_ENTRY##*|}"

    # Extract all condition types and statuses via jq-free approach using jsonpath
    ACCEPTED=$(kubectl -n "${ROUTE_NS}" get httproute "${ROUTE_NAME}" \
        -o jsonpath='{.status.parents[*].conditions[?(@.type=="Accepted")].status}' \
        2>/dev/null || true)
    RESOLVEDREFS=$(kubectl -n "${ROUTE_NS}" get httproute "${ROUTE_NAME}" \
        -o jsonpath='{.status.parents[*].conditions[?(@.type=="ResolvedRefs")].status}' \
        2>/dev/null || true)

    ROUTE_LABEL="HTTPRoute ${ROUTE_NS}/${ROUTE_NAME}"
    if [[ "${ACCEPTED}" == "True" && "${RESOLVEDREFS}" == "True" ]]; then
        log "${ROUTE_LABEL}: Accepted=True, ResolvedRefs=True ✅"
        gate_pass "${ROUTE_LABEL} Accepted+ResolvedRefs=True"
    else
        error "${ROUTE_LABEL}: Accepted='${ACCEPTED}' ResolvedRefs='${RESOLVEDREFS}'"
        gate_fail "${ROUTE_LABEL}" "Accepted='${ACCEPTED}' ResolvedRefs='${RESOLVEDREFS}'"
    fi
done

# ---------------------------------------------------------------------------
# Gate 5: HTTP reachability via data-plane Service (ephemeral curl pod)
# ---------------------------------------------------------------------------
log "--- Gate 5: HTTP reachability via data-plane Service ---"

# Discover the data-plane Service name dynamically (never hardcoded)
DP_SVC=$(kubectl -n "${NGF_NAMESPACE}" get svc \
    -l "gateway.networking.k8s.io/gateway-name=${GATEWAY_NAME}" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

if [[ -z "${DP_SVC}" ]]; then
    error "Could not discover data-plane Service for gateway '${GATEWAY_NAME}'"
    gate_fail "Data-plane Service discovery" "no Service found"
else
    log "Discovered data-plane Service: ${DP_SVC}"
    DP_SVC_DNS="${DP_SVC}.${NGF_NAMESPACE}.svc.cluster.local"

    # Build a single sh -c payload that runs all route checks in one ephemeral pod.
    # Results are wrapped in NGF_RESULTS_START/END markers so that kubectl's
    # attach-warning noise (which goes to stdout on -i) is reliably stripped.
    # Each result line format:  <label>|<actual_code>|<expected_code>
    CURL_SCRIPT="OUT=''"
    for ROUTE_ENTRY in "${ROUTES[@]}"; do
        IFS='|' read -r R_HOST R_PATH R_EXPECTED R_FOLLOW <<< "${ROUTE_ENTRY}"
        FOLLOW_FLAG=""
        [[ "${R_FOLLOW}" == "true" ]] && FOLLOW_FLAG="-L"

        HOST_FLAG=""
        LABEL="${R_PATH}"
        if [[ -n "${R_HOST}" ]]; then
            HOST_FLAG="-H 'Host: ${R_HOST}'"
            LABEL="${R_HOST}${R_PATH}"
        fi

        URL="http://${DP_SVC_DNS}${R_PATH}"
        CURL_SCRIPT+="; CODE=\$(curl -s -o /dev/null -w '%{http_code}' ${FOLLOW_FLAG} ${HOST_FLAG} '${URL}')"
        CURL_SCRIPT+="; OUT=\"\${OUT}${LABEL}|\${CODE}|${R_EXPECTED}
\""
    done
    CURL_SCRIPT+="; printf 'NGF_RESULTS_START\n%sNGF_RESULTS_END\n' \"\${OUT}\""

    POD_NAME="ngf-curl-${RANDOM}"
    log "Launching ephemeral curl pod '${POD_NAME}'..."

    # NOTE: we deliberately AVOID 'kubectl run --rm -i' here. On clusters where
    # the API server cannot upgrade the attach connection, kubectl silently
    # falls back to log streaming and races the '--rm' teardown, yielding an
    # EMPTY result. The previous version then parsed nothing, added zero gates,
    # and STILL reported success — masking a total HTTP-reachability blackout.
    # Instead: run detached, wait for completion, pull logs, then delete.
    kubectl run "${POD_NAME}" --restart=Never --image="${CURL_IMAGE}" \
        --command -- sh -c "${CURL_SCRIPT}" >/dev/null 2>&1 || true
    kubectl wait --for=jsonpath='{.status.phase}'=Succeeded \
        "pod/${POD_NAME}" --timeout=120s >/dev/null 2>&1 || true
    RAW_OUT=$(kubectl logs "${POD_NAME}" 2>/dev/null || true)
    kubectl delete pod "${POD_NAME}" --ignore-not-found --wait=false >/dev/null 2>&1 || true

    # Extract only lines between the markers (defensive — strips any stray noise)
    CURL_OUT=$(awk '/NGF_RESULTS_START/{found=1;next} /NGF_RESULTS_END/{found=0} found' <<< "${RAW_OUT}")

    # Completeness guard: every route in ROUTES must yield exactly one result
    # line. If fewer came back (pod never ran, image pull failed, logs lost),
    # FAIL loudly — never let an empty result masquerade as a pass.
    RESULT_LINES=$(grep -c '|' <<< "${CURL_OUT}" || true)
    EXPECTED_LINES=${#ROUTES[@]}
    if [[ "${RESULT_LINES}" -ne "${EXPECTED_LINES}" ]]; then
        error "HTTP reachability incomplete: ${RESULT_LINES}/${EXPECTED_LINES} route results (curl pod likely failed)"
        gate_fail "HTTP reachability completeness" "got ${RESULT_LINES}/${EXPECTED_LINES} results"
    fi

    while IFS='|' read -r LABEL ACTUAL EXPECTED; do
        [[ -z "${LABEL}" ]] && continue
        if [[ "${ACTUAL}" == "${EXPECTED}" ]]; then
            log "Route '${LABEL}': HTTP ${ACTUAL} ✅"
            gate_pass "HTTP route '${LABEL}' → ${ACTUAL}"
        else
            error "Route '${LABEL}': expected HTTP ${EXPECTED}, got ${ACTUAL}"
            gate_fail "HTTP route '${LABEL}'" "expected ${EXPECTED}, got ${ACTUAL}"
        fi
    done <<< "${CURL_OUT}"
fi

# ---------------------------------------------------------------------------
# Gate 6: cloudflared tunnel pod healthy
# This is the component the NGF cutover INTRODUCED (in-cluster cloudflared
# replacing the host systemd service). Gates 1-5 prove the in-cluster NGF half;
# this proves the tunnel half is up. cloudflared's readiness probe hits its own
# /ready (:2000), so Ready=True implies the tunnel is connected to CF's edge.
# restartCount==0 is the soak-stability signal (a crash-loop would surface here
# even while Ready flaps back to True). The full external chain (CF Access /
# OAuth) still needs a browser — out of scope for an unauthenticated script.
# ---------------------------------------------------------------------------
CF_NAMESPACE="cloudflared"
CF_SELECTOR="app.kubernetes.io/name=cloudflared"

log "--- Gate 6: cloudflared tunnel pod Running+Ready, 0 restarts ---"
CF_POD=$(kubectl -n "${CF_NAMESPACE}" get pods -l "${CF_SELECTOR}" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

if [[ -z "${CF_POD}" ]]; then
    error "No cloudflared pod found in ns '${CF_NAMESPACE}' (selector ${CF_SELECTOR})"
    gate_fail "cloudflared pod exists" "no pod found"
else
    CF_PHASE=$(kubectl -n "${CF_NAMESPACE}" get pod "${CF_POD}" \
        -o jsonpath='{.status.phase}' 2>/dev/null || true)
    CF_READY=$(kubectl -n "${CF_NAMESPACE}" get pod "${CF_POD}" \
        -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
    CF_RESTARTS=$(kubectl -n "${CF_NAMESPACE}" get pod "${CF_POD}" \
        -o jsonpath='{.status.containerStatuses[0].restartCount}' 2>/dev/null || true)
    if [[ "${CF_PHASE}" == "Running" && "${CF_READY}" == "True" && "${CF_RESTARTS}" == "0" ]]; then
        log "cloudflared pod '${CF_POD}' Running+Ready, ${CF_RESTARTS} restarts ✅"
        gate_pass "cloudflared pod '${CF_POD}' Running+Ready (0 restarts)"
    else
        error "cloudflared pod '${CF_POD}': phase=${CF_PHASE}, ready=${CF_READY}, restarts=${CF_RESTARTS}"
        gate_fail "cloudflared pod '${CF_POD}' healthy" "phase=${CF_PHASE} ready=${CF_READY} restarts=${CF_RESTARTS}"
    fi
fi

# ---------------------------------------------------------------------------
# Final summary
# ---------------------------------------------------------------------------
TOTAL=$(( PASS_COUNT + FAIL_COUNT ))
echo ""
log "=========================================="
log " NGF Connectivity Test — Final Summary"
log "=========================================="
for LINE in "${GATE_RESULTS[@]}"; do
    echo -e "$LINE"
done
echo ""
if [[ "${FAIL_COUNT}" -eq 0 ]]; then
    log "Result: ${PASS_COUNT}/${TOTAL} gates PASSED ✅"
    exit 0
else
    error "Result: ${FAIL_COUNT}/${TOTAL} gates FAILED ❌  (${PASS_COUNT} passed)"
    exit 1
fi
