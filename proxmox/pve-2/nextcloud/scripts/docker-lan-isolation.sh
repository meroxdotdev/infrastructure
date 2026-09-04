#!/bin/bash
# Isolate Docker containers from the local network.
#
# Why: Nextcloud is the one service here exposed to the internet. Assume it can
# be compromised. Without this, code execution inside a container reaches the
# whole flat LAN - pfSense, the NAS, Proxmox, the k8s cluster.
#
# ufw does not cover this. Container traffic is FORWARDed, not INPUT/OUTPUT,
# and Docker inserts its own rules ahead of the ufw chains. DOCKER-USER is
# evaluated before Docker's own rules and is the supported place for this.
#
# Anything not matched here falls off the end of the chain and leaves normally,
# so outbound internet still works.
#
# -o $IF restricts the drops to traffic leaving on the physical NIC. Traffic
# between containers stays on the br-* bridges and is never touched.
set -e

IF=ens18
PVE=10.57.57.250      # borg backup repository
DNS=10.57.57.1        # pfSense

iptables -N DOCKER-USER 2>/dev/null || true
iptables -F DOCKER-USER

# Replies on established connections pass.
iptables -A DOCKER-USER -m conntrack --ctstate RELATED,ESTABLISHED -j RETURN

# The only two destinations a container legitimately needs on the LAN.
iptables -A DOCKER-USER -o $IF -d $DNS -p udp --dport 53 -j RETURN
iptables -A DOCKER-USER -o $IF -d $DNS -p tcp --dport 53 -j RETURN
iptables -A DOCKER-USER -o $IF -d $PVE -p tcp --dport 22 -j RETURN

# Everything else private is denied.
iptables -A DOCKER-USER -o $IF -d 10.0.0.0/8      -j DROP
iptables -A DOCKER-USER -o $IF -d 172.16.0.0/12   -j DROP
iptables -A DOCKER-USER -o $IF -d 192.168.0.0/16  -j DROP
iptables -A DOCKER-USER -o $IF -d 100.64.0.0/10   -j DROP
iptables -A DOCKER-USER -o $IF -d 169.254.0.0/16  -j DROP
