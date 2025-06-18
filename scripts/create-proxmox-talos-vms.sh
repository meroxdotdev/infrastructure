#!/bin/bash

# Proxmox Kubernetes VM Deployment Script
# Deploys 6 VMs across 3 Proxmox nodes for Kubernetes cluster

# Color codes for output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration
ISO_STORAGE="local-data"
ISO_NAME="metal-amd64.iso"
DISK_STORAGE="cluster-storage"
TAG="k8s"

# VM configurations
declare -A VMS=(
    ["px-0,kubernetes-controlplane-1"]=800
    ["px-0,kubernetes-worker-1"]=801
    ["px-1,kubernetes-controlplane-2"]=802
    ["px-1,kubernetes-worker-2"]=803
    ["px-2,kubernetes-controlplane-3"]=804
    ["px-2,kubernetes-worker-3"]=805
)

# Function to create a VM
create_vm() {
    local node=$1
    local vmname=$2
    local vmid=$3
    local is_controlplane=false

    # Check if it's a control plane node
    if [[ $vmname == *"controlplane"* ]]; then
        is_controlplane=true
    fi

    # Set resources based on VM type
    if [ "$is_controlplane" = true ]; then
        local cores=4
        local memory=6144
        local disk_size="32"
    else
        local cores=4
        local memory=12288
        local disk_size="128"
    fi

    echo -e "${YELLOW}Creating VM: $vmname (ID: $vmid) on node: $node${NC}"

    # Create the VM using pvesh (which works through the cluster)
    pvesh create /nodes/$node/qemu \
        --vmid $vmid \
        --name $vmname \
        --tags $TAG \
        --sockets 1 \
        --cores $cores \
        --cpu host \
        --memory $memory \
        --net0 virtio,bridge=vmbr0 \
        --scsihw virtio-scsi-pci \
        --ide2 $ISO_STORAGE:iso/$ISO_NAME,media=cdrom

    if [ $? -eq 0 ]; then
        echo -e "${GREEN}VM $vmname created successfully${NC}"
    else
        echo -e "${RED}Failed to create VM $vmname${NC}"
        return 1
    fi

    # Add SCSI disk using pvesh set command
    echo -e "${YELLOW}Adding disk to VM $vmname${NC}"

    # Use pvesh to set the disk
    pvesh set /nodes/$node/qemu/$vmid/config \
        --scsi0 $DISK_STORAGE:$disk_size

    if [ $? -eq 0 ]; then
        echo -e "${GREEN}Disk added successfully to VM $vmname${NC}"
    else
        echo -e "${RED}Failed to add disk to VM $vmname${NC}"
        # If disk creation fails, let's try an alternative method
        echo -e "${YELLOW}Trying alternative method to add disk...${NC}"

        # Create a disk image manually and attach it
        pvesh create /nodes/$node/storage/$DISK_STORAGE/content \
            --vmid $vmid \
            --filename vm-$vmid-disk-0.raw \
            --size ${disk_size}G \
            --format raw

        if [ $? -eq 0 ]; then
            # Now attach the created disk
            pvesh set /nodes/$node/qemu/$vmid/config \
                --scsi0 $DISK_STORAGE:$vmid/vm-$vmid-disk-0.raw

            if [ $? -eq 0 ]; then
                echo -e "${GREEN}Disk added successfully using alternative method${NC}"
            else
                echo -e "${RED}Alternative disk creation also failed${NC}"
            fi
        fi
    fi

    echo -e "${GREEN}VM $vmname (ID: $vmid) deployment completed on node $node${NC}"

    # Set boot order to boot from CD-ROM first, then disk
    echo -e "${YELLOW}Setting boot order for VM $vmname...${NC}"
    pvesh set /nodes/$node/qemu/$vmid/config --boot c --bootdisk ide2

    # Start the VM
    echo -e "${YELLOW}Starting VM $vmname...${NC}"
    pvesh create /nodes/$node/qemu/$vmid/status/start

    if [ $? -eq 0 ]; then
        echo -e "${GREEN}VM $vmname started successfully${NC}"
    else
        echo -e "${YELLOW}Failed to start VM $vmname - you may need to start it manually${NC}"
    fi

    echo "----------------------------------------"
}

