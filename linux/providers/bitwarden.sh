#!/bin/sh

provider_probe() {
    printf '%s\n' \
        '{"protocol_version":1,"provider":"bitwarden","capabilities":{"agent":true,"private_key_export":true}}'
}

provider_requirements() {
    require_command bw
    require_command jq
}

provider_unlock() {
    trace_was_enabled=false
    case $- in
        *x*) trace_was_enabled=true; set +x ;;
    esac

    printf "? Master password: " >&2
    if [ -t 0 ]; then
        SSHWITCH_TTY_STATE=$(stty -g) || {
            [ "$trace_was_enabled" = false ] || set -x
            return 1
        }
        stty -echo || {
            SSHWITCH_TTY_STATE=""
            [ "$trace_was_enabled" = false ] || set -x
            return 1
        }
    fi
    password_read=true
    IFS= read -r SSHWITCH_BW_PASSWORD || password_read=false
    if [ -n "${SSHWITCH_TTY_STATE:-}" ]; then
        stty "$SSHWITCH_TTY_STATE" 2>/dev/null || true
        SSHWITCH_TTY_STATE=""
    fi
    printf "\n" >&2
    if [ "$password_read" = false ]; then
        unset SSHWITCH_BW_PASSWORD
        [ "$trace_was_enabled" = false ] || set -x
        return 1
    fi

    export SSHWITCH_BW_PASSWORD
    unlock_succeeded=true
    BW_SESSION=$(bw unlock --raw --passwordenv SSHWITCH_BW_PASSWORD 2>/dev/null) ||
        unlock_succeeded=false
    unset SSHWITCH_BW_PASSWORD
    BW_SESSION=$(printf '%s' "$BW_SESSION" | tr -d '\r\n')
    export BW_SESSION
    unlock_status=0
    if [ "$unlock_succeeded" = false ]; then
        unlock_status=1
    elif [ -z "$BW_SESSION" ]; then
        unlock_status=2
    fi
    [ "$trace_was_enabled" = false ] || set -x

    return "$unlock_status"
}

provider_authenticate() {
    status_json=$(bw status) || die "Unable to query Bitwarden status."
    status=$(printf '%s' "$status_json" | jq -er '.status') ||
        die "Bitwarden returned an invalid status response."

    case "$status" in
        unauthenticated)
            die "Bitwarden is not logged in. Run 'bw login' first."
            ;;
        locked)
            if [ "${NON_INTERACTIVE:-false}" = true ]; then
                die "Bitwarden requires an interactive unlock; run 'sshwitch' to refresh credentials."
            fi
            log_info "Unlocking Bitwarden vault..."
            provider_unlock ||
                die "Unable to unlock Bitwarden vault. Check your master password and try again."
            ;;
        unlocked)
            if [ -z "${BW_SESSION:-}" ]; then
                if [ "${NON_INTERACTIVE:-false}" = true ]; then
                    die "Bitwarden has no session key; run 'sshwitch' to refresh credentials."
                fi
                log_info "Requesting a Bitwarden session token..."
                provider_unlock ||
                    die "Unable to unlock Bitwarden vault. Check your master password and try again."
            fi
            ;;
        *)
            die "Unsupported Bitwarden status: $status"
            ;;
    esac
}

provider_sync() {
    log_info "Syncing Bitwarden vault..."
    bw sync >/dev/null ||
        die "Bitwarden sync failed; existing SSH configuration was not changed."
}

provider_list_records() {
    destination=$1
    trace_was_enabled=false
    case $- in
        *x*) trace_was_enabled=true; set +x ;;
    esac

    log_info "Fetching SSH key items..."
    SSHWITCH_BITWARDEN_ITEMS=$(bw list items) ||
        die "Unable to list Bitwarden items; existing SSH configuration was not changed."
    printf '%s' "$SSHWITCH_BITWARDEN_ITEMS" | jq -e 'type == "array"' >/dev/null ||
        die "Bitwarden returned invalid item data; existing SSH configuration was not changed."

    printf '%s' "$SSHWITCH_BITWARDEN_ITEMS" | jq -c '
        def field($names):
          (.fields // [] |
            map(select((.name | ascii_downcase) as $name | $names | index($name))) |
            first | .value // "");
        def normalized_alias:
          ascii_downcase |
          gsub("[^a-z0-9._-]"; "-") |
          sub("^-+"; "") |
          sub("-+$"; "");
        {
          schema_version: 1,
          provider: "bitwarden",
          records: [
            .[] | select(.type == 5) |
            {
              source_id: (.id // ""),
              name: .name,
              role: (
                field(["sshwitchrole", "syncsshrole", "role"]) as $role |
                if ($role | ascii_downcase) == "git-sign" or
                   ((.name | normalized_alias) == "git-sign" and $role == "")
                then "git-sign"
                else "host"
                end
              ),
              destination: {
                hostname: field(["hostname"]),
                user: field(["user"])
              },
              identity: {
                public_key: (.sshKey.publicKey // "")
              },
              git_principal: field(["email", "gitemail"]),
              shared: (
                (.organizationId // "") != "" and
                (.organizationId // "") != "00000000-0000-0000-0000-000000000000"
              )
            }
          ]
        }
    ' >"$destination" || die "Unable to normalize Bitwarden SSH items."
    chmod 600 "$destination"
    [ "$trace_was_enabled" = false ] || set -x
}

provider_export_private_key() {
    source_id=$1
    destination=$2
    trace_was_enabled=false
    case $- in
        *x*) trace_was_enabled=true; set +x ;;
    esac

    export_succeeded=true
    private_key=$(printf '%s' "${SSHWITCH_BITWARDEN_ITEMS:-[]}" |
        jq -er '
          .[] | select(.id == $source_id and .type == 5) |
          .sshKey.privateKey |
          select(type == "string" and length > 0)
        ' --arg source_id "$source_id") || export_succeeded=false
    if [ "$export_succeeded" = false ]; then
        unset private_key
        [ "$trace_was_enabled" = false ] || set -x
        return 2
    fi
    printf '%s\n' "$private_key" >"$destination"
    chmod 600 "$destination"
    unset private_key
    [ "$trace_was_enabled" = false ] || set -x
}

provider_clear_sensitive_state() {
    unset SSHWITCH_BITWARDEN_ITEMS
}
