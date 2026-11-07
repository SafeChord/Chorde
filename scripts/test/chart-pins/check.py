#!/usr/bin/env python3
"""Check the chart defaults and image pins of a gitops tree (Chorde#45).

Docs safechord.chorde.md section 4, item 1:

1. Every deployed chart application keeps the chart's default values.yaml
   beside its overlay, equal to `helm show values` of the chart at the
   application's targetRevision.
2. Every image Chorde pins itself, in an overlay or a manifest, is pinned
   as tag@digest. Images a chart picks by default are not checked.

    check.py <gitops-env-dir>      e.g. gitops/k3han
    check.py --list-pins <gitops-env-dir>
                                   print each self-pinned image and where

Exits 0 when both hold, 1 with one line per finding otherwise. Needs
python3 with PyYAML, and helm with network access to the chart repositories.
"""
import difflib
import fnmatch
import os
import re
import subprocess
import sys
import tempfile

import yaml

# The argocd Application is applied by hand at bootstrap; no stage lists it.
DEPLOYED_OUTSIDE_STAGES = {"argocd"}

DIGEST = re.compile(r"@sha256:[0-9a-f]{64}$")
IMAGE_KEY = re.compile(r"^(image|imagename)$|_image$", re.IGNORECASE)
DIGEST_KEYS = ("digest", "sha")

findings = []
pins = []  # (where, ref) of every image Chorde pins itself


def find(where, what):
    findings.append(f"{where}: {what}")


def load_all(path):
    with open(path) as f:
        return [d for d in yaml.safe_load_all(f) if d is not None]


def deployed_services(env_dir):
    """Map each deployed service to the stage file whose ApplicationSet renders
    its directory and that template's directory.exclude (None outside stages)."""
    services = {s: None for s in DEPLOYED_OUTSIDE_STAGES}
    stages = os.path.join(env_dir, "stages")
    for name in sorted(os.listdir(stages)):
        if not name.endswith(".yaml"):
            continue
        for doc in load_all(os.path.join(stages, name)):
            spec = doc.get("spec", {})
            source = spec.get("template", {}).get("spec", {}).get("source", {})
            exclude = (source.get("directory") or {}).get("exclude", "")
            for gen in spec.get("generators", []):
                for el in gen.get("list", {}).get("elements", []):
                    services[el["service"]] = (name, exclude)
    return services


def excluded(pattern, rel):
    """ArgoCD matches directory.exclude as a glob; {a,b} lists alternatives."""
    if pattern.startswith("{") and pattern.endswith("}"):
        return any(fnmatch.fnmatchcase(rel, p) for p in pattern[1:-1].split(","))
    return bool(pattern) and fnmatch.fnmatchcase(rel, pattern)


# ---------------------------------------------------------------------------
# 1. Chart defaults
# ---------------------------------------------------------------------------

def chart_sources(app_path):
    for doc in load_all(app_path):
        spec = doc.get("spec", {})
        sources = spec.get("sources") or ([spec["source"]] if "source" in spec else [])
        for src in sources:
            if "chart" in src:
                yield src


def helm_show_values(repo_url, chart, version):
    if re.match(r"^https?://", repo_url):
        cmd = ["helm", "show", "values", "--repo", repo_url, chart, "--version", version]
    else:  # ArgoCD writes an OCI registry without its oci:// scheme
        cmd = ["helm", "show", "values", f"oci://{repo_url.rstrip('/')}/{chart}", "--version", version]
    # helm reads a chart name that matches a directory under the working
    # directory as that local chart, so it runs in an empty one.
    with tempfile.TemporaryDirectory() as empty:
        out = subprocess.run(cmd, capture_output=True, text=True, cwd=empty)
    if out.returncode != 0:
        return None, " ".join(cmd) + ": " + out.stderr.strip().splitlines()[-1]
    return out.stdout, None


