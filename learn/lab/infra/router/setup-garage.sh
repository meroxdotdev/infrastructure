#!/usr/bin/env bash
# Module 14: a single-node Garage on lab-gw as Longhorn's backup target —
# the lab's version of the Garage on pve-3 (vps/roles/garage_setup). Outside
# the cluster on purpose: a backup that dies with the cluster is not one.
#
#   sudo ./setup-garage.sh
# Prints the S3 key pair Longhorn needs. Re-running is safe.
set -Eeuo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../../env.sh
source "${HERE}/../../env.sh"

[[ $EUID -eq 0 ]] || { echo "run with sudo" >&2; exit 1; }

# renovate: datasource=docker depName=dxflrs/garage
GARAGE_VERSION="v2.1.0"
BUCKET="longhorn"
KEY_NAME="longhorn-key"
CAPACITY="30G"

if [[ ! -x /usr/local/bin/garage ]] || ! /usr/local/bin/garage --version 2>/dev/null | grep -q "${GARAGE_VERSION#v}"; then
  echo "→ garage ${GARAGE_VERSION}"
  curl -fsSL -o /usr/local/bin/garage \
    "https://garagehq.deuxfleurs.fr/_releases/${GARAGE_VERSION}/x86_64-unknown-linux-musl/garage"
  chmod +x /usr/local/bin/garage
fi

id garage >/dev/null 2>&1 || useradd --system --home /var/lib/garage --shell /usr/sbin/nologin garage
install -d -o garage -g garage -m 750 /var/lib/garage /var/lib/garage/meta /var/lib/garage/data

if [[ ! -f /etc/garage.toml ]]; then
  echo "→ /etc/garage.toml"
  cat > /etc/garage.toml <<EOF
# Same shape as vps/roles/garage_setup/templates/garage.toml.j2
metadata_dir = "/var/lib/garage/meta"
data_dir = "/var/lib/garage/data"
db_engine = "lmdb"
replication_factor = 1

rpc_bind_addr = "127.0.0.1:3901"
rpc_public_addr = "127.0.0.1:3901"
rpc_secret = "$(openssl rand -hex 32)"

[s3_api]
s3_region = "garage"
api_bind_addr = "${LAB_GATEWAY}:3900"
root_domain = ".s3.garage"

[admin]
api_bind_addr = "127.0.0.1:3903"
admin_token = "$(openssl rand -base64 32)"
EOF
  chown root:garage /etc/garage.toml
  chmod 640 /etc/garage.toml
fi

cat > /etc/systemd/system/garage.service <<'EOF'
[Unit]
Description=Garage S3 (k8s lab backup target)
After=network-online.target
Wants=network-online.target

[Service]
User=garage
Group=garage
Environment=RUST_LOG=garage=info
ExecStart=/usr/local/bin/garage -c /etc/garage.toml server
Restart=on-failure
NoNewPrivileges=true
ProtectSystem=strict
ReadWritePaths=/var/lib/garage

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now garage >/dev/null
sleep 3

G() { garage -c /etc/garage.toml "$@"; }

if G layout show 2>/dev/null | grep -q "No nodes currently have a role"; then
  echo "→ layout"
  NODE_ID=$(G node id -q 2>/dev/null | cut -d@ -f1)
  G layout assign -z lab -c "$CAPACITY" "$NODE_ID" >/dev/null
  G layout apply --version 1 >/dev/null
fi

G bucket info "$BUCKET" >/dev/null 2>&1 || { echo "→ bucket $BUCKET"; G bucket create "$BUCKET" >/dev/null; }

if ! G key info "$KEY_NAME" >/dev/null 2>&1; then
  echo "→ key $KEY_NAME"
  G key create "$KEY_NAME" >/dev/null
  G bucket allow --read --write --owner "$BUCKET" --key "$KEY_NAME" >/dev/null
fi

echo
echo "✓ Garage S3 on http://${LAB_GATEWAY}:3900, region 'garage', bucket '${BUCKET}'."
echo "  Credentials for Longhorn (module 14, the SealedSecret):"
G key info "$KEY_NAME" --show-secret | grep -Ei 'key id|secret key'
