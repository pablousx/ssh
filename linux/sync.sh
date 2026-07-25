#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd -P)
DRY_RUN=false
case "${1:-}" in
    --version)
        if [ -f "$SCRIPT_DIR/VERSION" ]; then
            cat "$SCRIPT_DIR/VERSION"
        elif [ -f "$SCRIPT_DIR/../VERSION" ]; then
            cat "$SCRIPT_DIR/../VERSION"
        else
            printf "development\n"
        fi
        exit 0
        ;;
    --dry-run) DRY_RUN=true ;;
    "") ;;
    *) printf "Usage: %s [--dry-run|--version]\n" "$0" >&2; exit 2 ;;
esac

SYNC_START_MARKER="# --- START SYNC-SSH MANAGED SECTION ---"
SYNC_END_MARKER="# --- END SYNC-SSH MANAGED SECTION ---"
OUTPUT_DIR="$HOME/.ssh"
MAIN_CONFIG="$OUTPUT_DIR/config"
MANAGED_ROOT="$OUTPUT_DIR/sync-ssh"
CURRENT_DIR="$MANAGED_ROOT/current"
INCLUDE_LINE="Include ~/.ssh/sync-ssh/current/config"
APP_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/sync-ssh"
PREFERENCES_FILE="$APP_CONFIG_DIR/config"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/sync-ssh"
GIT_STATE_DIR="$STATE_DIR/git"
LOCK_DIR="$STATE_DIR/sync.lock"
STAGING_DIR=""
LOCK_ACQUIRED=false

if [ -L "$MAIN_CONFIG" ]; then
    resolved_main=$(readlink -f -- "$MAIN_CONFIG") || {
        printf "Unable to resolve SSH config symlink: %s\n" "$MAIN_CONFIG" >&2
        exit 1
    }
    [ -f "$resolved_main" ] || {
        printf "SSH config symlink target does not exist: %s\n" "$resolved_main" >&2
        exit 1
    }
    MAIN_CONFIG=$resolved_main
fi

log_info() { printf "\033[36m%s\033[0m\n" "$1" >&2; }
log_success() { printf "\033[32m%s\033[0m\n" "$1" >&2; }
log_warn() { printf "\033[33m%s\033[0m\n" "$1" >&2; }
log_error() { printf "\033[31m%s\033[0m\n" "$1" >&2; }

cleanup() {
    if [ -n "$STAGING_DIR" ] && [ -d "$STAGING_DIR" ]; then
        rm -rf -- "$STAGING_DIR"
    fi
    if [ "$LOCK_ACQUIRED" = true ] && [ -d "$LOCK_DIR" ]; then
        rmdir "$LOCK_DIR" 2>/dev/null || true
    fi
}
trap cleanup 0
trap 'exit 1' HUP INT TERM

die() {
    log_error "$1"
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

read_preference() {
    key=$1
    fallback=$2
    value=""

    if [ -f "$PREFERENCES_FILE" ]; then
        value=$(awk -F= -v key="$key" '$1 == key { sub(/^[^=]*=/, ""); print; exit }' "$PREFERENCES_FILE")
    fi

    # Read legacy preferences without writing to Git config.
    if [ -z "$value" ] && command -v git >/dev/null 2>&1; then
        case "$key" in
            commit_signing) value=$(git config --global --get sync-ssh.commit-signing 2>/dev/null || true) ;;
            keep_alive) value=$(git config --global --get sync-ssh.keep-alive 2>/dev/null || true) ;;
            agent_mode) value=$(git config --global --get sync-ssh.agent-mode 2>/dev/null || true) ;;
        esac
    fi

    [ -n "$value" ] || value=$fallback
    printf '%s\n' "$value"
}

acquire_lock() {
    mkdir -p "$STATE_DIR"
    chmod 700 "$STATE_DIR"
    if ! mkdir "$LOCK_DIR" 2>/dev/null; then
        die "Another sync-ssh process is already running."
    fi
    LOCK_ACQUIRED=true
}

