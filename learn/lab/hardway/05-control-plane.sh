#!/usr/bin/env bash
# Module 07, step 05 — kube-apiserver, kube-controller-manager, kube-scheduler
# on every node, plus the VIP in front. Three systemd units per node where
# kubeadm would use three static pods; the flags are the same either way.
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
need kubectl
require_file "$DL/kube-apiserver" "$PKI/apiserver.crt" "$KC/controller-manager.kubeconfig" "$PKI/encryption.key"

ETCD_SERVERS=$(endpoints 2379)
ENC_KEY=$(cat "$PKI/encryption.key")

for n in "${TARGETS[@]}"; do
  ip=${NODE_IP[$n]}
  S=$(stage_dir 05-control-plane "$n")
  P="$S/etc/kubernetes/pki"
  mkdir -p "$S/usr/local/bin" "$P/etcd" "$S/etc/systemd/system" "$S/var/log/kubernetes"

  install -m 755 "$DL/kube-apiserver" "$DL/kube-controller-manager" "$DL/kube-scheduler" "$DL/kubectl" "$S/usr/local/bin/"

  # Certificates: .crt 644, .key 600. ca.key is here because the
  # controller-manager signs CertificateSigningRequests with it.
  for f in ca apiserver apiserver-kubelet-client front-proxy-client; do
    install -m 644 "$PKI/$f.crt" "$P/$f.crt"
    install -m 600 "$PKI/$f.key" "$P/$f.key"
  done
  install -m 644 "$PKI/front-proxy-ca.crt" "$P/front-proxy-ca.crt"
  install -m 600 "$PKI/sa.key" "$P/sa.key"
  install -m 644 "$PKI/sa.pub" "$P/sa.pub"
  install -m 644 "$PKI/etcd/ca.crt" "$P/etcd/ca.crt"
  install -m 644 "$PKI/apiserver-etcd-client.crt" "$P/apiserver-etcd-client.crt"
  install -m 600 "$PKI/apiserver-etcd-client.key" "$P/apiserver-etcd-client.key"

  install -m 600 "$KC/controller-manager.kubeconfig" "$KC/scheduler.kubeconfig" "$KC/admin.kubeconfig" "$S/etc/kubernetes/"

  # Secrets in etcd are base64, i.e. plaintext, unless this file exists.
  # Read one back with etcdctl after this step and see "k8s:enc:secretbox".
  cat >"$S/etc/kubernetes/encryption-config.yaml" <<EOF
apiVersion: apiserver.config.k8s.io/v1
kind: EncryptionConfiguration
resources:
  - resources: ["secrets"]
    providers:
      - secretbox:
          keys:
            - name: key1
              secret: ${ENC_KEY}
      # Still able to read Secrets written before encryption was turned on.
      - identity: {}
EOF
  chmod 600 "$S/etc/kubernetes/encryption-config.yaml"

  # First match wins. Secrets: who touched them, never their content.
  cat >"$S/etc/kubernetes/audit-policy.yaml" <<'EOF'
apiVersion: audit.k8s.io/v1
kind: Policy
omitStages: ["RequestReceived"]
rules:
  - level: None
    nonResourceURLs: ["/healthz*", "/livez*", "/readyz*", "/version", "/metrics", "/openapi*"]
  - level: None
    resources:
      - group: "coordination.k8s.io"
        resources: ["leases"]
      - group: ""
        resources: ["events"]
      - group: "events.k8s.io"
        resources: ["events"]
  - level: Metadata
    resources:
      - group: ""
        resources: ["secrets", "serviceaccounts/token"]
  - level: None
    verbs: ["get", "list", "watch"]
  - level: Request
EOF
  chmod 644 "$S/etc/kubernetes/audit-policy.yaml"

  cat >"$S/etc/systemd/system/kube-apiserver.service" <<EOF
[Unit]
Description=Kubernetes API Server
Documentation=https://kubernetes.io/docs/reference/command-line-tools-reference/kube-apiserver/
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/usr/local/bin/kube-apiserver \\
  --advertise-address=${ip} \\
  --bind-address=0.0.0.0 \\
  --secure-port=${API_PORT} \\
  --allow-privileged=true \\
  --authorization-mode=Node,RBAC \\
  --enable-admission-plugins=NodeRestriction \\
  --client-ca-file=/etc/kubernetes/pki/ca.crt \\
  --tls-cert-file=/etc/kubernetes/pki/apiserver.crt \\
  --tls-private-key-file=/etc/kubernetes/pki/apiserver.key \\
  --etcd-servers=${ETCD_SERVERS} \\
  --etcd-cafile=/etc/kubernetes/pki/etcd/ca.crt \\
  --etcd-certfile=/etc/kubernetes/pki/apiserver-etcd-client.crt \\
  --etcd-keyfile=/etc/kubernetes/pki/apiserver-etcd-client.key \\
  --kubelet-client-certificate=/etc/kubernetes/pki/apiserver-kubelet-client.crt \\
  --kubelet-client-key=/etc/kubernetes/pki/apiserver-kubelet-client.key \\
  --kubelet-certificate-authority=/etc/kubernetes/pki/ca.crt \\
  --kubelet-preferred-address-types=InternalIP,Hostname \\
  --service-cluster-ip-range=${SERVICE_CIDR} \\
  --service-account-issuer=https://kubernetes.default.svc.${CLUSTER_DOMAIN} \\
  --service-account-key-file=/etc/kubernetes/pki/sa.pub \\
  --service-account-signing-key-file=/etc/kubernetes/pki/sa.key \\
  --requestheader-client-ca-file=/etc/kubernetes/pki/front-proxy-ca.crt \\
  --requestheader-allowed-names=front-proxy-client \\
  --requestheader-extra-headers-prefix=X-Remote-Extra- \\
  --requestheader-group-headers=X-Remote-Group \\
  --requestheader-username-headers=X-Remote-User \\
  --proxy-client-cert-file=/etc/kubernetes/pki/front-proxy-client.crt \\
  --proxy-client-key-file=/etc/kubernetes/pki/front-proxy-client.key \\
  --enable-aggregator-routing=true \\
  --encryption-provider-config=/etc/kubernetes/encryption-config.yaml \\
  --audit-policy-file=/etc/kubernetes/audit-policy.yaml \\
  --audit-log-path=/var/log/kubernetes/audit.log \\
  --audit-log-maxage=7 \\
  --audit-log-maxbackup=3 \\
  --audit-log-maxsize=100 \\
  --v=2
