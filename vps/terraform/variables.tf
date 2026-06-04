variable "hcloud_token" {
  description = "Hetzner Cloud API Token (generate at console.hetzner.cloud → Security → API Tokens)"
  type        = string
  sensitive   = true
}

variable "ssh_public_key_path" {
  description = "Path to your SSH public key file"
  type        = string
  default     = "~/.ssh/id_ed25519.pub"
}

variable "server_name" {
  description = "Name of the server in Hetzner"
  type        = string
  default     = "cloudlab-vps"
}

variable "server_type" {
  description = "Hetzner server type. cax21=4vCPU ARM 8GB €5.39 | cax31=8vCPU ARM 16GB €9.19 | cx32=4vCPU x86 8GB €6.49"
  type        = string
  default     = "cax21"
}

variable "server_location" {
  description = "Hetzner datacenter: nbg1=Nuremberg | fsn1=Falkenstein | hel1=Helsinki | ash=Ashburn"
  type        = string
  default     = "nbg1"
}

variable "allowed_ips" {
  description = "IPs allowed for SSH and Tailscale ingress (your home IP + any other trusted IPs)"
  type        = list(string)
  default     = ["0.0.0.0/0", "::/0"]
}
