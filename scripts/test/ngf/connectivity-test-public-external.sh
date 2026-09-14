#!/usr/bin/env bash
set -uo pipefail

# SafeChord Infrastructure: NGF Public Edge — EXTERNAL path test
# Purpose: Cover the half of the public path that connectivity-test-public.sh
#          explicitly declares out of scope — the real internet path
#          (DNS → Cloudflare → GCP firewall → edge hostPort → TLS → route).
#          Requires NO kubectl and NO cluster access; runs from any machine.
#
#          Its sibling connectivity-test-public.sh dials the data-plane
#          ClusterIP Service from inside the cluster. That deliberately skips
#          the hostPort, the GCP firewall and Cloudflare, so it can report all
#          gates green while public traffic is dead. The two are complementary;
#          neither replaces the other.
#
# Usage:   bash scripts/test/ngf/connectivity-test-public-external.sh
#          ORIGIN_IP=<gce public ip> bash .../connectivity-test-public-external.sh
#
# Exit:    0 = all gates passed, 1 = at least one gate failed.

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
ECHO_HOST="www.omh.idv.tw"
ECHO_PATH="/echo"
# Cloudflare takes ~20s to give up on an unresponsive origin before it emits
# a 52x, so the probe timeout must exceed that or the failure we are trying to
# read comes back as a local curl timeout (000) instead.
TIMEOUT=30

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
FIREWALL_YAML="${REPO_ROOT}/cluster/k3han/ansible/gce_firewall.yaml"
GATEWAY_YAML="${REPO_ROOT}/gitops/k3han/manifests/public-gateway/gateway.yaml"
CF_IPS_URL="https://www.cloudflare.com/ips-v4"

# ORIGIN_IP is optional. The address IS recorded in this repo as of Chorde#13 --
# inventory.ini carries it as gce-agent-tw's node_external_ip -- but this script
# deliberately does not read it. Defaulting it from the inventory would couple a
# credential-free test, runnable from any machine, to the ansible inventory
# format. Gate 5 is skipped unless the caller supplies it.
ORIGIN_IP="${ORIGIN_IP:-}"

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

gate_skip() {
    GATE_RESULTS+=("  ${YELLOW}SKIP${NC}  $1${2:+ — $2}")
}

# ---------------------------------------------------------------------------
# Gate 1: public DNS resolves the host
# ---------------------------------------------------------------------------
log "--- Gate 1: DNS resolution for ${ECHO_HOST} ---"
if command -v dig >/dev/null 2>&1; then
    RESOLVED=$(dig +short +time=5 A "${ECHO_HOST}" 2>/dev/null | grep -E '^[0-9]+\.' | tr '\n' ' ')
else
    RESOLVED=$(getent ahostsv4 "${ECHO_HOST}" 2>/dev/null | awk '{print $1}' | sort -u | tr '\n' ' ')
fi

if [[ -n "${RESOLVED// /}" ]]; then
    log "Resolved to: ${RESOLVED}✅"
    gate_pass "DNS ${ECHO_HOST} → ${RESOLVED}"
else
    error "${ECHO_HOST} does not resolve"
    gate_fail "DNS ${ECHO_HOST}" "no A record"
fi

# ---------------------------------------------------------------------------
# Gates 2 & 3: the live path through Cloudflare
#   Gate 2 — HTTPS ${ECHO_PATH} → 401 (auth wall reached = whole path alive)
#   Gate 3 — HTTP  ${ECHO_PATH} → 301 (redirect to HTTPS)
# A 5xx in the 520-527 family is Cloudflare reporting on the ORIGIN, not the
# app: 521 = origin refused the TCP connection (RST — nothing listening),
# 522 = TCP timed out (packets dropped: firewall, forwarding, or node down),
# 523 = origin unreachable, 526 = origin certificate invalid. The distinction
# is the whole diagnostic value of this gate, so the code is reported verbatim.
# NOTE: a 301 on the HTTP probe can be served by Cloudflare's own
#       "Always Use HTTPS" and is therefore NOT proof the origin is healthy.
# ---------------------------------------------------------------------------
probe() {
    # $1 = url ; echoes "<http_code>|<cf-ray>|<server>"
    local url="$1" hdr code ray srv
    hdr=$(mktemp)
    code=$(curl -s -o /dev/null -D "${hdr}" -w '%{http_code}' \
        --max-time "${TIMEOUT}" "${url}" 2>/dev/null)
    code="${code:-000}"
    ray=$(awk 'tolower($1) ~ /^cf-ray:/ {print $2}' "${hdr}" | tr -d '\r')
    srv=$(awk 'tolower($1) ~ /^server:/ {print $2}' "${hdr}" | tr -d '\r')
    rm -f "${hdr}"
    echo "${code}|${ray:-none}|${srv:-none}"
}