def check_chart_defaults(env_dir, services):
    manifests = os.path.join(env_dir, "manifests")
    for service, stage in sorted(services.items()):
        # ArgoCD renders a stage's service directory as plain manifests, and a
        # values.yaml there that reads like one fails the whole directory.
        values = os.path.join(manifests, service, "values.yaml")
        if stage and os.path.isfile(values) and not excluded(stage[1], "values.yaml"):
            find(f"{service}/values.yaml", f"rendered as a manifest: {stage[0]} does not exclude it")
        app = os.path.join(manifests, service, "application.yaml")
        if not os.path.isfile(app):
            continue
        for src in chart_sources(app):
            where = f"{service}/values.yaml"
            version = str(src["targetRevision"]).strip()
            want, err = helm_show_values(src["repoURL"], src["chart"], version)
            if err:
                find(where, f"cannot read the chart's defaults: {err}")
                continue
            path = os.path.join(manifests, service, "values.yaml")
            if not os.path.isfile(path):
                find(where, f"missing; expected `helm show values` of {src['chart']} {version}")
                continue
            with open(path) as f:
                have = f.read()
            if have != want:
                diff = list(difflib.unified_diff(want.splitlines(), have.splitlines(), lineterm="", n=0))
                changed = sum(1 for line in diff if line[:1] in "+-" and line[:3] not in ("+++", "---"))
                find(where, f"differs from {src['chart']} {version} defaults ({changed} lines)")


# ---------------------------------------------------------------------------
# 2. Image pins
# ---------------------------------------------------------------------------

def has_tag(ref):
    name = ref.split("@", 1)[0]
    return ":" in name.rsplit("/", 1)[-1]


def check_ref(where, ref):
    pins.append((where, ref))
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


def check_manifest_images(rel, doc):
    is_plan = doc.get("kind") == "Plan"

    def visit(node, path):
        for k, v in node.items():
            if not (isinstance(v, str) and IMAGE_KEY.search(str(k))):
                continue
            # A Plan's image is name-only: the system-upgrade-controller adds
            # the Plan's spec.version as its tag.
            if is_plan and not has_tag(v) and "@" not in v:
                continue
            check_ref(f"{rel} {'.'.join(path + [str(k)])}", v)

    walk(doc, [], visit)


def check_overlay_images(rel, doc):
    def visit(node, path):
        here = ".".join(path)
        for k, v in node.items():
            if isinstance(v, str) and IMAGE_KEY.search(str(k)):
                check_ref(f"{rel} {here + '.' if here else ''}{k}", v)
        tag = node.get("tag")
        if tag not in (None, ""):
            tag = str(tag)
            digest = next((str(node[k]) for k in DIGEST_KEYS if node.get(k)), "")
            ref = f"{node.get('registry', '')}/{node.get('repository', '')}:{tag}".lstrip("/")
            if digest and "@" not in tag:
                ref += "@" + (digest if digest.startswith("sha256:") else "sha256:" + digest)
            pins.append((f"{rel} {here}", ref))
            if not (DIGEST.search(tag) or re.fullmatch(r"(sha256:)?[0-9a-f]{64}", digest)):
                find(f"{rel} {here}.tag", f"tag `{tag}` is set without a digest")

    walk(doc, [], visit)


def check_images(env_dir):
    manifests = os.path.join(env_dir, "manifests")
    for root, _, files in os.walk(manifests):
        for name in sorted(files):
            if not name.endswith(".yaml") or name == "values.yaml" or "unsealed" in name:
                continue
            path = os.path.join(root, name)
            rel = os.path.relpath(path, manifests)
            for doc in load_all(path):
                if not isinstance(doc, dict):
                    continue
                if name == "values-custom.yaml":
                    check_overlay_images(rel, doc)
                else:
                    check_manifest_images(rel, doc)


def main():
    args = sys.argv[1:]
    if args[:1] == ["--list-pins"] and len(args) == 2:
        check_images(args[1])
        for where, ref in pins:
            print(f"{ref}\t{where}")
        sys.exit(0)
    if len(args) != 1:
        sys.exit(__doc__)
    env_dir = args[0]
    check_chart_defaults(env_dir, deployed_services(env_dir))
    check_images(env_dir)
    for line in findings:
        print(line)
    sys.exit(1 if findings else 0)


if __name__ == "__main__":
    main()