Restart=on-failure
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

  cat >"$S/etc/systemd/system/kube-controller-manager.service" <<EOF
[Unit]
Description=Kubernetes Controller Manager
Documentation=https://kubernetes.io/docs/reference/command-line-tools-reference/kube-controller-manager/
After=kube-apiserver.service

[Service]
ExecStart=/usr/local/bin/kube-controller-manager \\
  --kubeconfig=/etc/kubernetes/controller-manager.kubeconfig \\
  --authentication-kubeconfig=/etc/kubernetes/controller-manager.kubeconfig \\
  --authorization-kubeconfig=/etc/kubernetes/controller-manager.kubeconfig \\
  --bind-address=0.0.0.0 \\
  --cluster-name=${CLUSTER_NAME} \\
  --allocate-node-cidrs=true \\
  --cluster-cidr=${POD_CIDR} \\
  --node-cidr-mask-size=24 \\
  --service-cluster-ip-range=${SERVICE_CIDR} \\
  --cluster-signing-cert-file=/etc/kubernetes/pki/ca.crt \\
  --cluster-signing-key-file=/etc/kubernetes/pki/ca.key \\
  --client-ca-file=/etc/kubernetes/pki/ca.crt \\
  --requestheader-client-ca-file=/etc/kubernetes/pki/front-proxy-ca.crt \\
  --root-ca-file=/etc/kubernetes/pki/ca.crt \\
  --service-account-private-key-file=/etc/kubernetes/pki/sa.key \\
  --use-service-account-credentials=true \\
  --leader-elect=true \\
  --controllers=* \\
  --v=2
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

  cat >"$S/etc/systemd/system/kube-scheduler.service" <<EOF
[Unit]
Description=Kubernetes Scheduler
Documentation=https://kubernetes.io/docs/reference/command-line-tools-reference/kube-scheduler/
After=kube-apiserver.service

[Service]
ExecStart=/usr/local/bin/kube-scheduler \\
  --kubeconfig=/etc/kubernetes/scheduler.kubeconfig \\
  --authentication-kubeconfig=/etc/kubernetes/scheduler.kubeconfig \\
  --authorization-kubeconfig=/etc/kubernetes/scheduler.kubeconfig \\
  --bind-address=0.0.0.0 \\
  --leader-elect=true \\
  --v=2
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

  log "$n: push $(du -sh "$S" | cut -f1)"
  push_stage "$S" "$n"
  # restart, not enable --now: on an upgrade the units are unchanged and only
  # the binaries are new, which a running service would never pick up.
  on "$n" 'sudo systemctl daemon-reload && sudo systemctl enable kube-apiserver kube-controller-manager kube-scheduler >/dev/null 2>&1 && sudo systemctl restart kube-apiserver kube-controller-manager kube-scheduler'
done

for n in "${TARGETS[@]}"; do
  wait_for 90 "$n: apiserver /readyz" curl -sfk --max-time 2 "https://${NODE_IP[$n]}:${API_PORT}/readyz"
done

log "VIP"
bash "$(dirname "$0")/keepalived.sh"
wait_for 60 "VIP ${API_VIP} answers" curl -sfk --max-time 2 "https://${API_VIP}:${API_PORT}/readyz"

# The apiserver calls kubelets (logs, exec, port-forward) as the user in its
# kubelet-client certificate. Kubelets ask the apiserver whether that user may
# do it (authorization: Webhook) — and without this binding the answer is no.
# Try `kubectl logs` before applying it once, and read the error.
kubectl apply -f - <<'EOF' >/dev/null
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: kube-apiserver-kubelet-client
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: system:kubelet-api-admin
subjects:
  - apiGroup: rbac.authorization.k8s.io
    kind: User
    name: kube-apiserver-kubelet-client
EOF
ok "RBAC: apiserver → kubelet"

kubectl get --raw='/readyz?verbose' | tail -n 3
kubectl get leases -n kube-system kube-controller-manager kube-scheduler \
  -o custom-columns=LEASE:.metadata.name,HOLDER:.spec.holderIdentity
ok "control plane up. Next: ./06-nodes.sh"
