#!/usr/bin/env python3
"""Check the chart applications, chart defaults and image pins of a gitops tree
(Chorde#45, Chorde#77).

Docs safechord.chorde.md section 4, item 1:

1. A chart's version and Chorde's values for it reach Argo CD at one git
   revision. Each chart lives in a wrapper chart, gitops/<env>/charts/<service>/:
   Chart.yaml names the upstream chart as its one dependency at an exact
   version, values.yaml holds the overlay under the dependency's name, and
   nothing else pins the version (no Chart.lock, no charts/). The service's
   Application has the wrapper as its source and carries no values, no ref
   source and no upstream chart of its own. No chart values sit in a stage
   directory.
2. Every wrapper keeps the upstream chart's default values beside its overlay,
   as upstream-values.yaml, equal to `helm show values` of the dependency at
   its version.
3. Every image Chorde pins itself, in an overlay or a manifest, is pinned
   as tag@digest. Images a chart picks by default are not checked. The
   manifests are those under manifests/ and kustomize/, where a service a
   kustomization renders keeps its source (Chorde#54).
4. Every image a wrapper renders carries a digest, and a pin's tag is the one
   the chart's version renders by default (Chorde#53). Checked with
   --rendered, which renders every wrapper.

    check.py <gitops-env-dir>      e.g. gitops/k3han; rules 1 to 3
    check.py --rendered <gitops-env-dir>
                                   rule 4
    check.py --list-pins <gitops-env-dir>
                                   print each self-pinned image, where it is
                                   pinned and the namespace it runs in

--rendered renders each wrapper under charts/ three times with helm template:
with its overlay as it is, with every digest taken out of the overlay, and with
every pin taken out (its tag, digest and sha keys). In the first, every image
must carry a digest. The second and the third must render the same images, so
each pin's tag is the one the chart renders when the overlay sets none. An image
is a string under an `image`, `imageName` or `*_image` key, an `image` map of
repository and tag (NGF's NginxProxy), an env var named `*_IMAGE`, `*_IMAGES`
or `*IMAGE_NAME`, or a flag whose value is an image with a tag or a digest; a
CustomResourceDefinition is not read. The operand images an operator maps per operand version (OPERAND_MAPS)
are left to the operator, by tag. A dependency named by a file:// repository is
read from that directory, relative to the wrapper.

--list-pins prints `<image>\t<where>\t<namespace>` per pin. A pin in a
wrapper's values.yaml names the image its chart renders from it: the wrapper is
rendered with its overlay (helm pull, helm template, in a temp directory) and
the rendered image that carries the pin's digest is printed, so a tag-only pin
gets the repository the chart gives it (Chorde#69). A pin no rendered image
carries keeps the repository its overlay names, empty for a tag-only one. Its
namespace is the destination of the service's Application; a manifest's is its
kustomization's namespace, or else its own metadata.namespace, empty when
neither is set. A chart that cannot be rendered exits 1 with the error.

Exits 0 when all hold, 1 with one line per finding otherwise; each finding
names its file relative to the env dir. Needs python3 with PyYAML, and helm
with network access to the chart repositories.

A chart download that fails the way a passing outage does (an HTTP 5xx or
429, a failed connection, a timeout) is retried, waiting 5 s and doubling,
for up to 90 s from the first try, then is a finding with the last error; any
other error is a finding at once (Chorde#63). A helm run that hangs can take
helm's own 120 s client timeout, so a chart takes at most 90 s plus its last
run. CHART_PINS_RETRY_WINDOW and CHART_PINS_RETRY_FIRST_WAIT override the two
numbers, in seconds.
"""
import difflib
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time

import yaml

# The argocd Application is applied by hand at bootstrap; no stage lists it.
DEPLOYED_OUTSIDE_STAGES = {"argocd"}

DIGEST = re.compile(r"@sha256:[0-9a-f]{64}$")
RETRY_WINDOW = float(os.environ.get("CHART_PINS_RETRY_WINDOW", 90))
RETRY_FIRST_WAIT = float(os.environ.get("CHART_PINS_RETRY_FIRST_WAIT", 5))
# helm's last stderr line for an error that may pass: an HTTP status, as helm
# prints it for a chart repository (": 504 Gateway Timeout") or an OCI
# registry ("status code 503"), or a connection that failed or timed out.
TRANSIENT = re.compile(
    r"(: |status code:? )(429|5\d\d)\b"
    r"|connection refused|connection reset|no such host|network is unreachable"
    r"|i/o timeout|TLS handshake timeout|context deadline exceeded|Client\.Timeout"
    r"|unexpected EOF|: EOF$|broken pipe|stream error|server closed",
    re.IGNORECASE)
