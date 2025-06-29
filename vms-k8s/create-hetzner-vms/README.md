# Hetzner Cloud Kubernetes Infrastructure

This Terraform script creates a Kubernetes infrastructure on Hetzner Cloud with:

- 3 control plane VMs (named cloud-control-1, cloud-control-2, cloud-control-3) with internal IPs 10.100.0.11, 10.100.0.12, and 10.100.0.13
- 3 worker VMs (named cloud-worker-1, cloud-worker-2, cloud-worker-3) with internal IPs 10.100.0.101, 10.100.0.102, and 10.100.0.103
- Control VMs use 2 vCPU and 4GB RAM by default
- Worker VMs use 4 vCPU and 8GB RAM by default
- All VMs can communicate with each other through a private network (10.100.0.0/16)
- All VMs have public IPv4 addresses (IPv6 is disabled)
- Control nodes expose Kubernetes API on port 6443
- All VMs have SSH configured to listen on both ports 22 and 9022 (firewall only allows 9022)
- ICMP is only allowed within the private network

## Prerequisites

- [Terraform](https://www.terraform.io/downloads.html) installed (v1.0.0 or newer)
- Hetzner Cloud API token

## Configuration

1. Edit the `terraform.auto.tfvars` file with your server configuration and the `hetzner.secret.auto.tfvars` file with your Hetzner Cloud API token and SSH key:

```hcl
# In terraform.auto.tfvars:
# Server configuration
control_count = 3       # Number of control servers
worker_count = 3        # Number of worker servers
control_server_type = "cx22"  # 2 vCPU, 4 GB RAM
worker_server_type = "cx32"   # 4 vCPU, 8 GB RAM
image = "ubuntu-24.04"
location = "nbg1"       # Nuremberg, Germany
network_zone = "eu-central"

# Inventory configuration
domain_name = "k8s-hetzner.example.com"  # Domain name for inventory
ssh_key_path = "~/.ssh/id_rsa"           # Path to SSH key for Ansible

# In hetzner.secret.auto.tfvars:
# Hetzner Cloud API Token (required)
hcloud_token = "your-hetzner-cloud-api-token"

# SSH key (required)
ssh_key = "ssh-rsa AAAAB3N..."
```

## Available Configuration Variables

| Variable           | Description                       | Default       |
|---------------------|-----------------------------------|---------------|
| control_count      | Number of control servers to create | 3           |
| worker_count       | Number of worker servers to create | 3            |
| control_server_type | Type of server to create for control nodes | cx22 (2 CPU, 4GB RAM) |
| worker_server_type  | Type of server to create for worker nodes | cx31 (4 CPU, 8GB RAM) |
| image              | Image to use for server           | ubuntu-24.04  |
| domain_name        | Domain name for inventory file     | hetzner.your-domain.com |
| ssh_key_path       | Path to SSH private key for Ansible| ~/.ssh/id_rsa |
| location           | Location to create server in      | nbg1          |
| ssh_key            | SSH key to use for server         | Required      |
| network_zone       | Network zone for private network  | eu-central    |

## Usage

1. Initialize Terraform:

```bash
terraform init
```

2. Preview the changes:

```bash
terraform plan -var-file="terraform.tfvars"
```

3. Apply the changes:

```bash
terraform apply -var-file="terraform.tfvars"
```

4. Connect to VMs via SSH:

```bash
# SSH to control node 1
ssh -p 9022 root@$(terraform output -json | jq -r '.control_servers.value["cloud-control-1"].ipv4')

# SSH to worker node 1
ssh -p 9022 root@$(terraform output -json | jq -r '.worker_servers.value["cloud-worker-1"].ipv4')
```

4. To destroy the resources:

```bash
terraform destroy -var-file="terraform.tfvars"
```

## Outputs

After successful creation, you will get:

- `control_servers`: Details for each control plane server, including:
  - IPv4 public address
  - Internal IP address
  - Server status
- `worker_servers`: Details for each worker server, including:
  - IPv4 public address
  - Internal IP address
  - Server status
- `network`: Details about the private network
- `control_load_balancer`: Details for the control plane load balancer with Kubernetes API (port 6443)
- `worker_load_balancer`: Details for the worker nodes load balancer with HTTP/HTTPS traffic (ports 80/443)

## Ansible Inventory Generation

This script automatically generates an Ansible inventory file at `vms-k8s/envs/hetzner/generated.inventory.yaml` when you run `terraform apply`. The inventory includes:

- All VMs organized in groups (`control-nodes` and `worker-nodes`)
- Proper SSH connection details using the specified SSH key
- Public and internal IP addresses for each node
- Domain name configuration

You can customize the inventory by setting these variables in `terraform.auto.tfvars`:

```hcl
# Inventory configuration
domain_name = "k8s-hetzner.example.com"  # Your actual domain
ssh_key_path = "~/.ssh/your_private_key"  # Path to your SSH key
```
  - Service information (Kubernetes API on port 6443)
- `worker_load_balancer`: Details for the worker load balancer, including:
  - IPv4 and IPv6 public addresses
  - Service information (HTTPS on port 443)

## SSH Configuration

All VMs are automatically configured to listen for SSH connections on both port 22 and port 9022 using cloud-init. The firewall is configured to only allow external access via port 9022 for security reasons.

### How it works

1. A cloud-init script (`cloud-init-ssh.yaml`) is used during VM creation to:
   - Create `/etc/ssh/sshd_config.d/9022-port.conf` with both port definitions
   - Restart the SSH service to apply the changes
   - Configure UFW (if present) to allow port 9022

2. The firewall rules in Terraform:
   - Allow SSH access on port 9022 from any IPv4 address
   - Block direct access to port 22 from public networks
   - Allow all traffic (including SSH on port 22) between VMs on the private network

3. The Ansible inventory automatically includes the correct port:
   - Sets `ansible_port=9022` for all hosts
   - Enables seamless automation without manual SSH configuration

### Manual SSH Configuration

To add the VM to your SSH config for easier access:

```
# Add to ~/.ssh/config
Host hetzner-k8s-control-1
    HostName <control-1-ipv4>
    Port 9022
    User root
    IdentityFile ~/.ssh/your_private_key
```
