# initial_setup

Baseline OS setup for a fresh Ubuntu/Debian server (fails on anything else):
apt dist-upgrade + essential packages, timezone (`Europe/Bucharest`), NTP
(systemd-timesyncd on Ubuntu 24+, chrony otherwise), UFW (deny incoming, allow
SSH), unattended security upgrades, hostname from inventory.

Tunables in `defaults/main.yml`: `timezone`, `enable_ntp`, `enable_ufw`,
`allowed_ssh_port`, `system_packages`.
