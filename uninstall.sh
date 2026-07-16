#!/bin/sh
set -e

CONFIG_FILE="$HOME/.ssh/sync-ssh-env.sh"
INSTALL_DIR="$HOME/.local/share/sync-ssh"
KEYS_DIR="$HOME/.ssh/keys"

echo "========================================"
echo "  Sync-SSH Uninstaller"
echo "========================================"
echo

# Helper
confirm() {
    printf "%s (y/n) [n]: " "$1"
    read -r REPLY
    REPLY=$(echo "$REPLY" | tr '[:upper:]' '[:lower:]')
    [ "$REPLY" = "y" ] || [ "$REPLY" = "yes" ]
}

# 1. Remove source line from shell profiles
echo "Removing shell profile entries..."
for PROFILE in "$HOME/.zshrc" "$HOME/.bashrc" "$HOME/.bash_profile" "$HOME/.profile"; do
    if [ -f "$PROFILE" ]; then
        # Remove the comment line and the source line together (both added by setup)
        if grep -qF "sync-ssh-env.sh" "$PROFILE"; then
            # Use a temp file for portable in-place editing
            TMPFILE=$(mktemp)
            grep -v "# Added by Bitwarden SSH Sync setup" "$PROFILE" \
                | grep -v "sync-ssh-env.sh" > "$TMPFILE"
            mv "$TMPFILE" "$PROFILE"
            echo "  Cleaned: $PROFILE"
        fi
    fi
done

# 2. Remove the env/config file
if [ -f "$CONFIG_FILE" ]; then
    rm -f "$CONFIG_FILE"
    echo "Removed: $CONFIG_FILE"
fi

# 3. Remove the install directory (one-liner install)
if [ -d "$INSTALL_DIR" ]; then
    rm -rf "$INSTALL_DIR"
    echo "Removed: $INSTALL_DIR"
fi

# 4. Optionally remove synced public keys
echo
if confirm "Remove synced public keys from $KEYS_DIR?"; then
    if [ -d "$KEYS_DIR" ]; then
        rm -rf "$KEYS_DIR"
        echo "Removed: $KEYS_DIR"
    else
        echo "  $KEYS_DIR not found, skipping."
    fi
fi

# 5. Optionally clean the managed block from ~/.ssh/config
echo
if confirm "Remove the managed SSH config block from ~/.ssh/config?"; then
    SSH_CONFIG="$HOME/.ssh/config"
    if [ -f "$SSH_CONFIG" ]; then
        START_MARKER="# --- START SYNC-SSH MANAGED SECTION ---"
        END_MARKER="# --- END SYNC-SSH MANAGED SECTION ---"
        TMPFILE=$(mktemp)
        awk -v start="$START_MARKER" -v end="$END_MARKER" '
            $0 == start { skip=1; next }
            $0 == end   { skip=0; next }
            !skip        { print }
        ' "$SSH_CONFIG" > "$TMPFILE"
        mv "$TMPFILE" "$SSH_CONFIG"
        chmod 600 "$SSH_CONFIG"
        echo "  Managed block removed from $SSH_CONFIG"
    else
        echo "  $HOME/.ssh/config not found, skipping."
    fi
fi

# 6. Optionally remove git config entries
echo
if confirm "Remove Sync-SSH git config entries (sync-ssh.* globals)?"; then
    git config --global --unset sync-ssh.commit-signing 2>/dev/null || true
    git config --global --unset sync-ssh.keep-alive     2>/dev/null || true
    git config --global --unset sync-ssh.agent-mode     2>/dev/null || true
    echo "  Git config entries removed."
fi

echo
echo "========================================"
echo "  Sync-SSH has been uninstalled."
echo "  Restart your shell to apply changes."
echo "========================================"
