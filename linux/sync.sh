#!/bin/bash

# =========== Constants ===========
SYNC_START_MARKER="# --- START SYNC-SSH MANAGED SECTION ---"
SYNC_END_MARKER="# --- END SYNC-SSH MANAGED SECTION ---"
OUTPUT_DIR="$HOME/.ssh"
KEYS_DIR="$OUTPUT_DIR/keys"
SSH_CONFIG_FILE="$OUTPUT_DIR/config"
DOT_SSH_CONFIG="$HOME/.ssh/config"

# =========== Functions ===========

log_info() {
    echo -e "\e[36m$1\e[0m" >&2
}

log_success() {
    echo -e "\e[32m$1\e[0m" >&2
}

log_warn() {
    echo -e "\e[33m$1\e[0m" >&2
}

log_error() {
    echo -e "\e[31m$1\e[0m" >&2
}

ensure_dependencies() {
    if ! command -v bw &> /dev/null; then
        log_error "Bitwarden CLI (bw) not found."
        log_warn "Please install it: https://bitwarden.com/help/cli/"
        exit 1
    fi

    if ! command -v jq &> /dev/null; then
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
        echo -e "Host *\n  Port 22\n  AddKeysToAgent yes\n" > "$SSH_CONFIG_FILE"
    fi

    # Ensure markers exist
    if ! grep -qF "$SYNC_START_MARKER" "$SSH_CONFIG_FILE"; then
        log_info "Adding managed section markers to $SSH_CONFIG_FILE"
        echo -e "\n$SYNC_START_MARKER\n# This section is automatically generated. Manual changes will be lost.\n$SYNC_END_MARKER" >> "$SSH_CONFIG_FILE"
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

    if [ -z "$BW_SESSION" ]; then

        log_warn "Bitwarden Vault: $STATUS"
        log_info "Unlocking vault..."
        BW_SESSION=$(bw unlock --raw)
        if [ $? -eq 0 ]; then
            export BW_SESSION
            log_success "[OK] Vault unlocked successfully!"
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

    # Get Bitwarden items as a flat JSON array with extracted fields
    BW_DATA=$(bw list items | jq -c '[.[] | select(.type == 5) | {
        id: .id,
        name: .name,
        hostname: (.fields[]? | select(.name == "HostName") | .value),
        user: (.fields[]? | select(.name == "User") | .value),
        pubkey: .sshKey.publicKey,
        org: .organizationId
    }]')

    # Process git-sign separately
    GIT_SIGN=$(echo "$BW_DATA" | jq -c '.[] | select(.name | ascii_downcase == "git-sign")' | head -n 1)
    if [ -n "$GIT_SIGN" ] && [ "$(echo "$GIT_SIGN" | jq -r '.pubkey')" != "null" ]; then
        SIGN_PUB="$KEYS_DIR/git-sign.pub"
        echo "$GIT_SIGN" | jq -r '.pubkey' > "$SIGN_PUB"
        chmod 600 "$SIGN_PUB"

        git config --global gpg.format ssh
        git config --global user.signingkey "$SIGN_PUB"
        git config --global commit.gpgsign true
        log_success "Synced Git signing key: git-sign"
    fi

    NEW_MANAGED_CONTENT=""
    PROCESSED_COUNT=0

    # Process items
    while read -r ITEM; do
        NAME=$(echo "$ITEM" | jq -r '.name')
        [ "${NAME,,}" == "git-sign" ] && continue

        HOST=$(echo "$ITEM" | jq -r '.hostname // empty')
        USER=$(echo "$ITEM" | jq -r '.user // empty')
        PUB=$(echo "$ITEM" | jq -r '.pubkey // empty')
        ORG=$(echo "$ITEM" | jq -r '.org // empty')

        if [ -z "$PUB" ] || [ -z "$HOST" ]; then
            log_warn "Skipping '$NAME': Missing metadata (HostName or Public Key)"
            continue
        fi

        [ -n "$ORG" ] && [ "$ORG" != "null" ] && log_warn "Notice: '$NAME' is an Org key."

        SAFE_NAME=$(echo "$NAME" | sed 's/[^a-zA-Z0-9._-]/-/g' | tr '[:upper:]' '[:lower:]' | sed 's/^-//;s/-$//')
        PUB_FILE="$KEYS_DIR/$SAFE_NAME.pub"
        echo "$PUB" > "$PUB_FILE" && chmod 600 "$PUB_FILE"

        ENTRY="\nHost $SAFE_NAME\n  HostName $HOST\n"
        [ -n "$USER" ] && ENTRY+="  User $USER\n"
        ENTRY+="  IdentityFile $PUB_FILE\n  IdentitiesOnly yes\n"

        NEW_MANAGED_CONTENT+="$ENTRY"
        PROCESSED_COUNT=$((PROCESSED_COUNT + 1))
    done < <(echo "$BW_DATA" | jq -c '.[]')


    # Apply SSH KeepAlive preference
    KEEP_ALIVE_PREF=$(git config sync-ssh.keep-alive)
    if [ "$KEEP_ALIVE_PREF" = "yes" ]; then
        NEW_MANAGED_CONTENT+="\nHost *\n  ServerAliveInterval 60\n  ServerAliveCountMax 3\n"
    elif [ "$KEEP_ALIVE_PREF" = "no" ]; then
        NEW_MANAGED_CONTENT+="\nHost *\n  ServerAliveInterval 0\n"
    fi

    # Update config file using awk for reliable block replacement
    TEMP_CONFIG=$(mktemp)
    MANAGED_FILE=$(mktemp)
    echo -e "$NEW_MANAGED_CONTENT" > "$MANAGED_FILE"

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
