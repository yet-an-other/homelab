#!/bin/bash

if [ -z "$1" ]; then
    echo "Usage: apply.sh <folder>"
    exit 1
fi

if [ ! -d "$1" ]; then
    echo "$1 does not exist."
    exit 1
fi

ansible-playbook -i ansible/secret.inventory.yaml $1/create-$1.yaml