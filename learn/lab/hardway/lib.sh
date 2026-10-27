# shellcheck shell=bash
# Helpers for the hard-way steps. Sourced, never run.
#
# The pattern every step follows:
#   1. build $WORKDIR/stage/<step>/<node>/ — a tree that mirrors the node's /
#   2. push it:   tar on the jumpbox | ssh | sudo tar -C / on the node
#   3. start the services, then verify
# So `tree $WORKDIR/stage/05-control-plane/k8s-1` is exactly what step 05
# installs on k8s-1. Nothing is installed any other way.

HW_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../env.sh
source "${HW_DIR}/../env.sh"

PKI="${WORKDIR}/pki"
KC="${WORKDIR}/kubeconfigs"
DL="${WORKDIR}/downloads"

# The nodes a step installs onto. All of them by default; ONLY="k8s-2" (or
# "k8s-2 k8s-3") narrows it, for upgrading one node at a time (module 18).
# NODES itself never changes: cluster-wide values (the etcd member list,
# keepalived peers) are always built from every node.
read -r -a TARGETS <<<"${ONLY:-${NODES[*]}}"
for _t in "${TARGETS[@]}"; do
  [[ -n ${NODE_IP[$_t]:-} ]] || { printf '✗ ONLY: unknown node %s\n' "$_t" >&2; exit 1; }
done
unset _t

SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 -o BatchMode=yes -o LogLevel=ERROR)

log()  { printf '\033[1;34m→\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m✓\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m✗\033[0m %s\n' "$*" >&2; exit 1; }

# on <node> <command...>   — run on a node as the ssh user
on() { local n=$1; shift; ssh "${SSH_OPTS[@]}" "${SSH_USER}@${NODE_IP[$n]}" "$@"; }

# stage_dir <step> <node>  — a fresh, empty staging root
stage_dir() {
  local d="${WORKDIR}/stage/$1/$2"
  rm -rf "$d"
  mkdir -p "$d"
  printf '%s' "$d"
}

# push_stage <dir> <node>  — unpack a staging root onto the node's /
# --no-same-owner: files land owned by root, not by the jumpbox's uid.
# --no-overwrite-dir: never touch the mode of /etc, /usr and friends.
push_stage() {
  local dir=$1 n=$2
  tar -C "$dir" -czf - . | on "$n" sudo tar -C / -xzf - --no-same-owner --no-overwrite-dir
}

need() { for c in "$@"; do command -v "$c" >/dev/null || die "missing '$c' — run 00-jumpbox.sh first"; done; }

require_file() { for f in "$@"; do [[ -f $f ]] || die "missing $f — run the earlier steps first"; done; }

# Comma-separated https://<ip>:<port> for every node
endpoints() { local port=$1 out="" n; for n in "${NODES[@]}"; do out+="${out:+,}https://${NODE_IP[$n]}:${port}"; done; printf '%s' "$out"; }

# wait_for <seconds> <description> <command...>
wait_for() {
  local secs=$1 what=$2; shift 2
  local i
  for ((i = 0; i < secs; i += 3)); do
    if "$@" >/dev/null 2>&1; then ok "$what"; return 0; fi
    sleep 3
  done
  die "timed out after ${secs}s waiting for: $what"
}
