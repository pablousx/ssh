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
if [ "$SCRIPT_DIR" = "$HOME/.local/share/sshwitch" ]; then
    SSHWITCH_SH="$SCRIPT_DIR/sync.sh"
else
    REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd -P)
    SSHWITCH_SH="$REPO_ROOT/linux/sync.sh"
fi

CONFIG_FILE="$HOME/.ssh/sshwitch-env.sh"
LEGACY_CONFIG_FILE="$HOME/.ssh/sync-ssh-env.sh"
APP_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/sshwitch"
PREFERENCES_FILE="$APP_CONFIG_DIR/config"
LEGACY_PREFERENCES_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/sync-ssh/config"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/sshwitch"
LEGACY_STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/sync-ssh"
DEFAULT_BW_SOCK="$HOME/.bitwarden-ssh-agent.sock"

read_preference() {
    key=$1
    fallback=$2
    value=""
    preferences_source=$PREFERENCES_FILE
    if [ ! -f "$preferences_source" ] && [ -f "$LEGACY_PREFERENCES_FILE" ]; then
        preferences_source=$LEGACY_PREFERENCES_FILE
    fi
    if [ -f "$preferences_source" ]; then
        value=$(awk -F= -v key="$key" '$1 == key { sub(/^[^=]*=/, ""); print; exit }' "$preferences_source")
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
current_provider=$(read_preference provider bitwarden)
current_identity_backend=$(read_preference identity_backend "")
current_private_key_policy=$(read_preference private_key_policy "")
legacy_agent_mode=$(read_preference agent_mode "")
if [ -z "$current_identity_backend" ]; then
    case "$legacy_agent_mode" in
        disk) current_identity_backend="disk" ;;
        *) current_identity_backend="agent" ;;
    esac
fi
if [ -z "$current_private_key_policy" ]; then
    case "$current_identity_backend" in
        disk) current_private_key_policy="export" ;;
        *) current_private_key_policy="never" ;;
    esac
fi
printf '%s' "$current_provider" | grep -Eq '^[a-z0-9][a-z0-9-]*$' || {
    printf "Invalid provider preference: %s\n" "$current_provider" >&2
    exit 1
}
case "$current_identity_backend:$current_private_key_policy" in
    agent:never|disk:export) ;;
    *)
        printf "Invalid identity backend/private-key policy combination: %s/%s\n" \
            "$current_identity_backend" "$current_private_key_policy" >&2
        exit 1
        ;;
esac

printf "========================================\n"
printf "  SSHwitch Interactive Setup\n"
printf "========================================\n"
printf "Detected OS: %s\n\n" "$OS_NAME"
printf "Source provider: %s\n\n" "$current_provider"

GIT_SIGN=$(prompt_option "1. Enable Git commit signing via SSH? Current: $current_signing" "$current_signing")
KEEP_ALIVE=$(prompt_option "2. Enable SSH KeepAlive? Current: $current_keep_alive" "$current_keep_alive")

printf "\n3. Identity backend:\n"
if [ "$IS_WSL" = true ]; then
    printf "   [1] %s SSH Agent via the Windows pipe bridge (recommended)\n" "$current_provider"
else
    printf "   [1] %s SSH Agent (recommended)\n" "$current_provider"
fi
printf "   [2] Export private keys to the tool-owned directory (higher risk)\n"
printf "   [s] Preserve current backend (%s)\n" "$current_identity_backend"

while :; do
    printf "   Select mode (1/2/s) [s]: "
    read -r mode_input
    mode_input=$(printf '%s' "$mode_input" | tr '[:upper:]' '[:lower:]')
    [ -n "$mode_input" ] || mode_input="s"
    case "$mode_input" in
        1) IDENTITY_BACKEND="agent"; PRIVATE_KEY_POLICY="never"; break ;;
        2)
            IDENTITY_BACKEND="disk"
            PRIVATE_KEY_POLICY="export"
            printf "\033[33mWARNING: Disk mode exports private SSH keys in plaintext with user-only permissions.\033[0m\n"
            printf "Type 'export private keys' to confirm: "
            read -r disk_confirmation
            [ "$disk_confirmation" = "export private keys" ] || {
                printf "Disk mode was not confirmed.\n" >&2
                continue
            }
            break
            ;;
        s|skip|preserve)
            IDENTITY_BACKEND=$current_identity_backend
            PRIVATE_KEY_POLICY=$current_private_key_policy
            break
            ;;
        *) printf "Invalid option. Enter 1, 2, or s.\n" >&2 ;;
    esac
