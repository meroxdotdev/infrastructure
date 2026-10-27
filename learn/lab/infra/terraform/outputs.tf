output "ssh_router" {
  description = "Jump into the lab. -A forwards your agent so lab-gw can reach the nodes with your key."
  value       = "ssh -A ubuntu@${var.router_wan_ip}"
}

output "nodes" {
  value = { for name, n in local.nodes : name => n.ip }
}

output "next_step" {
  value = "On lab-gw: git clone https://github.com/meroxdotdev/infrastructure.git && sudo infrastructure/learn/lab/infra/router/setup-router.sh"
}
