#!/usr/bin/env bash
# Patch talos/talconfig.yaml with DR node IPs + MACs from Terraform outputs
# Run from repo root after: cd talos/terraform && terraform apply
#
# Creates a backup at talos/talconfig.yaml.prod-backup
# Restore prod config with: cp talos/talconfig.yaml.prod-backup talos/talconfig.yaml
set -euo pipefail

RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'; NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TF_DIR="$REPO_ROOT/talos/terraform"
TALCONFIG="$REPO_ROOT/talos/talconfig.yaml"
BACKUP="$REPO_ROOT/talos/talconfig.yaml.prod-backup"

echo ""
echo "DR talconfig patch"
echo "=================="
echo ""

if [ ! -d "$TF_DIR/.terraform" ]; then
    echo -e "${RED}Terraform not initialized. Run first:${NC}"
    echo "  cd talos/terraform && terraform init && terraform apply"
    exit 1
fi

if [ ! -f "$TALCONFIG" ]; then
    echo -e "${RED}talos/talconfig.yaml not found${NC}"
    exit 1
fi

echo "Reading Terraform outputs..."
TF_OUTPUT=$(cd "$TF_DIR" && terraform output -json 2>/dev/null)

NODE_IPS=$(echo "$TF_OUTPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print('\n'.join(d['node_ips']['value']))")
NODE_MACS=$(echo "$TF_OUTPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print('\n'.join(d['node_macs']['value']))")
NODE_VIP=$(echo "$TF_OUTPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['node_vip']['value'])")
NODE_GW=$(echo "$TF_OUTPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['node_gateway']['value'])")

mapfile -t IP_ARR <<< "$NODE_IPS"
mapfile -t MAC_ARR <<< "$NODE_MACS"

echo "  Node 1: IP=${IP_ARR[0]}  MAC=${MAC_ARR[0]}"
echo "  Node 2: IP=${IP_ARR[1]}  MAC=${MAC_ARR[1]}"
echo "  Node 3: IP=${IP_ARR[2]}  MAC=${MAC_ARR[2]}"
echo "  VIP:    $NODE_VIP"
echo ""

# Check backup already exists (prod config)
if [ -f "$BACKUP" ]; then
    echo -e "${YELLOW}Backup already exists at talos/talconfig.yaml.prod-backup${NC}"
    echo -n "Overwrite (re-patch from backup)? [y/N] "
    read -r CONFIRM
    if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
        cp "$BACKUP" "$TALCONFIG"
        echo "  Restored from backup, patching fresh."
    else
        echo "  Patching current talconfig.yaml."
    fi
else
    cp "$TALCONFIG" "$BACKUP"
    echo -e "${GREEN}Backed up prod config → talos/talconfig.yaml.prod-backup${NC}"
fi

echo ""
echo "Patching talconfig.yaml..."

python3 -c "import yaml" 2>/dev/null || python3 -m pip install pyyaml --break-system-packages -q

python3 - "$TALCONFIG" "${IP_ARR[0]}" "${IP_ARR[1]}" "${IP_ARR[2]}" \
                        "${MAC_ARR[0]}" "${MAC_ARR[1]}" "${MAC_ARR[2]}" \
                        "$NODE_VIP" "$NODE_GW" <<'PYEOF'
import sys, re

path = sys.argv[1]
ips  = [sys.argv[2], sys.argv[3], sys.argv[4]]
macs = [sys.argv[5], sys.argv[6], sys.argv[7]]
vip  = sys.argv[8]
gw   = sys.argv[9]

with open(path) as f:
    content = f.read()

# Prod IPs and MACs found in talconfig (extract to patch)
import yaml
data = yaml.safe_load(content)

prod_ips  = [n['ipAddress'] for n in data['nodes']]
prod_macs = [n['networkInterfaces'][0]['deviceSelector']['hardwareAddr'] for n in data['nodes']]
prod_vip  = data['nodes'][0]['networkInterfaces'][0]['vip']['ip']
prod_ep   = data['endpoint']  # https://10.x.x.88:6443

# Replace in raw YAML (preserves formatting and comments)
for i in range(3):
    content = content.replace(prod_ips[i], ips[i])
    content = content.replace(prod_macs[i], macs[i].lower())

content = content.replace(prod_vip, vip)
# Replace endpoint VIP (https://old_vip:6443)
content = re.sub(r'(endpoint:\s*https://)[\d.]+(:6443)', rf'\g<1>{vip}\2', content)
# Replace additionalApiServerCertSans VIP
content = content.replace(f'- "{prod_vip}"', f'- "{vip}"')

with open(path, 'w') as f:
    f.write(content)
PYEOF

echo -e "${GREEN}talconfig.yaml patched for DR cluster.${NC}"
echo ""
echo "Verify the changes:"
echo "  diff talos/talconfig.yaml.prod-backup talos/talconfig.yaml"
echo ""
echo "Bootstrap the DR cluster:"
echo "  cd $REPO_ROOT && task bootstrap:talos"
echo ""
echo "  NOTE: 'task bootstrap:talos' sends apply-config to the IPs in talconfig"
echo "  (${IP_ARR[0]}, ${IP_ARR[1]}, ${IP_ARR[2]})."
echo "  If nodes booted via DHCP and have different IPs, apply config manually:"
echo ""
echo "  # First generate configs:"
echo "  cd $REPO_ROOT/talos && talhelper genconfig"
echo ""
echo "  # Then apply to each node's DHCP IP:"
echo "  talosctl apply-config -n <dhcp_ip_1> --insecure -f talos/clusterconfig/<node1>.yaml"
echo "  talosctl apply-config -n <dhcp_ip_2> --insecure -f talos/clusterconfig/<node2>.yaml"
echo "  talosctl apply-config -n <dhcp_ip_3> --insecure -f talos/clusterconfig/<node3>.yaml"
echo ""
echo "  # Nodes will reboot with static IPs, then bootstrap:"
echo "  talosctl bootstrap -n ${IP_ARR[0]}"
echo "  talosctl kubeconfig -n ${IP_ARR[0]} $REPO_ROOT --force"
echo ""
echo "After testing — restore prod config:"
echo "  cp talos/talconfig.yaml.prod-backup talos/talconfig.yaml"
