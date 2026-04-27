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

    if [ "$STATUS" != "unlocked" ]; then
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
    # Type 5 is SSH Key. Return an array of objects for easier lookup.
    bw list items | jq -c '[.[] | select(.type == 5) | {name: .name, hostname: (.fields[]? | select(.name == "HostName") | .value), user: (.fields[]? | select(.name == "User") | .value)}]'
}

sync_ssh() {
    ensure_dependencies
    initialize_ssh_config
    unlock_vault

    # Get keys from native SSH agent
    AGENT_KEYS=$(ssh-add -L 2>/dev/null)
    EXIT_CODE=$?

    if [ $EXIT_CODE -ne 0 ] || [ -z "$AGENT_KEYS" ] || [[ "$AGENT_KEYS" == "The agent has no identities"* ]]; then
        log_error "Error: No keys found in ssh-agent or agent not responding."
        log_warn "Make sure your SSH agent is running and has keys loaded with: ssh-add"
        return 1
    fi

    # Get Bitwarden data as a JSON array
    BW_DATA=$(get_bitwarden_keys)

    NEW_MANAGED_CONTENT=""
    PROCESSED_COUNT=0

    # Process each key from agent
    while read -r KEY_LINE; do
        [ -z "$KEY_LINE" ] && continue
        [[ "$KEY_LINE" == "The agent has no identities"* ]] && continue

        # Parts: [type] [key-blob] [comment]
        # awk handles the first two, cut gets the rest (comment may have spaces)
        TYPE=$(echo "$KEY_LINE" | awk '{print $1}')
        COMMENT=$(echo "$KEY_LINE" | cut -d' ' -f3-)

        # Reset variables for this key
        HOSTNAME=""
        USER=""
        MATCH=""

        # Find match in BW data array
        MATCH=$(echo "$BW_DATA" | jq -c --arg comment "$COMMENT" '.[] | select(.name == $comment)' | head -n 1)

        if [ -n "$MATCH" ]; then
            HOSTNAME=$(echo "$MATCH" | jq -r '.hostname // empty')
            USER=$(echo "$MATCH" | jq -r '.user // empty')
        fi

        # Fallback if no Bitwarden metadata
        if [ -z "$HOSTNAME" ] || [ "$HOSTNAME" = "null" ]; then
            HOSTNAME="$COMMENT"
        fi

        # Sanitize Host alias (safeName)
        SAFE_NAME=$(echo "$COMMENT" | sed 's/[^a-zA-Z0-9._-]/-/g' | tr '[:upper:]' '[:lower:]' | sed 's/^-//;s/-$//')
        if [ -z "$SAFE_NAME" ]; then
            SAFE_NAME="ssh-key-$RANDOM"
        fi

        PUBKEY_FILE="$KEYS_DIR/$SAFE_NAME.pub"
        echo "$KEY_LINE" > "$PUBKEY_FILE"

        # Build config entry
        ENTRY="\nHost $SAFE_NAME\n"
        ENTRY+="  HostName $HOSTNAME\n"
        if [ -n "$USER" ] && [ "$USER" != "null" ]; then
            ENTRY+="  User $USER\n"
        fi
        ENTRY+="  IdentityFile $PUBKEY_FILE\n"
        ENTRY+="  IdentitiesOnly yes\n"

        NEW_MANAGED_CONTENT+="$ENTRY"
        PROCESSED_COUNT=$((PROCESSED_COUNT + 1))
    done <<< "$AGENT_KEYS"

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
