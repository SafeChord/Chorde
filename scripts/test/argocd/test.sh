#!/usr/bin/env bash
# Requirement tests for Argo CD deploying itself from the bootstrap stage
# (Chorde#68), its AppProjects with it (Chorde#94).
#
# Runs check.py against gitops/k3han, then against small trees built in a temp
# directory, each breaking or keeping the rule one way, so the check is shown
# to catch what it guards.
#
#   scripts/test/argocd/test.sh
#
# Needs: bash, python3 with PyYAML.
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../../.." && pwd)
CHECK="$HERE/check.py"

PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); echo "  ok   $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL $1"; [ $# -gt 1 ] && echo "$2" | sed 's/^/       /'; }

# expect <name> pass|fail <env-dir> [pattern the output must hold]
expect() {
  local name=$1 want=$2 dir=$3 pattern=${4:-} out rc
  out=$(python3 "$CHECK" "$dir" 2>&1); rc=$?
  if [ "$want" = pass ] && [ $rc -eq 0 ]; then ok "$name"
  elif [ "$want" = fail ] && [ $rc -eq 1 ] && { [ -z "$pattern" ] || grep -qF -- "$pattern" <<<"$out"; }; then ok "$name"
  else fail "$name (want $want, rc $rc)" "$out"
  fi
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# stage <file> <services...>: an ApplicationSet listing the services, as the
# K3han stages write it.
stage() {
  local file=$1; shift
  {
    echo "apiVersion: argoproj.io/v1alpha1"
    echo "kind: ApplicationSet"
    echo "metadata:"
    echo "  name: k3han-$(basename "$file" .yaml)"
    echo "spec:"
    echo "  generators:"
    echo "    - list:"
    echo "        elements:"
    for s in "$@"; do printf '          - service: %s\n            wave: "1"\n' "$s"; done
    [ $# -eq 0 ] && echo "          []"
    echo "  template:"
    echo "    spec:"
    echo "      source:"
    echo "        path: 'gitops/k3han/manifests/{{service}}'"
  } > "$file"
}

# application [finalizer]: the argocd Application, optionally with a finalizer.
application() {
  echo "apiVersion: argoproj.io/v1alpha1"
  echo "kind: Application"
  echo "metadata:"
  echo "  name: argocd"
  echo "  namespace: argocd"
  [ -n "${1:-}" ] && printf '  finalizers:\n    - %s\n' "$1"
  echo "spec:"
  echo "  project: chorde"
  echo "  source:"
  echo "    repoURL: https://github.com/SafeChord/Chorde.git"
  echo "    targetRevision: main"
  echo "    path: gitops/k3han/charts/argocd"
}

# appproject <name> [sync-options]: an AppProject, by default with the sync
# options Prune=false and Delete=false; "-" leaves the annotation out.
appproject() {
  local opts=${2-Prune=false,Delete=false}
  echo "apiVersion: argoproj.io/v1alpha1"
  echo "kind: AppProject"
  echo "metadata:"
  echo "  name: $1"
  echo "  namespace: argocd"
  [ "$opts" != - ] && printf '  annotations:\n    argocd.argoproj.io/sync-options: "%s"\n' "$opts"
  echo "spec:"
  echo "  sourceRepos:"
  echo "    - '*'"
}

# appprojects: chorde and safezone, as one file.
appprojects() { appproject chorde; echo "---"; appproject safezone; }

# new_env <bootstrap services...>: an env dir whose bootstrap stage lists the
# services, with the argocd Application and the AppProjects in
# manifests/argocd/.
new_env() {
  local dir; dir=$(mktemp -d "$TMP/env.XXXX")
  mkdir -p "$dir/stages" "$dir/manifests/argocd"
  stage "$dir/stages/00-bootstrap.yaml" "$@"
  application > "$dir/manifests/argocd/application.yaml"
  appprojects > "$dir/manifests/argocd/appprojects.yaml"
  echo "$dir"
}

echo "== gitops/k3han"
expect "Argo CD deploys itself from the bootstrap stage" pass "$REPO/gitops/k3han"

echo "== the bootstrap stage"
d=$(new_env sealed-secrets argocd keda)
expect "bootstrap lists argocd among other services" pass "$d"

d=$(new_env sealed-secrets keda)
expect "bootstrap without argocd" fail "$d" "stages/00-bootstrap.yaml: does not list argocd"

d=$(new_env sealed-secrets keda)
stage "$d/stages/01-platform.yaml" argocd
expect "argocd listed by another stage only" fail "$d" "stages/00-bootstrap.yaml: does not list argocd"

d=$(new_env sealed-secrets)
sed -i 's/^          - service: sealed-secrets$/          # - service: argocd\n&/' "$d/stages/00-bootstrap.yaml"
expect "argocd commented out of the list" fail "$d" "does not list argocd"

d=$(new_env)
expect "bootstrap listing nothing" fail "$d" "does not list argocd"

d=$(new_env sealed-secrets)
stage "$TMP/second.yaml" argocd
{ echo "---"; cat "$TMP/second.yaml"; } >> "$d/stages/00-bootstrap.yaml"
expect "argocd in a second ApplicationSet of the bootstrap file" pass "$d"

d=$(new_env sealed-secrets argocd)
sed -i 's/^kind: ApplicationSet$/kind: Application/' "$d/stages/00-bootstrap.yaml"
expect "argocd listed in a document that is not an ApplicationSet" fail "$d" "does not list argocd"

d=$(new_env argocd); mv "$d/stages/00-bootstrap.yaml" "$d/stages/00-core.yaml"
expect "no bootstrap stage" fail "$d" "stages/00-bootstrap.yaml: not found"

echo "== the argocd Application"
d=$(new_env argocd)
application resources-finalizer.argocd.argoproj.io > "$d/manifests/argocd/application.yaml"
expect "the Application with the resources finalizer" fail "$d" "manifests/argocd/application.yaml: the argocd Application carries resources-finalizer.argocd.argoproj.io"

d=$(new_env argocd)
application resources-finalizer.argocd.argoproj.io/background > "$d/manifests/argocd/application.yaml"
expect "the Application with the background resources finalizer" fail "$d" "carries resources-finalizer.argocd.argoproj.io/background"

d=$(new_env argocd)
application example.com/keep > "$d/manifests/argocd/application.yaml"
expect "the Application with another finalizer" pass "$d"

d=$(new_env argocd)
{ printf 'apiVersion: v1\nkind: Namespace\nmetadata:\n  name: argocd\n---\n'; application resources-finalizer.argocd.argoproj.io; } > "$d/manifests/argocd/application.yaml"
expect "the finalizer on the second document of a file" fail "$d" "carries resources-finalizer"

d=$(new_env argocd); rm "$d/manifests/argocd/application.yaml"
expect "no argocd Application" fail "$d" "manifests/argocd: holds no Application named argocd"

d=$(new_env argocd)
sed -i 's/^  name: argocd$/  name: argo/' "$d/manifests/argocd/application.yaml"
expect "an Application by another name" fail "$d" "holds no Application named argocd"

d=$(new_env argocd)
application resources-finalizer.argocd.argoproj.io > "$d/manifests/argocd/unsealed-local.yaml"
expect "an ignored unsealed file is not read" pass "$d"

echo "== the AppProjects"
d=$(new_env argocd)
expect "chorde and safezone, both kept from prune and delete" pass "$d"

d=$(new_env argocd); rm "$d/manifests/argocd/appprojects.yaml"
expect "no AppProjects" fail "$d" "manifests/argocd: defines no AppProject named chorde"

d=$(new_env argocd); appproject chorde > "$d/manifests/argocd/appprojects.yaml"
expect "safezone, named only by SafeZone-Deploy, missing" fail "$d" "defines no AppProject named safezone"

d=$(new_env argocd)
sed -i 's/^    spec:$/    spec:\n      project: platform/' "$d/stages/00-bootstrap.yaml"
expect "a project a stage's template names, undefined" fail "$d" "defines no AppProject named platform"

d=$(new_env argocd)
sed -i 's/^  project: chorde$/  project: default/' "$d/manifests/argocd/application.yaml"
expect "the project default needs no definition" pass "$d"

d=$(new_env argocd)
{ appproject chorde Delete=false; echo "---"; appproject safezone; } > "$d/manifests/argocd/appprojects.yaml"
expect "chorde without Prune=false" fail "$d" "the AppProject chorde lacks the sync option Prune=false"

d=$(new_env argocd)
{ appproject chorde; echo "---"; appproject safezone Prune=false; } > "$d/manifests/argocd/appprojects.yaml"
expect "safezone without Delete=false" fail "$d" "the AppProject safezone lacks the sync option Delete=false"

d=$(new_env argocd)
{ appproject chorde -; echo "---"; appproject safezone; } > "$d/manifests/argocd/appprojects.yaml"
expect "chorde without sync options" fail "$d" "the AppProject chorde lacks the sync option Prune=false"

d=$(new_env argocd)
{ appproject chorde "Prune=true,Delete=false"; echo "---"; appproject safezone; } > "$d/manifests/argocd/appprojects.yaml"
expect "chorde with Prune=true" fail "$d" "lacks the sync option Prune=false"

d=$(new_env argocd)
{ appproject chorde "Delete=false, ServerSideApply=true , Prune=false"; echo "---"; appproject safezone; } > "$d/manifests/argocd/appprojects.yaml"
expect "options in another order, with spaces and another option" pass "$d"

d=$(new_env argocd); mv "$d/manifests/argocd/appprojects.yaml" "$d/manifests/argocd/unsealed-projects.yaml"
expect "AppProjects only in an ignored unsealed file" fail "$d" "defines no AppProject named chorde"

d=$(new_env argocd); mv "$d/manifests/argocd/appprojects.yaml" "$d/stages/appprojects.yaml"
expect "AppProjects outside manifests/argocd" fail "$d" "defines no AppProject named chorde"

d=$(new_env argocd)
sed -i 's/^kind: AppProject$/kind: ConfigMap/' "$d/manifests/argocd/appprojects.yaml"
expect "documents named chorde and safezone that are not AppProjects" fail "$d" "defines no AppProject named chorde"

echo
echo "passed $PASS, failed $FAIL"
[ $FAIL -eq 0 ]
