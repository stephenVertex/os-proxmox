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
RUN_INIT=$(python3 -c "import yaml; val = yaml.safe_load(open('$CONFIG_FILE')).get('run_init', True); print(str(val).lower())")
START_ORCHESTRATOR=$(python3 -c "import yaml; val = yaml.safe_load(open('$CONFIG_FILE')).get('start_orchestrator', False); print(str(val).lower())")
LINEAR_PROJECT_SLUG=$(python3 -c "import yaml; print(yaml.safe_load(open('$CONFIG_FILE')).get('linear_project_slug', ''))")

# Validate required fields
if [ -z "$LINEAR_PROJECT_SLUG" ]; then
    log "ERROR: linear_project_slug is required but not set in $CONFIG_FILE"
    touch /var/lib/opensymphony-firstboot-done
    exit 1
fi

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
    
    # Build env var exports for the sudo command
    ENV_EXPORTS=""
    if [ -f "$ENV_FILE" ]; then
        while IFS= read -r line || [[ -n "$line" ]]; do
            [[ -z "$line" || "$line" =~ ^# ]] && continue
            ENV_EXPORTS="$ENV_EXPORTS export $line;"
        done < "$ENV_FILE"
    fi
    
    # Run init non-interactively by piping answers:
    #   "n"  -> No AI PR review scaffolding
    #   "{slug}" or "" -> Linear project slug (injected if provided, blank otherwise)
    #   ""   -> LLM_BASE_URL (uses default if not set in env)
    #   ""   -> Skip commit/push prompt
    # If LLM env vars are set via the env file, LLM prompts are skipped.
    # If WORKFLOW.md already exists, skip entirely.
    if [ ! -f "$WORKSPACE_DIR/WORKFLOW.md" ]; then
        log "Piping non-interactive answers to opensymphony init"
        if [ -n "$LINEAR_PROJECT_SLUG" ]; then
            log "Injecting Linear project slug: $LINEAR_PROJECT_SLUG"
        fi
        sudo -u opensymphony bash -c "
            export PATH=\"/home/opensymphony/.cargo/bin:/home/opensymphony/.local/bin:\$PATH\"
            export HOME=/home/opensymphony
            $ENV_EXPORTS
            cd '$WORKSPACE_DIR'
            # Pipe answers: n (no AI PR), slug or blank, blank (LLM_URL), blank (skip commit)
            printf 'n\n%s\n\n\n' '$LINEAR_PROJECT_SLUG' | opensymphony init || true
        "
    else
        log "WORKFLOW.md already exists, skipping init"
    fi
fi

# Enable and configure systemd service for orchestrator if requested
if [ "$START_ORCHESTRATOR" = "true" ]; then
    log "Configuring orchestrator auto-start"
    systemctl enable opensymphony-orchestrator.service || true
fi

log "Firstboot setup complete"
touch /var/lib/opensymphony-firstboot-done
