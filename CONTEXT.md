# Homelab

Infrastructure-as-code for the bdgn.me homelab: Proxmox LXC containers and VMs, Kubernetes clusters, and cloud-hosted VPN entry nodes.

## Language

### VPN topology

**forpost**:
The cloud-hosted VPN entry node: an Ubuntu VM on a public cloud provider that accepts user VPN connections and forwards the traffic onward.
_Avoid_: frontgate, front-door, gateway

**alwyzon**:
The external exit VM through which forpost's default-bound traffic reaches the internet. Lives outside this repository and is not managed by it.
_Avoid_: exit node, front-door

**bastion**:
The existing internal VM (`vm-bastion`) that provides access to internal VMs; forpost forwards privileged users' internal-destined traffic here.
_Avoid_: jump host

**privileged user**:
A VPN user whose forpost routing sends internal destinations (bdgn.me, 192.168.0.0/16) to the bastion. Identified by the authenticated email tag in forpost's xray config; non-privileged users get default routing to alwyzon (with 192.168.0.0/16 blocked).

**xform**:
The externally maintained, read-only observability panel associated with forpost's xray server. This repository owns deploying and connecting it; panel behavior, authentication, and data remain upstream concerns.
_Avoid_: xray control panel

### Unrelated, easy to confuse

**frontgate**:
A separate xray-based setup in this repo (`frontgate/`), unrelated to forpost; usable as a reference example only.

**front-door**:
An internal nginx/xray VM (`vm-front-door/`), unrelated to forpost despite the role-sounding name.
