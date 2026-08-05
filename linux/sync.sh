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

LEGACY_START_MARKER="# --- START SYNC-SSH MANAGED SECTION ---"
LEGACY_END_MARKER="# --- END SYNC-SSH MANAGED SECTION ---"
OUTPUT_DIR="$HOME/.ssh"
MAIN_CONFIG="$OUTPUT_DIR/config"
MANAGED_ROOT="$OUTPUT_DIR/sshwitch"
CURRENT_DIR="$MANAGED_ROOT/current"
INCLUDE_LINE="Include ~/.ssh/sshwitch/current/config"
LEGACY_INCLUDE_LINE="Include ~/.ssh/sync-ssh/current/config"
APP_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/sshwitch"
PREFERENCES_FILE="$APP_CONFIG_DIR/config"
LEGACY_PREFERENCES_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/sync-ssh/config"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/sshwitch"
LEGACY_STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/sync-ssh"
GIT_STATE_DIR="$STATE_DIR/git"
LOCK_DIR="$STATE_DIR/sync.lock"
STAGING_DIR=""
LOCK_ACQUIRED=false
SSHWITCH_TTY_STATE=""

resolve_symlink_target() {
    target_path=$1
    link_count=0
    while [ -L "$target_path" ]; do
        link_count=$((link_count + 1))
        [ "$link_count" -le 40 ] || return 1
        link_target=$(readlink "$target_path") || return 1
        case "$link_target" in
            /*) target_path=$link_target ;;
            *) target_path="$(dirname "$target_path")/$link_target" ;;
        esac
    done
    target_dir=$(CDPATH= cd -- "$(dirname "$target_path")" && pwd -P) || return 1
    printf '%s/%s\n' "$target_dir" "$(basename "$target_path")"
}

if [ -L "$MAIN_CONFIG" ]; then
    resolved_main=$(resolve_symlink_target "$MAIN_CONFIG") || {
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
    if [ -n "$SSHWITCH_TTY_STATE" ]; then
        stty "$SSHWITCH_TTY_STATE" 2>/dev/null || true
        SSHWITCH_TTY_STATE=""
    fi
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

    preferences_source=$PREFERENCES_FILE
    if [ ! -f "$preferences_source" ] && [ -f "$LEGACY_PREFERENCES_FILE" ]; then
        preferences_source=$LEGACY_PREFERENCES_FILE
    fi
    if [ -f "$preferences_source" ]; then
        value=$(awk -F= -v key="$key" '$1 == key { sub(/^[^=]*=/, ""); print; exit }' "$preferences_source")
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

load_provider() {
    provider_name=$1
    provider_adapter="$SCRIPT_DIR/providers/$provider_name.sh"
    [ -f "$provider_adapter" ] || die "Unsupported provider: $provider_name"
    # Provider adapters implement the versioned provider contract.
    # shellcheck source=/dev/null
    . "$provider_adapter"
    provider_capabilities=$(provider_probe) ||
        die "Provider '$provider_name' capability probe failed."
    printf '%s' "$provider_capabilities" | jq -e --arg provider "$provider_name" '
      type == "object" and
      (keys | sort) == (["protocol_version", "provider", "capabilities"] | sort) and
      .protocol_version == 1 and
      .provider == $provider and
      (.capabilities | type == "object") and
      (.capabilities.agent | type == "boolean") and
      (.capabilities.private_key_export | type == "boolean")
    ' >/dev/null || die "Provider '$provider_name' returned an invalid capability probe."
    PROVIDER_SUPPORTS_AGENT=$(printf '%s' "$provider_capabilities" | jq -r '.capabilities.agent')
    PROVIDER_SUPPORTS_PRIVATE_EXPORT=$(printf '%s' "$provider_capabilities" |
        jq -r '.capabilities.private_key_export')
}

validate_provider_records() {
    records_path=$1
    provider_name=$2

    jq -e --arg provider "$provider_name" '
      def exact_keys($expected):
        (keys | sort) == ($expected | sort);
      def safe_text:
        type == "string" and (test("[\u0000-\u001F\u007F]") | not);
      type == "object" and
      exact_keys(["schema_version", "provider", "records"]) and
      .schema_version == 1 and
      .provider == $provider and
      (.records | type == "array") and
      all(.records[];
        type == "object" and
        exact_keys([
          "source_id", "name", "role", "destination", "identity",
          "git_principal", "shared"
        ]) and
        (.source_id | safe_text and length > 0) and
        (.name | safe_text and length > 0) and
        (.role == "host" or .role == "git-sign") and
        (.destination |
          type == "object" and
          exact_keys(["hostname", "user"]) and
          (.hostname | safe_text) and
          (.user | safe_text)
        ) and
        (.identity |
          type == "object" and
          exact_keys(["public_key"]) and
          (.public_key | safe_text and length > 0)
        ) and
        (.git_principal | safe_text) and
        (.shared | type == "boolean")
      )
    ' "$records_path" >/dev/null ||
        die "Provider '$provider_name' returned records that violate schema version 1."
}

acquire_lock() {
    mkdir -p "$STATE_DIR"
    chmod 700 "$STATE_DIR"
    if ! mkdir "$LOCK_DIR" 2>/dev/null; then
        die "Another SSHwitch process is already running."
    fi
    LOCK_ACQUIRED=true
}

import_legacy_state() {
    if [ ! -d "$GIT_STATE_DIR" ] && [ -d "$LEGACY_STATE_DIR/git" ]; then
        cp -pR "$LEGACY_STATE_DIR/git" "$GIT_STATE_DIR"
        chmod 700 "$GIT_STATE_DIR"
        find "$GIT_STATE_DIR" -type d -exec chmod 700 {} \;
        find "$GIT_STATE_DIR" -type f -exec chmod 600 {} \;
    fi
}

write_public_key() {
    key_value=$1
    destination=$2
    printf '%s\n' "$key_value" >"$destination"
    chmod 600 "$destination"
    ssh-keygen -lf "$destination" >/dev/null 2>&1 ||
        die "Provider returned an invalid SSH public key for $(basename "$destination")."
}

verify_agent_identity() {
    public_key_path=$1
    expected_identity=$(awk 'NF >= 2 { print $1 " " $2; exit }' "$public_key_path")
    [ -n "$expected_identity" ] || die "Unable to identify a provider public key."
    agent_identities=$(ssh-add -L 2>/dev/null) ||
        die "Unable to list identities from the selected SSH agent."
    printf '%s\n' "$agent_identities" |
        awk -v expected="$expected_identity" '
          NF >= 2 && ($1 " " $2) == expected { found=1 }
          END { exit(found ? 0 : 1) }
        ' || die "A provider public key is not available from the selected SSH agent."
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

    if [ "$signing_pref" = "yes" ]; then
        if [ ! -f "$sign_key_path" ]; then
            log_warn "Git signing is enabled, but no 'git-sign' public key was found; SSH configuration was synced without updating Git signing settings."
            return 0
        fi
        require_command git
        set_owned_git_value gpg.format gpg-format ssh
        set_owned_git_value user.signingkey user-signingkey "$sign_key_path"
        set_owned_git_value commit.gpgsign commit-gpgsign true
        if [ -f "$allowed_signers_path" ]; then
            set_owned_git_value gpg.ssh.allowedSignersFile allowed-signers-file "$allowed_signers_path"
        fi
    elif [ "$signing_pref" = "no" ]; then
        require_command git
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
        start_count=$(grep -cF "$LEGACY_START_MARKER" "$MAIN_CONFIG" || true)
        end_count=$(grep -cF "$LEGACY_END_MARKER" "$MAIN_CONFIG" || true)
    fi

    if [ "$start_count" -ne "$end_count" ] || [ "$start_count" -gt 1 ]; then
        die "Malformed legacy Sync-SSH markers in $MAIN_CONFIG; refusing to modify it."
    fi

    if [ -f "$MAIN_CONFIG" ]; then
        if [ "$start_count" -eq 1 ]; then
            awk -v start="$LEGACY_START_MARKER" -v end="$LEGACY_END_MARKER" '
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
    legacy_include_count=$(grep -cF "$LEGACY_INCLUDE_LINE" "$staged_main" || true)
    total_include_count=$((include_count + legacy_include_count))
    [ "$total_include_count" -le 1 ] ||
        die "Duplicate SSHwitch or legacy Sync-SSH Include directives found in $MAIN_CONFIG."
    if [ "$legacy_include_count" -eq 1 ]; then
        include_temp="${staged_main}.include"
        awk -v old="$LEGACY_INCLUDE_LINE" -v new="$INCLUDE_LINE" '
            $0 == "# Added by Sync-SSH" ||
            $0 == "# Added by Bitwarden SSH Sync" {
                pending_comment=$0
                next
            }
            $0 == old {
                if (pending_comment != "") print "# Added by SSHwitch"
                print new
                pending_comment=""
                next
            }
            {
                if (pending_comment != "") print pending_comment
                pending_comment=""
                print
            }
            END {
                if (pending_comment != "") print pending_comment
            }
        ' "$staged_main" >"$include_temp"
        mv "$include_temp" "$staged_main"
    elif [ "$include_count" -eq 0 ]; then
        include_temp="${staged_main}.include"
        {
            printf "# Added by SSHwitch\n%s\n\n" "$INCLUDE_LINE"
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

    main_temp="$(dirname "$MAIN_CONFIG")/.sshwitch-config.$$"
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

sshwitch_sync() {
    require_command jq
    require_command ssh
    require_command ssh-keygen

    provider=$(read_preference provider "")
    identity_backend=$(read_preference identity_backend "")
    private_key_policy=$(read_preference private_key_policy "")
    legacy_agent_mode=$(read_preference agent_mode "")
    keep_alive=$(read_preference keep_alive skip)
    commit_signing=$(read_preference commit_signing skip)

    [ -n "$provider" ] || provider="bitwarden"
    if [ -z "$identity_backend" ]; then
        case "$legacy_agent_mode" in
            disk) identity_backend="disk" ;;
            bitwarden|"") identity_backend="agent" ;;
            *) die "Invalid legacy agent_mode preference: $legacy_agent_mode" ;;
        esac
    fi
    if [ -z "$private_key_policy" ]; then
        case "$identity_backend" in
            agent) private_key_policy="never" ;;
            disk) private_key_policy="export" ;;
            *) die "Invalid identity_backend preference: $identity_backend" ;;
        esac
    fi
    printf '%s' "$provider" | grep -Eq '^[a-z0-9][a-z0-9-]*$' ||
        die "Invalid provider preference: $provider"
    case "$identity_backend:$private_key_policy" in
        agent:never|disk:export) ;;
        *) die "Invalid identity backend/private-key policy combination: $identity_backend/$private_key_policy" ;;
    esac
    [ "$identity_backend" != "agent" ] || require_command ssh-add
    case "$keep_alive" in yes|no|skip) ;; *) die "Invalid keep_alive preference: $keep_alive" ;; esac
    case "$commit_signing" in yes|no|skip) ;; *) die "Invalid commit_signing preference: $commit_signing" ;; esac

    load_provider "$provider"
    if [ "$identity_backend" = "agent" ] && [ "$PROVIDER_SUPPORTS_AGENT" != true ]; then
        die "Provider '$provider' does not support the agent identity backend."
    fi
    if [ "$private_key_policy" = "export" ] &&
        [ "$PROVIDER_SUPPORTS_PRIVATE_EXPORT" != true ]; then
        die "Provider '$provider' does not support private-key export."
    fi
    provider_requirements
    acquire_lock
    import_legacy_state

    mkdir -p "$OUTPUT_DIR" "$MANAGED_ROOT"
    chmod 700 "$OUTPUT_DIR" "$MANAGED_ROOT"
    STAGING_DIR=$(mktemp -d "$MANAGED_ROOT/.staging.XXXXXX")
    chmod 700 "$STAGING_DIR"
    mkdir "$STAGING_DIR/keys"
    chmod 700 "$STAGING_DIR/keys"
    generated_config="$STAGING_DIR/config"
    aliases_file="$STAGING_DIR/.aliases"
    items_file="$STAGING_DIR/.items"
    provider_records="$STAGING_DIR/.provider-records"
    : >"$generated_config"
    : >"$aliases_file"
    chmod 600 "$generated_config" "$aliases_file"

    provider_authenticate
    provider_list_records "$provider_records"
    validate_provider_records "$provider_records" "$provider"
    jq -c '.records | sort_by(.name | ascii_downcase) | .[]' \
        "$provider_records" >"$items_file"
    chmod 600 "$items_file"

    processed_count=0
    sign_email=""
    while IFS= read -r item; do
        [ -n "$item" ] || continue
        name=$(printf '%s' "$item" | jq -er '.name')
        source_id=$(printf '%s' "$item" | jq -er '.source_id')
        role=$(printf '%s' "$item" | jq -er '.role')
        hostname=$(printf '%s' "$item" | jq -r '.destination.hostname')
        user=$(printf '%s' "$item" | jq -r '.destination.user')
        email=$(printf '%s' "$item" | jq -r '.git_principal')
        pubkey=$(printf '%s' "$item" | jq -r '.identity.public_key')
        shared=$(printf '%s' "$item" | jq -r '.shared')
        alias=$(sanitize_alias "$name")
        [ "$role" = "git-sign" ] && alias="git-sign"

        [ -n "$alias" ] || die "Provider item '$name' produces an empty SSH alias."
        printf '%s' "$alias" | grep -Eq '^[a-z0-9][a-z0-9._-]*$' ||
            die "Provider item '$name' produces an invalid SSH alias."
        if grep -qxF "$alias" "$aliases_file"; then
            die "Multiple provider items produce the SSH alias '$alias'."
        fi
        printf '%s\n' "$alias" >>"$aliases_file"

        write_public_key "$pubkey" "$STAGING_DIR/keys/$alias.pub"
        if [ "$identity_backend" = "agent" ]; then
            verify_agent_identity "$STAGING_DIR/keys/$alias.pub"
        fi

        if [ "$role" = "git-sign" ]; then
            sign_email=$email
            if [ "$private_key_policy" = "export" ]; then
                if provider_export_private_key "$source_id" "$STAGING_DIR/keys/git-sign"; then
                    :
                elif [ "$?" -ne 2 ]; then
                    die "Provider private-key export failed for '$name'."
                fi
            fi
            continue
        fi

        [ -n "$hostname" ] || die "Provider SSH item '$name' has no HostName field."
        printf '%s' "$hostname" | grep -Eq '^[^[:space:]#]+$' ||
            die "Provider SSH item '$name' contains an invalid HostName."
        if [ -n "$user" ]; then
            printf '%s' "$user" | grep -Eq '^[^[:space:]#]+$' ||
                die "Provider SSH item '$name' contains an invalid User."
        fi
        [ "$shared" = false ] || log_warn "Using shared provider SSH item: $name"

        identity_suffix=".pub"
        if [ "$private_key_policy" = "export" ]; then
            if ! provider_export_private_key "$source_id" "$STAGING_DIR/keys/$alias"; then
                die "Disk identity backend requires a private key for '$name'."
            fi
            identity_suffix=""
        fi

        printf "\nHost %s\n  HostName %s\n" "$alias" "$hostname" >>"$generated_config"
        [ -z "$user" ] || printf "  User %s\n" "$user" >>"$generated_config"
        printf "  IdentityFile \"~/.ssh/sshwitch/current/keys/%s%s\"\n  IdentitiesOnly yes\n" \
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
            if [ "$private_key_policy" = "export" ] && [ -f "$STAGING_DIR/keys/$managed_alias" ]; then
                printf "keys/%s\n" "$managed_alias"
            fi
        done <"$aliases_file"
        [ -f "$STAGING_DIR/allowed_signers" ] && printf "allowed_signers\n"
    } >"$STAGING_DIR/manifest"
    chmod 600 "$STAGING_DIR/manifest"
    rm -f "$provider_records" "$items_file" "$aliases_file"

    # OpenSSH must accept the complete generated file before anything is published.
    validation_alias=$(awk '/^Host / && $2 != "*" { print $2; exit }' "$generated_config")
    [ -n "$validation_alias" ] || validation_alias="sshwitch-validation"
    ssh -F "$generated_config" -G "$validation_alias" >/dev/null 2>&1 ||
        die "OpenSSH rejected the generated configuration."

    staged_main="$STATE_DIR/main-config.new"
    prepare_main_config "$staged_main"

    if [ "$commit_signing" = "yes" ]; then
        if [ -f "$STAGING_DIR/keys/git-sign.pub" ]; then
            require_command git
        elif [ "$DRY_RUN" = true ]; then
            log_warn "Git signing is enabled, but no 'git-sign' public key was found; SSH configuration would be synced without updating Git signing settings."
        fi
    fi
    if [ "$DRY_RUN" = true ]; then
        log_info "Dry run successful: generated configuration passed validation; no live files were changed."
        if command -v diff >/dev/null 2>&1 && [ -f "$MAIN_CONFIG" ]; then
            diff -u "$MAIN_CONFIG" "$staged_main" || true
        fi
        return 0
    fi

    if [ ! -f "$STATE_DIR/config.pre-sshwitch" ] && [ -f "$MAIN_CONFIG" ]; then
        cp -p "$MAIN_CONFIG" "$STATE_DIR/config.pre-sshwitch"
        chmod 600 "$STATE_DIR/config.pre-sshwitch"
    fi

    publish_transaction "$staged_main"
    rm -f "$staged_main"

    apply_git_signing "$commit_signing" \
        "$CURRENT_DIR/keys/git-sign.pub" \
        "$CURRENT_DIR/allowed_signers"

    log_success "Synced $processed_count SSH hosts from $provider using the $identity_backend identity backend."
}

sshwitch_sync
