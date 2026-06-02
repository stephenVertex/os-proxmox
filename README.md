# OpenSymphony Proxmox Template

> One Proxmox template. Infinite OpenSymphony agents. Zero configuration drift.

A parameterized Proxmox template that turns VM cloning into a **one-command** operation for deploying [OpenSymphony](https://github.com/kumanday/OpenSymphony) orchestrator instances. Each clone targets a different git repository, a different Linear project, and a different set of API keys — without touching the base image.

---

## Table of Contents

- [What You Get](#what-you-get)
- [Architecture Overview](#architecture-overview)
- [Required Variables](#required-variables)
- [The Full Lifecycle](#the-full-lifecycle)
- [Quick Start](#quick-start)
- [Clone Script Options](#clone-script-options)
- [Instance Configuration YAML](#instance-configuration-yaml)
- [Environment Variables](#environment-variables)
- [Template Maintenance](#template-maintenance)
- [Troubleshooting](#troubleshooting)
- [File Reference](#file-reference)

---

## What You Get

| Component | What It Is |
|-----------|------------|
| **Template VM 205** | A Debian 13 cloud image with everything pre-installed |
| **One-command cloning** | `clone-opensymphony.sh` creates, configures, and boots a new instance |
| **Non-interactive `opensymphony init`** | The firstboot script handles all prompts automatically |
| **Linear project slug injection** | The slug is piped into `opensymphony init` and baked into `WORKFLOW.md` |
| **GitHub CLI** | Pre-installed `gh` for PRs, push, branch operations |
| **Auto-start orchestrator** | Optional `--auto-run` enables the systemd service |

### Pre-installed in the Template

- Rust toolchain
- `uv` (Python package manager)
- Python 3.13
- Git
- OpenSymphony CLI (v1.7.2)
- OpenHands runtime (v1.14.0)
- GitHub CLI (`gh`)
- `opensymphony-firstboot.service` (systemd)
- `opensymphony-orchestrator.service` (systemd)

---

## Architecture Overview

```
Proxmox Host (seykhl)
  |
  +-- Template VM 205 (opensymphony-base)
        |
        +-- Clone VM 300 (my-project)
        |     |
        |     +-- Cloud-init: DHCP, SSH keys
        |     +-- Firstboot:
        |     |     1. Read /etc/opensymphony/instance-config.yaml
        |     |     2. Read /etc/opensymphony/environment
        |     |     3. Clone git repo
        |     |     4. Run opensymphony init (non-interactive)
        |     |     5. Enable orchestrator (optional)
        |     +-- Orchestrator (if --auto-run)
        |           |
        |           +-- opensymphony run
        |                 +-- Reads Linear issues
        |                 +-- Dispatches to OpenHands agents
        |                 +-- Agents push code via gh CLI
        |
        +-- Clone VM 301 (other-project)
              +-- Different repo
              +-- Different Linear project
              +-- Different API keys
```

### The Secret Sauce

The template is a **true base image**. It contains the tools, but no configuration. Per-instance configuration is injected **after** the clone boots, not baked into the template. This means:

- ✅ One template serves all projects
- ✅ Each project gets its own VM with its own secrets
- ✅ No secrets in the template disk
- ✅ Linked or full clones — both work

---

## Required Variables

To spin up a working instance, you need these four things:

### 1. `--id` — Proxmox VM ID
A unique ID for the new VM (e.g., `300`, `301`). Proxmox tracks everything by VM ID.

### 2. `--name` — VM Hostname
The display name and hostname of the VM (e.g., `my-project`, `api-service`).

### 3. `--repo` — Git Repository URL
The repository to clone into `~/workspace`. Can be HTTPS or SSH.

```bash
# HTTPS
--repo https://github.com/you/my-project.git

# SSH (requires --ssh-key)
--repo git@github.com:you/my-project.git
```

### 4. `--linear-slug` — Linear Project Slug
The **required** Linear project slug. This is injected into `WORKFLOW.md` as `project_slug`. Without it, `opensymphony run` will fail to resolve the workflow.

```bash
--linear-slug "my-project"
```

**Note:** `linear_project_slug` is validated in the firstboot script. If it's empty, the script exits with an error.

---

## The Full Lifecycle

Here is exactly what happens when you run the clone command:

### Phase 1: Provisioning (on Proxmox host)

```bash
clone-opensymphony.sh \
  --id 300 \
  --name my-project \
  --repo git@github.com:me/my-project.git \
  --linear-slug "my-project" \
  --linear-key "lin_api_xxx" \
  --github-token "ghp_xxx" \
  --llm-model "openai/gpt-4o" \
  --llm-key "sk-xxx" \
  --oh-secret "random-secret" \
  --start --auto-run
```

1. `qm clone 205 300` — creates a full clone of template 205
2. `qm set 300 --ipconfig0 ip=dhcp --ciuser opensymphony` — configures cloud-init
3. Generates two files:
   - `/tmp/opensymphony-config-300.yaml` (instance config)
   - `/tmp/opensymphony-env-300` (environment variables)
4. Starts the VM
5. Waits for SSH to come up
6. SCPs both files into the VM at `/etc/opensymphony/`
7. Removes `/var/lib/opensymphony-firstboot-done` (forces firstboot to run)
8. **SSH executes:** `sudo /usr/local/sbin/opensymphony-firstboot`

### Phase 2: First Boot (inside the VM)

The `opensymphony-firstboot.service` runs after network and cloud-init complete:

**Step 1: Config Validation**
- Reads `/etc/opensymphony/instance-config.yaml`
- Validates that `linear_project_slug` is set
- Exits with error if missing

**Step 2: Environment Loading**
- Sources `/etc/opensymphony/environment`
- All API keys are now available as env vars

**Step 3: Git Clone**
```bash
git clone -b main git@github.com:me/my-project.git /home/opensymphony/workspace
```

**Step 4: OpenSymphony Init (non-interactive)**
The script runs:
```bash
printf 'n\nmy-project\n\n\n' | opensymphony init
```

**What each answer does:**

| Answer | Prompt | Result |
|--------|--------|--------|
| `n` | "Also scaffold automated OpenHands AI PR review? [y/N]" | **No** — `.github/workflows/ai-pr-review.yml` is NOT created |
| `my-project` | "Enter your Linear project slug/key" | **Injected** into `WORKFLOW.md` as `project_slug: "my-project"` |
| `""` | "LLM_BASE_URL is not set..." | Uses **default** `https://api.fireworks.ai/inference/v1` |
| `""` | "Commit and push these OpenSymphony bootstrap changes to `origin/main` now? [y/N]" | **Skipped** — files are created but NOT committed |

**Files created in `~/workspace/`:**
- `WORKFLOW.md` — with `project_slug: "my-project"` and your git remote
- `AGENTS.md` — project instructions
- `config.yaml` — OpenSymphony config
- `.github/CODEOWNERS` — code ownership
- `.github/pull_request_template.md` — PR template
- `.agents/skills/` — all skills (linear, commit, push, land, etc.)
- `.opensymphony/memory/memory.yaml` — memory bootstrap

**Files NOT created:**
- `.github/workflows/ai-pr-review.yml` — because you answered `n`

**Step 5: Orchestrator Service (if `--auto-run`)**
```bash
systemctl enable opensymphony-orchestrator.service
```
Sets the service to start on boot, but does not start it now.

**Step 6: Marker File**
```bash
touch /var/lib/opensymphony-firstboot-done
```
Prevents the script from running again on reboot.

### Phase 3: Orchestrator Starts (if `--auto-run`)

The `opensymphony-orchestrator.service` starts after firstboot completes:

```
[Unit]
After=network.target opensymphony-firstboot.service
Wants=opensymphony-firstboot.service
```

1. Loads environment from `/etc/opensymphony/environment`
2. Sets `WorkingDirectory=/home/opensymphony/workspace`
3. Runs: `opensymphony run`
4. `opensymphony run` reads `WORKFLOW.md` with `project_slug: "my-project"`
5. Connects to Linear API using `LINEAR_API_KEY`
6. **Fetches issues** from the `my-project` Linear project
7. **Starts the orchestrator loop** — waiting for work

### Phase 4: What You Can Do Now

**SSH into the VM:**
```bash
ssh opensymphony@192.168.0.XXX
```

**Check the firstboot log:**
```bash
sudo journalctl -u opensymphony-firstboot
```

**Check the orchestrator:**
```bash
sudo systemctl status opensymphony-orchestrator
```

**Start the TUI (in another terminal):**
```bash
ssh opensymphony@192.168.0.XXX
cd ~/workspace
opensymphony tui
```

**The files are uncommitted** — if you want to commit them:
```bash
cd ~/workspace
git add -A
git commit -m "Add OpenSymphony bootstrap files"
git push origin main
```

---

## Quick Start

### 1. SSH to the Proxmox Host

```bash
ssh seykhl
```

### 2. Create a New Instance

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
  --start --auto-run
```

### 3. Monitor First Boot

```bash
ssh opensymphony@<vm-ip>
sudo journalctl -u opensymphony-firstboot -f
```

### 4. Start the TUI

```bash
ssh opensymphony@<vm-ip>
cd ~/workspace
opensymphony tui
```

---

## Clone Script Options

| Option | Required | Description |
|--------|----------|-------------|
| `--id` | **Yes** | Proxmox VM ID (e.g., `300`) |
| `--name` | **Yes** | VM hostname and display name |
| `--repo` | **Yes** | Git repository URL to clone |
| `--linear-slug` | **Yes** | Linear project slug (injected into `WORKFLOW.md`) |
| `--branch` | No | Git branch (default: `main`) |
| `--ssh-key` | No | Path to SSH private key for private repos |
| `--linear-key` | No | Linear API key (`LINEAR_API_KEY`) |
| `--github-token` | No | GitHub token for `gh` CLI (`GH_TOKEN`) |
| `--llm-model` | No | LLM model string (e.g., `openai/gpt-4o`) |
| `--llm-key` | No | LLM API key (`LLM_API_KEY`) |
| `--llm-url` | No | LLM base URL (`LLM_BASE_URL`) |
| `--oh-secret` | No | OpenHands secret key (`OH_SECRET_KEY`) |
| `--memory` | No | RAM in MB (default: `4096`) |
| `--cores` | No | CPU cores (default: `2`) |
| `--disk-size` | No | Extra disk size (e.g., `+20G`) |
| `--start` | No | Start the VM after creation |
| `--auto-run` | No | Enable `opensymphony run` on boot |
| `--env-file` | No | Additional environment file to inject |

---

## Instance Configuration YAML

The file injected at `/etc/opensymphony/instance-config.yaml`:

```yaml
# OpenSymphony Instance Configuration
# Injected per-clone to parameterize the VM

# Git repository to clone
git_repo: "git@github.com:me/my-project.git"

# Git branch to checkout
git_branch: "main"

# SSH private key for private repos (multiline string)
git_ssh_key: |
  -----BEGIN OPENSSH PRIVATE KEY-----
  ...
  -----END OPENSSH PRIVATE KEY-----

# Directory where the repo will be cloned
workspace_dir: "/home/opensymphony/workspace"

# Whether to run 'opensymphony init' after cloning
run_init: true

# Whether to enable the orchestrator systemd service
start_orchestrator: true

# Linear project slug (required, injected into WORKFLOW.md)
linear_project_slug: "my-project"
```

**Note:** The `linear_project_slug` field is **required**. If it's empty, the firstboot script exits with an error.

---

## Environment Variables

The file injected at `/etc/opensymphony/environment`:

```bash
# Linear
LINEAR_API_KEY=lin_api_xxx

# GitHub
GH_TOKEN=ghp_xxx

# LLM
LLM_MODEL=openai/gpt-4o
LLM_API_KEY=sk-xxx
LLM_BASE_URL=https://api.openai.com/v1

# OpenHands
OH_SECRET_KEY=random-secret
```

**How they are used:**

| Variable | Used By | Purpose |
|----------|---------|---------|
| `LINEAR_API_KEY` | `opensymphony run` | Connects to Linear API to fetch issues |
| `GH_TOKEN` | `gh` CLI | Authenticates GitHub operations (PRs, push, branch) |
| `LLM_MODEL` | `opensymphony init` | Skips the "LLM model" prompt during init |
| `LLM_API_KEY` | `opensymphony init` | Skips the "LLM API key" prompt during init |
| `LLM_BASE_URL` | `opensymphony init` | Skips the "LLM base URL" prompt during init |
| `OH_SECRET_KEY` | `opensymphony run` | OpenHands runtime secret |

**Note:** The `opensymphony init` command checks these env vars. If they are set, the prompts are skipped. If they are not set, `opensymphony init` will prompt interactively (which would hang in a non-interactive script).

---

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

**Important:** After updating the template disk, you must also update the files in `/usr/local/sbin/` (the firstboot script) if they have changed.

---

## Troubleshooting

### "ERROR: linear_project_slug is required but not set"

You forgot `--linear-slug` in the clone command. The firstboot script validates this field and exits if it's empty.

### "Could not determine VM IP address"

The clone script could not find the VM's IP. Check:
1. Is the VM running? `qm status <vmid>`
2. Is the guest agent running? `qm guest exec <vmid> -- hostname`
3. Is DHCP working? Check the Proxmox DHCP leases

### "opensymphony init failed: input closed while waiting for a response"

The `opensymphony init` command received an unexpected prompt. This usually happens when:
- An env var is missing (e.g., `LLM_MODEL` or `LLM_API_KEY`)
- The git remote is not detected
- The firstboot script is out of sync with the `opensymphony` version

Fix: Check the firstboot log and compare the prompts with the script's expected answers.

### "gh auth status" fails

The `gh` CLI is not authenticated. The `GH_TOKEN` env var is read from `/etc/opensymphony/environment`. Make sure:
1. `--github-token` was passed to the clone script
2. The token is valid and has the right scopes
3. The environment file was injected correctly

### The orchestrator is not running

If `--auto-run` was used but the orchestrator is not running:
1. Check if firstboot completed: `ls /var/lib/opensymphony-firstboot-done`
2. Check the orchestrator status: `sudo systemctl status opensymphony-orchestrator`
3. Check the logs: `sudo journalctl -u opensymphony-orchestrator`

### WORKFLOW.md has "YOUR-PROJECT-SLUG"

The `linear_project_slug` was not injected correctly. Check:
1. The instance config has the slug: `cat /etc/opensymphony/instance-config.yaml`
2. The firstboot script ran and logged it: `sudo journalctl -u opensymphony-firstboot`

---

## File Reference

| File | Purpose | Where It Lives |
|------|---------|----------------|
| `clone-opensymphony.sh` | One-command VM creation and configuration | Proxmox host (`/usr/local/bin/`) |
| `find-vm-ip.sh` | Helper to find VM IP addresses | Proxmox host (`/usr/local/bin/`) |
| `opensymphony-firstboot.sh` | Firstboot script: clone, init, configure | Template (`/usr/local/sbin/`) |
| `opensymphony-firstboot.service` | systemd service that runs firstboot | Template (`/etc/systemd/system/`) |
| `opensymphony-orchestrator.service` | systemd service for `opensymphony run` | Template (`/etc/systemd/system/`) |
| `instance-config.yaml` | Default YAML config template | Repo (injected per-clone) |
| `opensymphony-firstboot.sh` | Latest version of firstboot script | Repo (deployed to template) |

---

## Proxmox Host: `seykhl`

- **Host**: `192.168.0.202`
- **SSH**: `root@seykhl` (configured in `~/.ssh/config`)
- **Template**: VM 205 (`opensymphony-base`)
- **Clone script**: `/usr/local/bin/clone-opensymphony.sh`
- **IP helper**: `/usr/local/bin/find-vm-ip`

---

## GitHub

- **Repo**: `https://github.com/stephenVertex/os-proxmox`
- **Issues**: Tracked via `bd` (beads) — run `bd onboard` in the repo

---

> Made with coffee and cloud-init by someone who got tired of manually configuring VMs.
