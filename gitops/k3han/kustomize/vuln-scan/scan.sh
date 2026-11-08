#!/bin/sh
# vuln-scan: scan the images running in K3han with trivy and upload the findings
# to GitHub Code Scanning on SafeChord/Chorde (Chorde#40; Docs:
# safechord.chorde.k3han.operations.md §3.1). GitHub calls retry 5xx, 429 and
# failed connections with growing waits for up to an hour.
#
# Any failure of the run as a whole (listing pods, fetching the vulnerability
# database, minting the token, the upload, its processing) exits non-zero: the
# Job fails and KubeJobFailed reaches Slack. An image trivy cannot analyse does
# not fail the run; it is uploaded as a vuln-scan/not-covered alert.
#
# Runs in the aquasec/trivy image (Alpine), which lacks curl, jq and openssl:
# they are added with apk when missing.
set -eu

HERE=${VULN_SCAN_HOME:-$(cd "$(dirname "$0")" && pwd)}
WORK_DIR=${WORK_DIR:-$(mktemp -d)}
SA_DIR=${SA_DIR:-/var/run/secrets/kubernetes.io/serviceaccount}
APP_DIR=${APP_DIR:-/github-app}
VEX_FILE=${VEX_FILE:-/vex/vex.openvex.json}
KUBE_API=${KUBE_API:-https://kubernetes.default.svc}
GITHUB_API=${GITHUB_API:-https://api.github.com}
GITHUB_REPO=${GITHUB_REPO:-SafeChord/Chorde}
GITHUB_REF=${GITHUB_REF:-refs/heads/main}
EXCLUDE_NAMESPACES=${EXCLUDE_NAMESPACES:-safezone}
SEVERITY=${SEVERITY:-HIGH,CRITICAL}
POLL_INTERVAL=${POLL_INTERVAL:-10}
POLL_TRIES=${POLL_TRIES:-60}

log() { echo "vuln-scan: $*" >&2; }
die() { log "FAILED: $*"; exit 1; }

ensure_tools() {
  missing=""
  for t in curl jq openssl gzip base64; do
    command -v "$t" >/dev/null 2>&1 || missing="$missing $t"
  done
  [ -z "$missing" ] && return 0
  log "installing$missing"
  # shellcheck disable=SC2086
  apk add --no-cache $(echo "$missing" | sed 's/gzip//; s/base64//') >/dev/null || die "apk add$missing"
}

list_images() {
  curl -sSf --cacert "$SA_DIR/ca.crt" \
    -H "Authorization: Bearer $(cat "$SA_DIR/token")" \
    "$KUBE_API/api/v1/pods" -o "$WORK_DIR/pods.json" || die "listing pods"
  exclude=$(printf '%s' "$EXCLUDE_NAMESPACES" | jq -R -c 'split(",")')
  jq -c --argjson exclude "$exclude" -f "$HERE/images.jq" "$WORK_DIR/pods.json" \
    > "$WORK_DIR/images.jsonl" || die "reading the pod list"
  count=$(wc -l < "$WORK_DIR/images.jsonl")
  [ "$count" -gt 0 ] || die "no image listed outside $EXCLUDE_NAMESPACES: an empty list is not a clean cluster"
  log "$count images to scan (leaving out namespaces: $EXCLUDE_NAMESPACES)"
}

uncovered() { # uncovered <ref> <image> <reason>
  log "not covered: $2: $3"
  jq -n -c --arg ref "$1" --arg image "$2" --arg reason "$3" \
    '{ref: $ref, image: $image, uncovered: $reason}' >> "$WORK_DIR/entries.jsonl"
}

scan_images() {
  trivy image --quiet --download-db-only < /dev/null || die "fetching the vulnerability database"
  : > "$WORK_DIR/entries.jsonl"
  i=0
  while IFS= read -r line; do
    i=$((i + 1))
    ref=$(printf '%s' "$line" | jq -r .ref)
    image=$(printf '%s' "$line" | jq -r .image)
    out="$WORK_DIR/scan-$i"
    if trivy image --quiet --skip-db-update --scanners vuln --severity "$SEVERITY" \
         --vex "$VEX_FILE" --format json -o "$out.json" "$ref" < /dev/null 2> "$out.err"; then
      if jq -e '(.Results // []) | length > 0' "$out.json" > /dev/null; then
        trivy convert --format sarif -o "$out.sarif" "$out.json" < /dev/null || die "converting the report of $image"
        jq -c --arg ref "$ref" --arg image "$image" '{ref: $ref, image: $image, doc: .}' "$out.sarif" \
          >> "$WORK_DIR/entries.jsonl"
      else
        uncovered "$ref" "$image" "trivy detected no OS or package in the image"
      fi
    else
      uncovered "$ref" "$image" "scan failed: $(tail -n 1 "$out.err" | cut -c 1-300)"
    fi
  done < "$WORK_DIR/images.jsonl"

  jq -s -f "$HERE/sarif.jq" "$WORK_DIR/entries.jsonl" > "$WORK_DIR/result.sarif" || die "merging the reports"
  log "$(jq -r '.runs[0].results | "\(map(select(.ruleId != "vuln-scan/not-covered")) | length) alerts, \(map(select(.ruleId == "vuln-scan/not-covered")) | length) images not covered"' "$WORK_DIR/result.sarif")"
}

b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }

github_request() { # github_request <call> <failure> <response> <auth> <curl args...>
  local call=$1 failure=$2 response=$3 auth=$4
  shift 4
  local started delay now elapsed wait remaining app_id installation header payload signature jwt
  local status curl_rc curl_error

  started=
  delay=5
  while :; do
    now=$(date +%s)

    if [ "$auth" = app ]; then
      # App JWTs last only ten minutes; sign a new one for every token attempt.
      app_id=$(tr -d ' \r\n' < "$APP_DIR/app-id")
      installation=$(tr -d ' \r\n' < "$APP_DIR/installation-id")
      header=$(printf '{"alg":"RS256","typ":"JWT"}' | b64url)
      payload=$(printf '{"iat":%s,"exp":%s,"iss":"%s"}' $((now - 60)) $((now + 540)) "$app_id" | b64url)
      signature=$(printf '%s.%s' "$header" "$payload" | openssl dgst -sha256 -sign "$APP_DIR/private-key" | b64url) \
        || die "signing the App JWT"
      jwt="$header.$payload.$signature"
    elif [ "$auth" = installation ] && { [ -z "${TOKEN:-}" ] || [ "$now" -ge "${TOKEN_REFRESH_AT:-0}" ]; }; then
      github_token
    fi

    : > "$WORK_DIR/github-curl.err"
    if [ "$auth" = app ]; then
      if status=$(curl -sS -X POST -H "Authorization: Bearer $jwt" \
          -H "Accept: application/vnd.github+json" "$@" \
          -o "$response" -w '%{http_code}' 2> "$WORK_DIR/github-curl.err"); then
        curl_rc=0
      else
        curl_rc=$?
      fi
    else
      if status=$(curl -sS -H "Authorization: Bearer $TOKEN" \
          -H "Accept: application/vnd.github+json" \
          -H "X-GitHub-Api-Version: 2022-11-28" "$@" \
          -o "$response" -w '%{http_code}' 2> "$WORK_DIR/github-curl.err"); then
        curl_rc=0
      else
        curl_rc=$?
      fi
    fi
    curl_error=$(cat "$WORK_DIR/github-curl.err")

    if [ "$curl_rc" -eq 0 ]; then
      case $status in
        2[0-9][0-9]) return 0 ;;
        429|5[0-9][0-9]) ;;
        *) die "$failure (HTTP $status)" ;;
      esac
    else
      case $curl_rc in
        5|6|7|16|18|28|35|52|55|56|92) ;;
        *)
          [ -n "$curl_error" ] || curl_error="curl exited with code $curl_rc"
          die "$failure: $curl_error"
          ;;
      esac
    fi

    now=$(date +%s)
    [ -n "$started" ] || started=$now
    elapsed=$((now - started))
    if [ "$elapsed" -ge 3600 ]; then
      if [ -n "$curl_error" ]; then
        die "$failure: $curl_error"
      fi
      die "$failure (HTTP $status)"
    fi

    wait=$delay
    remaining=$((3600 - elapsed))
    [ "$wait" -le "$remaining" ] || wait=$remaining
    if [ -n "$curl_error" ]; then
      log "$call failed ($curl_error); retrying in ${wait}s"
    else
      log "$call returned HTTP $status; retrying in ${wait}s"
    fi
    sleep "$wait"
    if [ "$delay" -lt 300 ]; then
      delay=$((delay * 2))
      [ "$delay" -le 300 ] || delay=300
    fi
  done
}

