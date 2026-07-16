#!/bin/sh

# =========== Constants ===========
SYNC_START_MARKER="# --- START SYNC-SSH MANAGED SECTION ---"
SYNC_END_MARKER="# --- END SYNC-SSH MANAGED SECTION ---"
OUTPUT_DIR="$HOME/.ssh"
KEYS_DIR="$OUTPUT_DIR/keys"
SSH_CONFIG_FILE="$OUTPUT_DIR/config"
DOT_SSH_CONFIG="$HOME/.ssh/config"

# =========== Functions ===========

log_info() {
    printf "\033[36m%s\033[0m\n" "$1" >&2
}

log_success() {
    printf "\033[32m%s\033[0m\n" "$1" >&2
}

log_warn() {
    printf "\033[33m%s\033[0m\n" "$1" >&2
}

log_error() {
    printf "\033[31m%s\033[0m\n" "$1" >&2
}

ensure_dependencies() {
    if ! command -v bw > /dev/null 2>&1; then
        log_error "Bitwarden CLI (bw) not found."
        log_warn "Please install it: https://bitwarden.com/help/cli/"
        exit 1
    fi

    if ! command -v jq > /dev/null 2>&1; then
        log_error "jq not found."
        log_warn "Please install it (e.g., sudo apt install jq)"
        exit 1
    fi
}

initialize_ssh_config() {
    mkdir -p "$HOME/.ssh"
    mkdir -p "$KEYS_DIR"
    chmod 700 "$HOME/.ssh"
    chmod 700 "$KEYS_DIR"

    if [ ! -f "$SSH_CONFIG_FILE" ]; then
        log_info "Creating default config at $SSH_CONFIG_FILE"
        printf "Host *\n  Port 22\n  AddKeysToAgent yes\n  ForwardAgent no\n\n" > "$SSH_CONFIG_FILE"
    fi

    # Ensure markers exist
    if ! grep -qF "$SYNC_START_MARKER" "$SSH_CONFIG_FILE"; then
        log_info "Adding managed section markers to $SSH_CONFIG_FILE"
        printf "\n%s\n# This section is automatically generated. Manual changes will be lost.\n%s\n" "$SYNC_START_MARKER" "$SYNC_END_MARKER" >> "$SSH_CONFIG_FILE"
    fi

    # Link ~/.ssh/config to our config if they are different files
    if [ "$DOT_SSH_CONFIG" != "$SSH_CONFIG_FILE" ]; then
        if [ -f "$DOT_SSH_CONFIG" ] && [ ! "$DOT_SSH_CONFIG" -ef "$SSH_CONFIG_FILE" ]; then
            log_warn "Backing up existing $DOT_SSH_CONFIG to $DOT_SSH_CONFIG.bak"
            mv "$DOT_SSH_CONFIG" "$DOT_SSH_CONFIG.bak"
        fi

        if [ ! -e "$DOT_SSH_CONFIG" ]; then
            if ln "$SSH_CONFIG_FILE" "$DOT_SSH_CONFIG" 2>/dev/null; then
                log_success "Hard linked $DOT_SSH_CONFIG -> $SSH_CONFIG_FILE"
            else
                ln -s "$SSH_CONFIG_FILE" "$DOT_SSH_CONFIG"
                log_success "Symbolic linked $DOT_SSH_CONFIG -> $SSH_CONFIG_FILE"
            fi
        fi
    fi
}

unlock_vault() {
    STATUS=$(bw status | jq -r '.status')

    if [ "$STATUS" = "unauthenticated" ]; then
        log_error "[ERROR] Bitwarden is not logged in. Please run 'bw login' first."
        exit 1
    fi

    if [ "$STATUS" = "locked" ] || [ -z "$BW_SESSION" ]; then

        log_warn "Bitwarden Vault: $STATUS"
        log_info "Unlocking vault..."
        RAW_UNLOCK=$(bw unlock --raw)

        if [ $? -eq 0 ]; then
            BW_SESSION=$(printf '%s\n' "$RAW_UNLOCK" | grep -oE '[A-Za-z0-9+/=_-]{80,}' | tail -n 1)
            if [ -n "$BW_SESSION" ]; then
                export BW_SESSION
                log_success "[OK] Vault unlocked successfully!"
            else
                log_error "[ERROR] Could not extract session key"
                exit 1
            fi
        else
            log_error "[ERROR] Failed to unlock vault"
            exit 1
        fi
    fi
}

get_bitwarden_keys() {
    log_info "Syncing Bitwarden vault..."
    bw sync > /dev/null

    log_info "Fetching items from Bitwarden..."
    # Type 5 is SSH Key. Return an array of objects.
    bw list items | jq -c '[.[] | select(.type == 5)]'
}

