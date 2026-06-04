output "server_ip" {
  description = "Public IPv4 of the new server"
  value       = hcloud_server.cloudlab.ipv4_address
}

output "server_ipv6" {
  description = "Public IPv6 of the new server"
  value       = hcloud_server.cloudlab.ipv6_address
}

output "ansible_host_entry" {
  description = "Paste this into inventories/production/hosts"
  value       = "vps01 ansible_host=${hcloud_server.cloudlab.ipv4_address}"
}

output "ssh_command" {
  description = "SSH command to connect"
  value       = "ssh root@${hcloud_server.cloudlab.ipv4_address}"
}
