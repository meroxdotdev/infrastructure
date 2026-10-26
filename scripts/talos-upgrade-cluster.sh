#!/usr/bin/env bash
# Bring every node to the versions in talos/talenv.yaml, one node at a time,
# waiting for the cluster to be whole again before touching the next.
# See docs/operations.md, "Upgrading Talos and Kubernetes".
set -Eeuo pipefail

ROOT_DIR="$(git rev-parse --show-toplevel)"
TALOS_DIR="${ROOT_DIR}/talos"
TIMEOUT=${TIMEOUT:-3600}

TALOS_VERSION=$(yq '.talosVersion' "${TALOS_DIR}/talenv.yaml")
KUBERNETES_VERSION=$(yq '.kubernetesVersion' "${TALOS_DIR}/talenv.yaml")
NODES=$(yq '.nodes[].hostname' "${TALOS_DIR}/talconfig.yaml")
ALL_IPS=$(yq '[.nodes[].ipAddress] | join(",")' "${TALOS_DIR}/talconfig.yaml")
COUNT=$(echo "${NODES}" | wc -l | tr -d ' ')

log() { echo "$(date +%H:%M:%S) $*"; }
ip_of() { yq ".nodes[] | select(.hostname == \"$1\") | .ipAddress" "${TALOS_DIR}/talconfig.yaml"; }

# Lines a dry-run apply would change on a node, minus the diff headers.
drift() {
    talosctl --nodes "$(ip_of "$1")" apply-config --dry-run \
        --file "${TALOS_DIR}/clusterconfig/kubernetes-$1.yaml" 2>&1 |
        grep -E '^[-+] ' || true
}

# Whole means: every node Ready, every etcd member answering, and no attached
# Longhorn volume short of a replica. The last one is the one that matters -
# draining the next node while a volume is still rebuilding can take away its
# only healthy replica.
not_whole() {
    kubectl get nodes --no-headers | awk '$2 != "Ready" {print "node " $1 " " $2}'
    local members
    members=$(talosctl --nodes "${ALL_IPS}" etcd status 2>/dev/null | tail -n +2 | wc -l | tr -d ' ')
    [[ ${members} == "${COUNT}" ]] || echo "etcd ${members}/${COUNT} members answering"
    kubectl -n longhorn-system get volumes.longhorn.io --no-headers \
        -o custom-columns=NAME:.metadata.name,STATE:.status.state,ROBUSTNESS:.status.robustness |
        awk '$2 == "attached" && $3 != "healthy" {print "volume " $1 " " $3}'
}

wait_whole() {
    local start=${SECONDS} pending
    while pending=$(not_whole) && [[ -n ${pending} ]]; do
        if ((SECONDS - start > TIMEOUT)); then
            log "✗ cluster still not whole after ${TIMEOUT}s:"
            echo "${pending}"
            exit 1
        fi
        log "  waiting: $(echo "${pending}" | wc -l | tr -d ' ') item(s), e.g. $(echo "${pending}" | head -1)"
        sleep 30
    done
    log "✓ cluster whole"
}

log "→ Target: Talos ${TALOS_VERSION}, Kubernetes ${KUBERNETES_VERSION}"
if ! OUT=$(task talos:generate-config 2>&1); then
    echo "${OUT}"
    exit 1
fi

# Only image lines may differ before an upgrade: the installer, and the
# Kubernetes components when the Kubernetes version moved. Anything else is
# config drift, which belongs in its own reviewed apply-node, not inside an
# upgrade.
for NODE in ${NODES}; do
    if UNEXPECTED=$(drift "${NODE}" | grep -v -E '^[-+]\s+image: ') && [[ -n ${UNEXPECTED} ]]; then
        log "✗ ${NODE}: the generated config differs from the running one beyond image tags:"
        echo "${UNEXPECTED}"
        log "  Review it with: talosctl -n $(ip_of "${NODE}") apply-config --dry-run -f talos/clusterconfig/kubernetes-${NODE}.yaml"
        exit 1
    fi
done
log "✓ no config drift beyond image tags"

wait_whole

for NODE in ${NODES}; do
    RUNNING=$(kubectl get node "${NODE}" -o jsonpath='{.status.nodeInfo.osImage}')
    if [[ ${RUNNING} == *"(${TALOS_VERSION})"* ]]; then
        log "• ${NODE}: already on ${TALOS_VERSION}"
        continue
    fi
    log "→ ${NODE}: ${RUNNING} → ${TALOS_VERSION}"
    task talos:upgrade-node IP="$(ip_of "${NODE}")"
    wait_whole
done

if kubectl get nodes -o jsonpath='{range .items[*]}{.status.nodeInfo.kubeletVersion}{"\n"}{end}' |
    grep -qvx "${KUBERNETES_VERSION}"; then
    log "→ Kubernetes → ${KUBERNETES_VERSION}"
    task talos:upgrade-k8s
    wait_whole
else
    log "• Kubernetes: already on ${KUBERNETES_VERSION}"
fi

# talosctl upgrade takes the installer image as a flag and leaves the one in
# the machine config alone, so the last step brings the configs in line.
for NODE in ${NODES}; do
    if [[ -n $(drift "${NODE}") ]]; then
        task talos:apply-node IP="$(ip_of "${NODE}")" >/dev/null
    fi
    [[ -z $(drift "${NODE}") ]] || {
        log "✗ ${NODE}: config still differs after apply"
        exit 1
    }
done
log "✓ done: every node on Talos ${TALOS_VERSION} / Kubernetes ${KUBERNETES_VERSION}, configs match git"
