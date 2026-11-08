#!/usr/bin/env python3
"""Check that every stage directory holds plain manifests only (Chorde#54).

Docs safechord.chorde.md section 4, item 2: a stage renders each service
directory as plain manifests and nothing else. A service that a tool renders,
a chart or a kustomization, keeps only its Application in that directory,
pointing at its source. A stage that sets any `directory` option makes Argo CD
render a kustomization there as plain manifests, so one left in a stage
directory is applied as an object and its generated resources are pruned.

A service directory is gitops/<env>/manifests/<service> for each service a
stage's ApplicationSet lists. In it, anywhere below it, these are findings:

- a kustomization: a file kustomize reads as one (kustomization.yaml,
  kustomization.yml, Kustomization), or any document whose apiVersion is
  kustomize.config.k8s.io (a renamed kustomization, a Component);
- a Helm chart: Chart.yaml;
- Jsonnet: *.jsonnet, *.libsonnet;
- a YAML or JSON file the stage renders that does not parse, such as a
  chart template.

    check.py <gitops-env-dir>      e.g. gitops/k3han

Exits 0 when none is found, 1 with one line per finding otherwise. Needs
python3 with PyYAML.
"""
import fnmatch
import os
import sys

import yaml

KUSTOMIZATION_FILES = {"kustomization.yaml", "kustomization.yml", "Kustomization"}
KUSTOMIZE_GROUP = "kustomize.config.k8s.io/"
JSONNET = (".jsonnet", ".libsonnet")
MANIFEST = (".yaml", ".yml", ".json")

findings = []


def find(where, what):
    findings.append(f"{where}: {what}")


def stage_services(env_dir):
    """Map each service a stage lists to (stage file, its directory.exclude)."""
    services = {}
    stages = os.path.join(env_dir, "stages")
    for name in sorted(os.listdir(stages)):
        if not name.endswith(".yaml"):
            continue
        with open(os.path.join(stages, name)) as f:
            docs = [d for d in yaml.safe_load_all(f) if d]
        for doc in docs:
            spec = doc.get("spec", {})
            source = spec.get("template", {}).get("spec", {}).get("source", {})
            exclude = (source.get("directory") or {}).get("exclude", "")
            for gen in spec.get("generators", []):
                for el in gen.get("list", {}).get("elements", []) or []:
                    services[el["service"]] = (name, exclude)
    return services


def excluded(pattern, rel):
    """ArgoCD matches directory.exclude as a glob; {a,b} lists alternatives."""
    if pattern.startswith("{") and pattern.endswith("}"):
        return any(fnmatch.fnmatchcase(rel, p) for p in pattern[1:-1].split(","))
    return bool(pattern) and fnmatch.fnmatchcase(rel, pattern)


def check_service(env_dir, service, stage, exclude):
    top = os.path.join(env_dir, "manifests", service)
    for root, _, files in os.walk(top):
        for name in sorted(files):
            path = os.path.join(root, name)
            rel = os.path.relpath(path, top)
            where = f"{service}/{rel}"
            if name in KUSTOMIZATION_FILES:
                find(where, f"a kustomization in a directory {stage} renders as plain manifests")
                continue
            if name == "Chart.yaml":
                find(where, f"a Helm chart in a directory {stage} renders as plain manifests")
                continue
            if name.endswith(JSONNET):
                find(where, f"Jsonnet in a directory {stage} renders as plain manifests")
                continue
            if not name.endswith(MANIFEST) or excluded(exclude, rel):
                continue
            try:
                with open(path) as f:
                    docs = [d for d in yaml.safe_load_all(f) if d is not None]
            except yaml.YAMLError as e:
                mark = getattr(e, "problem_mark", None)
                line = f" (line {mark.line + 1})" if mark else ""
                find(where, f"does not parse as YAML{line}; {stage} renders it as a manifest")
                continue
            for doc in docs:
                api = doc.get("apiVersion", "") if isinstance(doc, dict) else ""
                if isinstance(api, str) and api.startswith(KUSTOMIZE_GROUP):
                    find(where, f"a {doc.get('kind', 'kustomize')} document in a directory {stage} renders as plain manifests")
                    break


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    env_dir = sys.argv[1]
    for service, (stage, exclude) in sorted(stage_services(env_dir).items()):
        check_service(env_dir, service, stage, exclude)
    for line in findings:
        print(line)
    sys.exit(1 if findings else 0)


if __name__ == "__main__":
    main()
