#!/bin/bash

# Error handling
set -e
trap 'echo "Error occurred. Check configuration."' ERR

# Root kontroll
if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root."
   exit 1
fi

BRIDGE="vmbr0"
DHCP_START="100"
DHCP_END="200"

# Funktsioon subneti numbri kontrolliks
function subnet_exists() {
    local num=$1
    if pvesh get /cluster/sdn/vnets 2>/dev/null | grep -q "\"vnet$num\""; then
        return 0
    else
        return 1
    fi
}

# Küsi subnet number ja kontrolli, et pole kasutusel
while true; do
    read -p "Enter subnet number (0-255) to create 192.168.X.0/24: " SUBNET_ID
    if ! [[ "$SUBNET_ID" =~ ^[0-9]+$ ]] || [ "$SUBNET_ID" -lt 0 ] || [ "$SUBNET_ID" -gt 255 ]; then
        echo "Invalid number. Must be 0-255."
        continue
    fi
    if subnet_exists "$SUBNET_ID"; then
        echo "Subnet number $SUBNET_ID is already in use. Choose another."
        continue
    fi
    break
done

# Küsi VM ID
while true; do
    read -p "Enter VM ID to attach network: " VMID
    if ! qm status "$VMID" &>/dev/null; then
        echo "VM with ID $VMID does not exist."
        continue
    fi
    break
done

# Defineerime nimed ja IP
ZONE="zone$SUBNET_ID"
VNET="vnet$SUBNET_ID"
SUBNET="192.168.$SUBNET_ID.0/24"
GATEWAY="192.168.$SUBNET_ID.1"
DHCP_RANGE_START="192.168.$SUBNET_ID.$DHCP_START"
DHCP_RANGE_END="192.168.$SUBNET_ID.$DHCP_END"

echo "Creating SDN simple zone with DHCP enabled..."
if ! pvesh get "/cluster/sdn/zones/$ZONE" &>/dev/null; then
    pvesh create /cluster/sdn/zones \
        --zone "$ZONE" \
        --type simple \
        --dhcp dnsmasq \
        --ipam pve
else
    echo "Zone already exists, updating DHCP settings..."
    pvesh set "/cluster/sdn/zones/$ZONE" \
        --dhcp dnsmasq \
        --ipam pve
fi

echo "Creating VNet..."
if ! pvesh get "/cluster/sdn/vnets/$VNET" &>/dev/null; then
    pvesh create /cluster/sdn/vnets \
        --vnet "$VNET" \
        --zone "$ZONE"
else
    echo "VNet already exists."
fi

# REMOVE VLAN TAG – simple zones do not support it

echo "Creating Subnet with DHCP range $DHCP_RANGE_START-$DHCP_RANGE_END and SNAT enabled..."
pvesh create "/cluster/sdn/vnets/$VNET/subnets" \
    --subnet "$SUBNET" \
    --gateway "$GATEWAY" \
    --type subnet \
    --dhcp-range "start-address=$DHCP_RANGE_START,end-address=$DHCP_RANGE_END" \
    --snat 1

echo "Applying SDN configuration..."
pvesh set /cluster/sdn

echo "Checking VM $VMID network configuration..."
if qm config "$VMID" | grep -q "^net0:"; then
    echo "WARNING: VM $VMID already has net0 configured:"
    qm config "$VMID" | grep "^net0:"
    read -p "Do you want to overwrite it? (y/n): " confirm
    if [[ $confirm != "y" ]]; then
        echo "Aborted. VM network not modified."
        exit 1
    fi
fi

echo "Attaching VM $VMID to VNet $VNET..."
qm set "$VMID" --net0 virtio,bridge="$VNET"

echo ""
echo "========================================="
echo "Done! Network configuration complete."
echo "========================================="
echo "Zone: $ZONE"
echo "VNet: $VNET"
echo "Subnet: $SUBNET"
echo "Gateway: $GATEWAY"
echo "DHCP: $DHCP_RANGE_START - $DHCP_RANGE_END"
echo "DHCP Server: dnsmasq"
echo "SNAT: Enabled"
echo "VM $VMID connected to $VNET"
echo "========================================="
