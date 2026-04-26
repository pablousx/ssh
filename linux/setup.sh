#!/bin/bash

# =========== SSH Config Setup Script ===========

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
SYNC_SCRIPT="$SCRIPT_DIR/sync.sh"

add_to_shell_profile() {
    local PROFILE_FILE=""
    
    # Detect shell
    if [[ "$SHELL" == */zsh ]]; then
        PROFILE_FILE="$HOME/.zshrc"
    else
        PROFILE_FILE="$HOME/.bashrc"
    fi

    local ALIAS_LINE="alias sync-ssh='$SYNC_SCRIPT'"

    if [ -f "$PROFILE_FILE" ]; then
        if ! grep -q "alias sync-ssh" "$PROFILE_FILE"; then
            echo -e "\n# Sync SSH keys from Bitwarden\n$ALIAS_LINE" >> "$PROFILE_FILE"
            echo -e "\e[32m[OK] Added sync-ssh alias to $PROFILE_FILE\e[0m"
            echo -e "\e[36m   Restart your terminal or run: source $PROFILE_FILE\e[0m"
        else
            echo -e "\e[37m[INFO] sync-ssh alias already in $PROFILE_FILE, skipping.\e[0m"
        fi
    else
        echo -e "\e[31m[ERROR] Could not find profile file ($PROFILE_FILE)\e[0m"
    fi
}

echo "========================================"
echo "  SSH Config with Bitwarden - Setup"
echo "========================================="
echo ""

# Make sync script executable
chmod +x "$SYNC_SCRIPT"

# Add alias to profile
add_to_shell_profile

echo ""
echo -e "\e[32mSetup complete!\e[0m"
echo -e "\e[36m   Run 'sync-ssh' to sync your SSH keys\e[0m"
