terraform {
  required_providers {
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = "~> 1.42.0"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.4.0"
    }
  }
  required_version = ">= 1.0.0"
}

# Define variables
variable "hcloud_token" {
  description = "Hetzner Cloud API Token"
  type        = string
  sensitive   = true
}

variable "control_count" {
  description = "Number of control servers to create"
  type        = number
  default     = 3
}

variable "worker_count" {
  description = "Number of worker servers to create"
  type        = number
  default     = 3
}

variable "control_server_type" {
  description = "Type of server to create for control nodes"
  type        = string
  default     = "cx22" # 2 vCPU, 4 GB RAM
}

variable "worker_server_type" {
  description = "Type of server to create for worker nodes"
  type        = string
  default     = "cx32" # 4 vCPU, 8 GB RAM
}

variable "image" {
  description = "Image to use for server"
  type        = string
  default     = "ubuntu-24.04"
}

variable "location" {
  description = "Location to create server in"
  type        = string
  default     = "nbg1" # Nuremberg, Germany
}

variable "ssh_key" {
  description = "SSH key to use for server (required)"
  type        = string
  # No default means it's required
}

variable "network_zone" {
  description = "Network zone to create private network in"
  type        = string
  default     = "eu-central"
}

variable "root_domain_name" {
  description = "The root domain name to use in the generated inventory file, e.g. 'your-domain.com'. used for root cookies"
  type        = string
  default     = "" 
}

variable "main_domain_name" {
  description = "Domain name to use in the generated inventory file, e.g. 'kuber-hetzner.your-domain.com'. The homepage will be available at this domain"
  type        = string
  default     = "" 
}

variable "ssh_key_path" {
  description = "Path to SSH private key to use for server access"
  type        = string
  default     = "~/.ssh/id_rsa"
}

# Configure the Hetzner Cloud Provider
provider "hcloud" {
  token = var.hcloud_token
}

# Create SSH key (required)
resource "hcloud_ssh_key" "default" {
  name       = "terraform-key"
  public_key = var.ssh_key
}

# Create a private network for internal communication
resource "hcloud_network" "private" {
  name     = "private-network"
  ip_range = "10.100.0.0/16"
}

# Create a subnet within the network
resource "hcloud_network_subnet" "private_subnet" {
  network_id   = hcloud_network.private.id
  type         = "cloud"
  network_zone = var.network_zone
  ip_range     = "10.100.0.0/24" # Single subnet for all nodes
}

# Read cloud-init configuration
data "local_file" "cloud_init_config" {
  filename = "${path.module}/cloud-init-ssh.yaml"
}

# Create Hetzner Cloud control servers
resource "hcloud_server" "control" {
  count       = var.control_count
  name        = "cloud-control-${count.index + 1}"
  server_type = var.control_server_type
  image       = var.image
  location    = var.location
  user_data   = data.local_file.cloud_init_config.content

  # Use the SSH key (required)
  ssh_keys = [hcloud_ssh_key.default.id]

  # Enable public IPv4, disable IPv6
  public_net {
    ipv4_enabled = true
    ipv6_enabled = false
  }

  # Wait for server to be running
  lifecycle {
    create_before_destroy = true
  }

  # Add firewall rules (excluding inter-node firewall to avoid circular dependency)
  firewall_ids = [hcloud_firewall.default.id, hcloud_firewall.control_plane.id]

  # Attach to the private network
  depends_on = [hcloud_network_subnet.private_subnet]
}

# Attach control servers to the private network with specific IP addresses
resource "hcloud_server_network" "control_network" {
  count      = var.control_count
  server_id  = hcloud_server.control[count.index].id
  network_id = hcloud_network.private.id

  # Assigning custom IPs: 10.100.0.11, 10.100.0.12, 10.100.0.13
  ip = "10.100.0.${count.index + 11}"
}

# Create Hetzner Cloud worker servers
resource "hcloud_server" "worker" {
  count       = var.worker_count
  name        = "cloud-worker-${count.index + 1}"
  server_type = var.worker_server_type
  image       = var.image
  location    = var.location
  user_data   = data.local_file.cloud_init_config.content

  # Use the SSH key (required)
  ssh_keys = [hcloud_ssh_key.default.id]

  # Enable public IPv4, disable IPv6
  public_net {
    ipv4_enabled = true
    ipv6_enabled = false
  }

  # Wait for server to be running
  lifecycle {
    create_before_destroy = true
  }

  # Add basic firewall rules (excluding inter-node firewall to avoid circular dependency)
  firewall_ids = [hcloud_firewall.default.id]

  # Attach to the private network
  depends_on = [hcloud_network_subnet.private_subnet]
}

# Attach worker servers to the private network with specific IP addresses
resource "hcloud_server_network" "worker_network" {
  count      = var.worker_count
  server_id  = hcloud_server.worker[count.index].id
  network_id = hcloud_network.private.id

  # Assigning custom IPs: 10.100.0.101, 10.100.0.102, 10.100.0.103
  ip = "10.100.0.${count.index + 101}"
}

# Create a firewall for Kubernetes control plane nodes
resource "hcloud_firewall" "control_plane" {
  name = "control-plane-firewall"

  # Allow Kubernetes API access (port 6443)
  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "6443"
    source_ips = ["0.0.0.0/0"] # Allow from IPv4
  }
}

# Create a basic firewall
resource "hcloud_firewall" "default" {
  name = "cloud-firewall"

  # Allow SSH from any IPv4 on port 9022
  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "9022"
    source_ips = ["0.0.0.0/0"]
  }

  # Allow all traffic between VMs via private network
  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "any"
    source_ips = ["10.100.0.0/16"]
  }

  rule {
    direction  = "in"
    protocol   = "udp"
    port       = "any"
    source_ips = ["10.100.0.0/16"]
  }

  rule {
    direction  = "in"
    protocol   = "icmp"
    source_ips = ["10.100.0.0/16"] # Allow ICMP only within the private network
  }
}

