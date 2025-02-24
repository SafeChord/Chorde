# K3han - Distributed Kubernetes Infrastructure

## Overview
K3han is a lightweight yet scalable Kubernetes-based infrastructure designed to efficiently manage microservices, observability, and CI/CD in a multi-node, cross-region setup. The cluster consists of:

- **Hetzner VPS** (K3s Server) - The primary control node for the cluster.
- **Desktop-Agent** (Home Server) - A powerful local machine serving as a worker node.
- **Oracle VM** (Planned) - A potential additional worker node used for demo environments.

## Features
### ✅ Core Infrastructure
- **K3s-based Cluster**: Lightweight Kubernetes for simplified management.
- **WireGuard VPN**: Secure cross-node communication over a private network.
- **Cloudflare Tunnel**: Exposes internal services securely without public IP exposure.
- **DNS Management**: Internal & external DNS resolution via CoreDNS & Cloudflare.

### 🚀 CI/CD & GitOps
- **ArgoCD**: GitOps-based deployment management.
- **GitHub Actions**: CI/CD automation for container builds and deployments.
- **GHCR (GitHub Container Registry)**: Secure container image storage.

### 🔍 Monitoring & Observability
- **Prometheus**: Metrics collection & monitoring.
- **Grafana**: Dashboard visualization.
- **Loki (Planned)**: Centralized logging for microservices.

### 🛠 Security & Secrets Management
- **Sealed Secrets**: Kubernetes-native secret encryption.
- **git-crypt**: Secure Git-based secret storage.
- **RBAC & Network Policies**: Fine-grained access control.

## Cluster Node Architecture
### **Current System Specification**
| Node           | Role         | Specs (CPU/RAM) | Location      | Purpose |
|---------------|-------------|----------------|--------------|----------|
| `hz-server`   | Master Node | 4vCPU / 16GB RAM | Hetzner VPS  | Control Plane & Load Balancer |
| `desktop-agent` | Worker Node | Intel i5-13600K / 64GB RAM | Home Server | High-performance workloads |
| `oracle-vm` (Planned) | Worker Node | 2vCPU / 8GB RAM | Oracle Cloud | Demo Environment |

### **Minimum System Requirements (For Future Open Source)**
| Node Type      | Role             | Minimum Specs       | Recommended Specs         | Example Deployment |
|---------------|-----------------|---------------------|---------------------------|-------------------|
| Master Node   | Control Plane    | 2vCPU / 4GB RAM     | 4vCPU / 16GB RAM          | Any VPS Provider  |
| Worker Node   | Application Node | 2vCPU / 4GB RAM     | 6vCPU / 32GB+ RAM         | Cloud / On-Prem   |
| Demo Node     | Testing          | 1vCPU / 2GB RAM     | 2vCPU / 8GB RAM           | Lightweight VM    |

## Architecture Diagrams
(To be added in future updates)

- **K3han Overall Topology**
- **GitOps / CI/CD Workflow**
- **Monitoring & Logging Architecture**
- **Kubernetes Service Traffic Flow**

## Deployment Workflow
1. **Code push to GitHub** → Triggers GitHub Actions.
2. **CI/CD builds & pushes images** to GHCR.
3. **ArgoCD syncs infrastructure & applications** from GitOps repository.
4. **Prometheus & Grafana monitor cluster health.**

## Secret & Security Management
- **Sealed Secrets**: Encrypts Kubernetes secrets for safer GitOps practices.
- **git-crypt**: Secures private repository secrets.
- **RBAC Policies**: Ensures granular access control within Kubernetes.

## GitOps Repository Structure (CHorde)
```
CHorde/
├── cluster/
│   ├── k3han/
│   │   ├── argocd/
│   │   ├── prometheus/
│   │   ├── values-secret.yaml (git-crypt encrypted)
│   │   ├── infra-configs/
│   ├── other-clusters/ (Planned for future expansion)
│
├── environments/
│   ├── dev/
│   ├── prod/
│
├── docs/
└── README.md
```

## Getting Started
### Clone Repository
```bash
 git clone https://github.com/your-repo/CHorde.git
 cd CHorde
```

### Initialize Git-Crypt
```bash
git-crypt init
git-crypt add-gpg-user your-email@example.com
```

### Install ArgoCD
```bash
helm install argocd argo/argocd -f values.yaml -n argocd
```

### Access ArgoCD
```bash
kubectl port-forward svc/argocd-server -n argocd 8080:443
```

## Contributors
- **@your-github** - Infra & DevOps
- **@another-contributor** - Backend & Microservices

## License
MIT License

