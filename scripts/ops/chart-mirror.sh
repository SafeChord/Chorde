#!/bin/sh
# Mirror into zot, as OCI artifacts, the charts whose upstream publishes none
# at the version a wrapper names (Chorde#102).
#
# For each wrapper in MIRROR_CHARTS, reads its dependency's name, version and
# classic repository from gitops/<env>/charts/<wrapper>/Chart.yaml, and, unless
# zot already holds that version, pulls it from the repository and pushes it
# to oci://<registry>/<repository host and path>/<name>:<version>. keda's
# 2.21.0 from https://kedacore.github.io/charts lands at
# <registry>/kedacore.github.io/charts/keda:2.21.0. No sync entry in zot's
# configuration names these hosts, so zot never looks for them upstream.
#
#   chart-mirror.sh <gitops-env-dir> <registry host:port>
#
# Environment:
#   MIRROR_CHARTS      wrappers to mirror, space-separated (default below)
#   REGISTRY_USERNAME  zot user allowed to push; REGISTRY_PASSWORD its password
#   PLAIN_HTTP         1 (default) talks to the registry over plain HTTP
#
# Exits 0 when every chart is in zot, 1 when any is not, after trying all.
# Runs in zot's chart-mirror CronJob; written to run the same from CI.
# Needs: sh, awk, helm 3.
set -u

# keda: kedacore/charts publishes no OCI artifact. alloy: grafana publishes
# one only from 1.16.0; drop it once the wrapper names 1.16.0 or later.
MIRROR_CHARTS=${MIRROR_CHARTS:-"keda alloy"}

ENV_DIR=${1:?usage: chart-mirror.sh <gitops-env-dir> <registry host:port>}
REGISTRY=${2:?usage: chart-mirror.sh <gitops-env-dir> <registry host:port>}
PLAIN=""
[ "${PLAIN_HTTP:-1}" = 1 ] && PLAIN="--plain-http"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

logged_in=0
login() {
  [ $logged_in = 1 ] && return 0
  if [ -z "${REGISTRY_USERNAME:-}" ] || [ -z "${REGISTRY_PASSWORD:-}" ]; then
    echo "REGISTRY_USERNAME and REGISTRY_PASSWORD are needed to push" >&2
    return 1
  fi
  printf '%s' "$REGISTRY_PASSWORD" |
    helm registry login "$REGISTRY" $PLAIN -u "$REGISTRY_USERNAME" --password-stdin >/dev/null ||
    return 1
  logged_in=1
}

failed=0
for wrapper in $MIRROR_CHARTS; do
  chart_dir="$ENV_DIR/charts/$wrapper"
  if [ ! -f "$chart_dir/Chart.yaml" ]; then
    echo "FAIL $wrapper: no $chart_dir/Chart.yaml"
    failed=1
    continue
  fi

  # NAME VERSION REPOSITORY STATUS, after a header line; read offline.
  deps=$(helm dependency list "$chart_dir" 2>/dev/null | awk 'NR > 1 && NF >= 3 { print $1, $2, $3 }')
  if [ -z "$deps" ]; then
    echo "FAIL $wrapper: no dependency in $chart_dir/Chart.yaml"
    failed=1
    continue
  fi

  echo "$deps" | {
    rc=0
    while read -r name version repo; do
      case $repo in
        http://*|https://*) ;;
        *) echo "skip $wrapper: $name $version comes from $repo, not a classic repository"; continue ;;
      esac
      path=$(echo "$repo" | sed -e 's|^https\{0,1\}://||' -e 's|/*$||')
      ref="oci://$REGISTRY/$path/$name"

      if helm show chart "$ref" --version "$version" $PLAIN >/dev/null 2>&1; then
        echo "ok   $wrapper: $path/$name:$version already in zot"
        continue
      fi

      if ! helm pull "$name" --repo "$repo" --version "$version" -d "$WORK" >/dev/null; then
        echo "FAIL $wrapper: cannot pull $name $version from $repo"
        rc=1
        continue
      fi
      if ! login; then
        echo "FAIL $wrapper: cannot log in to $REGISTRY"
        rc=1
        continue
      fi
      if helm push "$WORK/$name-$version.tgz" "oci://$REGISTRY/$path" $PLAIN >/dev/null; then
        echo "push $wrapper: $path/$name:$version"
      else
        echo "FAIL $wrapper: cannot push $name $version to $REGISTRY/$path"
        rc=1
      fi
    done
    exit $rc
  } || failed=1
done

exit $failed