IMAGE_KEY = re.compile(r"^(image|imagename)$|_image$", re.IGNORECASE)
DIGEST_KEYS = ("digest", "sha")
# Env vars through which strimzi maps each Kafka version to an operand image:
# left to the operator by tag (Docs safechord.chorde.md section 4, item 1).
OPERAND_MAPS = {
    "STRIMZI_KAFKA_IMAGES", "STRIMZI_KAFKA_CONNECT_IMAGES", "STRIMZI_KAFKA_MIRROR_MAKER_2_IMAGES",
    "STRIMZI_DEFAULT_KAFKA_EXPORTER_IMAGE", "STRIMZI_DEFAULT_CRUISE_CONTROL_IMAGE",
}

findings = []
pins = []  # (where, ref, namespace) of every image Chorde pins itself


def find(where, what):
    findings.append(f"{where}: {what}")


def load_all(path):
    with open(path) as f:
        return [d for d in yaml.safe_load_all(f) if d is not None]


def deployed_services(env_dir):
    """Map each deployed service to the stage file that lists it (None outside stages)."""
    services = {s: None for s in DEPLOYED_OUTSIDE_STAGES}
    stages = os.path.join(env_dir, "stages")
    for name in sorted(os.listdir(stages)):
        if not name.endswith(".yaml"):
            continue
        for doc in load_all(os.path.join(stages, name)):
            for gen in doc.get("spec", {}).get("generators", []):
                for el in gen.get("list", {}).get("elements", []) or []:
                    services[el["service"]] = name
    return services


# ---------------------------------------------------------------------------
# 1. Chart applications: version and values at one revision (Chorde#77)
# ---------------------------------------------------------------------------

WRAPPER_PATH = re.compile(r"^gitops/[^/]+/charts/([^/]+)/?$")
# Every way an Application can carry values of its own, apart from its source.
VALUE_KEYS = ("values", "valuesObject", "parameters", "fileParameters", "valueFiles")
EXACT_VERSION = re.compile(r"^v?\d+\.\d+\.\d+(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$")
VALUES_FILE = re.compile(r"^values.*\.ya?ml$|^upstream-values\.ya?ml$")


def app_sources(doc):
    spec = doc.get("spec", {}) if isinstance(doc, dict) else {}
    return spec.get("sources") or ([spec["source"]] if spec.get("source") else [])


def check_applications(env_dir, services):
    manifests = os.path.join(env_dir, "manifests")
    for service, stage in sorted(services.items()):
        top = os.path.join(manifests, service)
        if not os.path.isdir(top):
            continue
        for name in sorted(os.listdir(top)):
            if stage and VALUES_FILE.match(name):
                find(f"manifests/{service}/{name}",
                     f"chart values in a directory {stage} renders; they belong in charts/{service}/")
        app = os.path.join(top, "application.yaml")
        if not os.path.isfile(app):
            continue
        where = f"manifests/{service}/application.yaml"
        for doc in load_all(app):
            if not isinstance(doc, dict) or doc.get("kind") != "Application":
                continue
            for src in app_sources(doc):
                if "ref" in src:
                    find(where, f"source `ref: {src['ref']}` reaches the application apart from its chart version")
                if "chart" in src:
                    find(where, f"names chart {src['chart']} {src.get('targetRevision')} itself; "
                                f"its version and values belong in charts/{service}/")
                helm = src.get("helm") or {}
                for key in VALUE_KEYS:
                    if key in helm:
                        find(where, f"helm.{key} carries values apart from the chart's own values.yaml")
                m = WRAPPER_PATH.match(str(src.get("path", "")))
                if not m:
                    continue
                if m.group(1) != service:
                    find(where, f"source path {src['path']} is not this service's wrapper, charts/{service}")
                elif not os.path.isfile(os.path.join(env_dir, "charts", service, "Chart.yaml")):
                    find(where, f"source path {src['path']} holds no Chart.yaml")


