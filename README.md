### Homelab setup 

Setup proxmox hosts and set of vm/lxc's for homelab

Usage:
- copy `ansible/template-proxmox-inventory.yaml` to `ansible/secret-proxmox-inventory.yaml`
- set the secret variable values
- run  `ansible-playbook -i ansible/secret-proxmox-inventory.yaml <folder>/<script>.yaml`