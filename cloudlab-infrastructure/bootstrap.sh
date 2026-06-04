#!/bin/bash
set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}╔════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║  CloudLab Merox - Ansible Bootstrap   ║${NC}"
echo -e "${GREEN}╚════════════════════════════════════════╝${NC}"
echo ""

# Check if running as root
if [ "$EUID" -eq 0 ]; then 
   echo -e "${RED}✗ Don't run as root. Run as normal user with sudo access.${NC}"
   exit 1
fi

# Check OS
if ! grep -q "Ubuntu" /etc/os-release; then
    echo -e "${YELLOW}⚠ Warning: This script is tested on Ubuntu 24.04 LTS${NC}"
    read -p "Continue anyway? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi

echo -e "${GREEN}[1/6]${NC} Installing prerequisites..."
sudo apt update -qq
sudo apt install -y python3-pip git sshpass > /dev/null 2>&1

echo -e "${GREEN}[2/6]${NC} Installing Ansible..."
pip3 install --user ansible > /dev/null 2>&1
export PATH="$HOME/.local/bin:$PATH"

# Check if repo already cloned
if [ -d "cloudlab-merox" ]; then
    echo -e "${YELLOW}⚠ cloudlab-merox directory exists. Using existing clone.${NC}"
    cd cloudlab-merox
    git pull origin main > /dev/null 2>&1 || true
else
    echo -e "${GREEN}[3/6]${NC} Cloning repository..."
    git clone https://github.com/meroxdotdev/cloudlab-merox.git
    cd cloudlab-merox
fi

echo -e "${GREEN}[4/6]${NC} Installing Ansible collections..."
~/.local/bin/ansible-galaxy collection install -r requirements.yml > /dev/null 2>&1

echo -e "${GREEN}[5/6]${NC} Configuration check..."
if [ ! -f "inventories/production/hosts" ]; then
    echo -e "${RED}✗ Inventory file not found!${NC}"
    exit 1
fi

if [ ! -f "inventories/production/group_vars/all/vault.yml" ]; then
    echo -e "${RED}✗ Vault file not found!${NC}"
    echo -e "${YELLOW}Please create vault.yml with required secrets.${NC}"
    exit 1
fi

echo -e "${GREEN}[6/6]${NC} Testing connectivity..."
if ~/.local/bin/ansible vps_servers -m ping --ask-vault-pass; then
    echo ""
    echo -e "${GREEN}✓ Bootstrap complete!${NC}"
    echo ""
    echo "Available commands:"
    echo "  make setup         - Full deployment (~6 min)"
    echo "  make ping          - Test connectivity"
    echo "  make help          - Show all commands"
    echo ""
    echo -e "${GREEN}Ready to deploy!${NC} Run: ${YELLOW}make setup${NC}"
else
    echo -e "${RED}✗ Connectivity test failed${NC}"
    echo "Check your inventory and vault password"
    exit 1
fi