def check_wrappers(env_dir):
    charts = os.path.join(env_dir, "charts")
    if not os.path.isdir(charts):
        return
    for service in sorted(os.listdir(charts)):
        top = os.path.join(charts, service)
        if not os.path.isdir(top):
            continue
        rel = f"charts/{service}"
        chart_yaml = os.path.join(top, "Chart.yaml")
        if not os.path.isfile(chart_yaml):
            find(rel, "a wrapper directory without Chart.yaml")
            continue
        for extra in ("Chart.lock", "charts"):
            if os.path.exists(os.path.join(top, extra)):
                find(f"{rel}/{extra}", "pins the dependency apart from Chart.yaml; Argo CD builds it from Chart.yaml")
        chart = (load_all(chart_yaml) or [{}])[0]
        deps = chart.get("dependencies") or []
        if len(deps) != 1:
            find(f"{rel}/Chart.yaml", f"declares {len(deps)} dependencies; a wrapper holds exactly one")
            continue
        dep = deps[0]
        version = str(dep.get("version", "")).strip()
        if not EXACT_VERSION.match(version):
            find(f"{rel}/Chart.yaml", f"dependency {dep.get('name')} version `{version}` is not an exact version")
            continue
        key = dep.get("alias") or dep.get("name")
        values = os.path.join(top, "values.yaml")
        if not os.path.isfile(values):
            find(f"{rel}/values.yaml", "missing; the overlay lives here, under " + str(key))
        else:
            for doc in load_all(values):
                for k in (doc if isinstance(doc, dict) else {}):
                    if k not in (key, "global"):
                        find(f"{rel}/values.yaml", f"top-level key `{k}` reaches no chart; values for {dep.get('name')} go under `{key}`")
        check_defaults(f"{rel}/upstream-values.yaml", os.path.join(top, "upstream-values.yaml"),
                       str(dep.get("repository", "")), str(dep.get("name")), version)


# ---------------------------------------------------------------------------
# 2. Chart defaults
# ---------------------------------------------------------------------------

def chart_ref(repo_url, chart):
    """The arguments that name a chart in a repository to helm show and helm pull."""
    if re.match(r"^https?://", repo_url):
        return ["--repo", repo_url, chart]
    # Chart.yaml names an OCI registry as oci://<registry>/<path>
    registry = re.sub(r"^oci://", "", repo_url).rstrip("/")
    return [f"oci://{registry}/{chart}"]


def helm_show_values(repo_url, chart, version):
    return helm_run(["helm", "show", "values", *chart_ref(repo_url, chart), "--version", version])


def helm_run(cmd):
    """Run a helm command that downloads a chart, retrying a passing outage."""
    started, wait, runs = time.monotonic(), RETRY_FIRST_WAIT, 0
    while True:
        runs += 1
        # helm reads a chart name that matches a directory under the working
        # directory as that local chart, so it runs in an empty one.
        with tempfile.TemporaryDirectory() as empty:
            out = subprocess.run(cmd, capture_output=True, text=True, cwd=empty)
        if out.returncode == 0:
            return out.stdout, None
        lines = out.stderr.strip().splitlines()
        err = " ".join(cmd) + ": " + (lines[-1] if lines else f"exit status {out.returncode}")
        if not TRANSIENT.search(err):
            return None, err
        now = time.monotonic()
        left = started + RETRY_WINDOW - now
        if left <= 0:
            return None, f"{err} (still failing after {runs} runs over {now - started:.0f} s)"
        # The last wait is cut to the window and ends in one more run.
        time.sleep(min(wait, left))
        wait *= 2


def check_defaults(where, path, repo_url, chart, version):
    want, err = helm_show_values(repo_url, chart, version)
    if err:
        find(where, f"cannot read the chart's defaults: {err}")
        return
    if not os.path.isfile(path):
        find(where, f"missing; expected `helm show values` of {chart} {version}")
        return
    with open(path) as f:
        have = f.read()
    if have != want:
        diff = list(difflib.unified_diff(want.splitlines(), have.splitlines(), lineterm="", n=0))
        changed = sum(1 for line in diff if line[:1] in "+-" and line[:3] not in ("+++", "---"))
        find(where, f"differs from {chart} {version} defaults ({changed} lines)")


# ---------------------------------------------------------------------------
# 3. Image pins
# ---------------------------------------------------------------------------

def has_tag(ref):
    name = ref.split("@", 1)[0]
    return ":" in name.rsplit("/", 1)[-1]


def check_ref(where, ref, namespace=""):
    pins.append((where, ref, namespace))
    if not (has_tag(ref) and DIGEST.search(ref)):
        find(where, f"image `{ref}` is not pinned as tag@digest")


