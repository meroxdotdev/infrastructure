#!/bin/bash
set -euo pipefail

# Retention for the off-site restic repository, and the reason it runs here
# instead of on pve-2.
#
# pve-2 reaches this repository through rest-server in --append-only mode: it can
# add snapshots and can never remove one. That is the entire point, because root
# on pve-2 could previously delete the off-site copy with a single forget --prune.
# Something still has to expire old snapshots, and that something must hold
# rights pve-2 does not have. So it runs here, against the filesystem, bypassing
# the append-only port completely.
#
# Time-based retention, never counted retention. --keep-last and --keep-daily N
# count snapshots, so a compromised client that inserts a batch of cheap empty
# snapshots pushes the real ones out of the window and makes THIS job delete
# them - the client never deletes anything itself. Append-only stops deletion,
# not insertion. Expressed as durations, inserted snapshots cost disk and nothing
# else.
#
# The guard below closes the other half of that hole. Every --keep-within window
# is measured relative to the NEWEST snapshot in the repository, not to the
# current time, so a single snapshot dated in the future drags the whole window
# forward and every real snapshot falls outside it. If anything is dated ahead of
# now, this job refuses to prune and reports it rather than acting on it.

REPO=/srv/restic-repo/data
PWFILE=/etc/restic/repo-password
IMAGE=restic/restic:0.18.0
OWNER=999:987          # restic-backup, which owns the repository

# Create a check at healthchecks.io and paste its URL here. Without it a failure
# of this job is silent, and a retention job that silently stops is a repository
# that silently fills the disk.
HC_URL=""

fail() {
  echo "restic-retention: $*" >&2
  [ -n "$HC_URL" ] && curl -fsS -m 10 --retry 3 -o /dev/null --data-raw "$*" "$HC_URL/fail" || true
  exit 1
}
trap 'fail "aborted unexpectedly"' ERR

r() {
  docker run --rm -u "$OWNER" \
    -v "$REPO":/repo -v "$PWFILE":/pw:ro \
    -e RESTIC_REPOSITORY=/repo -e RESTIC_PASSWORD_FILE=/pw \
    "$IMAGE" "$@"
}

# Refuse to touch anything while a snapshot claims to be from the future.
newest=$(r snapshots --json | jq -r '[.[].time] | max')
newest_epoch=$(date -d "$newest" +%s)
now_epoch=$(date +%s)
skew=$(( newest_epoch - now_epoch ))
if [ "$skew" -gt 3600 ]; then
  fail "newest snapshot is dated ${skew}s in the future ($newest) - refusing to prune, investigate pve-2 before clearing this"
fi

# No grouping, deliberately. Retention is applied per group, so any group that
# stops receiving new snapshots freezes with its contents pinned forever. The
# nightly script picked --group-by host to survive a change to the backup path
# set, and then the host was renamed from `pve` to `pve-2` on 2026-09-04, which
# created exactly the stranded group it was avoiding: ten snapshots under `pve`
# that no policy will ever expire, because nothing new will ever join them.
# Grouping by path has the same failure on a path change. This repository only
# ever receives backups from one machine, so there is nothing for grouping to
# separate - one policy across every snapshot is both simpler and immune to
# both renames and path changes.
r forget --group-by '' \
  --keep-within 3d \
  --keep-within-daily 7d \
  --keep-within-weekly 30d \
  --keep-within-monthly 90d \
  --prune

trap - ERR
[ -n "$HC_URL" ] && curl -fsS -m 10 --retry 3 -o /dev/null "$HC_URL" || true
echo "restic-retention: done"
