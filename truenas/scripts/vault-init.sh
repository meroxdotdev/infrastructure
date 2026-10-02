#!/bin/bash
# The vault's only init script: System → Advanced → Init/Shutdown Scripts,
# type Script, when POSTINIT, path /mnt/vault/system/scripts/vault-init.sh.
#
# POSTINIT runs once the pool is imported and the middleware is up, which is
# exactly the moment the nightly run needs. Both jobs are detached: an init
# script that blocks holds up the boot, and TrueNAS kills it at its timeout.
#
#   1. fan-control.sh first, so the fans drop to the floor right after POST;
#   2. vault-nightly.sh, which ends in the power-off gate.
set -u
SYS=/mnt/vault/system
mkdir -p "$SYS/logs"

setsid nohup "$SYS/scripts/fan-control.sh" >>"$SYS/logs/fan-control.log" 2>&1 </dev/null &
setsid nohup "$SYS/scripts/vault-nightly.sh" >/dev/null 2>&1 </dev/null &
exit 0