def walk(node, path, visit):
    if isinstance(node, dict):
        visit(node, path)
        for k, v in node.items():
            walk(v, path + [str(k)], visit)
    elif isinstance(node, list):
        for i, v in enumerate(node):
            walk(v, path + [str(i)], visit)


def check_manifest_images(rel, doc, namespace=""):
    is_plan = doc.get("kind") == "Plan"
    meta = doc.get("metadata")
    namespace = namespace or str((meta if isinstance(meta, dict) else {}).get("namespace") or "")

    def visit(node, path):
        for k, v in node.items():
            if not (isinstance(v, str) and IMAGE_KEY.search(str(k))):
                continue
            # A Plan's image is name-only: the system-upgrade-controller adds
            # the Plan's spec.version as its tag.
            if is_plan and not has_tag(v) and "@" not in v:
                continue
            check_ref(f"{rel} {'.'.join(path + [str(k)])}", v, namespace)

    walk(doc, [], visit)


def check_overlay_images(rel, doc, namespace=""):
    def visit(node, path):
        here = ".".join(path)
        for k, v in node.items():
            if isinstance(v, str) and IMAGE_KEY.search(str(k)):
                check_ref(f"{rel} {here + '.' if here else ''}{k}", v, namespace)
        tag = node.get("tag")
        tag = "" if tag is None else str(tag)
        digest = next((str(node[k]) for k in DIGEST_KEYS if node.get(k)), "")
        if not (tag or digest):
            return
        ref = f"{node.get('registry', '')}/{node.get('repository', '')}".lstrip("/") + (f":{tag}" if tag else "")
        if digest and "@" not in tag:
            ref += "@" + (digest if digest.startswith("sha256:") else "sha256:" + digest)
        # A pin set through a digest key alone leaves the tag to the chart (Chorde#53).
        pins.append((f"{rel} {here}", ref, namespace))
        if tag and not (DIGEST.search(tag) or re.fullmatch(r"(sha256:)?[0-9a-f]{64}", digest)):
            find(f"{rel} {here}.tag", f"tag `{tag}` is set without a digest")

    walk(doc, [], visit)


def kustomize_namespace(root):
    """The namespace a kustomization in root sets on everything it renders, or ""."""
    for name in ("kustomization.yaml", "kustomization.yml"):
        path = os.path.join(root, name)
        if os.path.isfile(path):
            doc = (load_all(path) or [{}])[0]
            return str((doc if isinstance(doc, dict) else {}).get("namespace") or "")
    return ""


def destination_namespace(env_dir, service):
    """The destination namespace of the service's Application, or ""."""
    app = os.path.join(env_dir, "manifests", service, "application.yaml")
    for doc in load_all(app) if os.path.isfile(app) else []:
        if isinstance(doc, dict) and doc.get("kind") == "Application":
            return str(doc.get("spec", {}).get("destination", {}).get("namespace") or "")
    return ""


def check_images(env_dir):
    trees = [os.path.join(env_dir, "manifests"), os.path.join(env_dir, "kustomize")]
    for root, _, files in (w for tree in trees for w in os.walk(tree)):
        namespace = kustomize_namespace(root)
        for name in sorted(files):
            # Chart values in a stage directory are a finding of their own.
            if not name.endswith(".yaml") or VALUES_FILE.match(name) or "unsealed" in name:
                continue
            path = os.path.join(root, name)
            rel = os.path.relpath(path, env_dir)
            for doc in load_all(path):
                if isinstance(doc, dict):
                    check_manifest_images(rel, doc, namespace)
    charts = os.path.join(env_dir, "charts")
    for service in sorted(os.listdir(charts)) if os.path.isdir(charts) else []:
        path = os.path.join(charts, service, "values.yaml")
        if os.path.isfile(path):
            for doc in load_all(path):
                if isinstance(doc, dict):
                    check_overlay_images(os.path.relpath(path, env_dir), doc,
                                         destination_namespace(env_dir, service))


# ---------------------------------------------------------------------------
# Rendered images (--rendered, Chorde#53) and pins as the chart renders them
# (--list-pins, Chorde#69)
# ---------------------------------------------------------------------------

