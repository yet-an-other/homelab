#!/bin/bash

# Parse arguments
ENV=""
ONLY_DEPLOY=""

while [[ $# -gt 0 ]]; do
    case $1 in
        -only)
            ONLY_DEPLOY="$2"
            shift 2
            ;;
        *)
            if [ -z "$ENV" ]; then
                ENV="$1"
            else
                echo "Unknown argument: $1"
                exit 1
            fi
            shift
            ;;
    esac
done

if [ -z "$ENV" ]; then
    echo "Usage: deploy-k8s-env.sh <env> [-only <deploy-name>]"
    echo "Example: deploy-k8s-env.sh proxmox"
    echo "Example: deploy-k8s-env.sh proxmox -only prometheus"
    exit 1
fi

if [ ! -f "./envs/$ENV/generated.inventory.yaml" ]; then
    echo "./envs/$ENV/generated.inventory.yaml does not exist."
    exit 1
fi

# Build ansible-playbook command
ANSIBLE_CMD="ansible-playbook -i ./envs/$ENV/generated.inventory.yaml --extra-vars @./envs/$ENV/vars.secret.yaml"

# Add only_deploy variable if specified
if [ -n "$ONLY_DEPLOY" ]; then
    ANSIBLE_CMD="$ANSIBLE_CMD --extra-vars only_deploy=$ONLY_DEPLOY"
fi

ANSIBLE_CMD="$ANSIBLE_CMD ./deploy-k8s-env/deploy-environment.yaml"

echo "Running: $ANSIBLE_CMD"
eval $ANSIBLE_CMD 