done

printf "\nConfiguration summary:\n"
printf "  OS:              %s\n" "$OS_NAME"
printf "  Git SSH signing: %s\n" "$GIT_SIGN"
printf "  SSH KeepAlive:   %s\n" "$KEEP_ALIVE"
printf "  Provider:        %s\n" "$current_provider"
printf "  Identity backend:%s\n" " $IDENTITY_BACKEND"
printf "  Private keys:    %s\n" "$PRIVATE_KEY_POLICY"
printf "Proceed? (y/n) [y]: "
read -r confirmation
confirmation=$(printf '%s' "$confirmation" | tr '[:upper:]' '[:lower:]')
[ -n "$confirmation" ] || confirmation="y"
case "$confirmation" in y|yes) ;; *) printf "Setup aborted.\n"; exit 1 ;; esac

if [ "$IS_WSL" = true ] && [ "$IDENTITY_BACKEND" = "agent" ]; then
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
if [ ! -d "$STATE_DIR/git" ] && [ -d "$LEGACY_STATE_DIR/git" ]; then
    cp -pR "$LEGACY_STATE_DIR/git" "$STATE_DIR/git"
    chmod 700 "$STATE_DIR/git"
    find "$STATE_DIR/git" -type d -exec chmod 700 {} \;
    find "$STATE_DIR/git" -type f -exec chmod 600 {} \;
fi
if [ ! -f "$STATE_DIR/bridge.pid" ] && [ -f "$LEGACY_STATE_DIR/bridge.pid" ]; then
    cp -p "$LEGACY_STATE_DIR/bridge.pid" "$STATE_DIR/bridge.pid"
    chmod 600 "$STATE_DIR/bridge.pid"
fi

preferences_temp="$APP_CONFIG_DIR/.config.$$"
{
    printf "version=2\n"
    printf "provider=%s\n" "$current_provider"
    printf "identity_backend=%s\n" "$IDENTITY_BACKEND"
    printf "private_key_policy=%s\n" "$PRIVATE_KEY_POLICY"
    printf "commit_signing=%s\n" "$GIT_SIGN"
    printf "keep_alive=%s\n" "$KEEP_ALIVE"
} >"$preferences_temp"
chmod 600 "$preferences_temp"
mv "$preferences_temp" "$PREFERENCES_FILE"

env_temp="$HOME/.ssh/.sshwitch-env.$$"
printf "# Managed by SSHwitch\n" >"$env_temp"
if [ "$IS_WSL" = true ]; then
    cat >>"$env_temp" <<EOF
SSHWITCH_AGENT_SOCKET="\$HOME/.bitwarden-ssh-agent.sock"
SSHWITCH_STATE_DIR="\${XDG_STATE_HOME:-\$HOME/.local/state}/sshwitch"
SSHWITCH_AGENT_PID="\$SSHWITCH_STATE_DIR/bridge.pid"
export SSHWITCH_AGENT_SOCKET SSHWITCH_STATE_DIR SSHWITCH_AGENT_PID

sshwitch_agent_enabled() {
    identity_backend=\$(awk -F= '\$1 == "identity_backend" { print \$2; exit }' "$PREFERENCES_FILE")
    [ "\$identity_backend" = "agent" ] && return 0
    [ -n "\$identity_backend" ] && return 1
    [ "\$(awk -F= '\$1 == "agent_mode" { print \$2; exit }' "$PREFERENCES_FILE")" = "bitwarden" ]
}

sshwitch_bridge_running() {
    [ -f "\$SSHWITCH_AGENT_PID" ] || return 1
    bridge_pid=\$(cat "\$SSHWITCH_AGENT_PID")
    case "\$bridge_pid" in *[!0-9]*|"") return 1 ;; esac
    kill -0 "\$bridge_pid" 2>/dev/null || return 1
    ps -p "\$bridge_pid" -o args= 2>/dev/null |
        grep -F "socat UNIX-LISTEN:\$SSHWITCH_AGENT_SOCKET" >/dev/null
}