ENV_IMAGE = re.compile(r"(^|_)IMAGES?$|IMAGE_NAME$", re.IGNORECASE)
# A flag whose value is an image reference with a tag or a digest, whatever the
# flag is named (kube-prometheus-stack's --prometheus-config-reloader=<image>);
# a URL or a path is not one.
FLAG_IMAGE = re.compile(r"^--?[\w.-]+=([a-z0-9][a-z0-9.-]*(?::[0-9]+)?/[\w./-]+(?::[\w.-]+)?(?:@sha256:[0-9a-f]{64})?)$")


def split_image(node):
    """The image an `image` map of repository and tag renders, or None."""
    if not (isinstance(node, dict) and node.get("repository")):
        return None
    ref = f"{node.get('registry') or ''}/{node['repository']}".lstrip("/")
    if node.get("tag") not in (None, ""):
        ref += f":{node['tag']}"
    digest = next((str(node[k]) for k in DIGEST_KEYS if node.get(k)), "")
    if digest and "@" not in ref:
        ref += "@" + (digest if digest.startswith("sha256:") else "sha256:" + digest)
    return ref


def rendered_images(docs):
    """(where, ref) of every image the rendered documents name, operand maps aside."""
    images = []
    for doc in docs:
        if not isinstance(doc, dict) or doc.get("kind") == "CustomResourceDefinition":
            continue
        meta = doc.get("metadata") or {}
        what = f"{doc.get('kind')}/{meta.get('name')}"

        def visit(node, path):
            here = ".".join(path)
            dot = here + "." if here else ""
            for k, v in node.items():
                if isinstance(v, str) and v.strip() and IMAGE_KEY.search(str(k)):
                    images.append((f"{what} {dot}{k}", v.strip()))
                elif str(k) == "image" and split_image(v):
                    images.append((f"{what} {dot}{k}", split_image(v)))
                elif isinstance(v, list):
                    for i, x in enumerate(v):
                        m = FLAG_IMAGE.match(x.strip()) if isinstance(x, str) else None
                        if m and (":" in m.group(1).rsplit("/", 1)[-1] or "@" in m.group(1)):
                            images.append((f"{what} {dot}{k}.{i}", m.group(1)))
            name = node.get("name")
            if isinstance(name, str) and ENV_IMAGE.search(name) and isinstance(node.get("value"), str):
                if name not in OPERAND_MAPS:
                    for token in node["value"].split():
                        images.append((f"{what} {dot}value", token.split("=", 1)[-1]))

        walk(doc, [], visit)
    return images


def pull_wrapper(env_dir, service, tmp):
    """Copy the wrapper into tmp with its dependency fetched; (chart dir, None) or (None, error)."""
    top = os.path.join(env_dir, "charts", service)
    dep = ((load_all(os.path.join(top, "Chart.yaml")) or [{}])[0].get("dependencies") or [{}])[0]
    chart = os.path.join(tmp, service)
    shutil.copytree(top, chart, ignore=shutil.ignore_patterns("Chart.lock", "charts"))
    deps = os.path.join(chart, "charts")
    os.mkdir(deps)
    repo = str(dep.get("repository", ""))
    if repo.startswith("file://"):
        src = os.path.join(top, repo[len("file://"):])
        if not os.path.isfile(os.path.join(src, "Chart.yaml")):
            return None, f"{repo}: no chart there"
        shutil.copytree(src, os.path.join(deps, str(dep.get("name"))))
        return chart, None
    _, err = helm_run(["helm", "pull", *chart_ref(repo, str(dep.get("name"))),
                       "--version", str(dep.get("version")), "--untar", "--destination", deps])
    return (None, err) if err else (chart, None)


def template(chart, service, namespace, values=None):
    """The documents the chart renders, with values.yaml replaced by values if given."""
    if values is not None:
        with open(os.path.join(chart, "values.yaml"), "w") as f:
            yaml.safe_dump_all(values, f)
    cmd = ["helm", "template", service, chart, "--namespace", namespace or "default"]
    out = subprocess.run(cmd, capture_output=True, text=True)
    if out.returncode != 0:
        lines = out.stderr.strip().splitlines()
        return None, " ".join(cmd) + ": " + (lines[-1] if lines else f"exit status {out.returncode}")
    return [d for d in yaml.safe_load_all(out.stdout) if d is not None], None


def render_wrapper(env_dir, service, namespace):
    """Every image the wrapper renders with its overlay, or (None, error)."""
    with tempfile.TemporaryDirectory() as tmp:
        chart, err = pull_wrapper(env_dir, service, tmp)
        docs, err = (None, err) if err else template(chart, service, namespace)
    if err:
        return None, err
    return {ref for _, ref in rendered_images(docs) if RENDERED_REF.match(ref)}, None


