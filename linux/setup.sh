#!/bin/sh
set -eu

IS_WSL=false
OS_NAME="Linux"
if [ -n "${WSL_DISTRO_NAME:-}" ] || [ -n "${WSL_INTEROP:-}" ] ||
    { [ -f /proc/version ] && grep -qi microsoft /proc/version; }; then
    IS_WSL=true
    OS_NAME="Linux (WSL: ${WSL_DISTRO_NAME:-unknown})"
fi

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd -P)
if [ "$SCRIPT_DIR" = "$HOME/.local/share/sync-ssh" ]; then
    SYNC_SH="$SCRIPT_DIR/sync.sh"
else
    REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd -P)
    SYNC_SH="$REPO_ROOT/linux/sync.sh"
fi

CONFIG_FILE="$HOME/.ssh/sync-ssh-env.sh"
APP_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/sync-ssh"
PREFERENCES_FILE="$APP_CONFIG_DIR/config"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/sync-ssh"
DEFAULT_BW_SOCK="$HOME/.bitwarden-ssh-agent.sock"

read_preference() {
    key=$1
    fallback=$2
    value=""
    if [ -f "$PREFERENCES_FILE" ]; then
        value=$(awk -F= -v key="$key" '$1 == key { sub(/^[^=]*=/, ""); print; exit }' "$PREFERENCES_FILE")
    elif command -v git >/dev/null 2>&1; then
        case "$key" in
            commit_signing) value=$(git config --global --get sync-ssh.commit-signing 2>/dev/null || true) ;;
            keep_alive) value=$(git config --global --get sync-ssh.keep-alive 2>/dev/null || true) ;;
            agent_mode) value=$(git config --global --get sync-ssh.agent-mode 2>/dev/null || true) ;;
        esac
    fi
    [ -n "$value" ] || value=$fallback
    printf '%s\n' "$value"
}

prompt_option() {
    prompt_text=$1
    current_value=$2
    while :; do
        printf "%s (yes [y], no [n], preserve [s]) [s]: " "$prompt_text" >&2
        read -r user_input
        user_input=$(printf '%s' "$user_input" | tr '[:upper:]' '[:lower:]')
        [ -n "$user_input" ] || user_input="skip"
        case "$user_input" in
            y|yes) printf "yes\n"; return ;;
            n|no) printf "no\n"; return ;;
            s|skip|preserve) printf "%s\n" "$current_value"; return ;;
            *) printf "Invalid option. Use 'y', 'n', or 's'.\n" >&2 ;;
        esac
    done
}

current_signing=$(read_preference commit_signing skip)
current_keep_alive=$(read_preference keep_alive skip)
current_agent_mode=$(read_preference agent_mode bitwarden)

printf "========================================\n"
printf "  Sync-SSH Interactive Setup\n"
printf "========================================\n"
printf "Detected OS: %s\n\n" "$OS_NAME"

GIT_SIGN=$(prompt_option "1. Enable Git commit signing via SSH? Current: $current_signing" "$current_signing")
KEEP_ALIVE=$(prompt_option "2. Enable SSH KeepAlive? Current: $current_keep_alive" "$current_keep_alive")

printf "\n3. SSH key mode:\n"
if [ "$IS_WSL" = true ]; then
    printf "   [1] Bitwarden SSH Agent via the Windows pipe bridge (recommended)\n"
else
    printf "   [1] Bitwarden SSH Agent (recommended)\n"
fi
printf "   [2] Export private keys to the tool-owned directory (higher risk)\n"
printf "   [s] Preserve current mode (%s)\n" "$current_agent_mode"

