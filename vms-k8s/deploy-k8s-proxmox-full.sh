#!/bin/bash
set -e

ansible-playbook -i ../ansible/inventory.secret.yaml create-vms-k8s.yaml

./deploy-k8s.sh proxmox

./deploy-k8s-env.sh proxmox