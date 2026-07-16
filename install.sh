#!/bin/sh
set -e

REPO_URL="https://raw.githubusercontent.com/pablousx/ssh/main"
INSTALL_DIR="$HOME/.local/share/sync-ssh"

echo "Installing Bitwarden SSH Sync..."

# Check OS
if [ "$(uname -s)" = "Windows_NT" ]; then
    echo "This one-liner is for Linux/WSL. For Windows, please see the README."
    exit 1
fi

# Ensure curl is installed
if ! command -v curl > /dev/null 2>&1; then
    echo "Error: curl is required to install."
    exit 1
fi

mkdir -p "$INSTALL_DIR"

echo "Downloading scripts to $INSTALL_DIR..."
curl -fsSL "$REPO_URL/linux/setup.sh" -o "$INSTALL_DIR/setup.sh"
curl -fsSL "$REPO_URL/linux/sync.sh" -o "$INSTALL_DIR/sync.sh"
chmod +x "$INSTALL_DIR/setup.sh" "$INSTALL_DIR/sync.sh"

# Run setup
cd "$INSTALL_DIR"
./setup.sh < /dev/tty