while :; do
    printf "   Select mode (1/2/s) [s]: "
    read -r mode_input
    mode_input=$(printf '%s' "$mode_input" | tr '[:upper:]' '[:lower:]')
    [ -n "$mode_input" ] || mode_input="s"
    case "$mode_input" in
        1) AGENT_MODE="bitwarden"; break ;;
        2)
            AGENT_MODE="disk"
            printf "\033[33mWARNING: Disk mode exports private SSH keys in plaintext with user-only permissions.\033[0m\n"
            printf "Type 'export private keys' to confirm: "
            read -r disk_confirmation
            [ "$disk_confirmation" = "export private keys" ] || {
                printf "Disk mode was not confirmed.\n" >&2
                continue
            }
            break
            ;;
        s|skip|preserve) AGENT_MODE=$current_agent_mode; break ;;
        *) printf "Invalid option. Enter 1, 2, or s.\n" >&2 ;;
    esac
done

printf "\nConfiguration summary:\n"
printf "  OS:              %s\n" "$OS_NAME"
printf "  Git SSH signing: %s\n" "$GIT_SIGN"
printf "  SSH KeepAlive:   %s\n" "$KEEP_ALIVE"
printf "  SSH key mode:    %s\n" "$AGENT_MODE"
printf "Proceed? (y/n) [y]: "
read -r confirmation
confirmation=$(printf '%s' "$confirmation" | tr '[:upper:]' '[:lower:]')
[ -n "$confirmation" ] || confirmation="y"
case "$confirmation" in y|yes) ;; *) printf "Setup aborted.\n"; exit 1 ;; esac

if [ "$IS_WSL" = true ] && [ "$AGENT_MODE" = "bitwarden" ]; then
    command -v socat >/dev/null 2>&1 || {
        printf "Error: socat is required for WSL agent mode.\n" >&2
        exit 1
    }
    command -v npiperelay.exe >/dev/null 2>&1 || {
        printf "Error: npiperelay.exe is required for WSL agent mode.\n" >&2
        exit 1
    }
fi

mkdir -p "$HOME/.ssh" "$APP_CONFIG_DIR" "$STATE_DIR"
chmod 700 "$HOME/.ssh" "$APP_CONFIG_DIR" "$STATE_DIR"

preferences_temp="$APP_CONFIG_DIR/.config.$$"
{
    printf "commit_signing=%s\n" "$GIT_SIGN"
    printf "keep_alive=%s\n" "$KEEP_ALIVE"
    printf "agent_mode=%s\n" "$AGENT_MODE"
} >"$preferences_temp"
chmod 600 "$preferences_temp"
mv "$preferences_temp" "$PREFERENCES_FILE"

env_temp="$HOME/.ssh/.sync-ssh-env.$$"
printf "# Managed by Bitwarden SSH Sync\n" >"$env_temp"
if [ "$IS_WSL" = true ]; then
    cat >>"$env_temp" <<EOF
SYNC_SSH_AGENT_SOCKET="\$HOME/.bitwarden-ssh-agent.sock"
SYNC_SSH_STATE_DIR="\${XDG_STATE_HOME:-\$HOME/.local/state}/sync-ssh"
SYNC_SSH_AGENT_PID="\$SYNC_SSH_STATE_DIR/bridge.pid"
export SYNC_SSH_AGENT_SOCKET SYNC_SSH_STATE_DIR SYNC_SSH_AGENT_PID

sync-ssh-bridge-running() {
    [ -f "\$SYNC_SSH_AGENT_PID" ] || return 1
    bridge_pid=\$(cat "\$SYNC_SSH_AGENT_PID")
    case "\$bridge_pid" in *[!0-9]*|"") return 1 ;; esac
    kill -0 "\$bridge_pid" 2>/dev/null || return 1
    ps -p "\$bridge_pid" -o args= 2>/dev/null |
        grep -F "socat UNIX-LISTEN:\$SYNC_SSH_AGENT_SOCKET" >/dev/null
}