unlock_vault() {
    status_json=$(bw status) || die "Unable to query Bitwarden status."
    status=$(printf '%s' "$status_json" | jq -er '.status') || die "Bitwarden returned an invalid status response."

    case "$status" in
        unauthenticated)
            die "Bitwarden is not logged in. Run 'bw login' first."
            ;;
        locked)
            log_info "Unlocking Bitwarden vault..."
            session=$(bw unlock --raw) || die "Failed to unlock Bitwarden vault."
            session=$(printf '%s' "$session" | tr -d '\r\n')
            [ -n "$session" ] || die "Bitwarden returned an empty session token."
            BW_SESSION=$session
            export BW_SESSION
            ;;
        unlocked)
            if [ -z "${BW_SESSION:-}" ]; then
                log_info "Requesting a Bitwarden session token..."
                session=$(bw unlock --raw) || die "Failed to obtain a Bitwarden session token."
                session=$(printf '%s' "$session" | tr -d '\r\n')
                [ -n "$session" ] || die "Bitwarden returned an empty session token."
                BW_SESSION=$session
                export BW_SESSION
            fi
            ;;
        *)
            die "Unsupported Bitwarden status: $status"
            ;;
    esac
}

fetch_vault_items() {
    log_info "Syncing Bitwarden vault..."
    bw sync >/dev/null || die "Bitwarden sync failed; existing SSH configuration was not changed."

    log_info "Fetching SSH key items..."
    raw_items=$(bw list items) || die "Unable to list Bitwarden items; existing SSH configuration was not changed."
    printf '%s' "$raw_items" | jq -e 'type == "array"' >/dev/null ||
        die "Bitwarden returned invalid item data; existing SSH configuration was not changed."
    printf '%s' "$raw_items"
}