# Function to cleanup VMs if they exist
cleanup_existing_vms() {
    echo -e "${YELLOW}Checking for existing VMs...${NC}"

    for vm_config in "${!VMS[@]}"; do
        IFS=',' read -r node vmname <<< "$vm_config"
        vmid=${VMS[$vm_config]}

        # Check if VM exists
        if pvesh get /nodes/$node/qemu/$vmid/status/current &>/dev/null; then
            echo -e "${YELLOW}Found existing VM $vmid on node $node${NC}"
            read -p "Do you want to remove it? (y/n): " -n 1 -r
            echo
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                echo -e "${YELLOW}Stopping and removing VM $vmid...${NC}"
                # Stop VM if running
                pvesh create /nodes/$node/qemu/$vmid/status/stop &>/dev/null
                sleep 2
                # Remove VM
                pvesh delete /nodes/$node/qemu/$vmid
                echo -e "${GREEN}VM $vmid removed${NC}"
            fi
        fi
    done
}

# Main execution
echo -e "${GREEN}Starting Proxmox Kubernetes VM deployment...${NC}"
echo "========================================"

# Check if running as root or with appropriate permissions
if [ "$EUID" -ne 0 ] && ! groups | grep -q "root\|sudo"; then
    echo -e "${RED}Please run as root or with sudo privileges${NC}"
    exit 1
fi

# Check if we're on a Proxmox node
if ! command -v pvesh &> /dev/null; then
    echo -e "${RED}This script must be run on a Proxmox node${NC}"
    exit 1
fi

# Ask if user wants to cleanup existing VMs
read -p "Do you want to check and cleanup existing VMs? (y/n): " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    cleanup_existing_vms
fi

# Deploy VMs
for vm_config in "${!VMS[@]}"; do
    IFS=',' read -r node vmname <<< "$vm_config"
    vmid=${VMS[$vm_config]}

    # Check if VM already exists
    if pvesh get /nodes/$node/qemu/$vmid/status/current &>/dev/null; then
        echo -e "${YELLOW}VM $vmid already exists on node $node. Skipping...${NC}"
        continue
    fi

    create_vm "$node" "$vmname" "$vmid"

    # Add a small delay between VM creations
    sleep 2
done

echo -e "${GREEN}Deployment complete!${NC}"
echo "========================================"
echo "Summary of deployed VMs:"
echo ""
echo "Node px-0:"
echo "  - kubernetes-controlplane-1 (ID: 800) - 4 cores, 6GB RAM, 32GB disk"
echo "  - kubernetes-worker-1 (ID: 801) - 4 cores, 12GB RAM, 128GB disk"
echo ""
echo "Node px-1:"
echo "  - kubernetes-controlplane-2 (ID: 802) - 4 cores, 6GB RAM, 32GB disk"
echo "  - kubernetes-worker-2 (ID: 803) - 4 cores, 12GB RAM, 128GB disk"
echo ""
echo "Node px-2:"
echo "  - kubernetes-controlplane-3 (ID: 804) - 4 cores, 6GB RAM, 32GB disk"
echo "  - kubernetes-worker-3 (ID: 805) - 4 cores, 12GB RAM, 128GB disk"
echo ""
echo "All VMs are configured with:"
echo "  - ISO: $ISO_STORAGE:iso/$ISO_NAME"
echo "  - Storage: $DISK_STORAGE"
echo "  - CPU Type: host"
echo "  - Tag: $TAG"
echo "  - Network: vmbr0 (default bridge)"

# Show actual disk allocation status
echo ""
echo -e "${YELLOW}Checking disk allocation status...${NC}"
for vm_config in "${!VMS[@]}"; do
    IFS=',' read -r node vmname <<< "$vm_config"
    vmid=${VMS[$vm_config]}

    echo -n "$vmname (ID: $vmid): "
    CONFIG=$(pvesh get /nodes/$node/qemu/$vmid/config 2>/dev/null)
    if echo "$CONFIG" | grep -q "scsi0"; then
        DISK_INFO=$(echo "$CONFIG" | grep "scsi0" | sed 's/.*scsi0: //')
        echo -e "${GREEN}Disk configured - $DISK_INFO${NC}"
    else
        echo -e "${RED}No disk found${NC}"
    fi
done

# Show VM running status
echo ""
echo -e "${YELLOW}VM Status:${NC}"
for vm_config in "${!VMS[@]}"; do
    IFS=',' read -r node vmname <<< "$vm_config"
    vmid=${VMS[$vm_config]}

    echo -n "$vmname (ID: $vmid): "
    STATUS=$(pvesh get /nodes/$node/qemu/$vmid/status/current 2>/dev/null | grep -o '"status":"[^"]*"' | cut -d'"' -f4)
    if [ -n "$STATUS" ]; then
        if [ "$STATUS" = "running" ]; then
            echo -e "${GREEN}$STATUS${NC}"
        else
            echo -e "${YELLOW}$STATUS${NC}"
        fi
    else
        echo -e "${RED}Unknown${NC}"
    fi
done