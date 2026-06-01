#!/bin/bash
# find-vm-ip: Quick helper to find the IP of a Proxmox VM
# Usage: find-vm-ip <vmid>

VMID="${1:-}"

if [[ -z "$VMID" ]]; then
    echo "Usage: find-vm-ip <vmid>"
    echo "Example: find-vm-ip 207"
    exit 1
fi

# Check if VM exists
if ! qm config "$VMID" &>/dev/null; then
    echo "Error: VM $VMID not found"
    exit 1
fi

# Get VM name and status
VM_NAME=$(qm config "$VMID" | grep '^name:' | awk '{print $2}')
VM_STATUS=$(qm status "$VMID" | awk '{print $2}')

echo "VM $VMID ($VM_NAME): $VM_STATUS"

if [[ "$VM_STATUS" != "running" ]]; then
    echo "VM is not running — start it first with: qm start $VMID"
    exit 1
fi

# Method 1: Try guest agent first
GUEST_IP=$(qm guest exec "$VMID" -- /bin/bash -c "hostname -I 2>/dev/null | awk '{print \$1}'" 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -1)

if [[ -n "$GUEST_IP" ]]; then
    echo "IP: $GUEST_IP (via guest agent)"
    exit 0
fi

# Method 2: Check ARP table for VM MAC
MAC=$(qm config "$VMID" | grep net0 | grep -oE '([A-Fa-f0-9]{2}:){5}[A-Fa-f0-9]{2}' | head -1)
if [[ -n "$MAC" ]]; then
    ARP_IP=$(ip neigh show | grep -i "$MAC" | grep -v FAILED | awk '{print $1}' | head -1)
    if [[ -n "$ARP_IP" ]]; then
        echo "IP: $ARP_IP (via ARP, MAC: $MAC)"
        exit 0
    fi
fi

# Method 3: Scan network and look for the MAC
if [[ -n "$MAC" ]]; then
    echo "Scanning network for MAC $MAC..."
    SCAN_IP=$(nmap -sn 192.168.0.0/24 2>/dev/null | grep -iB 1 "$MAC" | grep "Nmap scan report" | sed 's/.*for //' | head -1)
    if [[ -n "$SCAN_IP" ]]; then
        echo "IP: $SCAN_IP (via network scan, MAC: $MAC)"
        exit 0
    fi
fi

echo "Could not determine IP address for VM $VMID"
echo "Make sure the VM is running and the guest agent is installed"
exit 1