log "--- Gate 2: HTTPS https://${ECHO_HOST}${ECHO_PATH} via Cloudflare ---"
IFS='|' read -r HTTPS_CODE HTTPS_RAY HTTPS_SRV <<< "$(probe "https://${ECHO_HOST}${ECHO_PATH}")"
log "code=${HTTPS_CODE} server=${HTTPS_SRV} cf-ray=${HTTPS_RAY}"

if [[ "${HTTPS_CODE}" == "401" ]]; then
    log "Auth wall reached — full public path is alive ✅"
    gate_pass "HTTPS ${ECHO_PATH} → 401 (auth wall reached)"
elif [[ "${HTTPS_CODE}" =~ ^52[0-7]$ ]]; then
    error "Cloudflare ${HTTPS_CODE}: the edge could not use the origin (ray ${HTTPS_RAY})"
    case "${HTTPS_CODE}" in
        521) warn "521 = origin REFUSED the connection → nothing bound to the edge hostPort" ;;
        522) warn "522 = origin TCP TIMED OUT → packets dropped (firewall / forwarding / node down)" ;;
        523) warn "523 = origin unreachable → routing or DNS at the Cloudflare origin record" ;;
        526) warn "526 = origin certificate invalid → the CF Origin cert at the HTTPS listener" ;;
    esac
    gate_fail "HTTPS ${ECHO_PATH}" "Cloudflare ${HTTPS_CODE}, ray ${HTTPS_RAY}"
else
    error "Unexpected status ${HTTPS_CODE} (expected 401)"
    gate_fail "HTTPS ${ECHO_PATH}" "expected 401, got ${HTTPS_CODE}"
fi

log "--- Gate 3: HTTP http://${ECHO_HOST}${ECHO_PATH} → 301 ---"
IFS='|' read -r HTTP_CODE HTTP_RAY _ <<< "$(probe "http://${ECHO_HOST}${ECHO_PATH}")"
if [[ "${HTTP_CODE}" == "301" ]]; then
    log "HTTP ${HTTP_CODE} ✅ (may originate at Cloudflare — not proof of origin health)"
    gate_pass "HTTP ${ECHO_PATH} → 301"
else
    error "HTTP probe: expected 301, got ${HTTP_CODE} (ray ${HTTP_RAY})"
    gate_fail "HTTP ${ECHO_PATH}" "expected 301, got ${HTTP_CODE}"
fi

# ---------------------------------------------------------------------------
# Gate 4: Cloudflare IPv4 range drift — three-way
# The CF range list is duplicated in two repo files and drifts upstream on
# Cloudflare's schedule. safechord.chorde.k3han.ingress.md §4 requires the two
# to stay in sync; nothing executable enforced that until this gate. ArgoCD
# cannot catch it — both files can match git while contradicting each other.
#   1. live   — https://www.cloudflare.com/ips-v4
#   2. fw     — gce_firewall.yaml   (GCP allowlist; decides who reaches :443)
#   3. proxy  — gateway.yaml        (NginxProxy.trustedAddresses; decides
#                                    whose X-Forwarded-For is believed)
# A range in `live` but not in `fw` is dropped traffic from real Cloudflare.
# A range in `proxy` but not in `live` is a client-IP spoofing surface.
# ---------------------------------------------------------------------------
log "--- Gate 4: Cloudflare IPv4 range sync (live vs firewall vs NginxProxy) ---"
CIDR_RE='[0-9]{1,3}(\.[0-9]{1,3}){3}/[0-9]{1,2}'

LIVE_CIDRS=$(curl -s --max-time 15 "${CF_IPS_URL}" 2>/dev/null \
    | grep -oE "^${CIDR_RE}$" | sort -u)
