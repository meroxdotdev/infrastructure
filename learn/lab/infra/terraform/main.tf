# The lab's four VMs on one Proxmox host. Same provider as talos/terraform/,
# different idea: those VMs boot an ISO and wait to be configured over an API;
# these boot a cloud image that cloud-init configures on first boot.
#
#   tofu init && tofu plan && tofu apply      (or terraform — the files are the same)

terraform {
  required_version = ">= 1.6"
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.118"
    }
  }
}

provider "proxmox" {
  endpoint  = var.proxmox_url
  api_token = var.proxmox_api_token
  insecure  = true # self-signed PVE certificate, as in talos/terraform

  # Importing a cloud image into a VM disk is done over SSH to the host, not
  # through the API. The key must be loaded without a passphrase prompt.
  ssh {
    username    = "root"
    private_key = file(pathexpand(var.proxmox_ssh_private_key_path))
  }
}

locals {
  nodes = {
    "k8s-1" = { ip = "10.10.0.11", vmid = var.vmid_start + 1 }
    "k8s-2" = { ip = "10.10.0.12", vmid = var.vmid_start + 2 }
    "k8s-3" = { ip = "10.10.0.13", vmid = var.vmid_start + 3 }
  }
  ssh_keys = [trimspace(file(pathexpand(var.ssh_public_key_path)))]
}

# A bridge with no physical port is a switch that exists only inside this
# host: the lab's VMs plug into it, and the only way out is through lab-gw.
# Option B in docs/01-laborator.md replaces it with a VLAN on vmbr0.
resource "proxmox_virtual_environment_network_linux_bridge" "lab" {
  count     = var.lab_vlan_id == null ? 1 : 0
  node_name = var.proxmox_node
  name      = var.lab_bridge
  comment   = "k8s learn lab - internal only, routed by lab-gw"
}

# Ubuntu's cloud image is a ready disk, not an installer. overwrite = false
# keeps the first download; "current" changes daily and would otherwise
# re-download and recreate every VM on the next apply.
resource "proxmox_virtual_environment_download_file" "ubuntu" {
  content_type        = "iso"
  datastore_id        = var.iso_datastore
  node_name           = var.proxmox_node
  url                 = "https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
  file_name           = "noble-server-cloudimg-amd64.img"
  overwrite           = false
  overwrite_unmanaged = true
}

resource "proxmox_virtual_environment_vm" "router" {
  name            = "lab-gw"
  description     = "k8s learn lab: router (nftables NAT, FRR/BGP), jumpbox, Garage S3. Managed by learn/lab/infra/terraform."
  node_name       = var.proxmox_node
  vm_id           = var.vmid_start
  tags            = ["learn", "k8s-lab"]
  on_boot         = false
  stop_on_destroy = true

  agent {
    enabled = false
  }

  cpu {
    cores = 2
    type  = "host"
  }

  memory {
    dedicated = 2048
  }

  disk {
    datastore_id = var.disk_datastore
    file_id      = proxmox_virtual_environment_download_file.ubuntu.id
    interface    = "virtio0"
    iothread     = true
    discard      = "on"
    size         = 40
  }

  # First NIC: the home LAN. Second NIC: the lab. cloud-init's ip_config
  # blocks below are matched to these in order.
  network_device {
    bridge = var.wan_bridge
    model  = "virtio"
  }

  network_device {
    bridge  = var.lab_vlan_id == null ? var.lab_bridge : var.wan_bridge
    model   = "virtio"
    vlan_id = var.lab_vlan_id
  }

  operating_system {
    type = "l26"
  }

  serial_device {}

  initialization {
    datastore_id = var.disk_datastore
    dns {
      servers = ["1.1.1.1", "9.9.9.9"]
    }
    ip_config {
      ipv4 {
        address = "${var.router_wan_ip}/${var.home_prefix}"
        gateway = var.home_gateway
      }
    }
    ip_config {
      ipv4 {
        address = "10.10.0.1/24"
      }
    }
    user_account {
      username = "ubuntu"
      keys     = local.ssh_keys
    }
  }

  depends_on = [proxmox_virtual_environment_network_linux_bridge.lab]
}

resource "proxmox_virtual_environment_vm" "node" {
  for_each = local.nodes

  name            = each.key
  description     = "k8s learn lab: control plane + worker. Managed by learn/lab/infra/terraform."
  node_name       = var.proxmox_node
  vm_id           = each.value.vmid
  tags            = ["learn", "k8s-lab"]
  on_boot         = false
  stop_on_destroy = true

  agent {
    enabled = false
  }

  cpu {
    cores = var.node_cores
    type  = "host" # Cilium's eBPF wants the host's CPU features, not a generic model
  }

  memory {
    dedicated = var.node_memory_mb
  }

  disk {
    datastore_id = var.disk_datastore
    file_id      = proxmox_virtual_environment_download_file.ubuntu.id
    interface    = "virtio0"
    iothread     = true
    discard      = "on"
    size         = var.node_disk_gb
  }

  network_device {
    bridge  = var.lab_vlan_id == null ? var.lab_bridge : var.wan_bridge
    model   = "virtio"
    vlan_id = var.lab_vlan_id
  }

  operating_system {
    type = "l26"
  }

  serial_device {}

  initialization {
    datastore_id = var.disk_datastore
    dns {
      servers = ["1.1.1.1", "9.9.9.9"]
    }
    ip_config {
      ipv4 {
        address = "${each.value.ip}/24"
        gateway = "10.10.0.1"
      }
    }
    user_account {
      username = "ubuntu"
      keys     = local.ssh_keys
    }
  }

  depends_on = [proxmox_virtual_environment_network_linux_bridge.lab]
}
