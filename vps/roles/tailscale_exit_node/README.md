# tailscale_exit_node

Installs Tailscale from the official apt repo, enables IPv4/IPv6 forwarding,
and joins the tailnet as an exit node (`--advertise-exit-node --accept-routes
--accept-dns`). Idempotent: skips `tailscale up` if already logged in.

Auth key comes from vault (`vault_tailscale_auth_key`) — **reusable keys expire
after 90 days**; refresh it in the Tailscale admin console before any DR run
(see DEPLOY.md Phase 1). Flags are tunable in `defaults/main.yml`.

**DR note:** the new VPS will likely get a different tailnet IP than
`100.72.22.38`. `dr-verify-phase1` prints the new IP and warns if it changed —
see DEPLOY.md Phase 1.
