terraform {
  required_version = ">= 1.6"
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.110"
    }
  }
}

provider "proxmox" {
  endpoint  = var.proxmox_url
  api_token = "${var.proxmox_token_id}=${var.proxmox_token_secret}"
  insecure  = true
}

# Download Talos metal ISO to Proxmox ISO storage (idempotent)
resource "proxmox_virtual_environment_download_file" "talos_iso" {
  content_type        = "iso"
  datastore_id        = var.iso_storage
  node_name           = var.proxmox_nodes[0]
  file_name           = "talos-${var.talos_version}-metal-amd64.iso"
  url                 = "https://factory.talos.dev/image/${var.talos_image_id}/${var.talos_version}/metal-amd64.iso"
  overwrite_unmanaged = true
}

# 3 control-plane VMs, distributed across Proxmox nodes
resource "proxmox_virtual_environment_vm" "talos_node" {
  count     = 3
  name      = "kubernetes-dr-${count.index + 1}"
  node_name = var.proxmox_nodes[count.index % length(var.proxmox_nodes)]
  vm_id     = var.vmid_start + count.index
  tags      = ["talos", "k8s-dr"]

  cpu {
    cores = var.vm_cores
    type  = "host"
  }

  memory {
    dedicated = var.vm_memory_mb
  }

  # System disk
  disk {
    datastore_id = var.disk_storage
    file_format  = "raw"
    interface    = "scsi0"
    size         = var.vm_disk_gb
    discard      = "ignore"
  }

  # EFI disk — required for Talos UEFI boot
  efi_disk {
    datastore_id = var.disk_storage
    file_format  = "raw"
    type         = "4m"
  }

  # Talos ISO on IDE (maintenance mode boot)
  cdrom {
    enabled   = true
    file_id   = proxmox_virtual_environment_download_file.talos_iso.id
    interface = "ide2"
  }

  network_device {
    bridge      = var.network_bridge
    model       = "virtio"
    mac_address = upper(var.node_macs[count.index])
  }

  boot_order = ["ide2", "scsi0"]

  operating_system {
    type = "l26"
  }

  started = true

  # After Talos installs, ISO can be removed without TF destroying the VM
  lifecycle {
    ignore_changes = [cdrom]
  }
}