# Local values to collect all node IP addresses
locals {
  # Collect all node public IP addresses for firewall rules (convert to CIDR format)
  all_node_ips = concat(
    [for server in hcloud_server.control : "${server.ipv4_address}/32"],
    [for server in hcloud_server.worker : "${server.ipv4_address}/32"]
  )
}

# Create a firewall for inter-node communication via public IPs
# Only allow traffic between actual Kubernetes node public IP addresses
resource "hcloud_firewall" "inter_node_public" {
  name = "inter-node-public-firewall"

  # Allow all TCP traffic between Kubernetes nodes only
  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "any"
    source_ips = local.all_node_ips
  }

  # Allow all UDP traffic between Kubernetes nodes only
  rule {
    direction  = "in"
    protocol   = "udp"
    port       = "any"
    source_ips = local.all_node_ips
  }

  # Allow ICMP for network diagnostics between nodes only
  rule {
    direction  = "in"
    protocol   = "icmp"
    source_ips = local.all_node_ips
  }

  # This firewall depends on the servers being created first
  depends_on = [hcloud_server.control, hcloud_server.worker]
}

# Assign inter-node firewall to control servers
resource "hcloud_firewall_attachment" "control_inter_node" {
  firewall_id = hcloud_firewall.inter_node_public.id
  server_ids  = [for server in hcloud_server.control : server.id]
}

# Assign inter-node firewall to worker servers  
resource "hcloud_firewall_attachment" "worker_inter_node" {
  firewall_id = hcloud_firewall.inter_node_public.id
  server_ids  = [for server in hcloud_server.worker : server.id]
}

# Output the server information
output "control_servers" {
  value = {
    for idx, server in hcloud_server.control :
    server.name => {
      ipv4        = server.ipv4_address
      internal_ip = hcloud_server_network.control_network[idx].ip
      status      = server.status
    }
  }
}

output "worker_servers" {
  value = {
    for idx, server in hcloud_server.worker :
    server.name => {
      ipv4        = server.ipv4_address
      internal_ip = hcloud_server_network.worker_network[idx].ip
      status      = server.status
    }
  }
}

output "network" {
  value = {
    name     = hcloud_network.private.name
    ip_range = hcloud_network.private.ip_range
    subnet   = hcloud_network_subnet.private_subnet.ip_range
  }
}

output "control_load_balancer" {
  value = {
    name        = hcloud_load_balancer.control.name
    ipv4        = hcloud_load_balancer.control.ipv4
    internal_ip = hcloud_load_balancer_network.control.ip
    service     = "Kubernetes API (6443)"
  }
}

output "worker_load_balancer" {
  value = {
    name        = hcloud_load_balancer.worker.name
    ipv4        = hcloud_load_balancer.worker.ipv4
    internal_ip = hcloud_load_balancer_network.worker.ip
    services    = ["HTTP (80)", "HTTPS (443)"]
  }
}

output "inter_node_firewall_ips" {
  description = "IP addresses that will be allowed in the inter-node firewall"
  value       = local.all_node_ips
}




# Create a load balancer for worker nodes (HTTP/HTTPS traffic)
resource "hcloud_load_balancer" "worker" {
  name               = "worker-lb"
  load_balancer_type = "lb11" # Standard load balancer (20 Mbit/s)
  location           = var.location
}

# Attach the worker load balancer to the private network
resource "hcloud_load_balancer_network" "worker" {
  load_balancer_id = hcloud_load_balancer.worker.id
  network_id       = hcloud_network.private.id
  ip               = "10.100.0.20" # Reserve 20 for the worker LB
}

# Add target servers to the worker load balancer
resource "hcloud_load_balancer_target" "worker" {
  count            = var.worker_count
  type             = "server"
  load_balancer_id = hcloud_load_balancer.worker.id
  server_id        = hcloud_server.worker[count.index].id
  use_private_ip   = true
  depends_on       = [hcloud_server_network.worker_network]
}

# Configure HTTP service on the worker load balancer
resource "hcloud_load_balancer_service" "http" {
  load_balancer_id = hcloud_load_balancer.worker.id
  protocol         = "tcp"
  listen_port      = 80
  destination_port = 30080
}

# Configure HTTPS service on the worker load balancer
resource "hcloud_load_balancer_service" "https" {
  load_balancer_id = hcloud_load_balancer.worker.id
  protocol         = "tcp"
  listen_port      = 443
  destination_port = 30443
}

# Create a load balancer for control nodes (Kubernetes API traffic)
resource "hcloud_load_balancer" "control" {
  name               = "control-lb"
  load_balancer_type = "lb11" # Standard load balancer (20 Mbit/s)
  location           = var.location
}

# Attach the control load balancer to the private network
resource "hcloud_load_balancer_network" "control" {
  load_balancer_id = hcloud_load_balancer.control.id
  network_id       = hcloud_network.private.id
  ip               = "10.100.0.10" # Reserve 10 for the control LB
}

# Add target servers to the control load balancer
resource "hcloud_load_balancer_target" "control" {
  count            = var.control_count
  type             = "server"
  load_balancer_id = hcloud_load_balancer.control.id
  server_id        = hcloud_server.control[count.index].id
  use_private_ip   = true
  depends_on       = [hcloud_server_network.control_network]
}

# Configure Kubernetes API service on the control load balancer
resource "hcloud_load_balancer_service" "kubernetes_api" {
  load_balancer_id = hcloud_load_balancer.control.id
  protocol         = "tcp"
  listen_port      = 6443
  destination_port = 6446
}