start_sshwitch_agent() {
    sshwitch_agent_enabled || return 0
    export SSH_AUTH_SOCK="\$SSHWITCH_AGENT_SOCKET"
    mkdir -p "\$SSHWITCH_STATE_DIR"
    chmod 700 "\$SSHWITCH_STATE_DIR"

    if sshwitch_bridge_running && [ -S "\$SSH_AUTH_SOCK" ]; then
        return 0
    fi

    bridge_lock="\$SSHWITCH_STATE_DIR/bridge.lock"
    if ! mkdir "\$bridge_lock" 2>/dev/null; then
        return 0
    fi
    if sshwitch_bridge_running; then
        kill "\$bridge_pid" 2>/dev/null || true
    fi
    rm -f "\$SSH_AUTH_SOCK"
    setsid socat UNIX-LISTEN:"\$SSH_AUTH_SOCK",fork,mode=600 \\
        EXEC:"npiperelay.exe -ei -s //./pipe/openssh-ssh-agent",nofork \\
        >/dev/null 2>&1 &
    printf '%s\n' "\$!" >"\$SSHWITCH_AGENT_PID"
    rmdir "\$bridge_lock" 2>/dev/null || true
}

reset_ssh_agent() {
    if sshwitch_bridge_running; then
        kill "\$bridge_pid" 2>/dev/null || true
    fi
    rm -f "\$SSHWITCH_AGENT_PID" "\$SSHWITCH_STATE_DIR/bridge.lock"
    rm -f "\$SSHWITCH_AGENT_SOCKET"
    start_sshwitch_agent
    ssh-add -l
}

sshwitch() {
    sh "$SSHWITCH_SH" "\$@"
}

alias reset-ssh-agent='reset_ssh_agent'
alias sync-ssh='sshwitch'

case ":\$PATH:" in
    *:/usr/bin:*) ;;
    *) PATH="/usr/bin:\$PATH"; export PATH ;;
esac
start_sshwitch_agent
EOF
else
    cat >>"$env_temp" <<EOF
identity_backend=\$(awk -F= '\$1 == "identity_backend" { print \$2; exit }' "$PREFERENCES_FILE")
legacy_agent_mode=\$(awk -F= '\$1 == "agent_mode" { print \$2; exit }' "$PREFERENCES_FILE")
if [ "\$identity_backend" = "agent" ] ||
    { [ -z "\$identity_backend" ] && [ "\$legacy_agent_mode" = "bitwarden" ]; }; then
    export SSH_AUTH_SOCK="$DEFAULT_BW_SOCK"
fi

sshwitch() {
    sh "$SSHWITCH_SH" "\$@"
}

alias sync-ssh='sshwitch'
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
SOURCE_LINE='. "$HOME/.ssh/sshwitch-env.sh"'
LEGACY_SOURCE_LINE='. "$HOME/.ssh/sync-ssh-env.sh"'
profile_temp="${PROFILE}.sshwitch-setup.$$"
awk -v legacy_source="$LEGACY_SOURCE_LINE" '
    $0 == "# Added by Bitwarden SSH Sync setup" { next }
    $0 == "# Added by Sync-SSH setup" { next }
    $0 == legacy_source { next }
    { print }
' "$PROFILE" >"$profile_temp"
if ! cmp -s "$PROFILE" "$profile_temp"; then
    chmod --reference="$PROFILE" "$profile_temp" 2>/dev/null || chmod 600 "$profile_temp"
    mv "$profile_temp" "$PROFILE"
else
    rm -f "$profile_temp"
fi
if ! grep -qF "$SOURCE_LINE" "$PROFILE"; then
    printf "\n# Added by SSHwitch setup\n%s\n" "$SOURCE_LINE" >>"$PROFILE"
    printf "Added SSHwitch to %s\n" "$PROFILE"
else
    printf "Profile already configured: %s\n" "$PROFILE"
fi
rm -f "$LEGACY_CONFIG_FILE"

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
        if ! sh "$SSHWITCH_SH"; then
            printf "Initial sync failed. Setup remains installed; run sshwitch to retry.\n" >&2
        fi
        ;;
esac

printf "\nSetup complete.\n"
printf "Restart your shell or run: . \"\$HOME/.ssh/sshwitch-env.sh\"\n"
printf "Then run: sshwitch\n"
