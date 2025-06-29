# Kubernetes Cluster Automation

This collection of scripts automates the complete deployment of a production-ready Kubernetes cluster with infrastructure services. It creates a 6-node cluster (3 control-plane + 3 worker nodes) with high availability and comprehensive monitoring.

## Quick Start
```bash
# Full deployment on Proxmox
./deploy-k8s-proxmox-full.sh

# Or step by step:
ansible-playbook -i ../ansible/inventory.secret.yaml create-vms-k8s.yaml
./deploy-k8s.sh proxmox
./deploy-k8s-env.sh proxmox
```

## Architecture
- **HA Control Plane**: 3 control-plane nodes with stacked etcd
- **Load Balancing**: Keepalived + HAProxy for cluster endpoints (no MetalLB dependency)
- **Network**: Flannel CNI with dedicated VLANs and virtual IPs
- **Storage**: Longhorn distributed storage system
- **Multi-Cloud**: Supports both Proxmox and Hetzner Cloud deployments

## Components

### 🖥️ **create-vm/** - VM Infrastructure
Creates and configures VMs on Proxmox cluster with:
- Automated VM provisioning from Ubuntu template
- Network configuration with VLANs and static IPs
- Load balancer setup (keepalived + haproxy) 
- Auto-generates inventory files for subsequent deployments

### ⚙️ **deploy-k8s/** - Kubernetes Cluster
Deploys bare Kubernetes cluster with:
- Kubeadm-based installation (v1.32)
- Containerd runtime with security hardening
- Flannel networking with pod subnet isolation
- Multi-master HA configuration with certificate management

### 🚀 **deploy-k8s-env/** - Infrastructure Services
Complete observability and platform services stack:
- **Security**: Cert-manager, Zitadel (OIDC), OAuth2-proxy
- **Ingress**: Traefik with TLS termination and middleware
- **Storage**: MinIO S3-compatible object storage
- **Monitoring**: Prometheus, Grafana, Loki, Tempo, Alloy
- **Data**: PostgreSQL cluster with automated backups
- **GitOps**: ArgoCD for continuous deployment
- **Dashboard**: Homepage with service integration
- **Message Streaming**: Kafka cluster

### 🌐 **Multi-Environment Support**
- **envs/proxmox/**: On-premises Proxmox deployment
- **envs/hetzner/**: Hetzner Cloud deployment  
- **create-hetzner-vms/**: Terraform scripts for Hetzner infrastructure

All environments share the same Kubernetes configuration for consistency across local and cloud deployments. 
