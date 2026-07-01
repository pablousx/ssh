#!/bin/bash

# Detect environment
IS_WSL=false
OS_NAME="Linux"
if [ -n "$WSL_DISTRO_NAME" ] || [ -n "$WSL_INTEROP" ] || [ -f /proc/version ] && grep -qi microsoft /proc/version; then
    IS_WSL=true
    OS_NAME="Linux (WSL: $WSL_DISTRO_NAME)"
fi

# Paths
REPO_ROOT=$(realpath "$(dirname "$0")/..")
SYNC_SH="$REPO_ROOT/linux/sync.sh"
CONFIG_FILE="$HOME/.ssh/sync-ssh-env.sh"
DEFAULT_BW_SOCK="$HOME/.bitwarden-ssh-agent.sock"

prompt_option() {
    local prompt_text="$1"
    local default_val="$2"
    local user_input

    while true; do
        read -p "$prompt_text (yes [y], no [n], skip [s]) [$default_val]: " user_input
        user_input=$(echo "$user_input" | tr '[:upper:]' '[:lower:]')
        [ -z "$user_input" ] && user_input="$default_val"

        case "$user_input" in
            y|yes) echo "yes"; return 0 ;;
            n|no) echo "no"; return 0 ;;
            s|skip) echo "skip"; return 0 ;;
            *) echo "Invalid option. Please use 'y', 'n', or 's'." >&2 ;;
        esac
    done
}

echo "========================================"
echo "  Sync-SSH Interactive Setup"
echo "========================================"
echo "Detected OS: $OS_NAME"
echo

GIT_SIGN=$(prompt_option "1. Would you like to enable Git Commit Signing via SSH?" "skip")
KEEP_ALIVE=$(prompt_option "2. Would you like to enable SSH KeepAlive?" "skip")

echo -e "\n3. SSH Agent Mode:"
if [ "$IS_WSL" = true ]; then
    echo "   [1] Bitwarden SSH Agent via Windows pipe bridge (recommended)"
    echo "       Note: Requires socat + npiperelay.exe"
else
    echo "   [1] Bitwarden SSH Agent (recommended)"
fi
echo "   [2] Sync private keys to disk (insecure)"

while true; do
    read -p "   Select Mode (1/2) [1]: " AGENT_MODE_INPUT
    [ -z "$AGENT_MODE_INPUT" ] && AGENT_MODE_INPUT="1"
    
    if [ "$AGENT_MODE_INPUT" = "1" ]; then
        AGENT_MODE="bitwarden"
        break
    elif [ "$AGENT_MODE_INPUT" = "2" ]; then
        AGENT_MODE="disk"
        echo -e "\n   \e[33mWARNING: Mode 2 exports your private SSH keys to disk in plain text.\e[0m"
        break
    else
        echo "   Invalid option. Please enter 1 or 2." >&2
    fi
done

echo -e "\n========================================"
echo "Configuration Summary:"
echo "  OS:               $OS_NAME"
echo "  Git SSH Signing:  $GIT_SIGN"
echo "  SSH KeepAlive:    $KEEP_ALIVE"
echo "  Agent Mode:       $AGENT_MODE"
echo "========================================"
echo

read -p "Proceed with these settings? (y/n) [y]: " CONFIRM
CONFIRM=$(echo "$CONFIRM" | tr '[:upper:]' '[:lower:]')
[ -z "$CONFIRM" ] && CONFIRM="y"

if [ "$CONFIRM" != "y" ] && [ "$CONFIRM" != "yes" ]; then
    echo "Setup aborted."
    exit 1
fi

# Persist preferences
git config --global sync-ssh.commit-signing "$GIT_SIGN"
git config --global sync-ssh.keep-alive "$KEEP_ALIVE"
git config --global sync-ssh.agent-mode "$AGENT_MODE"

mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"

echo "# Managed by Sync-SSH (ssh repo)" > "$CONFIG_FILE"
chmod 600 "$CONFIG_FILE"

if [ "$IS_WSL" = true ]; then
    echo "Configuring WSL integration..."

    cat <<EOF >> "$CONFIG_FILE"
