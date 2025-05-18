#!/bin/bash

if [ -z "$1" ]; then
    echo "Usage: deploy-k8s.sh <env>\n example: deploy-k8s.sh proxmox"
    exit 1
fi

if [ ! -f "./envs/$1/generated.inventory.yaml" ]; then
    echo "./envs/$1/generated.inventory.yaml does not exist."
    exit 1
fi

ansible-playbook -i ./envs/$1/generated.inventory.yaml ./deploy-k8s/0-deploy-cluster.yaml