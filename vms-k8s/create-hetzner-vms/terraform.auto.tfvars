
# Server configuration
#
control_count       = 3      # Number of control servers
worker_count        = 3      # Number of worker servers
control_server_type = "cx22" # 2 vCPU, 4 GB RAM
worker_server_type  = "cx32" # 4 vCPU, 8 GB RAM
image               = "ubuntu-24.04"
location            = "nbg1" # Nuremberg, Germany
network_zone        = "eu-central"