FW_CIDRS=$(awk '/cloudflare_ipv4:/{f=1;next} f&&/^[[:space:]]*-[[:space:]]/{print;next} f{exit}' \
    "${FIREWALL_YAML}" 2>/dev/null | grep -oE "${CIDR_RE}" | sort -u)
PROXY_CIDRS=$(awk '/trustedAddresses:/{f=1;next} f&&/type:[[:space:]]*CIDR/{print;next} f{exit}' \
    "${GATEWAY_YAML}" 2>/dev/null | grep -oE "${CIDR_RE}" | sort -u)

if [[ -z "${LIVE_CIDRS}" || -z "${FW_CIDRS}" || -z "${PROXY_CIDRS}" ]]; then
    error "Could not read all three lists (live=$(wc -l <<< "${LIVE_CIDRS}") fw=$(wc -l <<< "${FW_CIDRS}") proxy=$(wc -l <<< "${PROXY_CIDRS}"))"
    gate_fail "CF range sync" "one or more lists unreadable"
else
    MISSING_FW=$(comm -23 <(echo "${LIVE_CIDRS}") <(echo "${FW_CIDRS}") | tr '\n' ' ')
    EXTRA_FW=$(comm -13 <(echo "${LIVE_CIDRS}") <(echo "${FW_CIDRS}") | tr '\n' ' ')
    FW_VS_PROXY=$(comm -3 <(echo "${FW_CIDRS}") <(echo "${PROXY_CIDRS}") | tr -d '\t' | tr '\n' ' ')

    DRIFT=false
    if [[ -n "${MISSING_FW// /}" ]]; then
        error "In live CF ranges but NOT in the GCP allowlist (traffic DROPPED): ${MISSING_FW}"
        DRIFT=true
    fi
    if [[ -n "${EXTRA_FW// /}" ]]; then
        warn "In the GCP allowlist but no longer published by Cloudflare: ${EXTRA_FW}"
        DRIFT=true
    fi
    if [[ -n "${FW_VS_PROXY// /}" ]]; then
        error "gce_firewall.yaml and NginxProxy.trustedAddresses disagree: ${FW_VS_PROXY}"
        DRIFT=true
    fi

    if [[ "${DRIFT}" == "false" ]]; then
        log "All three lists agree ($(wc -l <<< "${LIVE_CIDRS}") ranges) ✅"
        gate_pass "CF range sync (live = firewall = NginxProxy)"
    else
        gate_fail "CF range sync" "see drift above"
    fi
fi

# ---------------------------------------------------------------------------
# Gate 5 (optional): origin-bypass isolation
# safechord.chorde.k3han.ingress.md §3 requires a direct hit on the edge host
# from a non-Cloudflare source to TIME OUT (GCP default-deny drop), not to be
# refused. This asserts that invariant — it is NOT a diagnostic for an outage:
# from any non-Cloudflare machine a healthy edge and a dead one both time out.
# ---------------------------------------------------------------------------
log "--- Gate 5: origin-bypass isolation (optional) ---"
if [[ -z "${ORIGIN_IP}" ]]; then
    warn "ORIGIN_IP not set — skipping. Set it to the GCE public IP to assert the drop."
    gate_skip "Origin-bypass isolation" "ORIGIN_IP not set"
else
    timeout 8 bash -c "echo > /dev/tcp/${ORIGIN_IP}/443" >/dev/null 2>&1
    RC=$?
    case "${RC}" in
        124) log "Direct :443 timed out — firewall drop as designed ✅"
             gate_pass "Origin-bypass isolation (${ORIGIN_IP}:443 dropped)" ;;
        0)   error "Direct :443 CONNECTED from a non-Cloudflare source — allowlist is open"
             gate_fail "Origin-bypass isolation" "${ORIGIN_IP}:443 accepted the connection" ;;
        *)   error "Direct :443 REFUSED (rc=${RC}) — expected a silent drop, got an RST"
             gate_fail "Origin-bypass isolation" "${ORIGIN_IP}:443 refused (rc=${RC})" ;;
    esac
fi

# ---------------------------------------------------------------------------
# Final summary
# ---------------------------------------------------------------------------
TOTAL=$(( PASS_COUNT + FAIL_COUNT ))
echo ""
log "=========================================="
log " NGF Public External Path Test — Final Summary"
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
