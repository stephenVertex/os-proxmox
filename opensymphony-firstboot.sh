#!/bin/bash
set -e

CONFIG_FILE="/etc/opensymphony/instance-config.yaml"
LOG_FILE="/var/log/opensymphony-firstboot.log"

log() {
    echo "[$(date -Iseconds)] $1" | tee -a "$LOG_FILE"
}

# Only run once
if [ -f /var/lib/opensymphony-firstboot-done ]; then
    log "Firstboot already completed, skipping"
    exit 0
fi

log "Starting OpenSymphony firstboot setup..."

if [ ! -f "$CONFIG_FILE" ]; then
    log "No config found at $CONFIG_FILE - skipping setup"
    touch /var/lib/opensymphony-firstboot-done
    exit 0
fi

# Parse config with Python3 (always available on Debian)
python3 -c "
import yaml, sys
try:
    with open('$CONFIG_FILE') as f:
        config = yaml.safe_load(f)
    print('CONFIG_OK')
except Exception as e:
    print(f'CONFIG_ERROR: {e}', file=sys.stderr)
    sys.exit(1)
" || {
    log "ERROR: Invalid config file"
    touch /var/lib/opensymphony-firstboot-done
    exit 1
}

GIT_REPO=$(python3 -c "import yaml; print(yaml.safe_load(open('$CONFIG_FILE')).get('git_repo', ''))")
GIT_BRANCH=$(python3 -c "import yaml; print(yaml.safe_load(open('$CONFIG_FILE')).get('git_branch', 'main'))")
GIT_SSH_KEY=$(python3 -c "import yaml; print(yaml.safe_load(open('$CONFIG_FILE')).get('git_ssh_key', ''))")
WORKSPACE_DIR=$(python3 -c "import yaml; print(yaml.safe_load(open('$CONFIG_FILE')).get('workspace_dir', '/home/opensymphony/workspace'))")
RUN_INIT=$(python3 -c "import yaml; print(yaml.safe_load(open('$CONFIG_FILE')).get('run_init', 'true'))")
START_ORCHESTRATOR=$(python3 -c "import yaml; print(yaml.safe_load(open('$CONFIG_FILE')).get('start_orchestrator', 'false'))")

# Set up environment variables
ENV_FILE="/etc/opensymphony/environment"
if [ -f "$ENV_FILE" ]; then
    log "Loading environment from $ENV_FILE"
    set -a
    source "$ENV_FILE"
    set +a
fi

# Set up git SSH key if provided
if [ -n "$GIT_SSH_KEY" ]; then
    log "Setting up Git SSH key"
    mkdir -p /home/opensymphony/.ssh
    echo "$GIT_SSH_KEY" > /home/opensymphony/.ssh/id_ed25519
    chmod 600 /home/opensymphony/.ssh/id_ed25519
    chown -R opensymphony:opensymphony /home/opensymphony/.ssh
    ssh-keyscan -t ed25519 github.com 2>/dev/null >> /home/opensymphony/.ssh/known_hosts 2>/dev/null || true
    ssh-keyscan -t ed25519 gitlab.com 2>/dev/null >> /home/opensymphony/.ssh/known_hosts 2>/dev/null || true
fi

# Clone the repository
if [ -n "$GIT_REPO" ]; then
    log "Cloning repository: $GIT_REPO (branch: $GIT_BRANCH)"
    sudo -u opensymphony mkdir -p "$WORKSPACE_DIR"
    if [ -d "$WORKSPACE_DIR/.git" ]; then
        log "Repository already exists, pulling latest"
        sudo -u opensymphony bash -c "cd '$WORKSPACE_DIR' && git pull origin '$GIT_BRANCH'" || true
    else
        sudo -u opensymphony bash -c "cd /home/opensymphony && git clone -b '$GIT_BRANCH' '$GIT_REPO' '$WORKSPACE_DIR'"
    fi
    chown -R opensymphony:opensymphony "$WORKSPACE_DIR"
else
    log "No git_repo configured, skipping clone"
fi

# Run opensymphony init
if [ "$RUN_INIT" = "true" ] && [ -n "$GIT_REPO" ]; then
    log "Running opensymphony init in $WORKSPACE_DIR"
    sudo -u opensymphony bash -c "
        export PATH=\"/home/opensymphony/.cargo/bin:/home/opensymphony/.local/bin:\$PATH\"
        export HOME=/home/opensymphony
        cd '$WORKSPACE_DIR'
        # Non-interactive init: create basic config files
        if [ ! -f WORKFLOW.md ]; then
            opensymphony init || true
        fi
    "
fi

# Enable and configure systemd service for orchestrator if requested
if [ "$START_ORCHESTRATOR" = "true" ]; then
    log "Configuring orchestrator auto-start"
    systemctl enable opensymphony-orchestrator.service || true
fi

log "Firstboot setup complete"
touch /var/lib/opensymphony-firstboot-done