start-sync-ssh-agent() {
    [ "\$(awk -F= '\$1 == "agent_mode" { print \$2; exit }' "$PREFERENCES_FILE")" = "bitwarden" ] || return 0
    export SSH_AUTH_SOCK="\$SYNC_SSH_AGENT_SOCKET"
    mkdir -p "\$SYNC_SSH_STATE_DIR"
    chmod 700 "\$SYNC_SSH_STATE_DIR"

    if sync-ssh-bridge-running && [ -S "\$SSH_AUTH_SOCK" ]; then
        return 0
    fi

    bridge_lock="\$SYNC_SSH_STATE_DIR/bridge.lock"
    if ! mkdir "\$bridge_lock" 2>/dev/null; then
        return 0
    fi
    if sync-ssh-bridge-running; then
        kill "\$bridge_pid" 2>/dev/null || true
    fi
    rm -f "\$SSH_AUTH_SOCK"
    setsid socat UNIX-LISTEN:"\$SSH_AUTH_SOCK",fork,mode=600 \\
        EXEC:"npiperelay.exe -ei -s //./pipe/openssh-ssh-agent",nofork \\
        >/dev/null 2>&1 &
    printf '%s\n' "\$!" >"\$SYNC_SSH_AGENT_PID"
    rmdir "\$bridge_lock" 2>/dev/null || true
}

reset-ssh-agent() {
    if sync-ssh-bridge-running; then
        kill "\$bridge_pid" 2>/dev/null || true
    fi
    rm -f "\$SYNC_SSH_AGENT_PID" "\$SYNC_SSH_STATE_DIR/bridge.lock"
    rm -f "\$SYNC_SSH_AGENT_SOCKET"
    start-sync-ssh-agent
    ssh-add -l
}

sync-ssh() {
    sh "$SYNC_SH" "\$@"
}

case ":\$PATH:" in
    *:/usr/bin:*) ;;
    *) PATH="/usr/bin:\$PATH"; export PATH ;;
esac
start-sync-ssh-agent
EOF
else
    cat >>"$env_temp" <<EOF
if [ "\$(awk -F= '\$1 == "agent_mode" { print \$2; exit }' "$PREFERENCES_FILE")" = "bitwarden" ]; then
    export SSH_AUTH_SOCK="$DEFAULT_BW_SOCK"
fi

sync-ssh() {
    sh "$SYNC_SH" "\$@"
}
EOF
fi
chmod 600 "$env_temp"
mv "$env_temp" "$CONFIG_FILE"

case "${SHELL:-}" in
    */zsh) PROFILE="$HOME/.zshrc" ;;
    */bash) PROFILE="$HOME/.bashrc" ;;
    *) PROFILE="$HOME/.profile" ;;
esac
[ -f "$PROFILE" ] || : >"$PROFILE"
SOURCE_LINE='. "$HOME/.ssh/sync-ssh-env.sh"'
if ! grep -qF "$SOURCE_LINE" "$PROFILE"; then
    printf "\n# Added by Bitwarden SSH Sync setup\n%s\n" "$SOURCE_LINE" >>"$PROFILE"
    printf "Added Sync-SSH to %s\n" "$PROFILE"
else
    printf "Profile already configured: %s\n" "$PROFILE"
fi

# Preferences now live in the application config file.
if command -v git >/dev/null 2>&1; then
    git config --global --unset-all sync-ssh.commit-signing 2>/dev/null || true
    git config --global --unset-all sync-ssh.keep-alive 2>/dev/null || true
    git config --global --unset-all sync-ssh.agent-mode 2>/dev/null || true
    git config --global --unset-all sync-ssh.export-private-keys 2>/dev/null || true
fi

printf "\nRun a sync now? (y/n) [n]: "
read -r run_sync
run_sync=$(printf '%s' "$run_sync" | tr '[:upper:]' '[:lower:]')
case "$run_sync" in
    y|yes)
        if ! sh "$SYNC_SH"; then
            printf "Initial sync failed. Setup remains installed; run sync-ssh to retry.\n" >&2
        fi
        ;;
esac

printf "\nSetup complete.\n"
printf "Restart your shell or run: . \"\$HOME/.ssh/sync-ssh-env.sh\"\n"
printf "Then run: sync-ssh\n"
