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

echo "# Managed by Sync-SSH (ssh repo)" > "$CONFIG_FILE"

if [ "$IS_WSL" = true ]; then
    echo "Configuring WSL for Windows SSH Agent..."

    cat <<EOF >> "$CONFIG_FILE"
# WSL-specific: Use Windows OpenSSH Agent
alias ssh='ssh.exe'
alias ssh-add='ssh-add.exe'
alias scp='scp.exe'
alias sftp='sftp.exe'
alias sync-ssh='powershell.exe "Sync-SSH"'

# Ensure git uses Windows SSH
git config --global core.sshCommand "ssh.exe"
EOF
else
    echo "Configuring Linux for Native SSH Agent..."

    cat <<EOF >> "$CONFIG_FILE"
# Linux-specific: Use native SSH Agent
alias sync-ssh='bash "$SYNC_SH"'
EOF
fi

echo "Created $CONFIG_FILE"
echo "Please add the following line to your .zshrc or .bashrc:"
echo "source $CONFIG_FILE"
