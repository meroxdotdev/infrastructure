terraform {
  required_version = ">= 1.6"
  required_providers {
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = "~> 1.49"
    }
  }
}

provider "hcloud" {
  token = var.hcloud_token
}

resource "hcloud_ssh_key" "cloudlab" {
  name       = "cloudlab-merox"
  public_key = file(var.ssh_public_key_path)

  lifecycle {
    ignore_changes = [public_key]
  }
}

resource "hcloud_firewall" "cloudlab" {
  name = "cloudlab-vps"

  # SSH — only from your IPs
  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "22"
    source_ips = var.allowed_ips
  }

  # Tailscale WireGuard
  rule {
    direction  = "in"
    protocol   = "udp"
    port       = "41641"
    source_ips = var.allowed_ips
  }

  # HTTP + HTTPS (Traefik / Cloudflare tunnel health checks)
  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "80"
    source_ips = ["0.0.0.0/0", "::/0"]
  }

  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "443"
    source_ips = ["0.0.0.0/0", "::/0"]
  }

  # ICMP
  rule {
    direction  = "in"
    protocol   = "icmp"
    source_ips = ["0.0.0.0/0", "::/0"]
  }
}

resource "hcloud_server" "cloudlab" {
  name         = var.server_name
  image        = "ubuntu-24.04"
  server_type  = var.server_type
  location     = var.server_location
  ssh_keys     = [hcloud_ssh_key.cloudlab.id]
  firewall_ids = [hcloud_firewall.cloudlab.id]

  user_data = <<-EOF
    #cloud-config
    package_update: true
    packages:
      - python3
      - python3-pip
    runcmd:
      - mkdir -p /srv/docker /backup/synology
  EOF

  labels = {
    project     = "cloudlab"
    environment = "production"
    managed_by  = "terraform"
  }
}
