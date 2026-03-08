# Chorde: Platform & Infrastructure Layer

Chorde is the foundation of the SafeChord ecosystem. It provides the Kubernetes platform (K3s) and shared infrastructure services, managed via a pure GitOps workflow.

## Repository Structure

The repository follows a **Recursive GitOps (App-of-Apps)** architecture, utilizing ArgoCD `ApplicationSet` for layered orchestration and dynamic service deployment.

```text
Chorde/
├── cluster/                 # Physical infrastructure configuration
│   └── k3han/               # K3s cluster definitions
│       ├── ansible/         # Cluster provisioning playbooks
│       └── k3s/             # Node-specific systemd units & configs
│
├── gitops/                  # [State] ArgoCD Desired State
│   └── k3han/
│       ├── root.yaml        # Entry point: Manages the ApplicationSets in stages/
│       ├── stages/          # [Layer 0: Orchestrator] Stage-based ApplicationSets
│       │   ├── 00-bootstrap.yaml   # Basic security & ingress (Wave 1)
│       │   ├── 01-platform.yaml    # Operators & Observability (Wave 2)
│       │   └── 02-components.yaml  # Stateful services & App components (Wave 3)
│       │
│       └── manifests/       # [Content] Pure Kubernetes Manifests & Helm Apps
│           ├── argocd/      # ArgoCD self-management
│           ├── ingress-*/   # Public/Private Nginx controllers
│           ├── cnpg-*/      # CloudNativePG Operator & Clusters
│           ├── monitoring/  # Prometheus, Loki, Alloy, Fluent-bit
│           └── ...          # Other platform services (Keda, SealedSecrets, etc.)
│
├── scripts/                 # Operational & Validation tools
│   ├── ops/                 # Bootstrap & Secret sealing tools
│   └── test/                # E2E connectivity & health checks per component
│
└── legacy/                  # Archived configurations (v0.1, v0.2)
```

## GitOps Orchestration (App-of-Apps)

Chorde uses a three-stage synchronization strategy to ensure dependency integrity:

### Stage 0: Bootstrap
Focuses on essential services required for the cluster to function and receive traffic.
- **Security**: `sealed-secrets`
- **Traffic**: `ingress-public`, `ingress-private`
- **Automation**: `system-upgrade-controller`, `keda`

### Stage 1: Platform
Deploys the "Brain" of the cluster, including operators and the observability stack.
- **Operators**: `cnpg-operator`, `strimzi-operator`
- **Observability**: `prometheus`, `loki`, `alloy`, `fluent-bit`
- **Maintenance**: `system-upgrade-plan`

### Stage 2: Components
Deploys stateful middleware and shared application resources.
- **Databases**: `cnpg-postgresql` (PostgreSQL), `valkey` (Redis-compatible)
- **Messaging**: `strimzi-kafka` (Kafka)
- **Testing**: `echo-server`

## Infrastructure (k3han)

The cluster (codenamed `k3han`) is a hybrid-cloud K3s deployment spanning multiple providers:
- **Control Plane**: Hosted on a central server (`ct-serv-jp`).
- **Agents**: Edge nodes (Acer) and Cloud nodes (GCE).

> [!IMPORTANT]  
> **Ansible Disclaimer**: Due to the high variability of hardware nodes and the current small cluster scale, the provided Ansible playbooks are primarily used as a **Record of Actions (Documentation)** to track configuration steps. They are NOT intended for fully automated zero-touch provisioning at this stage.

Provisioning reference:
```bash
cd cluster/k3han/ansible
ansible-playbook -i inventory.ini privision.yaml
```

## Operational Workflows

### Bootstrap the GitOps Controller
To initialize the entire platform from a fresh K3s install:
1. Install ArgoCD manually or via `scripts/ops/bootstrap-cluster.sh`.
2. Apply the root application:
   ```bash
   kubectl apply -f gitops/k3han/root.yaml
   ```

### Secret Management
Secrets are managed using **Bitnami Sealed Secrets**.
- Unsealed secrets should **NEVER** be committed.
- Use `scripts/ops/seal.sh` to encrypt local manifests before committing.

### Validation
Each component includes automated test scripts in `scripts/test/`.
Example:
```bash
./scripts/test/ingress/ingress-isolation-test.sh
```
