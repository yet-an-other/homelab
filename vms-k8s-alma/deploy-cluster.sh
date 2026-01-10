#!/bin/bash

if [ -z "$1" ]; then
    echo "Usage: $0 <env>\n example: $0 proxmox"
    exit 1
fi

if [ ! -f "envs/$1/generated.inventory.yaml" ]; then
    echo "envs/$1/generated.inventory.yaml does not exist."
    exit 1
fi

ansible-playbook -i envs/$1/generated.inventory.yaml create-cluster/0-create-cluster.yaml