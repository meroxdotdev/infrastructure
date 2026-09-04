#!/bin/bash
# Explicit PATH: user crontabs get only /usr/bin:/bin, and talosctl lives in
# /usr/local/bin. Without this the job silently does nothing.
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
#
# Nightly etcd snapshot. Only matters because the cluster is a single node
# (talos/SINGLE-NODE.md): with three members a lost etcd rebuilt from its peers,
# with one there is no peer. Everything else is recoverable without this - Flux
# rebuilds the workloads from git and Longhorn holds the volume data - so the
# floor is a ~35 min DR.md rebuild. This turns that into a ~5 min restore.
#
# Restore:  talosctl bootstrap --recover-from=<snapshot>
#
# MUST run inside the nightly backup window (03:03), never at an arbitrary hour.
# The snapshot is ~186 MB and lands on `media`, so writing it wakes all twelve
# SAS disks - and a wake means a blocking AEN poll on the H730P that stalls
# etcd's own fsyncs on the SSDs behind it. Scheduled at 23:45 on 2026-08-17 it
# produced 53 slow fsyncs and an `etcdserver timeout` that failed a Flux
# Kustomization, i.e. this job caused exactly the outage it exists to recover
# from. Inside the window the disks are already spinning for the other jobs and
# it costs nothing extra. See proxmox/pve-2/spindown-setup.md.
#
# The credential is deliberately NOT the admin talosconfig. It carries the
# os:etcd:backup role only, so a compromise of this host cannot reboot or reset
# the node - verified: `talosctl reboot` with it returns PermissionDenied.
# Regenerate before the cert expires (1 year from 2026-08-17):
#   talosctl -n <node> config new --roles os:etcd:backup --crt-ttl 8760h <file>
set -euo pipefail

NODE="${ETCD_NODE:-10.57.57.80}"
DEST="${ETCD_SNAP_DIR:-/media/backups/etcd}"
KEEP_DAYS="${ETCD_SNAP_KEEP:-14}"
export TALOSCONFIG=/root/.talos-etcd-backup

mkdir -p "$DEST"
stamp=$(date +%F)
out="$DEST/etcd-${stamp}.db"

# Write to a temp name first: a half-written snapshot that keeps the final
# filename would look like a good backup to everything downstream.
if ! talosctl -n "$NODE" etcd snapshot "${out}.part" >/dev/null 2>&1; then
  echo "$(date '+%F %T') FAILED: snapshot did not complete" >&2
  rm -f "${out}.part"
  exit 1
fi
mv "${out}.part" "$out"

# Prune by the date ENCODED IN THE FILENAME, never `find -mtime`. rsync
# preserves source mtimes elsewhere in this tree and that has already wiped a
# same-day snapshot once (see weekly-push-to-synology.sh).
cutoff=$(date -d "-${KEEP_DAYS} days" +%F)
for f in "$DEST"/etcd-????-??-??.db; do
  [ -e "$f" ] || continue
  d=$(basename "$f" .db); d=${d#etcd-}
  [[ "$d" < "$cutoff" ]] && rm -f "$f"
done

echo "$(date '+%F %T') ok ($(du -h "$out" | cut -f1), $(ls -1 "$DEST"/etcd-*.db 2>/dev/null | wc -l) kept)"
