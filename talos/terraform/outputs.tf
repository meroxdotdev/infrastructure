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
    VMs created with fixed MACs (same as prod). Next steps:

    1. Wait ~60s for Talos maintenance mode + DHCP to initialize
    2. Verify nodes on prod IPs (Pi-hole gives same IPs via MAC reservation):
         until nmap -Pn -n -p 50000 ${var.node_ips[0]} ${var.node_ips[1]} ${var.node_ips[2]} 2>&1 | grep -c open | grep -q 3; do sleep 5; done

    3. Bootstrap Talos (no talconfig patching needed — IPs/MACs same as prod):
         task bootstrap:talos

    4. After testing — destroy DR cluster:
         terraform destroy
  EOT
}
