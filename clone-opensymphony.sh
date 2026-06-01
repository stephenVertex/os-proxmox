#!/bin/bash
set -e

# OpenSymphony VM Clone Script
# Run this on the Proxmox host (seykhl) to create a new OpenSymphony instance
# from the base template.

TEMPLATE_ID=205
SSH_KEY="/root/.ssh/id_ed25519"
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10"

show_usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Create a new OpenSymphony VM from the base template.

Required:
  --id VMID                  Proxmox VM ID for the new instance
  --name NAME                VM name
  --repo URL                 Git repository URL to clone
  --linear-slug SLUG         Linear project slug (injected into WORKFLOW.md)

Optional:
  --branch BRANCH            Git branch (default: main)
  --ssh-key FILE             Path to SSH private key for private repos
  --linear-key KEY           Linear API key
  --github-token TOKEN       GitHub token for gh CLI (PRs, push, etc.)
  --llm-model MODEL          LLM model (e.g., openai/gpt-4o)
  --llm-key KEY              LLM API key
  --llm-url URL              LLM base URL (optional)
  --oh-secret KEY            OpenHands secret key
  --memory MB                Memory in MB (default: 4096)
  --cores N                  CPU cores (default: 2)
  --disk-size SIZE           Disk size suffix (e.g., +20G)
  --start                    Start the VM after creation
  --auto-run                 Enable orchestrator auto-start
  --env-file FILE            Additional environment file to inject
  --wait-ssh                 Wait for SSH before exiting (default with --start)

Example:
  $0 --id 300 --name my-project \
     --repo git@github.com:me/my-project.git \
     --ssh-key /root/.ssh/id_ed25519 \
     --linear-key "lin_api_xxx" \
     --llm-model "openai/gpt-4o" \
     --llm-key "sk-xxx" \
     --oh-secret "random-secret" \
     --start --auto-run
EOF
}

# Defaults
BRANCH="main"
MEMORY="4096"
CORES="2"
START=0
AUTO_RUN=0
GIT_SSH_KEY=""
LINEAR_KEY=""
LINEAR_SLUG=""
GITHUB_TOKEN=""
LLM_MODEL=""
LLM_KEY=""
LLM_URL=""
OH_SECRET=""
ENV_FILE=""
DISK_SIZE=""
WAIT_SSH=0

while [[ $# -gt 0 ]]; do
    case $1 in
        --id) VMID="$2"; shift 2 ;;
        --name) NAME="$2"; shift 2 ;;
        --repo) REPO="$2"; shift 2 ;;
        --branch) BRANCH="$2"; shift 2 ;;
        --ssh-key) GIT_SSH_KEY="$2"; shift 2 ;;
        --linear-key) LINEAR_KEY="$2"; shift 2 ;;
        --linear-slug) LINEAR_SLUG="$2"; shift 2 ;;
        --github-token) GITHUB_TOKEN="$2"; shift 2 ;;
        --llm-model) LLM_MODEL="$2"; shift 2 ;;
        --llm-key) LLM_KEY="$2"; shift 2 ;;
        --llm-url) LLM_URL="$2"; shift 2 ;;
        --oh-secret) OH_SECRET="$2"; shift 2 ;;
        --memory) MEMORY="$2"; shift 2 ;;
        --cores) CORES="$2"; shift 2 ;;
        --disk-size) DISK_SIZE="$2"; shift 2 ;;
        --start) START=1; WAIT_SSH=1; shift ;;
        --auto-run) AUTO_RUN=1; shift ;;
        --env-file) ENV_FILE="$2"; shift 2 ;;
        --wait-ssh) WAIT_SSH=1; shift ;;
        -h|--help) show_usage; exit 0 ;;
        *) echo "Unknown option: $1"; show_usage; exit 1 ;;
    esac
done

if [[ -z "$VMID" || -z "$NAME" || -z "$REPO" || -z "$LINEAR_SLUG" ]]; then
    echo "Error: --id, --name, --repo, and --linear-slug are required"
    show_usage
    exit 1
fi

# Check if template exists
if ! qm config $TEMPLATE_ID &>/dev/null; then
    echo "Error: Template $TEMPLATE_ID not found"
    exit 1
fi

# Check if target VMID exists
if qm config $VMID &>/dev/null; then
    echo "Error: VM $VMID already exists"
    exit 1
fi

echo "Cloning template $TEMPLATE_ID to VM $VMID ($NAME)..."
qm clone $TEMPLATE_ID $VMID --name "$NAME"

# Set basic cloud-init via qm set
qm set $VMID --ipconfig0 ip=dhcp --ciuser opensymphony

# Set resources
qm set $VMID --memory $MEMORY --cores $CORES

# Resize disk if requested
if [[ -n "$DISK_SIZE" ]]; then
    echo "Resizing disk: $DISK_SIZE"
    qm resize $VMID scsi0 $DISK_SIZE
fi

# Build instance config YAML
INSTANCE_CONFIG="/tmp/opensymphony-config-$VMID.yaml"
cat > "$INSTANCE_CONFIG" <<EOF
git_repo: "$REPO"
git_branch: "$BRANCH"
workspace_dir: "/home/opensymphony/workspace"
run_init: true
start_orchestrator: $(if [[ $AUTO_RUN -eq 1 ]]; then echo "true"; else echo "false"; fi)
EOF

if [[ -n "$LINEAR_SLUG" ]]; then
    echo "linear_project_slug: \"$LINEAR_SLUG\"" >> "$INSTANCE_CONFIG"
fi

