variable "proxmox_url" {
  description = "Proxmox API URL (e.g. https://10.57.57.254:8006)"
  type        = string
}

variable "proxmox_token_id" {
  description = "Proxmox API token ID (format: user@realm!tokenname)"
  type        = string
}

variable "proxmox_token_secret" {
  description = "Proxmox API token secret"
  type        = string
  sensitive   = true
}

variable "proxmox_nodes" {
  description = "Proxmox node names to distribute VMs across"
  type        = list(string)
  default     = ["px-0", "px-1", "px-2"]
}

variable "talos_version" {
  description = "Talos version — must match talos/talenv.yaml"
  type        = string
  default     = "v1.13.3"
}

variable "talos_image_id" {
  description = "Talos factory image hash — from talosImageURL in talconfig.yaml"
  type        = string
  default     = "8d37fcc01bb9173406853e7fd97ad9eda40732043f88e09dafe55e53fcf4b510"
}

variable "iso_storage" {
  description = "Proxmox storage for ISO files"
  type        = string
  default     = "local-data"
}

variable "disk_storage" {
  description = "Proxmox storage for VM disks"
  type        = string
  default     = "cluster-storage"
}

variable "network_bridge" {
  description = "Proxmox network bridge"
  type        = string
  default     = "vmbr0"
}

variable "vmid_start" {
  description = "Starting VMID for DR nodes (prod uses 800-805, DR uses 810+ by default)"
  type        = number
  default     = 810
}

variable "vm_cores" {
  description = "vCPU count per VM"
  type        = number
  default     = 4
}

variable "vm_memory_mb" {
  description = "RAM in MB per VM"
  type        = number
  default     = 8192
}

variable "vm_disk_gb" {
  description = "Root disk size in GB"
  type        = number
  default     = 50
}

variable "node_macs" {
  description = "Fixed MAC addresses for DR VMs — must match talconfig.yaml hardwareAddr. Set to prod MACs so DHCP gives same IPs and talconfig needs no patching."
  type        = list(string)
  default     = ["bc:24:11:a7:ba:13", "bc:24:11:a5:4b:9e", "bc:24:11:0e:cd:ab"]
}

variable "node_ips" {
  description = "Static IPs for the 3 DR nodes — use prod IPs when prod cluster is stopped"
  type        = list(string)
  default     = ["10.57.57.80", "10.57.57.82", "10.57.57.84"]
}

variable "node_vip" {
  description = "VIP for Kubernetes API — use prod VIP when prod cluster is stopped"
  type        = string
  default     = "10.57.57.88"
}

variable "node_gateway" {
  description = "Default gateway for the nodes"
  type        = string
  default     = "10.57.57.1"
}