# WSL-specific: Bridge Bitwarden SSH agent to native Linux ssh
AGENT_MODE=\$(git config sync-ssh.agent-mode)
if [ "\$AGENT_MODE" = "bitwarden" ] || [ -z "\$AGENT_MODE" ]; then
    export SSH_AUTH_SOCK="\$HOME/.bitwarden-ssh-agent.sock"

    # Use pgrep to check if socat is already running instead of probing with ssh-add,
    # as concurrent probes (e.g. from Zellij opening multiple panes) can overwhelm
    # and deadlock the Bitwarden Windows named pipe.
    if ! pgrep -f "socat UNIX-LISTEN:\$SSH_AUTH_SOCK" > /dev/null; then
        rm -f "\$SSH_AUTH_SOCK"
        (setsid socat UNIX-LISTEN:"\$SSH_AUTH_SOCK",fork \\
            EXEC:"npiperelay.exe -ei -s //./pipe/openssh-ssh-agent",nofork \\
            &>/dev/null &)
    fi

    # Ensure native Linux ssh is preferred over Windows ssh.exe (WSL interop PATH ordering)
    export PATH="/usr/bin:\$PATH"
fi

sync-ssh() {
    if [ -z "\$BW_SESSION" ] || [ "\$(bw status | jq -r '.status')" = "locked" ]; then
        echo "Unlocking Bitwarden Vault..."
        export BW_SESSION=\$(bw unlock --raw | grep -oE '[A-Za-z0-9+/=_-]{80,}' | tail -n 1)
    fi
    bash "$SYNC_SH"
}

# Helper to forcefully restart the SSH bridge if the connection ever dies
# (e.g. if Bitwarden is restarted on Windows)
reset-ssh-agent() {
    echo "Resetting Bitwarden SSH Agent bridge..."
    pkill -f "socat UNIX-LISTEN:\$SSH_AUTH_SOCK" 2>/dev/null
    pkill -f "npiperelay.exe" 2>/dev/null
    rm -f "\$SSH_AUTH_SOCK"

    (setsid socat UNIX-LISTEN:"\$SSH_AUTH_SOCK",fork \\
        EXEC:"npiperelay.exe -ei -s //./pipe/openssh-ssh-agent",nofork \\
        &>/dev/null &)

    echo "Bridge restarted. Testing connection..."
    sleep 1
    ssh-add -l
}
EOF
else
    echo "Configuring Linux integration..."

    cat <<EOF >> "$CONFIG_FILE"
# Linux-specific: Use Bitwarden SSH Agent if enabled
AGENT_MODE=\$(git config sync-ssh.agent-mode)
if [ "\$AGENT_MODE" = "bitwarden" ] || [ -z "\$AGENT_MODE" ]; then
    # Default Bitwarden path. Adjust if using Snap or custom location.
    if [ -S "$DEFAULT_BW_SOCK" ]; then
        export SSH_AUTH_SOCK="$DEFAULT_BW_SOCK"
    elif [ -z "\$SSH_AUTH_SOCK" ] || [ ! -S "\$SSH_AUTH_SOCK" ]; then
        export SSH_AUTH_SOCK="$DEFAULT_BW_SOCK"
        echo "Warning: Bitwarden SSH Agent socket not found at \$SSH_AUTH_SOCK"
        echo "Ensure 'SSH Agent' is enabled in Bitwarden Desktop settings."
    fi
fi

sync-ssh() {
    if [ -z "\$BW_SESSION" ]; then
        echo "Unlocking Bitwarden Vault..."
        export BW_SESSION=\$(bw unlock --raw)
    fi
    bash "$SYNC_SH"
}
EOF
fi

echo "Created $CONFIG_FILE"
echo "Please add the following line to your .zshrc or .bashrc:"
echo "source $CONFIG_FILE"

# Finally ask if user wants to sync right away
echo
read -p "Do you want to sync SSH keys right away? (y/n) [n]: " RUN_SYNC
RUN_SYNC=$(echo "$RUN_SYNC" | tr '[:upper:]' '[:lower:]')
if [ "$RUN_SYNC" = "y" ] || [ "$RUN_SYNC" = "yes" ]; then
    echo "Running sync..."
    bash "$SYNC_SH"
fi
