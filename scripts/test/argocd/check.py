#!/usr/bin/env python3
"""Check that Argo CD deploys itself from the bootstrap stage (Chorde#68), its
AppProjects with it (Chorde#94).

Docs safechord.chorde.md section 2: the bootstrap stage lists argocd, so the
generated bootstrap-argocd syncs manifests/argocd/, the argocd Application and
the SealedSecrets of Argo CD's repository credentials.

1. stages/00-bootstrap.yaml lists the service argocd in a list generator.
   bootstrap-argocd carries the ApplicationSet's resources finalizer and the
   stage prunes, so taking argocd out of the list deletes the argocd
   Application and the repository Secrets.
2. manifests/argocd/ holds the Application named argocd, and it carries no
   resources finalizer: deleted with one, it would delete Argo CD itself.
3. manifests/argocd/ defines every AppProject an Application needs (Chorde#94):
   each project an Application or ApplicationSet under the env dir names, and
   safezone, which SafeZone-Deploy's Applications name. Each carries the sync
   options Prune=false and Delete=false: the stage prunes and bootstrap-argocd
   carries the resources finalizer, so without them removing the file, or
   deleting bootstrap-argocd, deletes the project. The project default is
   Argo CD's own and needs no definition.

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
# Named by Applications outside Chorde (SafeZone-Deploy).
EXTERNAL_PROJECTS = {"safezone"}
BUILTIN_PROJECTS = {"default"}
SYNC_OPTIONS = "argocd.argoproj.io/sync-options"
REQUIRED_OPTIONS = ("Prune=false", "Delete=false")

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


def manifests(top):
    """Yield (path, doc) for every manifest document under top, skipping the
    git-ignored unsealed files."""
    for root, dirs, files in os.walk(top):
        dirs.sort()
        for name in sorted(files):
            if not name.endswith(MANIFEST) or name.startswith("unsealed-"):
                continue
            path = os.path.join(root, name)
            for doc in load_all(path):
                if isinstance(doc, dict):
                    yield path, doc


def named_projects(env_dir):
    projects = set(EXTERNAL_PROJECTS)
    for _, doc in manifests(env_dir):
        spec = doc.get("spec") or {}
        if doc.get("kind") == "Application":
            project = spec.get("project")
        elif doc.get("kind") == "ApplicationSet":
            project = ((spec.get("template") or {}).get("spec") or {}).get("project")
        else:
            continue
        if isinstance(project, str) and project:
            projects.add(project)
    return projects - BUILTIN_PROJECTS


def check_appprojects(env_dir):
    top = os.path.join(env_dir, "manifests", SERVICE)
    defined = {}
    for path, doc in manifests(top):
        if doc.get("kind") != "AppProject":
            continue
        meta = doc.get("metadata") or {}
        defined[meta.get("name")] = (path, meta)
    for project in sorted(named_projects(env_dir)):
        if project not in defined:
            find(f"manifests/{SERVICE}",
                 f"defines no AppProject named {project}; an Application names it")
            continue
        path, meta = defined[project]
        raw = (meta.get("annotations") or {}).get(SYNC_OPTIONS) or ""
        options = {o.strip() for o in str(raw).split(",")}
        for option in REQUIRED_OPTIONS:
            if option not in options:
                find(os.path.relpath(path, env_dir),
                     f"the AppProject {project} lacks the sync option {option}; "
                     "the stage's prune or bootstrap-argocd's finalizer would delete it")


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    check_stage(sys.argv[1])
    check_application(sys.argv[1])
    check_appprojects(sys.argv[1])
    for line in findings:
        print(line)
    sys.exit(1 if findings else 0)


if __name__ == "__main__":
    main()
