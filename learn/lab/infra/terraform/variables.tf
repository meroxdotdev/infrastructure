variable "proxmox_url" {
  description = "Proxmox API URL, e.g. https://10.57.57.254:8006"
  type        = string
}

variable "proxmox_api_token" {
  description = "API token as user@realm!tokenid=secret (Datacenter → Permissions → API Tokens)"
  type        = string
  sensitive   = true
}

variable "proxmox_ssh_private_key_path" {
  description = "Key with root SSH access to the PVE host, used for the disk import. No passphrase."
  type        = string
  default     = "~/.ssh/id_ed25519"
}

variable "proxmox_node" {
  description = "PVE host that runs the whole lab (option A in docs/01-laborator.md)"
  type        = string
  default     = "pve-1"
}

variable "iso_datastore" {
  description = "Storage with the 'ISO image' content type, for the cloud image"
  type        = string
  default     = "local"
}

variable "disk_datastore" {
  description = "Storage for VM disks and the cloud-init drive"
  type        = string
  default     = "local-lvm"
}

variable "wan_bridge" {
  description = "The bridge on the home LAN (where lab-gw's first NIC goes)"
  type        = string
  default     = "vmbr0"
}

variable "lab_bridge" {
  description = "Internal bridge for the lab network, created by this config when lab_vlan_id is null"
  type        = string
  default     = "vmbr10"
}

variable "lab_vlan_id" {
  description = "Option B: put the lab on this VLAN of wan_bridge instead of an internal bridge (needs a VLAN-aware bridge and a switch that passes tags)"
  type        = number
  default     = null
}

variable "router_wan_ip" {
  description = "lab-gw's address on the home LAN. Must match ROUTER_WAN_IP in learn/lab/env.sh"
  type        = string
  default     = "10.57.57.90"
}

variable "home_prefix" {
  description = "Prefix length of the home LAN"
  type        = number
  default     = 24
}

variable "home_gateway" {
  description = "Home LAN gateway (pfSense)"
  type        = string
  default     = "10.57.57.1"
}

variable "ssh_public_key_path" {
  description = "Your public key, installed for user 'ubuntu' on every VM"
  type        = string
  default     = "~/.ssh/id_ed25519.pub"
}

variable "vmid_start" {
  description = "lab-gw gets this VMID, the nodes the next three. Prod uses 810-812, DR 820+"
  type        = number
  default     = 900
}

variable "node_cores" {
  type    = number
  default = 4
}

variable "node_memory_mb" {
  description = "8 GB fits the full platform (module 15). 4 GB works until kube-prometheus-stack"
  type        = number
  default     = 8192
}

variable "node_disk_gb" {
  type    = number
  default = 60
}
