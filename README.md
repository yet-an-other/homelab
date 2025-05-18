### Homelab setup 

Setup proxmox hosts and set of vm/lxc's for homelab

Usage:
- copy `ansible/template-proxmox-inventory.yaml` to `ansible/secret.inventory.yaml`
- set the secret variable values
- run  
    `ansible-playbook -i ansible/secret.inventory.yaml <folder>/<script>.yaml`
    or
    `./apply.sh <folder>`