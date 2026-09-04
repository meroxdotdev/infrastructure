#!/bin/bash
# Monthly restore drill for the restic-push-oracle.sh leg: proves data can
# actually be pulled back out of the Oracle repository and matches what's
# live on this host - not just that `restic check` says the repo is
# internally consistent. Restores two representative paths (small config +
# a real backup category) to a throwaway dir, compares against the live
# source with sha256sum, cleans up. Never touches the live data.
set -uo pipefail
export RESTIC_REPOSITORY="sftp:oracle-vps-restic:/data"
export RESTIC_PASSWORD_FILE="/root/.restic-oracle-password"

HC_URL="https://hc-ping.com/REPLACE-ME-SEE-PRIVATE-NOTES"
FAIL=0
DRILL_DIR="/tmp/restic-restore-drill-$$"

ping_hc() {
  [ -n "$HC_URL" ] || return 0
  curl -fsS -m 10 --retry 3 -o /dev/null "$HC_URL$1" || true
}

cleanup() {
  rm -rf "$DRILL_DIR"
}
trap cleanup EXIT

mkdir -p "$DRILL_DIR"

check_path() {
  local path="$1"
  local restored="$DRILL_DIR$path"

  if ! restic restore latest --include "$path" --target "$DRILL_DIR" >/dev/null 2>&1; then
    echo "✗ $path: restic restore failed"
    FAIL=1
    return
  fi

  if [ ! -e "$restored" ]; then
    echo "✗ $path: restored but not found at $restored"
    FAIL=1
    return
  fi

  # Hash content only (awk '{print $1}') - the full sha256sum line includes
  # the filename, and the restored copy's path always differs from the live
  # one (different parent dir), which would make this comparison fail even
  # when the actual file content is byte-identical.
  local live_sum restored_sum
  live_sum=$(find "$path" -type f -exec sha256sum {} \; | awk '{print $1}' | sort | sha256sum)
  restored_sum=$(find "$restored" -type f -exec sha256sum {} \; | awk '{print $1}' | sort | sha256sum)

  if [ "$live_sum" = "$restored_sum" ]; then
    echo "✓ $path: restore drill OK (checksums match)"
  else
    echo "✗ $path: restored content does not match live source"
    FAIL=1
  fi
}

check_path /media/backups/pfsense
check_path /media/backups/immich-postgres

if [ "$FAIL" -eq 0 ]; then
  ping_hc ""
  echo "$(date -Is) restic restore drill: all OK"
  exit 0
else
  ping_hc "/fail"
  echo "$(date -Is) restic restore drill: FAILURES detected"
  exit 1
fi
