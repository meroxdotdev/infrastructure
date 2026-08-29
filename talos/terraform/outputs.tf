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
  description = "Fixed MAC addresses for DR VMs (match talconfig.yaml hardwareAddr)"
  value       = var.node_macs
}

output "next_steps" {
  description = "What to do after terraform apply"
  value       = <<-EOT
    ${length(var.node_macs)} VM(s) created with prod's MACs. Next:

    1. Wait ~60s for Talos to reach maintenance mode (it boots on DHCP first)
    2. task dr:apply-talos-configs    # matches MAC → config, waits for static IPs
    3. task bootstrap:talos
    4. task bootstrap:apps
    5. task longhorn:restore
    6. task dr:verify

    Tear down with: task dr:destroy-vms && task dr:restore-prod
  EOT
}
