#!/bin/bash

# This script deploys a Kubernetes cluster on Hetzner Cloud


set -e

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
cd "${SCRIPT_DIR}/create-hetzner-vms"

echo "🚀 Step 1: Creating Hetzner Cloud VMs with Terraform"
terraform apply -auto-approve

echo "✅ Successfully created Hetzner Cloud infrastructure."
echo "📄 Ansible inventory generated at: ${SCRIPT_DIR}/envs/hetzner/generated.inventory.yaml"
echo "🔒 SSH is configured on ALL VMs to listen on port 9022"

echo "🔐 Step 2: Ensuring that target VMs are accessible via SSH..."

# Helper function to check if a VM is accessible via SSH
check_ssh_access() {
  local ip=$1
  local hostname=$2
  local max_attempts=10
  local counter=0
  local ssh_key="${HOME}/Sync/Projects/hetzner/hetzner-vpn-key.ossh"
  
  echo "  🔄 Testing SSH connection to ${hostname} (${ip})..."
  
  while ! ssh -i "${ssh_key}" -o "StrictHostKeyChecking=no" -o "ConnectTimeout=5" -p 9022 root@${ip} "hostname" &>/dev/null; do
    if [ $counter -eq $max_attempts ]; then
      echo "  ❌ Failed to connect to ${hostname} after ${max_attempts} attempts."
      return 1
    fi
    echo "  ⏱️ Waiting for SSH connection to ${hostname} (attempt ${counter}/${max_attempts})..."
    sleep 10
    ((counter++))
  done
  
  echo "  ✅ Successfully connected to ${hostname} via SSH port 9022"
  return 0
}

# Get all server IPs from Terraform output
FIRST_CONTROL_IP=$(terraform output -json | jq -r '.control_servers.value["cloud-control-1"].ipv4')
ALL_CONTROL_SERVERS=$(terraform output -json | jq -r '.control_servers.value | to_entries | map({name: .key, ip: .value.ipv4})')
ALL_WORKER_SERVERS=$(terraform output -json | jq -r '.worker_servers.value | to_entries | map({name: .key, ip: .value.ipv4})')

# Check the first control node first (critical for bootstrapping)
if ! check_ssh_access "$FIRST_CONTROL_IP" "cloud-control-1"; then
  echo "❌ Failed to connect to the primary control node. Please check your SSH setup and firewall rules."
  exit 1
fi

echo "📦 Step 3: Installing Kubernetes..."
cd "${SCRIPT_DIR}"
# ansible-playbook -i envs/hetzner/generated.inventory.yaml deploy-k8s/0-deploy-cluster.yaml

# echo "🌟 Step 4: Setting up Kubernetes workloads..."
# ansible-playbook -i envs/hetzner/generated.inventory.yaml deploy-k8s-env/deploy-environment.yaml

# echo "🎉 Successfully deployed Kubernetes cluster on Hetzner Cloud!"
echo "📝 Control Plane Load Balancer: $(terraform -chdir=create-hetzner-vms output -json | jq -r '.control_load_balancer.value.ipv4'):6443"
echo "🌐 Worker Load Balancer: $(terraform -chdir=create-hetzner-vms output -json | jq -r '.worker_load_balancer.value.ipv4'):80"

# echo "🔧 To access your cluster, run:"
# echo "export KUBECONFIG=\${SCRIPT_DIR}/envs/hetzner/admin.conf"
# echo "kubectl get nodes"

echo "🔑 SSH access instructions:"
echo "  - Connect to any VM using: ssh -p 9022 root@<VM_IP_ADDRESS>"
echo "  - Example: ssh -p 9022 root@\${FIRST_CONTROL_IP}"
