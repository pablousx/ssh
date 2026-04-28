#!/bin/bash

# Detect environment
IS_WSL=false
if [ -n "$WSL_DISTRO_NAME" ] || [ -n "$WSL_INTEROP" ] || [ -f /proc/version ] && grep -qi microsoft /proc/version; then
    IS_WSL=true
fi

# Paths
REPO_ROOT=$(realpath "$(dirname "$0")/..")
SYNC_SH="$REPO_ROOT/linux/sync.sh"
SYNC_PS1="$REPO_ROOT/windows/sync.ps1"
CONFIG_FILE="$HOME/.ssh/sync-ssh-env.sh"

mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"

echo "# Managed by Sync-SSH (ssh repo)" > "$CONFIG_FILE"
chmod 600 "$CONFIG_FILE"

if [ "$IS_WSL" = true ]; then
    echo "Configuring WSL for Windows SSH Agent..."

    cat <<EOF >> "$CONFIG_FILE"
# WSL-specific: Bridge Bitwarden SSH agent to native Linux ssh
export SSH_AUTH_SOCK="\$HOME/.ssh/bitwarden-agent.sock"

ssh-add -l &>/dev/null
if [ \$? -eq 2 ] || [ ! -S "\$SSH_AUTH_SOCK" ]; then
    rm -f "\$SSH_AUTH_SOCK"
    (setsid socat UNIX-LISTEN:"\$SSH_AUTH_SOCK",fork \\
        EXEC:"npiperelay.exe -ei -s //./pipe/openssh-ssh-agent",nofork \\
        &>/dev/null &)
fi

alias sync-ssh='bash "$REPO_ROOT/linux/sync.sh"'

# Optional GPG configuration (for commit signing)
# Uncomment and adjust as needed if you want to sign commits:
# if command -v gpg.exe &>/dev/null; then
#   git config --global gpg.program "gpg.exe"
# else
#   git config --global gpg.program "gpg"
# fi
# git config --global commit.gpgsign true
# export GPG_TTY=\$(tty 2>/dev/null || echo "notty")
EOF
else
    echo "Configuring Linux for Native SSH Agent..."

    cat <<EOF >> "$CONFIG_FILE"
# Linux-specific: Use native SSH Agent
alias sync-ssh='bash "$SYNC_SH"'

# Optional GPG configuration (for commit signing)
# Uncomment if you want to sign commits:
# git config --global gpg.program "gpg"
# git config --global commit.gpgsign true
# export GPG_TTY=\$(tty 2>/dev/null || echo "notty")
EOF
fi

echo "Created $CONFIG_FILE"
echo "Please add the following line to your .zshrc or .bashrc:"
echo "source $CONFIG_FILE"
