#!/usr/bin/env bash
# Render talos/clusterconfig/ from talconfig.yaml, talenv.yaml and
# talsecret.sops.yaml with plain talosctl: one machine config per node, plus
# the admin talosconfig.
#
# This replaced talhelper, archived on 2026-08-26 with its last release unable
# to render Talos 1.14 configs. talconfig.yaml kept talhelper's shape so the DR
# tasks that read it did not have to change; only the subset below is
# understood, and anything else in the file is ignored.
set -Eeuo pipefail

TALOS_DIR="$(git rev-parse --show-toplevel)/talos"
OUT="${TALOS_DIR}/clusterconfig"
cd "${TALOS_DIR}"

TALOS_VERSION=$(yq '.talosVersion' talenv.yaml)
KUBERNETES_VERSION=$(yq '.kubernetesVersion' talenv.yaml)
CONTRACT=$(yq '.configContract' talconfig.yaml)
CLUSTER=$(yq '.clusterName' talconfig.yaml)
ENDPOINT=$(yq '.endpoint' talconfig.yaml)

WORK=$(mktemp -d)
trap 'rm -rf "${WORK}"' EXIT
sops --decrypt talsecret.sops.yaml > "${WORK}/secrets.yaml"

yq 'explode(.) | {
  "machine": {"certSANs": .additionalMachineCertSans},
  "cluster": {
    "apiServer": {"certSANs": .additionalApiServerCertSans},
    "network": {"cni": .cniConfig, "podSubnets": .clusterPodNets, "serviceSubnets": .clusterSvcNets}
  }
}' talconfig.yaml > "${WORK}/cluster.yaml"

PATCHES=(--config-patch "@${WORK}/cluster.yaml")
for p in $(yq '.patches[]' talconfig.yaml); do PATCHES+=(--config-patch "${p}"); done
for p in $(yq '.controlPlane.patches[]' talconfig.yaml); do PATCHES+=(--config-patch-control-plane "${p}"); done

gen() {
    talosctl gen config "${CLUSTER}" "${ENDPOINT}" \
        --with-secrets "${WORK}/secrets.yaml" \
        --talos-version "${CONTRACT}" \
        --kubernetes-version "${KUBERNETES_VERSION}" \
        --with-docs=false --with-examples=false \
        --force "$@" >/dev/null
}

for i in $(seq 0 $(($(yq '.nodes | length' talconfig.yaml) - 1))); do
    export N=".nodes[${i}]"
    NODE=$(yq "${N}.hostname" talconfig.yaml)
    [[ $(yq "${N}.controlPlane" talconfig.yaml) == "true" ]] || {
        echo "${NODE}: only control-plane nodes are supported" >&2
        exit 1
    }

    # Per-node patch: install target and labels in v1alpha1, then the network
    # as the multi-document config Talos 1.13+ expects.
    TALOS_VERSION="${TALOS_VERSION}" yq 'eval(strenv(N)) as $n | {"machine": {
        "install": {"disk": $n.installDisk, "image": $n.talosImageURL + ":" + strenv(TALOS_VERSION)},
        "nodeLabels": $n.nodeLabels
    }} | ... comments=""' talconfig.yaml > "${WORK}/node.yaml"
    echo "---" >> "${WORK}/node.yaml"
    yq 'eval(strenv(N)) as $n | {"apiVersion": "v1alpha1", "kind": "HostnameConfig",
        "auto": "off", "hostname": $n.hostname}' talconfig.yaml >> "${WORK}/node.yaml"

    for j in $(seq 0 $(($(yq "${N}.networkInterfaces | length" talconfig.yaml) - 1))); do
        echo "---" >> "${WORK}/node.yaml"
        N="${N}.networkInterfaces[${j}]" LINK="ethSel${j}" yq 'eval(strenv(N)) as $l | [
            {"apiVersion": "v1alpha1", "kind": "LinkAliasConfig", "name": strenv(LINK),
             "selector": {"match": "glob(\"" + $l.deviceSelector.hardwareAddr + "\", mac(link.hardware_addr))"}},
            {"apiVersion": "v1alpha1", "kind": "Layer2VIPConfig", "name": $l.vip.ip, "link": strenv(LINK)},
            {"apiVersion": "v1alpha1", "kind": "LinkConfig", "name": strenv(LINK), "mtu": $l.mtu,
             "addresses": [$l.addresses[] | {"address": .}],
             "routes": [$l.routes[] | {"gateway": .gateway}]}
        ] | .[] | split_doc' talconfig.yaml >> "${WORK}/node.yaml"
    done

    gen "${PATCHES[@]}" --config-patch "@${WORK}/node.yaml" \
        --output-types controlplane --output "${OUT}/${CLUSTER}-${NODE}.yaml"
    talosctl validate --config "${OUT}/${CLUSTER}-${NODE}.yaml" --mode metal >/dev/null
    echo "generated ${OUT}/${CLUSTER}-${NODE}.yaml"
done

NODES=$(yq '[.nodes[].ipAddress] | join(" ")' talconfig.yaml)
gen --output-types talosconfig --output "${OUT}/talosconfig"
# shellcheck disable=SC2086
talosctl --talosconfig "${OUT}/talosconfig" config endpoint ${NODES}
# shellcheck disable=SC2086
talosctl --talosconfig "${OUT}/talosconfig" config node ${NODES}
echo "generated ${OUT}/talosconfig"
