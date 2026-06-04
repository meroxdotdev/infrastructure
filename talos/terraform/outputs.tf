output "node_ips" {
  description = "DR node IPs (use these in gen-dr-talconfig.sh)"
  value       = var.node_ips
}

output "node_vip" {
  description = "DR Kubernetes API VIP"
  value       = var.node_vip
}

output "node_gateway" {
  description = "Gateway for DR nodes"
  value       = var.node_gateway
}

output "node_macs" {
  description = "MAC addresses assigned by Proxmox (needed for talconfig.yaml deviceSelector)"
  value       = [for vm in proxmox_virtual_environment_vm.talos_node : vm.network_device[0].mac_address]
}

output "next_steps" {
  description = "What to do after terraform apply"
  value       = <<-EOT
    VMs created. Next steps:

    1. Wait ~30s for Talos maintenance mode to initialize
    2. Verify nodes are reachable:
         nmap -Pn -n -p 50000 ${var.node_ips[0]} ${var.node_ips[1]} ${var.node_ips[2]} -vv | grep Discovered

       NOTE: Talos in maintenance mode has NO IP until you apply config.
       VMs boot from ISO — get IPs via DHCP or check Proxmox console.
       If DHCP is available, use the DHCP IPs for --insecure bootstrap.
       Otherwise assign static IPs first via Proxmox console (temporary).

    3. Generate talconfig patch and bootstrap:
         bash ../../scripts/gen-dr-talconfig.sh
         task bootstrap:talos

    4. After testing — destroy DR cluster:
         terraform destroy
         cp talos/talconfig.yaml.prod-backup talos/talconfig.yaml
  EOT
}
