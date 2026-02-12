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

# Funktsioon ühe subneti loomiseks
function create_subnet() {
    local SUBNET_ID=$1
    local VMID=$2
    local ZONE="zone$SUBNET_ID"
    local VNET="vnet$SUBNET_ID"
    local SUBNET="192.168.$SUBNET_ID.0/24"
    local GATEWAY="192.168.$SUBNET_ID.1"
    local DHCP_RANGE_START="192.168.$SUBNET_ID.$DHCP_START"
    local DHCP_RANGE_END="192.168.$SUBNET_ID.$DHCP_END"
   
    echo "----------------------------------------"
    echo "Creating network for subnet $SUBNET_ID..."
    echo "----------------------------------------"
   
    # Loo Zone
    if ! pvesh get "/cluster/sdn/zones/$ZONE" &>/dev/null; then
        pvesh create /cluster/sdn/zones \
            --zone "$ZONE" \
            --type simple \
            --dhcp dnsmasq \
            --ipam pve
        echo "Zone $ZONE created."
    else
        echo "Zone $ZONE already exists, updating..."
        pvesh set "/cluster/sdn/zones/$ZONE" \
            --dhcp dnsmasq \
            --ipam pve
    fi
   
    # Loo VNet
    if ! pvesh get "/cluster/sdn/vnets/$VNET" &>/dev/null; then
        pvesh create /cluster/sdn/vnets \
            --vnet "$VNET" \
            --zone "$ZONE"
        echo "VNet $VNET created."
    else
        echo "VNet $VNET already exists."
    fi
   
    # Loo Subnet
    echo "Creating Subnet with DHCP range $DHCP_RANGE_START-$DHCP_RANGE_END..."
    if ! pvesh get "/cluster/sdn/vnets/$VNET/subnets/$SUBNET" &>/dev/null; then
        pvesh create "/cluster/sdn/vnets/$VNET/subnets" \
            --subnet "$SUBNET" \
            --gateway "$GATEWAY" \
            --type subnet \
            --dhcp-range "start-address=$DHCP_RANGE_START,end-address=$DHCP_RANGE_END" \
            --snat 1
        echo "Subnet $SUBNET created."
    else
        echo "Subnet $SUBNET already exists."
    fi
   
    # Kui VMID on määratud, ühenda VM
    if [[ -n "$VMID" && "$VMID" != "0" ]]; then
        if qm status "$VMID" &>/dev/null; then
            echo "Attaching VM $VMID to VNet $VNET..."
            qm set "$VMID" --net0 virtio,bridge="$VNET"
            echo "VM $VMID connected to $VNET"
        else
            echo "WARNING: VM $VMID does not exist, skipping attachment."
        fi
    fi
   
    echo "✓ Subnet $SUBNET_ID configuration complete."
    echo ""
}

# Funktsioon CSV failide otsimiseks
function find_csv_files() {
    local csv_files=()
    while IFS= read -r -d '' file; do
        csv_files+=("$file")
    done < <(find "$(pwd)" -maxdepth 1 -type f -name "*.csv" -print0 2>/dev/null)
    echo "${csv_files[@]}"
}

# Küsi režiim
echo "========================================="
echo "Proxmox SDN Network Setup Script"
echo "========================================="
echo "Choose setup mode:"
echo "1) Interactive mode (single subnet)"
echo "2) Batch mode (CSV import)"
read -p "Enter choice (1 or 2): " MODE

if [[ "$MODE" == "1" ]]; then
    # INTERACTIVE MODE
    echo ""
    echo "--- Interactive Mode ---"
   
    # Küsi subnet number
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
        read -p "Enter VM ID to attach network (or 0 to skip): " VMID
        if [[ "$VMID" == "0" ]]; then
            break
        fi
        if ! qm status "$VMID" &>/dev/null; then
            echo "VM with ID $VMID does not exist."
            continue
        fi
       
        # Kontrolli kas net0 on juba olemas
        if qm config "$VMID" | grep -q "^net0:"; then
            echo "WARNING: VM $VMID already has net0 configured:"
            qm config "$VMID" | grep "^net0:"
            read -p "Do you want to overwrite it? (y/n): " confirm
            if [[ $confirm != "y" ]]; then
                echo "Aborted. VM network not modified."
                exit 1
            fi
        fi
        break
    done
   
    create_subnet "$SUBNET_ID" "$VMID"
   
