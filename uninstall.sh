#!/bin/sh
set -eu

ENV_FILE="$HOME/.ssh/sync-ssh-env.sh"
INSTALL_DIR="$HOME/.local/share/sync-ssh"
MANAGED_ROOT="$HOME/.ssh/sync-ssh"
MAIN_CONFIG="$HOME/.ssh/config"
APP_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/sync-ssh"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/sync-ssh"
GIT_STATE_DIR="$STATE_DIR/git"
INCLUDE_LINE="Include ~/.ssh/sync-ssh/current/config"
START_MARKER="# --- START SYNC-SSH MANAGED SECTION ---"
END_MARKER="# --- END SYNC-SSH MANAGED SECTION ---"

if [ -L "$MAIN_CONFIG" ]; then
    resolved_main=$(readlink -f -- "$MAIN_CONFIG") || {
        printf "Unable to resolve SSH config symlink: %s\n" "$MAIN_CONFIG" >&2
        exit 1
    }
    MAIN_CONFIG=$resolved_main
fi

confirm() {
    printf "%s (y/n) [n]: " "$1"
    read -r reply </dev/tty
    reply=$(printf '%s' "$reply" | tr '[:upper:]' '[:lower:]')
    [ "$reply" = "y" ] || [ "$reply" = "yes" ]
}

safe_replace() {
    source_file=$1
    generated_file=$2
    chmod --reference="$source_file" "$generated_file" 2>/dev/null || chmod 600 "$generated_file"
    mv "$generated_file" "$source_file"
}

restore_git_setting() {
    slug=$1
    state_path="$GIT_STATE_DIR/$slug"
    [ -d "$state_path" ] || return 0
    command -v git >/dev/null 2>&1 || {
        printf "Git is unavailable; preserving state for manual restoration: %s\n" "$state_path" >&2
        return 0
    }
    git_key=$(case "$slug" in
        gpg-format) printf "gpg.format" ;;
        user-signingkey) printf "user.signingkey" ;;
        commit-gpgsign) printf "commit.gpgsign" ;;
        allowed-signers-file) printf "gpg.ssh.allowedSignersFile" ;;
    esac)
    current=$(git config --global --get "$git_key" 2>/dev/null || true)
    owned=$(cat "$state_path/owned")
    if [ "$current" = "$owned" ]; then
        if [ -f "$state_path/was-present" ]; then
            git config --global "$git_key" "$(cat "$state_path/previous")"
        else
            git config --global --unset-all "$git_key" 2>/dev/null || true
        fi
    else
        printf "Preserving user-modified Git setting: %s\n" "$git_key"
    fi
    rm -rf -- "$state_path"
}

printf "========================================\n"
printf "  Sync-SSH Uninstaller\n"
printf "========================================\n"

if [ -f "$STATE_DIR/bridge.pid" ]; then
    bridge_pid=$(cat "$STATE_DIR/bridge.pid")
    case "$bridge_pid" in
        *[!0-9]*|"") ;;
        *)
            if ps -p "$bridge_pid" -o args= 2>/dev/null |
                grep -F "socat UNIX-LISTEN:$HOME/.bitwarden-ssh-agent.sock" >/dev/null; then
                kill "$bridge_pid" 2>/dev/null || true
            fi
            ;;
    esac
    rm -f "$STATE_DIR/bridge.pid" "$HOME/.bitwarden-ssh-agent.sock"
fi

printf "Removing shell profile entries...\n"
for profile in "$HOME/.zshrc" "$HOME/.bashrc" "$HOME/.bash_profile" "$HOME/.profile"; do
    [ -f "$profile" ] || continue
    temp_profile="${profile}.sync-ssh-uninstall.$$"
    awk -v env_file="$ENV_FILE" '
        $0 == "# Added by Bitwarden SSH Sync setup" { next }
        $0 == ". \"$HOME/.ssh/sync-ssh-env.sh\"" { next }
        $0 == "source " env_file { next }
        { print }
    ' "$profile" >"$temp_profile"
    if ! cmp -s "$profile" "$temp_profile"; then
        safe_replace "$profile" "$temp_profile"
        printf "  Cleaned: %s\n" "$profile"
    else
        rm -f "$temp_profile"
    fi
done

rm -f "$ENV_FILE"
[ ! -d "$INSTALL_DIR" ] || rm -rf -- "$INSTALL_DIR"

if confirm "Remove the generated SSH configuration and keys from $MANAGED_ROOT?"; then
    [ ! -d "$MANAGED_ROOT" ] || rm -rf -- "$MANAGED_ROOT"
    printf "Removed tool-owned SSH files.\n"
fi

if confirm "Remove the sync-ssh Include line or legacy managed block from $MAIN_CONFIG?"; then
    if [ -f "$MAIN_CONFIG" ]; then
        start_count=$(grep -cF "$START_MARKER" "$MAIN_CONFIG" || true)
        end_count=$(grep -cF "$END_MARKER" "$MAIN_CONFIG" || true)
        if [ "$start_count" -ne "$end_count" ] || [ "$start_count" -gt 1 ]; then
            printf "Malformed legacy markers found; refusing to edit %s.\n" "$MAIN_CONFIG" >&2
        else
            temp_config="${MAIN_CONFIG}.sync-ssh-uninstall.$$"
            awk -v include="$INCLUDE_LINE" -v start="$START_MARKER" -v end="$END_MARKER" '
                $0 == start { skip=1; next }
                $0 == end && skip { skip=0; next }
                $0 == include { next }
                $0 == "# Added by Bitwarden SSH Sync" { next }
                !skip { print }
                END { if (skip) exit 42 }
            ' "$MAIN_CONFIG" >"$temp_config" || {
                rm -f "$temp_config"
                printf "Unable to safely edit %s.\n" "$MAIN_CONFIG" >&2
                exit 1
            }
            safe_replace "$MAIN_CONFIG" "$temp_config"
            chmod 600 "$MAIN_CONFIG"
        fi
    fi
fi

if confirm "Restore Git settings previously changed by Sync-SSH?"; then
    restore_git_setting allowed-signers-file
    restore_git_setting commit-gpgsign
    restore_git_setting user-signingkey
    restore_git_setting gpg-format
fi

if command -v git >/dev/null 2>&1; then
    git config --global --unset-all sync-ssh.commit-signing 2>/dev/null || true
    git config --global --unset-all sync-ssh.keep-alive 2>/dev/null || true
    git config --global --unset-all sync-ssh.agent-mode 2>/dev/null || true
    git config --global --unset-all sync-ssh.export-private-keys 2>/dev/null || true
fi

[ ! -d "$APP_CONFIG_DIR" ] || rm -rf -- "$APP_CONFIG_DIR"
if [ -d "$STATE_DIR" ] && [ -z "$(find "$STATE_DIR" -mindepth 1 -maxdepth 1 -print -quit)" ]; then
    rmdir "$STATE_DIR"
fi

printf "\nSync-SSH has been uninstalled. Restart your shell to remove loaded functions.\n"