github_token() {
  local token
  github_request token "minting the installation token" "$WORK_DIR/token.json" app \
    "$GITHUB_API/app/installations/$(tr -d ' \r\n' < "$APP_DIR/installation-id")/access_tokens"
  token=$(jq -r .token "$WORK_DIR/token.json")
  [ -n "$token" ] && [ "$token" != null ] || die "no token in the App's answer"
  TOKEN=$token
  TOKEN_REFRESH_AT=$(($(date +%s) + 3000))
}

upload() {
  github_token
  branch=${GITHUB_REF#refs/heads/}
  github_request head "reading the head of $GITHUB_REF" "$WORK_DIR/commit.json" installation \
    "$GITHUB_API/repos/$GITHUB_REPO/commits/$branch"
  sha=$(jq -r .sha "$WORK_DIR/commit.json")

  gzip -c "$WORK_DIR/result.sarif" | base64 | tr -d '\n' > "$WORK_DIR/result.sarif.gz.b64"
  log "uploading $(wc -c < "$WORK_DIR/result.sarif.gz.b64") bytes (gzip, base64) against $GITHUB_REF $sha"
  jq -n --arg sha "$sha" --arg ref "$GITHUB_REF" --rawfile sarif "$WORK_DIR/result.sarif.gz.b64" \
    '{commit_sha: $sha, ref: $ref, sarif: $sarif, tool_name: "vuln-scan"}' > "$WORK_DIR/upload.json"
  github_request upload "Code Scanning refused the upload" "$WORK_DIR/upload.resp" installation \
    -X POST --data-binary "@$WORK_DIR/upload.json" \
    "$GITHUB_API/repos/$GITHUB_REPO/code-scanning/sarifs"
  id=$(jq -r .id "$WORK_DIR/upload.resp")

  n=0
  while [ "$n" -lt "$POLL_TRIES" ]; do
    n=$((n + 1))
    github_request status "reading the processing status of upload $id" "$WORK_DIR/status.json" installation \
      "$GITHUB_API/repos/$GITHUB_REPO/code-scanning/sarifs/$id"
    status=$(jq -r .processing_status "$WORK_DIR/status.json")
    case $status in
      complete) log "upload $id processed"; return 0 ;;
      failed) die "Code Scanning rejected upload $id: $(jq -c .errors "$WORK_DIR/status.json")" ;;
    esac
    sleep "$POLL_INTERVAL"
  done
  die "upload $id still $status after $POLL_TRIES polls"
}

ensure_tools
list_images
scan_images
upload
