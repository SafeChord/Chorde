#!/usr/bin/env python3
"""Check that Argo CD deploys itself from the bootstrap stage (Chorde#68).

Docs safechord.chorde.md section 2: the bootstrap stage lists argocd, so the
generated bootstrap-argocd syncs manifests/argocd/, the argocd Application and
the SealedSecrets of Argo CD's repository credentials.

1. stages/00-bootstrap.yaml lists the service argocd in a list generator.
   bootstrap-argocd carries the ApplicationSet's resources finalizer and the
   stage prunes, so taking argocd out of the list deletes the argocd
   Application and the repository Secrets.
2. manifests/argocd/ holds the Application named argocd, and it carries no
   resources finalizer: deleted with one, it would delete Argo CD itself.

    check.py <gitops-env-dir>      e.g. gitops/k3han

Exits 0 when none is found, 1 with one line per finding otherwise. Needs
python3 with PyYAML.
"""
import os
import sys

import yaml

BOOTSTRAP = "00-bootstrap.yaml"
SERVICE = "argocd"
RESOURCES_FINALIZER = "resources-finalizer.argocd.argoproj.io"
MANIFEST = (".yaml", ".yml", ".json")

findings = []


def find(where, what):
    findings.append(f"{where}: {what}")


def load_all(path):
    with open(path) as f:
        return [d for d in yaml.safe_load_all(f) if d is not None]


def check_stage(env_dir):
    where = f"stages/{BOOTSTRAP}"
    path = os.path.join(env_dir, "stages", BOOTSTRAP)
    if not os.path.isfile(path):
        find(where, "not found; the bootstrap stage deploys argocd")
        return
    for doc in load_all(path):
        if not isinstance(doc, dict) or doc.get("kind") != "ApplicationSet":
            continue
        for gen in doc.get("spec", {}).get("generators", []) or []:
            for el in (gen.get("list") or {}).get("elements", []) or []:
                if isinstance(el, dict) and el.get("service") == SERVICE:
                    return
    find(where, f"does not list {SERVICE}; Argo CD deploys itself from the bootstrap stage")


def check_application(env_dir):
    top = os.path.join(env_dir, "manifests", SERVICE)
    found = False
    for root, _, files in os.walk(top):
        for name in sorted(files):
            if not name.endswith(MANIFEST) or name.startswith("unsealed-"):
                continue
            path = os.path.join(root, name)
            for doc in load_all(path):
                if not isinstance(doc, dict) or doc.get("kind") != "Application":
                    continue
                meta = doc.get("metadata") or {}
                if meta.get("name") != SERVICE:
                    continue
                found = True
                for fin in meta.get("finalizers") or []:
                    if str(fin).startswith(RESOURCES_FINALIZER):
                        find(os.path.relpath(path, env_dir),
                             f"the {SERVICE} Application carries {fin}; deleting it would delete Argo CD")
    if not found:
        find(f"manifests/{SERVICE}", f"holds no Application named {SERVICE}")


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    check_stage(sys.argv[1])
    check_application(sys.argv[1])
    for line in findings:
        print(line)
    sys.exit(1 if findings else 0)


if __name__ == "__main__":
    main()