sync_ssh() {
    ensure_dependencies
    initialize_ssh_config
    unlock_vault

    log_info "Syncing Bitwarden vault..."
    bw sync > /dev/null

    # Get Bitwarden items as a flat JSON array with extracted fields
    BW_DATA=$(bw list items | jq -c '[.[] | select(.type == 5) | {
        id: .id,
        name: .name,
        hostname: (.fields[]? | select(.name == "HostName") | .value),
        user: (.fields[]? | select(.name == "User") | .value),
        pubkey: .sshKey.publicKey,
        privkey: .sshKey.privateKey,
        org: .organizationId
    }]')

    AGENT_MODE=$(git config sync-ssh.agent-mode)
    EXPORT_PRIV_PREF=$(git config sync-ssh.export-private-keys)  # legacy fallback
    EXPORT_PRIV="no"
    if [ "$AGENT_MODE" = "disk" ] || [ "$EXPORT_PRIV_PREF" = "yes" ]; then
        EXPORT_PRIV="yes"
    fi

    # Process git-sign separately
    GIT_SIGN=$(printf '%s\n' "$BW_DATA" | jq -c '.[] | select(.name | ascii_downcase == "git-sign")' | head -n 1)
    if [ -n "$GIT_SIGN" ] && [ "$(printf '%s\n' "$GIT_SIGN" | jq -r '.pubkey')" != "null" ]; then
        SIGN_PUB="$KEYS_DIR/git-sign.pub"
        printf '%s\n' "$GIT_SIGN" | jq -r '.pubkey' > "$SIGN_PUB"
        chmod 600 "$SIGN_PUB"

        if [ "$EXPORT_PRIV" = "yes" ]; then
            SIGN_PRIV_VAL=$(printf '%s\n' "$GIT_SIGN" | jq -r '.privkey // empty')
            if [ -n "$SIGN_PRIV_VAL" ] && [ "$SIGN_PRIV_VAL" != "null" ]; then
                SIGN_PRIV="$KEYS_DIR/git-sign"
                printf '%s\n' "$SIGN_PRIV_VAL" > "$SIGN_PRIV"
                chmod 600 "$SIGN_PRIV"
            fi
        fi

        git config --global gpg.format ssh
        git config --global user.signingkey "$SIGN_PUB"
        git config --global commit.gpgsign true
        log_success "Synced Git signing key: git-sign"
    fi

    MANAGED_FILE=$(mktemp)
    PROCESSED_COUNT=0

    # Process items
    TMP_ITEMS=$(mktemp)
    printf '%s\n' "$BW_DATA" | jq -c '.[]' > "$TMP_ITEMS"
    while read -r ITEM; do
        NAME=$(printf '%s\n' "$ITEM" | jq -r '.name')
        [ "$(printf '%s\n' "$NAME" | tr '[:upper:]' '[:lower:]')" = "git-sign" ] && continue

        HOST=$(printf '%s\n' "$ITEM" | jq -r '.hostname // empty')
        USER=$(printf '%s\n' "$ITEM" | jq -r '.user // empty')
        PUB=$(printf '%s\n' "$ITEM" | jq -r '.pubkey // empty')
        PRIV=$(printf '%s\n' "$ITEM" | jq -r '.privkey // empty')
        ORG=$(printf '%s\n' "$ITEM" | jq -r '.org // empty')

        if [ -z "$PUB" ] || [ -z "$HOST" ]; then
            log_warn "Skipping '$NAME': Missing metadata (HostName or Public Key)"
            continue
        fi

        [ -n "$ORG" ] && [ "$ORG" != "null" ] && log_warn "Notice: '$NAME' is an Org key."

        SAFE_NAME=$(printf '%s\n' "$NAME" | sed 's/[^a-zA-Z0-9._-]/-/g' | tr '[:upper:]' '[:lower:]' | sed 's/^-//;s/-$//')
        PUB_FILE="$KEYS_DIR/$SAFE_NAME.pub"
        printf '%s\n' "$PUB" > "$PUB_FILE" && chmod 600 "$PUB_FILE"

        IDENTITY_FILE="$PUB_FILE"

        if [ "$EXPORT_PRIV" = "yes" ] && [ -n "$PRIV" ] && [ "$PRIV" != "null" ]; then
            PRIV_FILE="$KEYS_DIR/$SAFE_NAME"
            printf '%s\n' "$PRIV" > "$PRIV_FILE" && chmod 600 "$PRIV_FILE"
            IDENTITY_FILE="$PRIV_FILE"
        fi

        printf "\nHost %s\n  HostName %s\n" "$SAFE_NAME" "$HOST" >> "$MANAGED_FILE"
        if [ -n "$USER" ] && [ "$USER" != "null" ]; then
            printf "  User %s\n" "$USER" >> "$MANAGED_FILE"
        fi
        printf "  IdentityFile %s\n  IdentitiesOnly yes\n" "$IDENTITY_FILE" >> "$MANAGED_FILE"

        PROCESSED_COUNT=$((PROCESSED_COUNT + 1))
    done < "$TMP_ITEMS"
    rm -f "$TMP_ITEMS"

    # Apply SSH KeepAlive preference
    KEEP_ALIVE_PREF=$(git config sync-ssh.keep-alive)
    if [ "$KEEP_ALIVE_PREF" = "yes" ]; then
        printf "\nHost *\n  ServerAliveInterval 60\n  ServerAliveCountMax 3\n" >> "$MANAGED_FILE"
    elif [ "$KEEP_ALIVE_PREF" = "no" ]; then
        printf "\nHost *\n  ServerAliveInterval 0\n" >> "$MANAGED_FILE"
    fi

    # Update config file using awk for reliable block replacement
    TEMP_CONFIG=$(mktemp)

    awk -v start="$SYNC_START_MARKER" -v end="$SYNC_END_MARKER" -v managed="$MANAGED_FILE" '
    BEGIN { p=1 }
    $0 == start {
        print $0;
        print "# This section is automatically generated. Manual changes will be lost.";
        while ((getline line < managed) > 0) { print line }
        p=0
    }
    $0 == end { p=1; print $0; next }
    p { print $0 }
    ' "$SSH_CONFIG_FILE" > "$TEMP_CONFIG"

    rm "$MANAGED_FILE"
    mv "$TEMP_CONFIG" "$SSH_CONFIG_FILE"
    chmod 600 "$SSH_CONFIG_FILE"

    log_success "\n[OK] Done! Synced $PROCESSED_COUNT SSH keys and updated managed section in config!"
}

# Run sync
sync_ssh
