#!/bin/sh

provider_probe() {
    printf '%s\n' \
        '{"protocol_version":1,"provider":"bitwarden","capabilities":{"agent":true,"private_key_export":true}}'
}

provider_requirements() {
    require_command bw
    require_command jq
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

provider_list_records() {
    destination=$1

    log_info "Syncing Bitwarden vault..."
    bw sync >/dev/null ||
        die "Bitwarden sync failed; existing SSH configuration was not changed."

    log_info "Fetching SSH key items..."
    raw_items=$(bw list items) ||
        die "Unable to list Bitwarden items; existing SSH configuration was not changed."
    printf '%s' "$raw_items" | jq -e 'type == "array"' >/dev/null ||
        die "Bitwarden returned invalid item data; existing SSH configuration was not changed."

    printf '%s' "$raw_items" | jq -c '
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
}

provider_export_private_key() {
    source_id=$1
    destination=$2

    item_json=$(bw get item "$source_id") ||
        die "Unable to retrieve a Bitwarden SSH item for private-key export."
    private_key=$(printf '%s' "$item_json" |
        jq -er '
          select(type == "object" and .type == 5) |
          .sshKey.privateKey |
          select(type == "string" and length > 0)
        ') || return 2
    printf '%s\n' "$private_key" >"$destination"
    chmod 600 "$destination"
}
