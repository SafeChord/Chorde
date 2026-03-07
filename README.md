# Chorde: Platform & Infrastructure Layer

Chorde is the foundation of the SafeChord ecosystem. It provides the Kubernetes platform and shared infrastructure services.

## Repository Structure

The repository follows a **Recursive GitOps (App-of-Apps)** architecture, designed for pure declarative management via ArgoCD.

```text
Chorde/
├── cluster/                 # Physical infrastructure configuration
│   └── k3han/               # K3s cluster definitions (versions)
│
├── legacy/                  # Archived configurations (v0.1, v0.2)
│
├── scripts/                 # Bootstrap & Validation tools (Imperative)
│   ├── bootstrap.sh         # Cluster initialization
│   └── test/                # Connectivity & Health checks
│
├── helm-charts/             # [Logic] Local Overrides/Wrappers ONLY
│   ├── kafka/               # (Example) Heavily customized chart
│   └── ...                  # Note: Standard services use upstream charts directly in GitOps
│
└── gitops/                  # [State] ArgoCD Desired State
    └── k3han/
        ├── stages/          # [Layer 0: Orchestrator] Entry points for ArgoCD
        │   ├── 00-bootstrap.yaml  # Points to manifests/00-bootstrap
        │   ├── 01-infra.yaml      # Points to manifests/01-infra
        │   └── 02-ops.yaml        # Points to manifests/02-ops
        │
        └── manifests/       # [Content] Pure Kubernetes Manifests
            ├── 00-bootstrap/      # [Layer 1: App List] List of Applications
            │   ├── sealed-secret.yaml # Application pointing to manifests/sealed-secret
            │   └── argocd.yaml
            │
            ├── sealed-secret/     # [Layer 2: Resources] Actual Resources
            │   ├── controller.yaml
            │   └── crd.yaml
            │
            └── kafka/             # [Layer 2: Resources] Actual Resources
                ├── values.yaml
                └── sealed-secrets.yaml
```

## Key Principles

1.  **SafeZone-Free**: This repo contains NO application-specific logic for SafeZone. It is a pure platform layer.
2.  **Recursive App-of-Apps**: 
    *   **Layer 0 (Stages)** manages the lifecycle order.
    *   **Layer 1 (App List)** manages the list of active services.
    *   **Layer 2 (Resources)** manages the actual K8s resources.
3.  **Pure Declarative**: The `gitops/` directory contains *only* Kubernetes manifests. No operational scripts are allowed alongside state definitions.
4.  **Upstream First**: We prioritize using official Helm Charts directly. The `helm-charts/` directory is reserved *only* for charts that require significant structural modification or local wrapping.

## Workflow

### Adding a Platform Service

1.  **Define Resources (Layer 2)**:
    *   Create a directory `gitops/<cluster>/manifests/<service-name>/`.
    *   Add `values.yaml`, `kustomization.yaml`, or other resources.
    *   *Reference the official Helm Chart repository in your Application or Chart.yaml.*

2.  **Register Application (Layer 1)**:
    *   Create an Application manifest in the appropriate stage app list directory (e.g., `gitops/<cluster>/manifests/01-infra/<service-name>.yaml`).
    *   Point the `source.path` to your new directory from Step 1.

    *Note: You do NOT need to modify the Layer 0 (Stages) files.*

### Managing Secrets

*   Secrets must be encrypted using SealedSecrets.
*   Generated `sealed-secrets.yaml` files should be placed directly in the service's Layer 2 directory.