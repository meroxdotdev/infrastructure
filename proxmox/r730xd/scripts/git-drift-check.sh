#!/bin/bash
# Does what runs on this host still match what is in git?
#
# This repo's README says the host is the running copy and git is the
# reviewable one. That is a drift generator: every change has to be applied
# twice, and nothing notices when it is applied once. On 2026-08-29 a script
# was fixed in git and the host kept running the old one for hours, and the
# weekly Synology push still pointed at a directory that had been deleted.
#
# Prints to stdout and exits non-zero on drift. It does not ping anything —
# nightly-checks.sh runs this alongside the other two host checks and reports
# once, because all three are investigated the same way.
# Fetches a tarball rather than cloning: no git package on the hypervisor.
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
set -uo pipefail

TARBALL="https://github.com/meroxdotdev/infrastructure/archive/refs/heads/main.tar.gz"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

if ! curl -fsSL --max-time 60 "$TARBALL" | tar xz -C "$TMP" --strip-components=1 2>/dev/null; then
  echo "$(date '+%F %T') FETCH-FAILED: could not download the repo"
  exit 1
fi
G="$TMP/proxmox/r730xd"
DRIFT=""

# Healthcheck URLs are redacted in git (public repo), so blank them on both
# sides before comparing — a differing URL is expected, not drift.
norm() { sed 's|https://hc-ping\.com/[A-Za-z0-9_-]*|HCURL|g' "$1"; }

# --- scripts ---------------------------------------------------------------
for f in "$G"/scripts/*.sh; do
  n=$(basename "$f")
  # Most live in /root/scripts, but pfsense-backup-receive.sh is pinned as a
  # forced command at /root/ — check both rather than special-casing names.
  h=""
  for c in "/root/scripts/$n" "/root/$n"; do
    [ -f "$c" ] && { h="$c"; break; }
  done
  if [ -z "$h" ]; then
    DRIFT="$DRIFT\n  missing on host: scripts/$n"
  elif ! diff -q <(norm "$f") <(norm "$h") >/dev/null 2>&1; then
    DRIFT="$DRIFT\n  differs: $h"
  fi
done

# --- crontab ---------------------------------------------------------------
# The Synology line is redacted in git: its schedule reveals the NAS wake
# window. Compare everything else.
# Compare on meaning, not spacing: install-spindown.sh writes its lines with
# single spaces while etc/crontab uses two, which is not drift.
squeeze() { tr -s ' ' | sort; }
if ! diff -q \
  <(grep '^[0-9*]' "$G/etc/crontab" | squeeze) \
  <(crontab -l 2>/dev/null | grep '^[0-9*]' | grep -v weekly-push-to-synology | squeeze) \
  >/dev/null 2>&1; then
  DRIFT="$DRIFT\n  differs: crontab"
fi

# --- plain /etc files ------------------------------------------------------
# Skipped deliberately: authorized_keys, nut/upsmon.conf and nut/upsd.users
# carry redacted secrets in git, so they can never match.
check() {
  [ -f "$1" ] && [ -f "$2" ] || return 0
  diff -q "$1" "$2" >/dev/null 2>&1 || DRIFT="$DRIFT\n  differs: $3"
}
check "$G/etc/exports"            /etc/exports            "/etc/exports"
check "$G/etc/storage.cfg"        /etc/pve/storage.cfg    "/etc/pve/storage.cfg"
check "$G/etc/network-interfaces" /etc/network/interfaces "/etc/network/interfaces"
check "$G/etc/nut/ups.conf"       /etc/nut/ups.conf       "/etc/nut/ups.conf"
check "$G/etc/nut/nut.conf"       /etc/nut/nut.conf       "/etc/nut/nut.conf"
check "$G/etc/nut/upsd.conf"      /etc/nut/upsd.conf      "/etc/nut/upsd.conf"
check "$G/etc/fan-control.service" /etc/systemd/system/fan-control.service "fan-control.service"

# --- report ----------------------------------------------------------------
if [ -n "$DRIFT" ]; then
  printf '%s DRIFT:%b\n' "$(date '+%F %T')" "$DRIFT"
  exit 1
else
  echo "$(date '+%F %T') ok (host matches git)"
fi