elif [[ "$MODE" == "2" ]]; then
    # BATCH MODE (CSV)
    echo ""
    echo "--- Batch Mode (CSV Import) ---"
   
    # Otsi CSV failid praegusest kaustast
    echo "Searching for CSV files in current directory: $(pwd)"
    csv_files=($(find_csv_files))
   
    if [ ${#csv_files[@]} -eq 0 ]; then
        echo ""
        echo "ERROR: No CSV files found in current directory."
        echo "Please create a CSV file with format:"
        echo "  subnet_id,vm_id"
        echo "  10,100"
        echo "  11,101"
        exit 1
    fi
   
    echo ""
    echo "Found ${#csv_files[@]} CSV file(s):"
    for i in "${!csv_files[@]}"; do
        echo "  $((i+1))) ${csv_files[$i]}"
    done
    echo ""
   
    # Kui on ainult üks fail, kasuta seda automaatselt
    if [ ${#csv_files[@]} -eq 1 ]; then
        CSV_FILE="${csv_files[0]}"
        echo "Using: $CSV_FILE"
    else
        # Küsi kasutajalt valik
        while true; do
            read -p "Select CSV file (1-${#csv_files[@]}): " choice
            if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le ${#csv_files[@]} ]; then
                CSV_FILE="${csv_files[$((choice-1))]}"
                break
            else
                echo "Invalid choice. Please enter a number between 1 and ${#csv_files[@]}."
            fi
        done
    fi
   
    echo ""
    echo "Processing CSV file: $CSV_FILE"
    echo "CSV format expected: subnet_id,vm_id"
    echo ""
   
    # Loe CSV fail
    line_num=0
    while IFS=',' read -r subnet_id vm_id || [[ -n "$subnet_id" ]]; do
        line_num=$((line_num + 1))
       
        # Ignoreeri tühje ridu ja päiseid
        if [[ -z "$subnet_id" || "$subnet_id" == "subnet_id" ]]; then
            continue
        fi
       
        # Eemalda tühikud
        subnet_id=$(echo "$subnet_id" | xargs)
        vm_id=$(echo "$vm_id" | xargs)
       
        # Valideeri subnet_id
        if ! [[ "$subnet_id" =~ ^[0-9]+$ ]] || [ "$subnet_id" -lt 0 ] || [ "$subnet_id" -gt 255 ]; then
            echo "ERROR on line $line_num: Invalid subnet_id '$subnet_id'. Skipping."
            continue
        fi
       
        # Kontrolli kas subnet on juba olemas
        if subnet_exists "$subnet_id"; then
            echo "WARNING on line $line_num: Subnet $subnet_id already exists. Skipping."
            continue
        fi
       
        # Valideeri vm_id kui see on määratud
        if [[ -n "$vm_id" && "$vm_id" != "0" ]]; then
            if ! [[ "$vm_id" =~ ^[0-9]+$ ]]; then
                echo "WARNING on line $line_num: Invalid vm_id '$vm_id'. Creating subnet without VM attachment."
                vm_id="0"
            fi
        fi
       
        create_subnet "$subnet_id" "$vm_id"
       
    done < "$CSV_FILE"
   
    echo "CSV import completed!"
   
else
    echo "Invalid choice. Exiting."
    exit 1
fi

# Apply SDN configuration
echo "========================================="
echo "Applying SDN configuration..."
pvesh set /cluster/sdn

echo ""
echo "========================================="
echo "✓ All done! Network configuration complete."
echo "========================================="