RENDERED_REF = re.compile(r"^[^\s@]+@sha256:[0-9a-f]{64}$")


def unpin(node, keep_tags):
    """The overlay with its pins taken out: digests only (keep_tags), or tags too."""
    if isinstance(node, list):
        return [unpin(x, keep_tags) for x in node]
    if not isinstance(node, dict):
        return node
    out = {}
    pinned = any(node.get(k) for k in DIGEST_KEYS) or "@" in str(node.get("tag") or "")
    for k, v in node.items():
        if k in DIGEST_KEYS and v and re.fullmatch(r"(sha256:)?[0-9a-f]{64}", str(v)):
            continue
        if k == "tag" and pinned:
            if keep_tags and str(v or "").split("@", 1)[0]:
                out[k] = str(v).split("@", 1)[0]
            continue
        if isinstance(v, str) and IMAGE_KEY.search(str(k)) and DIGEST.search(v):
            if keep_tags:
                out[k] = v.split("@", 1)[0]
            continue
        out[k] = unpin(v, keep_tags)
    return out


def check_rendered(env_dir):
    charts = os.path.join(env_dir, "charts")
    for service in sorted(os.listdir(charts)) if os.path.isdir(charts) else []:
        top = os.path.join(charts, service)
        if not os.path.isfile(os.path.join(top, "Chart.yaml")):
            continue
        rel = f"charts/{service}"
        dep = ((load_all(os.path.join(top, "Chart.yaml")) or [{}])[0].get("dependencies") or [{}])[0]
        overlay = load_all(os.path.join(top, "values.yaml")) if os.path.isfile(os.path.join(top, "values.yaml")) else []
        namespace = destination_namespace(env_dir, service)
        renders = {}
        with tempfile.TemporaryDirectory() as tmp:
            chart, err = pull_wrapper(env_dir, service, tmp)
            for variant, values in (("pinned", None), ("tags", [unpin(d, True) for d in overlay]),
                                    ("defaults", [unpin(d, False) for d in overlay])):
                if err:
                    break
                docs, err = template(chart, service, namespace, values)
                renders[variant] = dict(rendered_images(docs or []))
        if err:
            find(rel, f"cannot render the wrapper: {err}")
            continue
        for where, ref in sorted(renders["pinned"].items()):
            if not DIGEST.search(ref):
                find(rel, f"{where} renders {ref} without a digest")
        for where, ref in sorted(renders["tags"].items()):
            default = renders["defaults"].get(where)
            if default is not None and default != ref:
                find(rel, f"{where} renders {renders['pinned'].get(where, ref)} from its pin; "
                          f"{dep.get('name')} {dep.get('version')} renders {default} there by default")


def rendered_pins(env_dir):
    """The pins, each overlay pin as the image its chart renders from it."""
    rendered, listed = {}, []
    for where, ref, namespace in pins:
        m = re.match(r"^charts/([^/]+)/values\.yaml ", where)
        digest = ref.split("@", 1)[1] if "@" in ref else ""
        if not (m and digest):
            listed.append((where, ref, namespace))
            continue
        service = m.group(1)
        if service not in rendered:
            rendered[service], err = render_wrapper(env_dir, service, namespace)
            if err:
                sys.exit(f"charts/{service}: cannot render the wrapper: {err}")
        refs = sorted(r for r in rendered[service] if r.endswith("@" + digest))
        listed.extend((where, r, namespace) for r in refs or [ref])
    return listed


def main():
    args = sys.argv[1:]
    if args[:1] == ["--list-pins"] and len(args) == 2:
        check_images(args[1])
        for where, ref, namespace in rendered_pins(args[1]):
            print(f"{ref}\t{where}\t{namespace}")
        sys.exit(0)
    if args[:1] == ["--rendered"] and len(args) == 2:
        check_rendered(args[1])
        for line in findings:
            print(line)
        sys.exit(1 if findings else 0)
    if len(args) != 1:
        sys.exit(__doc__)
    env_dir = args[0]
    check_applications(env_dir, deployed_services(env_dir))
    check_wrappers(env_dir)
    check_images(env_dir)
    for line in findings:
        print(line)
    sys.exit(1 if findings else 0)


if __name__ == "__main__":
    main()
