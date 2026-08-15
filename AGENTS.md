# Repository Guidelines

## Project Structure & Module Organization
Playbooks live in `ansible/`, with `template-proxmox-inventory.yaml` as the blueprint for the private `inventory.secret.yaml`. Each service or machine folder (`lxc-*`, `vm-*`, `node`, `proxmox-api`, etc.) contains a `create-<name>.yaml` play plus helper scripts or vars specific to that workload. Central utilities such as `apply.sh`, `link-secrets.sh`, and `updater/` orchestrate playbook execution and credential mounting.

## Build, Test, and Development Commands
Use `./apply.sh <folder>` (for example `./apply.sh lxc-syncthing`) to run the matching create playbook with the secret inventory. To work on individual plays, run `ansible-playbook -i ansible/inventory.secret.yaml lxc-sync/create-lxc-sync.yaml --check --diff` so you see planned mutations before applying them. When targeting ad-hoc hosts, reuse the inventory and script path above but swap in the relevant directory.

## Coding Style & Naming Conventions
YAML should use 2-space indentation, lowercase keys, and `snake_case` variable names to stay consistent with the current files. Tasks should have descriptive `name` fields and leverage Ansible modules instead of shell commands when available. Shell helpers follow the `#!/bin/bash` shebang and defensive argument checks as in `apply.sh`; mirror that pattern for new scripts.

## Testing Guidelines
Before committing, run `ansible-playbook <play>.yaml --syntax-check` and `--check` against a non-production host to validate ordering and idempotence. Prefer `--limit <host>` when experimenting so tests remain scoped. When touching shared roles, capture output snippets or screenshots showing the check run to attach to the PR description, and document any required manual verification (e.g., service status inside an LXC after deployment).

## Commit & Pull Request Guidelines
Recent history uses short, imperative subjects such as `move k8s to cilium` or `add alma front-door`; keep titles under ~60 characters and focus on *what* changes. Squash noisy work-in-progress commits locally, reference related VMs/LXCs in the body, and link issues when possible. Pull requests should describe the motivation, highlight risky playbook steps, and include validation details (commands run, host targets, screenshots for UI services).

## Security & Configuration Tips
Never commit populated inventories or cloud keys. Derive `ansible/inventory.secret.yaml` from the template, store secrets via your chosen password manager, and use `link-secrets.sh` to mount them locally. Rotate API tokens and SSH keys in `ansible/` host_vars frequently, and prefer vault-encrypted files when sharing configs beyond your machine.

## Agent skills

### Issue tracker

Issues are tracked in the repo's GitHub Issues via the `gh` CLI. See `docs/agents/issue-tracker.md`.

### Domain docs

Single-context: one root `CONTEXT.md` plus `docs/adr/`. See `docs/agents/domain.md`.
