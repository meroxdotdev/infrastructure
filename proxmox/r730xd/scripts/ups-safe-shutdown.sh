#!/bin/bash
# Triggered remotely by px-0 (10.57.57.254) UPS monitor (pwrstatd) on confirmed
# utility power failure, so this host shuts down gracefully instead of losing
# power ungracefully once the UPS battery runs out.
logger -t ups-safe-shutdown "Remote power-fail shutdown triggered from ${SSH_CLIENT%% *}"
systemctl poweroff
