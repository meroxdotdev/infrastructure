#!/usr/bin/env bash
# Extract Garage S3 longhorn-key credentials and update vault
# Run AFTER Phase 1 is complete, BEFORE Phase 2 (Longhorn restore needs these)
# Usage: bash scripts/garage-extract-creds.sh  (from repo root or vps/)
set -euo pipefail

RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'; NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VPS_DIR="$SCRIPT_DIR/../vps"
VAULT_FILE="$VPS_DIR/inventories/production/group_vars/all/vault.yml"
VAULT_PASS="$VPS_DIR/.vault_pass"

echo ""
echo "Garage S3 Credential Extractor"
echo "==============================="
echo ""

# Verify container is running
if ! docker ps --filter "name=^garage$" --filter "status=running" --format "{{.Names}}" 2>/dev/null | grep -q "^garage$"; then
    echo -e "${RED}✗ Container 'garage' not running. Is Phase 1 complete?${NC}"
    exit 1
fi

echo "Extracting longhorn-key credentials from Garage..."
RAW=$(docker exec garage /garage key info longhorn-key --show-secret 2>/dev/null)

if [ -z "$RAW" ]; then
    echo -e "${RED}✗ No output from garage. Verify with: docker exec garage /garage key list${NC}"
    exit 1
fi

ACCESS_KEY=$(echo "$RAW" | grep "Key ID:" | awk '{print $NF}')
SECRET_KEY=$(echo "$RAW" | grep "Secret key:" | awk '{print $NF}')

if [ -z "$ACCESS_KEY" ] || [ -z "$SECRET_KEY" ]; then
    echo -e "${RED}✗ Could not parse credentials. Raw output:${NC}"
    echo "$RAW"
    exit 1
fi

echo ""
echo -e "${GREEN}✓ Credentials extracted:${NC}"
echo "  garage_access_key_id:     $ACCESS_KEY"
echo "  garage_secret_access_key: $SECRET_KEY"
echo ""

# Try automatic vault update if prerequisites are available
if [ ! -f "$VAULT_PASS" ]; then
    echo -e "${YELLOW}No .vault_pass found — manual vault update required:${NC}"
    echo ""
    echo "  Run: cd vps && make vault-edit"
    echo "  Add or update these two lines:"
    echo "    garage_access_key_id: $ACCESS_KEY"
    echo "    garage_secret_access_key: $SECRET_KEY"
    exit 0
fi

if ! command -v python3 &>/dev/null; then
    echo -e "${YELLOW}python3 not found — manual vault update required:${NC}"
    echo "  cd vps && make vault-edit"
    echo "  Add: garage_access_key_id: $ACCESS_KEY"
    echo "  Add: garage_secret_access_key: $SECRET_KEY"
    exit 0
fi

echo -n "Update vault automatically? [y/N] "
read -r CONFIRM
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo "Skipping. Run: cd vps && make vault-edit"
    exit 0
fi

TMPFILE=$(mktemp)
trap 'rm -f "$TMPFILE"' EXIT

echo "Decrypting vault..."
ansible-vault decrypt "$VAULT_FILE" --vault-password-file "$VAULT_PASS" --output "$TMPFILE"

# Update or insert the two keys using Python (no yq dependency)
python3 - "$TMPFILE" "$ACCESS_KEY" "$SECRET_KEY" <<'PYEOF'
import sys, re

path, access_key, secret_key = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path) as f:
    content = f.read()

def upsert(text, key, value):
    pattern = rf'^({key}:\s*)(.*)$'
    replacement = f'{key}: {value}'
    new, n = re.subn(pattern, replacement, text, flags=re.MULTILINE)
    if n == 0:
        new = text.rstrip('\n') + f'\n{key}: {value}\n'
    return new

content = upsert(content, 'garage_access_key_id', access_key)
content = upsert(content, 'garage_secret_access_key', secret_key)

with open(path, 'w') as f:
    f.write(content)

print("  Vault file updated.")
PYEOF

echo "Re-encrypting vault..."
ansible-vault encrypt "$TMPFILE" --vault-password-file "$VAULT_PASS" --output "$VAULT_FILE"

echo ""
echo -e "${GREEN}✓ Vault updated with Garage S3 credentials.${NC}"
echo ""
echo "Verify with: cd vps && make view-vault | grep garage"
echo ""
echo "Next: proceed to Phase 2 (K8s bootstrap + Longhorn restore)"
