#!/bin/bash
# pve-2 post-install: everything after Proxmox is on disk and the media pool is
# imported. Idempotent — run it twice, nothing breaks.
#
#   ./reinstall.sh --check    what it would do, changes nothing
#   ./reinstall.sh            do it
#
# What it deliberately does NOT do, because a human has to:
#   - PERC H730P into HBA mode (firmware, before installing)
#   - the Proxmox installer itself (rpool mirror on the two Intel SSDs)
#   - zpool import -f media
#   - restic restore of /root (needs the repo password typed in)
#   - authorising AIO's borg key (AIO generates it interactively)
# REINSTALL.md covers those, and only those.
set -uo pipefail

CHECK=0; [ "${1:-}" = "--check" ] && CHECK=1
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FAIL=0

# Run from inside the repo checkout: every file this applies is a sibling.
# Copying just the script somewhere else silently applies the wrong paths.
for need in etc/crontab etc/exports etc/storage.cfg install-spindown.sh \
            scripts/fan-control.sh etc/fan-control.service; do
  [ -f "$REPO/$need" ] || {
    printf 'Run this from the repo checkout — %s is missing next to the script.\n' "$need"
    exit 1
  }
done

say()  { printf '\n\033[1;36m== %s\033[0m\n' "$1"; }
ok()   { printf '  \033[0;32m✓\033[0m %s\n' "$1"; }
warn() { printf '  \033[1;33m!\033[0m %s\n' "$1"; }
bad()  { printf '  \033[0;31m✗\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }
run()  { if [ "$CHECK" = 1 ]; then printf '  would run: %s\n' "$*"; else "$@"; fi; }

# --- preconditions ---------------------------------------------------------
say "Preconditions"
if zpool list media >/dev/null 2>&1; then
  ok "media pool imported"
else
  bad "media pool not imported — run: zpool import -f media"
fi
if zpool list rpool >/dev/null 2>&1; then
  ok "rpool present"
else
  bad "rpool missing — Proxmox is not installed yet"
fi
[ "$FAIL" -gt 0 ] && { printf '\nFix the above first.\n'; exit 1; }

# --- packages --------------------------------------------------------------
say "Packages"
PKGS="nfs-kernel-server sg3-utils smartmontools ipmitool restic rsync bc borgbackup"
MISSING=""
for p in $PKGS; do
  dpkg -s "$p" >/dev/null 2>&1 || MISSING="$MISSING $p"
done
if [ -n "$MISSING" ]; then
  run apt-get update -qq
  run apt-get install -y $MISSING
  ok "installed:$MISSING"
else
  ok "all present"
fi
# storcli is mirrored into the backup tree on purpose — no vendor URL needed
if ! command -v storcli64 >/dev/null 2>&1; then
  D=$(ls /media/backups/tools/storcli*.deb 2>/dev/null | head -1)
  [ -n "$D" ] && run dpkg -i "$D" || warn "storcli .deb not found in /media/backups/tools/"
else
  ok "storcli present"
fi

# --- storage and exports ---------------------------------------------------
say "Storage and NFS exports"
run install -m 644 "$REPO/etc/storage.cfg" /etc/pve/storage.cfg
run install -m 644 "$REPO/etc/exports" /etc/exports
run exportfs -ra
ok "storage.cfg and exports applied"

# Dataset properties do not come back with an import. Without the reservation a
# large download fills the pool and the first thing to fail with ENOSPC is the
# backup — irreplaceable data losing the race to the re-downloadable kind.
for spec in "reservation=150G media/backups" "quota=3T media/library"; do
  prop=${spec%% *}; ds=${spec##* }; key=${prop%%=*}; want=${prop#*=}
  have=$(zfs get -H -o value "$key" "$ds" 2>/dev/null)
  if [ "$have" = "$want" ]; then
    ok "$ds $key=$want"
  else
    run zfs set "$prop" "$ds"
    ok "$ds $key set to $want (was $have)"
  fi
done
# media/games was destroyed 2026-08-17 and must not come back
zfs list media/games >/dev/null 2>&1 && warn "media/games exists — it was retired, destroy it"

# --- schedule --------------------------------------------------------------
say "Schedule"
if crontab -l 2>/dev/null | grep -q git-drift-check; then
  ok "crontab already installed"
else
  run bash -c "crontab '$REPO/etc/crontab'"
  ok "crontab installed from the repo"
fi
warn "the weekly Synology line is redacted in git — add it back from /root/PRIVATE-NOTES.md"
warn "it must land inside the NAS wake window, which DSM keeps in its own local time"

# --- spin-down -------------------------------------------------------------
say "Spin-down"
if [ -x /root/scripts/sas-spindown.sh ] && systemctl is-active --quiet sas-spindown.timer; then
  ok "installed and the timer is active"
else
  run "$REPO/install-spindown.sh"
  ok "install-spindown.sh ran — it generates the four sas-*/spindown-* scripts"
fi

# --- fan control -----------------------------------------------------------
# Installed last of the host services and first of the ones you will hear. A
# fresh install runs on iDRAC's algorithm until this is in place, which is
# loud but never unsafe — so a failure here is a warning, not a hard stop.
say "Fan control"
run install -m 755 "$REPO/scripts/fan-control.sh" /root/scripts/fan-control.sh
run install -m 644 "$REPO/etc/fan-control.service" /etc/systemd/system/fan-control.service
run systemctl daemon-reload
run systemctl enable --now fan-control.service
if [ "$CHECK" = 1 ]; then
  ok "would install and enable fan-control.service"
elif systemctl is-active --quiet fan-control.service; then
  ok "fan-control.service running — /root/scripts/fan-control.sh --status to see it"
else
  warn "fan-control.service is not running; the box stays on iDRAC's algorithm (loud, safe)"
fi

# --- nextcloud borg receiver ----------------------------------------------
say "Nextcloud borg receiver"
if id borg-nextcloud >/dev/null 2>&1; then
  ok "borg-nextcloud user exists"
else
  run useradd --system --create-home --home-dir /var/lib/borg-nextcloud \
      --shell /bin/bash borg-nextcloud
  ok "borg-nextcloud created"
fi
run bash -c "zfs create media/backups/nextcloud 2>/dev/null || true"
run chown borg-nextcloud:borg-nextcloud /media/backups/nextcloud
run chmod 700 /media/backups/nextcloud
run install -d -m 700 -o borg-nextcloud -g borg-nextcloud /var/lib/borg-nextcloud/.ssh
ok "repository directory and ssh dir in place"
warn "AIO's borg key is authorised by hand — REINSTALL.md has the forced-command line"

# --- verify ----------------------------------------------------------------
say "Verify"
zpool status -x | grep -q "all pools are healthy" && ok "both pools healthy" || bad "check zpool status"
exportfs -v >/dev/null 2>&1 && ok "exports served" || bad "exportfs failed"
N=$(crontab -l 2>/dev/null | grep -c '^[0-9*]')
E=$(grep -c '^[0-9*]' "$REPO/etc/crontab")
[ "$N" -ge "$E" ] && ok "cron jobs: $N (repo declares $E, plus the redacted Synology line)" \
                  || bad "cron jobs: $N, expected at least $E"
systemctl is-active --quiet nfs-server && ok "nfs-server running" || bad "nfs-server not running"
systemctl is-active --quiet fan-control && ok "fan-control running" || warn "fan-control not running — fans on iDRAC's algorithm"
if [ -f /root/.restic-oracle-password ]; then
  ok "restic password present"
else
  warn "restic password missing — restore /root first (REINSTALL.md §Secrets)"
fi
[ -f /root/.talos-etcd-backup ] && ok "etcd backup credential present" \
  || warn "etcd credential missing — reissue it, REINSTALL.md has the command"

printf '\n'
if [ "$CHECK" = 1 ]; then
  printf 'Check only — nothing was changed.\n'
elif [ "$FAIL" -gt 0 ]; then
  printf '\033[0;31m%d check(s) failed.\033[0m\n' "$FAIL"; exit 1
else
  printf '\033[0;32mHost rebuilt. Remaining manual steps are in REINSTALL.md.\033[0m\n'
fi
