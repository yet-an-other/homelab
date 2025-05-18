This set of scripts creates a bare Kubernetes (k8s) cluster consisting of 3 control-plane nodes and 3 worker nodes.
The inventory file is located in /ansible/secret.inventory.yaml
To run: `./apply.sh vms-k8s`

The cluster uses two virtual IPs: one for the control plane nodes to administer k8s and another for worker nodes to provide website access. These virtual IPs are managed by keepalived and haproxy.
MetalLB is not used in order to maintain similar cluster configurations in both local and cloud environments.

### Scripts in folders
**create-vm**\
Creates virtual machines on proxmox cluster. vms params are in `create-vms-k8s.yaml`
It also creates a virtual ip's and load balancer using keepalived & haproxy
And automatically creates `deploy-envs/proxmox/generate.inventory.yaml` for subsequent scripts 


**deploy-k8s**\
deploy basic k8s cluster from `deploy-envs/proxmox/generate.inventory.yaml`
3 control plane nodes and 3 worker nodes with flannel
it should work on any cluster with ubuntu, just need to put the right inventory file
