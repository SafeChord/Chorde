#!/usr/bin/env bash
set -euo pipefail

# SafeChord Infrastructure: NGF Public Gateway Connectivity Test
# Purpose: Verify the NGF public-gateway (edge data plane on gce-agent-tw) is
#          Programmed, echo's HTTPRoutes are resolved, the HTTP listener
#          301-redirects to HTTPS, and the HTTPS listener enforces basic auth
#          (401 without credentials — proving the AuthenticationFilter + its
#          secret + the route all resolved). The authenticated 200 and the full
#          public internet path (DNS → edge hostPort → TLS) need a browser/curl
#          from OUTSIDE the cluster — out of scope for an unauthenticated,
#          credential-free in-cluster script.
# Usage: bash scripts/test/ngf/connectivity-test-public.sh

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
GATEWAY_NAME="public-gateway"
EDGE_NODE="gce-agent-tw"
ECHO_HOST="www.omh.idv.tw"
CURL_IMAGE="curlimages/curl:8.11.1"

# ---------------------------------------------------------------------------
# HTTPRoutes to verify  (name | namespace | require-ResolvedRefs(true|false))
# echo serves a backend + filters → ResolvedRefs proves backend/auth/snippet all
# resolved. echo-https-redirect is a pure RequestRedirect (no backendRef) →
# Accepted is the meaningful signal, ResolvedRefs is not asserted.
# ---------------------------------------------------------------------------
HTTPROUTES=(
    "echo|testing|true"
    "echo-https-redirect|testing|false"
)

# ---------------------------------------------------------------------------
# Per-gate pass/fail tracking
# ---------------------------------------------------------------------------
PASS_COUNT=0
FAIL_COUNT=0
declare -a GATE_RESULTS=()

gate_pass() {
    GATE_RESULTS+=("  ${GREEN}PASS${NC}  $1")
    PASS_COUNT=$(( PASS_COUNT + 1 ))
}

gate_fail() {
    local label="$1"
    local detail="${2:-}"
    GATE_RESULTS+=("  ${RED}FAIL${NC}  $label${detail:+ — $detail}")
    FAIL_COUNT=$(( FAIL_COUNT + 1 ))
}

# ---------------------------------------------------------------------------
# Gate 1: Gateway Programmed
# ---------------------------------------------------------------------------
log "--- Gate 1: Gateway '${GATEWAY_NAME}' (ns ${NGF_NAMESPACE}) Programmed=True ---"
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
# Gate 2: Data-plane pod Running+Ready AND pinned to the edge node
# ---------------------------------------------------------------------------
log "--- Gate 2: Data-plane pod Running+Ready on '${EDGE_NODE}' ---"
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
    DP_NODE=$(kubectl -n "${NGF_NAMESPACE}" get pod "${DP_POD}" \
        -o jsonpath='{.spec.nodeName}' 2>/dev/null || true)
    if [[ "${DP_PHASE}" == "Running" && "${DP_READY}" == "True" && "${DP_NODE}" == "${EDGE_NODE}" ]]; then
        log "Data-plane pod '${DP_POD}' Running+Ready on '${DP_NODE}' ✅"
        gate_pass "Data-plane pod '${DP_POD}' Running+Ready on '${EDGE_NODE}'"
    else
        error "Data-plane pod '${DP_POD}': phase=${DP_PHASE}, ready=${DP_READY}, node=${DP_NODE}"
        gate_fail "Data-plane pod '${DP_POD}' Running+Ready on edge" "phase=${DP_PHASE} ready=${DP_READY} node=${DP_NODE}"
    fi
fi

# ---------------------------------------------------------------------------
# Gate 3: HTTPRoutes Accepted (+ ResolvedRefs where a backend/filter exists)
# ---------------------------------------------------------------------------
log "--- Gate 3: HTTPRoute conditions ---"
for ROUTE_ENTRY in "${HTTPROUTES[@]}"; do
    IFS='|' read -r ROUTE_NAME ROUTE_NS REQUIRE_RR <<< "${ROUTE_ENTRY}"

    ACCEPTED=$(kubectl -n "${ROUTE_NS}" get httproute "${ROUTE_NAME}" \
        -o jsonpath='{.status.parents[*].conditions[?(@.type=="Accepted")].status}' \
        2>/dev/null || true)
    RESOLVEDREFS=$(kubectl -n "${ROUTE_NS}" get httproute "${ROUTE_NAME}" \
        -o jsonpath='{.status.parents[*].conditions[?(@.type=="ResolvedRefs")].status}' \
        2>/dev/null || true)

    ROUTE_LABEL="HTTPRoute ${ROUTE_NS}/${ROUTE_NAME}"
    OK=true
    [[ "${ACCEPTED}" == "True" ]] || OK=false
    if [[ "${REQUIRE_RR}" == "true" ]]; then
        [[ "${RESOLVEDREFS}" == "True" ]] || OK=false
    fi

    if [[ "${OK}" == "true" ]]; then
        log "${ROUTE_LABEL}: Accepted=${ACCEPTED}, ResolvedRefs=${RESOLVEDREFS:-n/a} ✅"
        gate_pass "${ROUTE_LABEL} Accepted${REQUIRE_RR:+ +ResolvedRefs}"
    else
        error "${ROUTE_LABEL}: Accepted='${ACCEPTED}' ResolvedRefs='${RESOLVEDREFS}'"
        gate_fail "${ROUTE_LABEL}" "Accepted='${ACCEPTED}' ResolvedRefs='${RESOLVEDREFS}'"
    fi
