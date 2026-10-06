#!/bin/bash
# Back up every git repository under ~/Projects into Synology Drive as one
# bundle per repository: full history, all branches, and the uncommitted work
# (tracked and untracked, .gitignore respected) as refs/backup/worktree.
# A bundle is rewritten only when its refs change, so the vault and restic
# see new bytes only for repositories that moved. A repository the Mac adds
# nothing to is skipped: the vault mirrors our GitHub repos itself
# (truenas/config/github-repos), and someone else's code is theirs to keep.
#
# Restore:  git clone <name>.bundle <name> && cd <name>
#           git fetch ../<name>.bundle refs/backup/worktree   # uncommitted work, if any
#           git checkout FETCH_HEAD -- .
set -euo pipefail

SRC=${SRC:-$HOME/Projects}
DEST=${DEST:-$HOME/Library/CloudStorage/SynologyDrive-Cloud/Lab/Repos/macbook}
STATE=${STATE:-$HOME/.local/state/repo-bundles}
MIRRORS=$(dirname "$0")/../truenas/config/github-repos
MAX_UNTRACKED_MB=50

log() { echo "$(date '+%F %T') $*"; }

# Commit the working tree to refs/backup/worktree through a throwaway index,
# leaving the real index and HEAD untouched. The ref is dropped when the tree
# is clean, and kept as is when nothing changed since the last run.
snapshot() {
  local repo=$1 idx tree head_tree commit untracked_kb
  untracked_kb=$(git -C "$repo" ls-files --others --exclude-standard -z \
    | (cd "$repo" && xargs -0 du -sk 2>/dev/null) | awk '{s+=$1} END {print s+0}')
  if (( untracked_kb > MAX_UNTRACKED_MB * 1024 )); then
    log "WARN $repo: ${untracked_kb} KB untracked, worktree not snapshotted (gitignore it or commit it)"
    return
  fi
  idx=$(mktemp)
  cp "$(git -C "$repo" rev-parse --absolute-git-dir)/index" "$idx" 2>/dev/null || true
  GIT_INDEX_FILE=$idx git -C "$repo" add -A
  tree=$(GIT_INDEX_FILE=$idx git -C "$repo" write-tree)
  rm -f "$idx"
  head_tree=$(git -C "$repo" rev-parse -q --verify 'HEAD^{tree}' || true)
  if [[ $tree == "$head_tree" ]]; then
    git -C "$repo" update-ref -d refs/backup/worktree 2>/dev/null || true
    return
  fi
  [[ $(git -C "$repo" rev-parse -q --verify 'refs/backup/worktree^{tree}' || true) == "$tree" ]] && return
  if [[ -n $head_tree ]]; then
    commit=$(git -C "$repo" commit-tree "$tree" -p HEAD -m "worktree snapshot")
  else
    commit=$(git -C "$repo" commit-tree "$tree" -m "worktree snapshot")
  fi
  git -C "$repo" update-ref refs/backup/worktree "$commit"
}

# Nothing to add when the Mac holds no commit and no change beyond origin, and
# origin is either mirrored by the vault already or someone else's code.
covered() {
  local repo=$1 origin
  origin=$(git -C "$repo" remote get-url origin 2>/dev/null | sed -E 's#//[^@/]*@#//#; s#\.git$##') || return 1
  [[ -n $origin ]] || return 1
  git -C "$repo" rev-parse -q --verify refs/backup/worktree >/dev/null && return 1
  [[ $(git -C "$repo" rev-list --count --branches --glob=refs/stash --not --remotes) == 0 ]] || return 1
  grep -qxF -e "$origin" -e "$origin.git" "$MIRRORS" && return 0
  [[ $origin != *github.com/meroxdotdev/* && $origin != *github.com/mer0x/* ]]
}

mkdir -p "$DEST" "$STATE"
keep=()
for dir in "$SRC"/*/; do
  repo=${dir%/}
  name=$(basename "$repo")
  if ! git -C "$repo" rev-parse --git-dir >/dev/null 2>&1; then
    log "WARN $name: not a git repository, not backed up"
    continue
  fi
  snapshot "$repo"
  if covered "$repo"; then
    continue
  fi
  refs=$(git -C "$repo" for-each-ref --format='%(objectname) %(refname)')
  if [[ -z $refs ]]; then
    log "WARN $name: no commits yet, not backed up"
    continue
  fi
  keep+=("$name.bundle")
  sum=$(shasum <<<"$refs" | cut -d' ' -f1)
  if [[ -f $DEST/$name.bundle && $(cat "$STATE/$name.refs" 2>/dev/null) == "$sum" ]]; then
    continue
  fi
  # Built outside Drive and moved in whole, so Drive never uploads half a file.
  git -C "$repo" bundle create "$STATE/$name.bundle" --all 2>/dev/null
  git -C "$repo" bundle verify -q "$STATE/$name.bundle" >/dev/null 2>&1
  mv "$STATE/$name.bundle" "$DEST/$name.bundle"
  echo "$sum" >"$STATE/$name.refs"
  log "bundled $name ($(du -h "$DEST/$name.bundle" | cut -f1))"
done

# Drop the bundles of repositories that no longer exist.
for f in "$DEST"/*.bundle; do
  [[ -e $f ]] || continue
  b=$(basename "$f")
  if [[ ! " ${keep[*]} " == *" $b "* ]]; then
    rm -f "$f" "$STATE/${b%.bundle}.refs"
    log "removed $b"
  fi
done

log "done, $(du -sh "$DEST" | cut -f1) in $DEST"