validate_text_fields() {
    items=$1
    printf '%s' "$items" | jq -e '
        [
          .[] | select(.type == 5) |
          .name,
          (.fields // [] | map(select((.name | ascii_downcase) == "hostname")) | first | .value // ""),
          (.fields // [] | map(select((.name | ascii_downcase) == "user")) | first | .value // ""),
          (.fields // [] | map(select((.name | ascii_downcase) == "email" or (.name | ascii_downcase) == "gitemail")) | first | .value // "")
        ]
        | all(.[];
            type == "string"
            and (test("[\u0000-\u001F\u007F]") | not)
        )
    ' >/dev/null || die "A Bitwarden SSH item contains a control character or a non-text metadata field."
}

write_public_key() {
    key_value=$1
    destination=$2
    printf '%s\n' "$key_value" >"$destination"
    chmod 600 "$destination"
    ssh-keygen -lf "$destination" >/dev/null 2>&1 ||
        die "Bitwarden returned an invalid SSH public key for $(basename "$destination")."
}

sanitize_alias() {
    printf '%s' "$1" |
        tr '[:upper:]' '[:lower:]' |
        sed 's/[^a-z0-9._-]/-/g; s/^-*//; s/-*$//'
}

record_git_previous() {
    git_key=$1
    slug=$2
    owned_value=$3
    key_dir="$GIT_STATE_DIR/$slug"

    [ -d "$key_dir" ] && return 0
    mkdir -p "$key_dir"
    chmod 700 "$key_dir"
    if previous=$(git config --global --get "$git_key" 2>/dev/null); then
        printf '%s' "$previous" >"$key_dir/previous"
        chmod 600 "$key_dir/previous"
        : >"$key_dir/was-present"
    fi
    printf '%s' "$owned_value" >"$key_dir/owned"
    chmod 600 "$key_dir/owned"
}

set_owned_git_value() {
    git_key=$1
    slug=$2
    value=$3
    record_git_previous "$git_key" "$slug" "$value"
    git config --global "$git_key" "$value"
    printf '%s' "$value" >"$GIT_STATE_DIR/$slug/owned"
}

restore_owned_git_value() {
    git_key=$1
    slug=$2
    key_dir="$GIT_STATE_DIR/$slug"
    [ -d "$key_dir" ] || return 0

    current=$(git config --global --get "$git_key" 2>/dev/null || true)
    owned=$(cat "$key_dir/owned")
    if [ "$current" = "$owned" ]; then
        if [ -f "$key_dir/was-present" ]; then
            git config --global "$git_key" "$(cat "$key_dir/previous")"
        else
            git config --global --unset-all "$git_key" 2>/dev/null || true
        fi
    else
        log_warn "Preserving user-modified Git setting: $git_key"
    fi
    rm -rf -- "$key_dir"
}

apply_git_signing() {
    signing_pref=$1
    sign_key_path=$2
    allowed_signers_path=$3

    [ "$signing_pref" = "skip" ] && return 0
    require_command git

    if [ "$signing_pref" = "yes" ]; then
        [ -f "$sign_key_path" ] || die "Git signing is enabled, but no 'git-sign' public key was found."
        set_owned_git_value gpg.format gpg-format ssh
        set_owned_git_value user.signingkey user-signingkey "$sign_key_path"
        set_owned_git_value commit.gpgsign commit-gpgsign true
        if [ -f "$allowed_signers_path" ]; then
            set_owned_git_value gpg.ssh.allowedSignersFile allowed-signers-file "$allowed_signers_path"
        fi
    elif [ "$signing_pref" = "no" ]; then
        restore_owned_git_value gpg.ssh.allowedSignersFile allowed-signers-file
        restore_owned_git_value commit.gpgsign commit-gpgsign
        restore_owned_git_value user.signingkey user-signingkey
        restore_owned_git_value gpg.format gpg-format
    else
        die "Invalid commit_signing preference: $signing_pref"
    fi
}

prepare_main_config() {
    staged_main=$1
    start_count=0
    end_count=0

    if [ -f "$MAIN_CONFIG" ]; then
        start_count=$(grep -cF "$SYNC_START_MARKER" "$MAIN_CONFIG" || true)
        end_count=$(grep -cF "$SYNC_END_MARKER" "$MAIN_CONFIG" || true)
    fi

    if [ "$start_count" -ne "$end_count" ] || [ "$start_count" -gt 1 ]; then
        die "Malformed legacy sync-ssh markers in $MAIN_CONFIG; refusing to modify it."
    fi

    if [ -f "$MAIN_CONFIG" ]; then
        if [ "$start_count" -eq 1 ]; then
            awk -v start="$SYNC_START_MARKER" -v end="$SYNC_END_MARKER" '
                $0 == start { skip=1; found_start=1; next }
                $0 == end && skip { skip=0; found_end=1; next }
                !skip { print }
                END { if (!found_start || !found_end || skip) exit 42 }
            ' "$MAIN_CONFIG" >"$staged_main" ||
                die "Unable to safely migrate the legacy managed SSH block."
        else
            cp "$MAIN_CONFIG" "$staged_main"
        fi
    else
        printf "Host *\n  Port 22\n  AddKeysToAgent yes\n  ForwardAgent no\n" >"$staged_main"
    fi

    include_count=$(grep -cF "$INCLUDE_LINE" "$staged_main" || true)
    [ "$include_count" -le 1 ] || die "Duplicate sync-ssh Include directives found in $MAIN_CONFIG."
    if [ "$include_count" -eq 0 ]; then
        include_temp="${staged_main}.include"
        {
            printf "# Added by Bitwarden SSH Sync\n%s\n\n" "$INCLUDE_LINE"
            cat "$staged_main"
        } >"$include_temp"
        mv "$include_temp" "$staged_main"
    fi
    chmod 600 "$staged_main"
}

publish_transaction() {
    staged_main=$1
    previous_dir="$MANAGED_ROOT/.previous"

    mkdir -p "$MANAGED_ROOT"
    chmod 700 "$MANAGED_ROOT"
    if [ -e "$previous_dir" ]; then
        rm -rf -- "$previous_dir"
    fi
    if [ -d "$CURRENT_DIR" ]; then
        mv "$CURRENT_DIR" "$previous_dir"
    fi
    if ! mv "$STAGING_DIR" "$CURRENT_DIR"; then
        [ -d "$previous_dir" ] && mv "$previous_dir" "$CURRENT_DIR"
        die "Unable to publish generated SSH files."
    fi
    STAGING_DIR=""

    main_temp="$(dirname "$MAIN_CONFIG")/.sync-ssh-config.$$"
    cp "$staged_main" "$main_temp"
    chmod 600 "$main_temp"
    if ! mv "$main_temp" "$MAIN_CONFIG"; then
        rm -f "$main_temp"
        rm -rf -- "$CURRENT_DIR"
        [ -d "$previous_dir" ] && mv "$previous_dir" "$CURRENT_DIR"
        die "Unable to publish the SSH configuration."
    fi
    [ -d "$previous_dir" ] && rm -rf -- "$previous_dir"
    return 0
}

sync_ssh() {
    require_command bw
    require_command jq
    require_command ssh
    require_command ssh-keygen

    agent_mode=$(read_preference agent_mode bitwarden)
    keep_alive=$(read_preference keep_alive skip)
    commit_signing=$(read_preference commit_signing skip)
    case "$agent_mode" in bitwarden|disk) ;; *) die "Invalid agent_mode preference: $agent_mode" ;; esac
    case "$keep_alive" in yes|no|skip) ;; *) die "Invalid keep_alive preference: $keep_alive" ;; esac
    case "$commit_signing" in yes|no|skip) ;; *) die "Invalid commit_signing preference: $commit_signing" ;; esac

    acquire_lock
    unlock_vault
    vault_items=$(fetch_vault_items)
    validate_text_fields "$vault_items"

    mkdir -p "$OUTPUT_DIR" "$MANAGED_ROOT"
    chmod 700 "$OUTPUT_DIR" "$MANAGED_ROOT"
    STAGING_DIR=$(mktemp -d "$MANAGED_ROOT/.staging.XXXXXX")
    chmod 700 "$STAGING_DIR"
    mkdir "$STAGING_DIR/keys"
    chmod 700 "$STAGING_DIR/keys"
    generated_config="$STAGING_DIR/config"
    aliases_file="$STAGING_DIR/.aliases"
    items_file="$STAGING_DIR/.items"
    : >"$generated_config"
    : >"$aliases_file"
    chmod 600 "$generated_config" "$aliases_file"

    if [ "$agent_mode" = "disk" ]; then
        printf '%s' "$vault_items" | jq -c '
          [.[] | select(.type == 5) | {
            name: .name,
            hostname: (.fields // [] | map(select((.name | ascii_downcase) == "hostname")) | first | .value // ""),
            user: (.fields // [] | map(select((.name | ascii_downcase) == "user")) | first | .value // ""),
            email: (.fields // [] | map(select((.name | ascii_downcase) == "email" or (.name | ascii_downcase) == "gitemail")) | first | .value // ""),
            pubkey: (.sshKey.publicKey // ""),
            privkey: (.sshKey.privateKey // ""),
            org: (.organizationId // "")
          }] | sort_by(.name | ascii_downcase) | .[]
        ' >"$items_file"
    else
        printf '%s' "$vault_items" | jq -c '
          [.[] | select(.type == 5) | {
            name: .name,
            hostname: (.fields // [] | map(select((.name | ascii_downcase) == "hostname")) | first | .value // ""),
            user: (.fields // [] | map(select((.name | ascii_downcase) == "user")) | first | .value // ""),
            email: (.fields // [] | map(select((.name | ascii_downcase) == "email" or (.name | ascii_downcase) == "gitemail")) | first | .value // ""),
            pubkey: (.sshKey.publicKey // ""),
            org: (.organizationId // "")
          }] | sort_by(.name | ascii_downcase) | .[]
        ' >"$items_file"
    fi
    chmod 600 "$items_file"

    processed_count=0
    sign_email=""
    while IFS= read -r item; do
        [ -n "$item" ] || continue
        name=$(printf '%s' "$item" | jq -er '.name')
        hostname=$(printf '%s' "$item" | jq -r '.hostname')
        user=$(printf '%s' "$item" | jq -r '.user')
        email=$(printf '%s' "$item" | jq -r '.email')
        pubkey=$(printf '%s' "$item" | jq -r '.pubkey')
        org=$(printf '%s' "$item" | jq -r '.org')
        alias=$(sanitize_alias "$name")

        [ -n "$alias" ] || die "Bitwarden item '$name' produces an empty SSH alias."
        printf '%s' "$alias" | grep -Eq '^[a-z0-9][a-z0-9._-]*$' ||
            die "Bitwarden item '$name' produces an invalid SSH alias."
        if grep -qxF "$alias" "$aliases_file"; then
            die "Multiple Bitwarden items produce the SSH alias '$alias'."
        fi
        printf '%s\n' "$alias" >>"$aliases_file"

        [ -n "$pubkey" ] || die "Bitwarden SSH item '$name' has no public key."
        write_public_key "$pubkey" "$STAGING_DIR/keys/$alias.pub"

        if [ "$alias" = "git-sign" ]; then
            sign_email=$email
            if [ "$agent_mode" = "disk" ]; then
                privkey=$(printf '%s' "$item" | jq -r '.privkey')
                if [ -n "$privkey" ]; then
                    printf '%s\n' "$privkey" >"$STAGING_DIR/keys/git-sign"
                    chmod 600 "$STAGING_DIR/keys/git-sign"
                fi
            fi
            continue
        fi

        [ -n "$hostname" ] || die "Bitwarden SSH item '$name' has no HostName field."
        printf '%s' "$hostname" | grep -Eq '^[^[:space:]#]+$' ||
            die "Bitwarden SSH item '$name' contains an invalid HostName."
        if [ -n "$user" ]; then
            printf '%s' "$user" | grep -Eq '^[^[:space:]#]+$' ||
                die "Bitwarden SSH item '$name' contains an invalid User."
        fi
        [ -z "$org" ] || log_warn "Using organization-owned SSH item: $name"

        identity_suffix=".pub"
        if [ "$agent_mode" = "disk" ]; then
            privkey=$(printf '%s' "$item" | jq -r '.privkey')
            [ -n "$privkey" ] || die "Disk mode requires a private key for '$name'."
            printf '%s\n' "$privkey" >"$STAGING_DIR/keys/$alias"
            chmod 600 "$STAGING_DIR/keys/$alias"
            identity_suffix=""
        fi

        printf "\nHost %s\n  HostName %s\n" "$alias" "$hostname" >>"$generated_config"
        [ -z "$user" ] || printf "  User %s\n" "$user" >>"$generated_config"
        printf "  IdentityFile \"~/.ssh/sync-ssh/current/keys/%s%s\"\n  IdentitiesOnly yes\n" \
            "$alias" "$identity_suffix" >>"$generated_config"
        processed_count=$((processed_count + 1))
    done <"$items_file"

    case "$keep_alive" in
        yes) printf "\nHost *\n  ServerAliveInterval 60\n  ServerAliveCountMax 3\n" >>"$generated_config" ;;
        no) printf "\nHost *\n  ServerAliveInterval 0\n" >>"$generated_config" ;;
    esac

    if [ -f "$STAGING_DIR/keys/git-sign.pub" ]; then
        [ -n "$sign_email" ] || sign_email=$(git config --global --get user.email 2>/dev/null || true)
        if [ -n "$sign_email" ]; then
            printf '%s %s\n' "$sign_email" "$(cat "$STAGING_DIR/keys/git-sign.pub")" >"$STAGING_DIR/allowed_signers"
            chmod 600 "$STAGING_DIR/allowed_signers"
        fi
    fi

    {
        printf "config\n"
        while IFS= read -r managed_alias; do
            [ -n "$managed_alias" ] || continue
            printf "keys/%s.pub\n" "$managed_alias"
            if [ "$agent_mode" = "disk" ] && [ -f "$STAGING_DIR/keys/$managed_alias" ]; then
                printf "keys/%s\n" "$managed_alias"
            fi
        done <"$aliases_file"
        [ -f "$STAGING_DIR/allowed_signers" ] && printf "allowed_signers\n"
    } >"$STAGING_DIR/manifest"
    chmod 600 "$STAGING_DIR/manifest"
    rm -f "$items_file" "$aliases_file"

    # OpenSSH must accept the complete generated file before anything is published.
    validation_alias=$(awk '/^Host / && $2 != "*" { print $2; exit }' "$generated_config")
    [ -n "$validation_alias" ] || validation_alias="sync-ssh-validation"
    ssh -F "$generated_config" -G "$validation_alias" >/dev/null 2>&1 ||
        die "OpenSSH rejected the generated configuration."

    staged_main="$STATE_DIR/main-config.new"
    prepare_main_config "$staged_main"

    if [ "$commit_signing" = "yes" ]; then
        require_command git
        [ -f "$STAGING_DIR/keys/git-sign.pub" ] ||
            die "Git signing is enabled, but no 'git-sign' public key was found."
    fi
    if [ "$DRY_RUN" = true ]; then
        log_info "Dry run successful: generated configuration passed validation; no live files were changed."
        if command -v diff >/dev/null 2>&1 && [ -f "$MAIN_CONFIG" ]; then
            diff -u "$MAIN_CONFIG" "$staged_main" || true
        fi
        return 0
    fi

    if [ ! -f "$STATE_DIR/config.pre-sync-ssh" ] && [ -f "$MAIN_CONFIG" ]; then
        cp -p "$MAIN_CONFIG" "$STATE_DIR/config.pre-sync-ssh"
        chmod 600 "$STATE_DIR/config.pre-sync-ssh"
    fi

    publish_transaction "$staged_main"
    rm -f "$staged_main"

    apply_git_signing "$commit_signing" \
        "$CURRENT_DIR/keys/git-sign.pub" \
        "$CURRENT_DIR/allowed_signers"

    log_success "Synced $processed_count SSH hosts using $agent_mode mode."
}

sync_ssh