done

# ---------------------------------------------------------------------------
# Gates 4 & 5: behaviour via the data-plane Service (ephemeral curl pod)
#   Gate 4 — HTTP /echo  → 301 (HTTP listener RequestRedirect to HTTPS)
#   Gate 5 — HTTPS /echo → 401 (HTTPS listener cert OK + route + auth enforced)
# For HTTPS we use --connect-to so SNI + Host + cert match the wildcard listener
# (hostname *.omh.idv.tw) while actually dialing the in-cluster Service. -k skips
# CA trust (CF Origin cert is not in curl's bundle; we're testing the edge, not CF).
# ---------------------------------------------------------------------------
log "--- Gates 4 & 5: redirect + auth via data-plane Service ---"
DP_SVC=$(kubectl -n "${NGF_NAMESPACE}" get svc \
    -l "gateway.networking.k8s.io/gateway-name=${GATEWAY_NAME}" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

if [[ -z "${DP_SVC}" ]]; then
    error "Could not discover data-plane Service for gateway '${GATEWAY_NAME}'"
    gate_fail "Data-plane Service discovery" "no Service found"
else
    log "Discovered data-plane Service: ${DP_SVC}"
    DP_SVC_DNS="${DP_SVC}.${NGF_NAMESPACE}.svc.cluster.local"

    CURL_SCRIPT="HTTP_CODE=\$(curl -s -o /dev/null -w '%{http_code}' -H 'Host: ${ECHO_HOST}' 'http://${DP_SVC_DNS}/echo')"
    CURL_SCRIPT+="; HTTPS_CODE=\$(curl -s -k -o /dev/null -w '%{http_code}' --connect-to '${ECHO_HOST}:443:${DP_SVC_DNS}:443' 'https://${ECHO_HOST}/echo')"
    CURL_SCRIPT+="; printf 'NGF_RESULTS_START\nhttp-redirect|%s|301\nhttps-auth|%s|401\nNGF_RESULTS_END\n' \"\${HTTP_CODE}\" \"\${HTTPS_CODE}\""

    POD_NAME="ngf-pub-curl-${RANDOM}"
    log "Launching ephemeral curl pod '${POD_NAME}'..."

    # Detached run + wait + logs (NOT 'run --rm -i', which silently races the
    # attach-fallback teardown and can lose output — see the private script note).
    kubectl run "${POD_NAME}" --restart=Never --image="${CURL_IMAGE}" \
        --command -- sh -c "${CURL_SCRIPT}" >/dev/null 2>&1 || true
    kubectl wait --for=jsonpath='{.status.phase}'=Succeeded \
        "pod/${POD_NAME}" --timeout=120s >/dev/null 2>&1 || true
    RAW_OUT=$(kubectl logs "${POD_NAME}" 2>/dev/null || true)
    kubectl delete pod "${POD_NAME}" --ignore-not-found --wait=false >/dev/null 2>&1 || true

    CURL_OUT=$(awk '/NGF_RESULTS_START/{found=1;next} /NGF_RESULTS_END/{found=0} found' <<< "${RAW_OUT}")

    # Completeness guard: both checks must report (else the pod never ran).
    RESULT_LINES=$(grep -c '|' <<< "${CURL_OUT}" || true)
    if [[ "${RESULT_LINES}" -ne 2 ]]; then
        error "Reachability incomplete: ${RESULT_LINES}/2 results (curl pod likely failed)"
        gate_fail "Reachability completeness" "got ${RESULT_LINES}/2 results"
    fi

    while IFS='|' read -r LABEL ACTUAL EXPECTED; do
        [[ -z "${LABEL}" ]] && continue
        if [[ "${ACTUAL}" == "${EXPECTED}" ]]; then
            log "Check '${LABEL}': HTTP ${ACTUAL} ✅"
            gate_pass "Behaviour '${LABEL}' → ${ACTUAL}"
        else
            error "Check '${LABEL}': expected HTTP ${EXPECTED}, got ${ACTUAL}"
            gate_fail "Behaviour '${LABEL}'" "expected ${EXPECTED}, got ${ACTUAL}"
        fi
    done <<< "${CURL_OUT}"
fi

# ---------------------------------------------------------------------------
# Final summary
# ---------------------------------------------------------------------------
TOTAL=$(( PASS_COUNT + FAIL_COUNT ))
echo ""
log "=========================================="
log " NGF Public Connectivity Test — Final Summary"
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
