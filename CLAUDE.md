# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

This is a homelab infrastructure-as-code repository that automates deployment of VMs, LXC containers, and Kubernetes clusters on Proxmox and Hetzner Cloud using Ansible and Terraform.

## Architecture

### Three-Tier Infrastructure

1. **LXC Containers** (`lxc-*/`): Lightweight containerized services
   - ntfy (notifications), homepage (dashboard), omada (network controller)
   - qBittorrent, sponsorblock, uptime-kuma, speedtest

2. **Nginx VMs**: Two dedicated reverse proxy/gateway VMs
   - `vm-nginx-dmz/`: DMZ nginx with xray proxy and stream configs
   - `vm-nginx-vip/`: VIP nginx with keepalived, WireGuard, HAProxy for Proxmox access

3. **Kubernetes Cluster** (`vms-k8s/`): Production-grade HA cluster
   - 3 control-plane + 3 worker nodes with stacked etcd
   - Keepalived + HAProxy for load balancing (no MetalLB)
   - Flannel CNI, Longhorn storage
   - Full observability stack: Prometheus, Grafana, Loki, Tempo, Alloy
   - Platform services: Traefik, cert-manager, MinIO, PostgreSQL, ArgoCD, Kafka, Zitadel (OIDC), OAuth2-proxy

## Secrets Management

This repo uses symlinks to secrets stored outside the repository:

```bash
# Run once to link all secrets
./link-secrets.sh
```

Creates symlinks:
- `ansible/inventory.secret.yaml` - Proxmox inventory with credentials
- `vms-k8s/envs/proxmox/vars.secret.yaml` - Proxmox k8s variables
- `vms-k8s/envs/hetzner/vars.secret.yaml` - Hetzner k8s variables
- `vms-k8s/create-hetzner-vms/hetzner.secret.auto.tfvars` - Terraform secrets

Template for inventory: `ansible/template-proxmox-inventory.yaml`

## Common Commands

### LXC Containers

```bash
# Deploy any LXC container
./apply.sh lxc-<name>
# Example:
./apply.sh lxc-ntfy

# Expands to:
ansible-playbook -i ansible/inventory.secret.yaml lxc-<name>/create-lxc-<name>.yaml
```

### Kubernetes Cluster

#### Full Proxmox Deployment
```bash
cd vms-k8s
./deploy-k8s-proxmox-full.sh
```

Executes in sequence:
1. Create VMs via Ansible
2. Deploy K8s cluster
3. Deploy infrastructure services

#### Step-by-Step Proxmox
```bash
cd vms-k8s

# 1. Create VMs on Proxmox
ansible-playbook -i ../ansible/inventory.secret.yaml create-vms-k8s.yaml

# 2. Install Kubernetes (uses auto-generated inventory)
./deploy-k8s.sh proxmox

# 3. Deploy all infrastructure services
./deploy-k8s-env.sh proxmox

# 3a. Deploy single service only
./deploy-k8s-env.sh proxmox -only prometheus
```

#### Hetzner Cloud Deployment
```bash
cd vms-k8s

# Full deployment with Terraform + K8s
./deploy-k8s-hetzner.sh

# Or manually:
cd create-hetzner-vms
terraform apply -auto-approve
cd ..
./deploy-k8s.sh hetzner
./deploy-k8s-env.sh hetzner
```

### Nginx VMs

```bash
# Deploy DMZ nginx
./apply.sh vm-nginx-dmz

# Deploy VIP nginx with WireGuard
./apply.sh vm-nginx-vip
```

## Key Design Patterns

### Auto-Generated Inventories
- VM creation playbooks auto-generate Ansible inventory files
- Located at `vms-k8s/envs/<env>/generated.inventory.yaml`
- Used by subsequent k8s deployment scripts

### Environment Abstraction
- `vms-k8s/envs/proxmox/` - On-premises config
- `vms-k8s/envs/hetzner/` - Cloud config
- Same K8s deployment manifests work for both environments

### Kubernetes Deployment Structure
- `vms-k8s/deploy-k8s/` - Bare k8s cluster (kubeadm, containerd, flannel)
  - `0-deploy-cluster.yaml` - Main orchestration playbook
  - `1-preset-nodes.yaml` → `2-create-first-cp.yaml` → `3-join-cps.yaml` → `4-join-workers.yaml`

- `vms-k8s/deploy-k8s-env/` - Infrastructure services
  - `deploy-environment.yaml` - Main orchestration playbook
  - Each subdirectory = one service with K8s manifests
  - Uses `only_deploy` variable to deploy single services

### LXC Container Pattern
All `lxc-*/create-lxc-*.yaml` playbooks follow:
1. Call `ansible/create-lxc.yaml` (creates container, adds SSH key, updates inventory)
2. Install service-specific packages
3. Deploy nginx config (most services have reverse proxy)
4. Configure systemd services

## File Organization

```
.
├── ansible/                    # Shared Ansible playbooks
│   ├── create-lxc.yaml        # Reusable LXC creation
│   ├── add-docker.yaml        # Docker installation
│   └── add-ssl-certificate.yaml
├── lxc-*/                     # Individual LXC service configs
├── vm-nginx-{dmz,vip}/        # Nginx gateway VMs
├── vms-k8s/
│   ├── create-vm/             # Proxmox VM provisioning
│   ├── deploy-k8s/            # K8s cluster deployment
│   ├── deploy-k8s-env/        # K8s services (each dir = one app)
│   ├── create-hetzner-vms/    # Terraform for Hetzner
│   └── envs/                  # Environment-specific vars
└── node/                      # (Legacy?)
```

## Technology Stack

- **IaC**: Ansible (VMs/LXC/K8s), Terraform (Hetzner Cloud)
- **Virtualization**: Proxmox VE with Ceph storage
- **Container Orchestration**: Kubernetes v1.32 (kubeadm)
- **Container Runtime**: containerd
- **Networking**: Flannel CNI, VLANs, keepalived/HAProxy
- **Storage**: Longhorn (K8s), Ceph (Proxmox)
- **Observability**: Prometheus, Grafana, Loki, Tempo, Alloy
- **Security**: cert-manager, Zitadel (OIDC), OAuth2-proxy