if [[ -n "$GIT_SSH_KEY" && -f "$GIT_SSH_KEY" ]]; then
    echo "git_ssh_key: |" >> "$INSTANCE_CONFIG"
    cat "$GIT_SSH_KEY" | sed 's/^/  /' >> "$INSTANCE_CONFIG"
fi

# Build environment file
ENV_TEMP="/tmp/opensymphony-env-$VMID"
: > "$ENV_TEMP"
if [[ -n "$LINEAR_KEY" ]]; then
    echo "LINEAR_API_KEY=$LINEAR_KEY" >> "$ENV_TEMP"
fi
if [[ -n "$GITHUB_TOKEN" ]]; then
    echo "GH_TOKEN=$GITHUB_TOKEN" >> "$ENV_TEMP"
fi
if [[ -n "$LLM_MODEL" ]]; then
    echo "LLM_MODEL=$LLM_MODEL" >> "$ENV_TEMP"
fi
if [[ -n "$LLM_KEY" ]]; then
    echo "LLM_API_KEY=$LLM_KEY" >> "$ENV_TEMP"
fi
if [[ -n "$LLM_URL" ]]; then
    echo "LLM_BASE_URL=$LLM_URL" >> "$ENV_TEMP"
fi
if [[ -n "$OH_SECRET" ]]; then
    echo "OH_SECRET_KEY=$OH_SECRET" >> "$ENV_TEMP"
fi
if [[ -n "$ENV_FILE" && -f "$ENV_FILE" ]]; then
    cat "$ENV_FILE" >> "$ENV_TEMP"
fi

echo ""
echo "VM $VMID ($NAME) created from template $TEMPLATE_ID"
echo ""
echo "Configuration:"
echo "  Git Repo:     $REPO"
echo "  Branch:       $BRANCH"
echo "  Memory:       ${MEMORY}MB"
echo "  Cores:        $CORES"
[[ -n "$DISK_SIZE" ]] && echo "  Disk resize:  $DISK_SIZE"
echo "  Auto-run:     $(if [[ $AUTO_RUN -eq 1 ]]; then echo "enabled"; else echo "disabled"; fi)"
echo ""

if [[ $START -eq 0 ]]; then
    echo "Start with: qm start $VMID"
    echo "Then inject config via SSH and run firstboot."
    exit 0
fi

echo "Starting VM $VMID..."
qm start $VMID

# Wait for IP
echo "Waiting for VM to get an IP address..."
VM_IP=""
for i in {1..60}; do
    VM_IP=$(qm guest cmd $VMID network-get-interfaces 2>/dev/null | \
        python3 -c "import sys,json; data=json.load(sys.stdin); print([i['ip-addresses'][0]['ip-address'] for i in data['result'] if i.get('ip-addresses')][0])" 2>/dev/null || true)
    if [[ -n "$VM_IP" && "$VM_IP" != "127.0.0.1" ]]; then
        break
    fi
    # Fallback: scan ARP for the VM MAC
    MAC=$(qm config $VMID | grep net0 | grep -oE '([A-Fa-f0-9]{2}:){5}[A-Fa-f0-9]{2}' | head -1)
    if [[ -n "$MAC" ]]; then
        VM_IP=$(ip neigh show | grep -i "$MAC" | awk '{print $1}' | head -1)
        if [[ -n "$VM_IP" ]]; then
            break
        fi
    fi
    sleep 5
done

if [[ -z "$VM_IP" ]]; then
    echo "ERROR: Could not determine VM IP address"
    echo "Check Proxmox DHCP leases or guest agent"
    exit 1
fi

echo "VM IP: $VM_IP"

# Wait for SSH
echo "Waiting for SSH..."
for i in {1..30}; do
    if ssh $SSH_OPTS -o ConnectTimeout=5 opensymphony@$VM_IP "echo ssh_ok" 2>/dev/null; then
        break
    fi
    sleep 5
done

# Copy config files
echo "Injecting OpenSymphony configuration..."
scp $SSH_OPTS "$INSTANCE_CONFIG" "opensymphony@$VM_IP:/tmp/instance-config.yaml"
scp $SSH_OPTS "$ENV_TEMP" "opensymphony@$VM_IP:/tmp/environment"

ssh $SSH_OPTS opensymphony@$VM_IP "
    sudo mv /tmp/instance-config.yaml /etc/opensymphony/instance-config.yaml
    sudo mv /tmp/environment /etc/opensymphony/environment
    sudo chmod 600 /etc/opensymphony/environment
    sudo rm -f /var/lib/opensymphony-firstboot-done
    echo 'Config injected. Running firstboot...'
    sudo /usr/local/sbin/opensymphony-firstboot
" || {
    echo "WARNING: Firstboot script failed or SSH disconnected"
}

echo ""
echo "========================================"
echo "VM $VMID ($NAME) is ready"
echo "IP: $VM_IP"
echo ""
echo "To monitor firstboot:"
echo "  ssh opensymphony@$VM_IP 'sudo journalctl -u opensymphony-firstboot -f'"
echo ""
echo "To access the workspace:"
echo "  ssh opensymphony@$VM_IP"
echo "  cd ~/workspace"
echo ""
if [[ $AUTO_RUN -eq 1 ]]; then
    echo "Orchestrator is configured to auto-start."
    echo "Check status: ssh opensymphony@$VM_IP 'sudo systemctl status opensymphony-orchestrator'"
else
    echo "To start manually:"
    echo "  ssh opensymphony@$VM_IP"
    echo "  cd ~/workspace && opensymphony run"
fi
echo "========================================"
