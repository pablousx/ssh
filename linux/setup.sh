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

prompt_option() {
    local prompt_text="$1"
    local default_val="$2"
    local user_input

    while true; do
        read -p "$prompt_text (enable [e], disable [d], skip [s]) [$default_val]: " user_input
        user_input=$(echo "$user_input" | tr '[:upper:]' '[:lower:]')
        [ -z "$user_input" ] && user_input="$default_val"

        case "$user_input" in
            e|enable) echo "enable"; return 0 ;;
            d|disable) echo "disable"; return 0 ;;
            s|skip) echo "skip"; return 0 ;;
            *) echo "Invalid option. Please use 'e', 'd', or 's'." >&2 ;;
        esac
    done
}

echo "========================================"
echo "  Sync-SSH Interactive Setup"
echo "========================================"
echo "Detected OS: $OS_NAME"
echo

GIT_SIGN=$(prompt_option "1. Git Commit Signing via SSH" "skip")
KEEP_ALIVE=$(prompt_option "2. SSH KeepAlive" "skip")

WSL_BRIDGE="skip"
if [ "$IS_WSL" = true ]; then
    WSL_BRIDGE=$(prompt_option "3. WSL SSH Agent Bridge" "enable")
fi

echo
echo "========================================"
echo "Final Confirmation:"
echo "  OS:               $OS_NAME"
echo "  Git SSH Signing:  $GIT_SIGN"
echo "  SSH KeepAlive:    $KEEP_ALIVE"
if [ "$IS_WSL" = true ]; then
    echo "  WSL Agent Bridge: $WSL_BRIDGE"
fi
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
[ "$IS_WSL" = true ] && git config --global sync-ssh.wsl-bridge "$WSL_BRIDGE"

mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"

echo "# Managed by Sync-SSH (ssh repo)" > "$CONFIG_FILE"
chmod 600 "$CONFIG_FILE"

if [ "$IS_WSL" = true ]; then
    echo "Configuring WSL integration..."

    cat <<EOF >> "$CONFIG_FILE"
# WSL-specific: Bridge Bitwarden SSH agent to native Linux ssh
WSL_BRIDGE_PREF=\$(git config sync-ssh.wsl-bridge)
if [ "\$WSL_BRIDGE_PREF" = "enable" ] || [ -z "\$WSL_BRIDGE_PREF" ] || [ "\$WSL_BRIDGE_PREF" = "skip" ]; then
    export SSH_AUTH_SOCK="\$HOME/.ssh/bitwarden-agent.sock"

    ssh-add -l &>/dev/null
    if [ \$? -eq 2 ] || [ ! -S "\$SSH_AUTH_SOCK" ]; then
        rm -f "\$SSH_AUTH_SOCK"
        (setsid socat UNIX-LISTEN:"\$SSH_AUTH_SOCK",fork \\
            EXEC:"npiperelay.exe -ei -s //./pipe/openssh-ssh-agent",nofork \\
            &>/dev/null &)
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
else
    echo "Configuring Linux integration..."

    cat <<EOF >> "$CONFIG_FILE"
# Linux-specific: Use native SSH Agent
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
