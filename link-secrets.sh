echo "Creating symlinks for secrets..."
echo "run once in the root of the homelab repo"
echo "This script will create symlinks to the secrets in the AppSecrets repo"


ln -s $HOME/Sync/Projects/AppSecrets/homelab/inventory.secret.yaml ./ansible/inventory.secret.yaml
ln -s $HOME/Sync/Projects/AppSecrets/homelab/vms-k8s/proxmox.vars.secret.yaml ./vms-k8s/envs/proxmox/vars.secret.yaml
ln -s $HOME/Sync/Projects/AppSecrets/homelab/vms-k8s/hetzner.vars.secret.yaml ./vms-k8s/envs/hetzner/vars.secret.yaml
ln -s $HOME/Sync/Projects/AppSecrets/homelab/vms-k8s/hetzner.secret.auto.tfvars ./vms-k8s/create-hetzner-vms/hetzner.secret.auto.tfvars