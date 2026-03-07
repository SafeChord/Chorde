#!/usr/bin/env bash
set -e

# Configuration
NAMESPACE="default"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PRIVATE_DIR="$SCRIPT_DIR/ingress-private"
PUBLIC_DIR="$SCRIPT_DIR/ingress-public"

# Test Targets
PUBLIC_URL="http://www.omh.idv.tw/echo"
PRIVATE_URL="https://k3han.omh.idv.tw/nginx"

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo -e "${GREEN}[INFO] $1${NC}"; }
warn() { echo -e "${YELLOW}[WARN] $1${NC}"; }
error() { echo -e "${RED}[ERROR] $1${NC}"; }

cleanup() {
    log "Cleaning up resources..."
    kubectl delete -f "$PRIVATE_DIR/nginx-test.yaml" --ignore-not-found
    kubectl delete -f "$PRIVATE_DIR/nginx-ingress.yaml" --ignore-not-found
    kubectl delete -f "$PUBLIC_DIR/echo-test.yaml" --ignore-not-found
    kubectl delete -f "$PUBLIC_DIR/echo-ingress.yaml" --ignore-not-found
    [ -f /tmp/curl_out.html ] && rm /tmp/curl_out.html
    log "Cleanup complete."
}

check_url() {
    local URL=$1
    local EXPECTED_CODE=$2
    local DESC=$3

    echo -n "Testing $DESC ($URL) ... "
    
    # Run curl and capture output
    # -L follows redirects, which usually leads to Cloudflare Login page (200 OK)
    CODE=$(curl -s -L --max-time 10 -o /tmp/curl_out.html -w "%{http_code}" "$URL")
    TITLE=$(grep -o "<title>.*</title>" /tmp/curl_out.html | sed 's/<[^>]*>//g' || echo "No Title")

    if [[ "$CODE" == "$EXPECTED_CODE" ]]; then
        echo -e "${GREEN}PASS (Got $CODE: $TITLE)${NC}"
    elif [[ "$TITLE" == *"Cloudflare Access"* ]] || [[ "$TITLE" == *"Sign in"* ]]; then
        echo -e "${GREEN}PASS (Reachable via Cloudflare Auth Wall)${NC}"
    elif [[ "$CODE" == "302" ]]; then
        echo -e "${GREEN}PASS (Redirected correctly)${NC}"
    else
        echo -e "${RED}FAIL (Expected $EXPECTED_CODE, Got $CODE)${NC}"
        echo "      Detected Title: $TITLE"
    fi
}

# Register cleanup
trap cleanup EXIT

log "--- Starting Ingress Connectivity Test (Production Domains) ---"

# 1. Deploy Workloads
log "Deploying Workloads..."
kubectl apply -f "$PRIVATE_DIR/nginx-test.yaml"
kubectl apply -f "$PRIVATE_DIR/nginx-ingress.yaml"

kubectl apply -f "$PUBLIC_DIR/echo-test.yaml"
kubectl apply -f "$PUBLIC_DIR/echo-ingress.yaml"

# 2. Wait for Readiness
log "Waiting for pods to be ready..."
kubectl wait --for=condition=ready pod -l app=test-nginx --timeout=60s
kubectl wait --for=condition=ready pod -l app=test-echo --timeout=60s

log "Waiting 15s for Ingress propagation & Cloudflare sync..."
sleep 15

# 3. Execute Tests
log "\n--- Executing Connectivity Tests ---"

# Test 1: Public Ingress (Should be accessible directly)
check_url "$PUBLIC_URL" "200" "Public Ingress -> Echo"

# Test 2: Private Ingress (Should be reachable, but behind Auth Wall)
check_url "$PRIVATE_URL" "200" "Private Ingress -> Nginx"

# Test 3: Isolation / Misdirection
# Try to access Private Path via Public Domain
# Expected: 404 (Nginx on Public Ingress doesn't know /nginx)
check_url "http://www.omh.idv.tw/nginx" "404" "Isolation Check (Public Domain -> Private Path)"

log "\n--- Test Suite Completed ---"
