#!/bin/bash

if [ -z "$1" ]; then
    echo "Usage: ./apply.sh <folder>"
    exit 1
fi

if [ ! -d "$1" ]; then
    echo "$1 does not exist."
    exit 1
fi

VERBOSE=""
if [ "$2" ]; then
    VERBOSE=$2
fi
ansible-playbook -i ansible/inventory.secret.yaml $1/create-$1.yaml $VERBOSE