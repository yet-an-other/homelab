#!/bin/bash

if [ -z "$1" ]; then
    echo "Usage: deploy-k8s-env.sh <env>\n example: deploy-k8s-env.sh proxmox"
    exit 1
fi

if [ ! -f "./envs/$1/generated.inventory.yaml" ]; then
    echo "./envs/$1/generated.inventory.yaml does not exist."
    exit 1
fi

ansible-playbook -i ./envs/$1/generated.inventory.yaml ./deploy-k8s-env/deploy-environment.yaml