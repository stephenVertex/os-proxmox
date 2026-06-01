# OpenSymphony Proxmox Template

A parameterized Proxmox template (VM 200) for running [OpenSymphony](https://github.com/kumanday/OpenSymphony) instances.

## Template Details

- **Template ID**: `205`
- **Name**: `opensymphony-base`
- **Base OS**: Debian 13 (trixie) generic cloud image
- **Pre-installed**:
  - Rust toolchain
  - `uv` (Python package manager)
  - Python 3.13
  - Git
  - OpenSymphony CLI (`opensymphony`)
  - OpenHands runtime (`opensymphony install openhands`)
- **Services**:
  - `opensymphony-firstboot.service` — runs on first boot to clone repo and configure
  - `opensymphony-orchestrator.service` — optional auto-start for `opensymphony run`

## Quick Start

### 1. Clone the Template

SSH to the Proxmox host (`seykhl`) and run:

```bash
clone-opensymphony.sh \
  --id 300 \
  --name my-project \
  --repo git@github.com:you/my-project.git \
  --linear-slug "my-project" \
  --branch main \
  --ssh-key /root/.ssh/id_ed25519 \
  --linear-key "lin_api_xxx" \
  --github-token "ghp_xxx" \
  --llm-model "openai/gpt-4o" \
  --llm-key "sk-xxx" \
  --oh-secret "random-secret" \
  --start
```

### 2. Clone Script Options

| Option | Required | Description |
|--------|----------|-------------|
| `--id` | Yes | Proxmox VM ID |
| `--name` | Yes | VM hostname and name |
| `--repo` | Yes | Git repository URL |
| `--linear-slug` | Yes | Linear project slug (injected into WORKFLOW.md) |
| `--branch` | No | Git branch (default: `main`) |
| `--ssh-key` | No | SSH key file for private repos |
| `--linear-key` | No | Linear API key |
| `--github-token` | No | GitHub token for gh CLI (PRs, push, etc.) |
| `--llm-model` | No | LLM model string |
| `--llm-key` | No | LLM API key |
| `--llm-url` | No | LLM base URL |
| `--oh-secret` | No | OpenHands secret key |
| `--memory` | No | RAM in MB (default: 4096) |
| `--cores` | No | CPU cores (default: 2) |
| `--disk-size` | No | Extra disk size (e.g., `+20G`) |
| `--start` | No | Start VM after creation |
| `--auto-run` | No | Enable `opensymphony run` on boot |
| `--env-file` | No | Additional env vars file |

### 3. Check First Boot Status

After the VM starts, SSH in and check the firstboot log:

```bash
ssh opensymphony@<vm-ip>
sudo journalctl -u opensymphony-firstboot -f
```

### 4. Manual Setup (Alternative)

If you prefer to configure manually instead of using `--auto-run`:

```bash
ssh opensymphony@<vm-ip>
cd ~/workspace
export LINEAR_API_KEY="..."
export OH_SECRET_KEY="..."
export LLM_MODEL="..."
export LLM_API_KEY="..."
opensymphony init
opensymphony run
```

In another terminal:
```bash
ssh opensymphony@<vm-ip>
opensymphony tui
```

## Parameterization Architecture

The template uses **cloud-init** + **systemd firstboot** for per-instance configuration:

1. **Cloud-init** injects `/etc/opensymphony/instance-config.yaml` and `/etc/opensymphony/environment`
2. **firstboot service** reads these files on first boot
3. It clones the specified git repo into `~/workspace`
4. It runs `opensymphony init` in the repo
5. If `start_orchestrator: true`, it enables the orchestrator systemd service

This means each clone can target a **different git repo** with **different API keys** without modifying the base image.

## Template Maintenance

To update the base template (e.g., upgrade OpenSymphony):

```bash
# Create a working VM from the template
qm clone 205 199 --name opensymphony-update --full 1
qm start 199
ssh opensymphony@<ip>

# Update
opensymphony update

# Clean up properly for templating
sudo cloud-init clean --logs --seed
sudo rm -f /etc/machine-id
sudo touch /etc/machine-id && sudo truncate -s 0 /etc/machine-id
sudo rm -f /etc/ssh/ssh_host_*
sudo apt-get clean
history -c

# Back on Proxmox host
qm shutdown 199
# Destroy old template and replace with updated one
qm destroy 205 --purge
mv /etc/pve/local/qemu-server/199.conf /etc/pve/local/qemu-server/205.conf
sed -i 's/name: opensymphony-update/name: opensymphony-base/' /etc/pve/local/qemu-server/205.conf
qm template 205
```

## Finding VM IP Addresses

A helper script is installed on the Proxmox host:

```bash
# Find the IP of any VM
find-vm-ip <vmid>

# Example
find-vm-ip 207
```

This tries multiple methods:
1. **Guest agent** (fastest, most reliable)
2. **ARP table lookup** by MAC address
3. **Network scan** with nmap

## Files

- `opensymphony-firstboot.sh` — firstboot script installed in template
- `opensymphony-firstboot.service` — systemd service for firstboot
- `opensymphony-orchestrator.service` — systemd service for `opensymphony run`
- `instance-config.yaml` — default config template
- `find-vm-ip.sh` — helper to find VM IP addresses on the Proxmox host
- `clone-opensymphony.sh` — Proxmox host script to clone and configure
