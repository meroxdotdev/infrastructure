#!/usr/bin/env bash
# Module 06, step 04 — etcd, three members, one per node. The only component
# of the control plane with state: everything `kubectl get` shows lives here.
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
need etcdctl
require_file "$DL/etcd" "$PKI/etcd/ca.crt"

INITIAL_CLUSTER=""
for n in "${NODES[@]}"; do INITIAL_CLUSTER+="${INITIAL_CLUSTER:+,}${n}=https://${NODE_IP[$n]}:2380"; done

for n in "${TARGETS[@]}"; do
  ip=${NODE_IP[$n]}
  S=$(stage_dir 04-etcd "$n")
  mkdir -p "$S/usr/local/bin" "$S/etc/etcd/pki" "$S/etc/systemd/system"

  install -m 755 "$DL/etcd" "$DL/etcdctl" "$DL/etcdutl" "$S/usr/local/bin/"
  install -m 644 "$PKI/etcd/ca.crt" "$S/etc/etcd/pki/ca.crt"
  install -m 644 "$PKI/etcd/${n}-server.crt" "$S/etc/etcd/pki/server.crt"
  install -m 600 "$PKI/etcd/${n}-server.key" "$S/etc/etcd/pki/server.key"
  install -m 644 "$PKI/etcd/${n}-peer.crt" "$S/etc/etcd/pki/peer.crt"
  install -m 600 "$PKI/etcd/${n}-peer.key" "$S/etc/etcd/pki/peer.key"
  install -m 644 "$PKI/etcd/etcdctl.crt" "$S/etc/etcd/pki/etcdctl.crt"
  install -m 600 "$PKI/etcd/etcdctl.key" "$S/etc/etcd/pki/etcdctl.key"

  # --initial-* only matter the first time, while the data dir is empty.
  # After that the membership lives in the data dir and these are ignored.
  cat >"$S/etc/systemd/system/etcd.service" <<EOF
[Unit]
Description=etcd — the cluster's only stateful component
Documentation=https://etcd.io/docs/
After=network-online.target
Wants=network-online.target

[Service]
# notify: systemd waits for etcd to say "ready", which needs a quorum.
Type=notify
ExecStart=/usr/local/bin/etcd \\
  --name=${n} \\
  --data-dir=/var/lib/etcd \\
  --listen-peer-urls=https://${ip}:2380 \\
  --initial-advertise-peer-urls=https://${ip}:2380 \\
  --listen-client-urls=https://${ip}:2379,https://127.0.0.1:2379 \\
  --advertise-client-urls=https://${ip}:2379 \\
  --listen-metrics-urls=http://0.0.0.0:2381 \\
  --initial-cluster=${INITIAL_CLUSTER} \\
  --initial-cluster-token=${CLUSTER_NAME}-etcd \\
  --initial-cluster-state=new \\
  --client-cert-auth=true \\
  --trusted-ca-file=/etc/etcd/pki/ca.crt \\
  --cert-file=/etc/etcd/pki/server.crt \\
  --key-file=/etc/etcd/pki/server.key \\
  --peer-client-cert-auth=true \\
  --peer-trusted-ca-file=/etc/etcd/pki/ca.crt \\
  --peer-cert-file=/etc/etcd/pki/peer.crt \\
  --peer-key-file=/etc/etcd/pki/peer.key \\
  --heartbeat-interval=100 \\
  --election-timeout=1000
Restart=on-failure
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

  log "$n: push $(du -sh "$S" | cut -f1)"
  push_stage "$S" "$n"
  on "$n" sudo systemctl daemon-reload
done

# All at once, and --no-block: a lone member cannot become ready (no quorum),
# so starting them one by one would hang on the first forever. restart, not
# start: on an upgrade (ONLY=…) the new binary must actually be loaded.
log "starting etcd on ${TARGETS[*]}"
for n in "${TARGETS[@]}"; do on "$n" 'sudo systemctl enable etcd >/dev/null 2>&1 && sudo systemctl restart --no-block etcd' </dev/null & done
wait

# shellcheck disable=SC1091
source "$WORKDIR/etcdctl.env"
wait_for 90 "etcd: all members healthy" etcdctl endpoint health --cluster
etcdctl member list -w table
etcdctl endpoint status --cluster -w table
ok "Next: ./05-control-plane.sh"
