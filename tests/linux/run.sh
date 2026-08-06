#!/bin/sh
set -eu

REPO_ROOT=$(CDPATH='' cd -- "$(dirname "$0")/../.." && pwd -P)
TEST_ROOT=$(mktemp -d)
PASS_COUNT=0

cleanup() {
    rm -rf -- "$TEST_ROOT"
}
trap cleanup 0
trap 'exit 1' HUP INT TERM

fail() {
    printf "FAIL: %s\n" "$1" >&2
    exit 1
}

assert_file() {
    [ -f "$1" ] || fail "Expected file: $1"
}

assert_no_file() {
    [ ! -e "$1" ] || fail "Expected path to be absent: $1"
}

assert_contains() {
    grep -qF "$2" "$1" || fail "Expected '$2' in $1"
}

new_home() {
    case_name=$1
    TEST_HOME="$TEST_ROOT/$case_name"
    mkdir -p "$TEST_HOME/.config/sshwitch" "$TEST_HOME/.local/state"
    chmod 700 "$TEST_HOME" "$TEST_HOME/.config/sshwitch" "$TEST_HOME/.local/state"
    export HOME="$TEST_HOME"
    export XDG_CONFIG_HOME="$TEST_HOME/.config"
    export XDG_STATE_HOME="$TEST_HOME/.local/state"
    export GIT_CONFIG_GLOBAL="$TEST_HOME/gitconfig"
    export BW_SESSION="mock-session-token"
    unset MOCK_FAIL_UNLOCK MOCK_FAIL_SYNC MOCK_FAIL_LIST MOCK_FAIL_GET MOCK_INVALID_JSON MOCK_ITEMS_MODE MOCK_HOSTNAME
    unset MOCK_BW_STATUS MOCK_BW_SESSION MOCK_LATEST_TAG MOCK_BW_CALL_LOG
    unset MOCK_SSH_ADD_CALL_LOG
    unset MOCK_AGENT_FAILURE MOCK_AGENT_MISMATCH MOCK_CURL_FAILURE MOCK_UNAME_S
    unset SSHWITCH_VERSION SYNC_SSH_VERSION
}

write_preferences() {
    backend=$1
    signing=${2:-skip}
    private_policy="never"
    [ "$backend" = "disk" ] && private_policy="export"
    printf "version=2\nprovider=bitwarden\nidentity_backend=%s\nprivate_key_policy=%s\ncommit_signing=%s\nkeep_alive=skip\nauto_sync=off\n" \
        "$backend" "$private_policy" "$signing" \
        >"$XDG_CONFIG_HOME/sshwitch/config"
    chmod 600 "$XDG_CONFIG_HOME/sshwitch/config"
}

write_legacy_preferences() {
    mode=$1
    printf "commit_signing=skip\nkeep_alive=skip\nagent_mode=%s\n" "$mode" \
        >"$XDG_CONFIG_HOME/sshwitch/config"
    chmod 600 "$XDG_CONFIG_HOME/sshwitch/config"
}

run_sync() {
    # TEST_SHELL_FLAGS intentionally expands into shell options such as "-x".
    # shellcheck disable=SC2086
    PATH="$REPO_ROOT/tests/mocks:$PATH" sh ${TEST_SHELL_FLAGS:-} "$REPO_ROOT/linux/sync.sh" "$@"
}

file_checksum() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    else
        shasum -a 256 "$1" | awk '{print $1}'
    fi
}

pass() {
    PASS_COUNT=$((PASS_COUNT + 1))
    printf "PASS: %s\n" "$1"
}

key_path="$TEST_ROOT/test-key"
ssh-keygen -q -t ed25519 -N "" -f "$key_path"
MOCK_PUBLIC_KEY=$(cat "$key_path.pub")
MOCK_PRIVATE_KEY=$(cat "$key_path")
export MOCK_PUBLIC_KEY MOCK_PRIVATE_KEY

new_home provider_contract
PATH="$REPO_ROOT/tests/mocks:$PATH"
export PATH
require_command() { command -v "$1" >/dev/null 2>&1 || fail "Missing provider command: $1"; }
log_info() { :; }
die() { fail "$1"; }
# shellcheck source=../../linux/providers/bitwarden.sh
# shellcheck disable=SC1091
. "$REPO_ROOT/linux/providers/bitwarden.sh"
probe=$(provider_probe)
printf '%s' "$probe" | jq -e '
  .protocol_version == 1 and .provider == "bitwarden" and
  .capabilities.agent == true and .capabilities.private_key_export == true
' >/dev/null || fail "Provider probe violates protocol version 1"
provider_requirements
provider_authenticate
provider_sync
provider_records="$TEST_HOME/provider-records.json"
provider_list_records "$provider_records"
jq -e '
  .schema_version == 1 and .provider == "bitwarden" and
  (.records | length == 1) and
  (.records[0] | has("private_key") | not) and
  (.records[0].identity | has("private_key") | not)
' "$provider_records" >/dev/null || fail "Provider list output is not canonical and secret-free"
if grep -qF -- "$MOCK_PRIVATE_KEY" "$provider_records"; then
    fail "Provider list output exposed a private key"
fi
provider_private="$TEST_HOME/provider-private"
provider_export_private_key production "$provider_private"
[ "$(cat "$provider_private")" = "$MOCK_PRIVATE_KEY" ] ||
    fail "Provider private-key export returned unexpected content"
pass "Bitwarden adapter conforms to provider protocol version 1"

new_home bitwarden_bad_password
write_preferences agent
export MOCK_BW_STATUS=locked
export MOCK_FAIL_UNLOCK=1
if bad_password_output=$(printf 'wrong-password\n' | run_sync 2>&1); then
    fail "Bitwarden unlock unexpectedly succeeded with a bad password"
fi
printf '%s' "$bad_password_output" |
    grep -qF "Unable to unlock Bitwarden vault. Check your master password and try again." ||
    fail "Bitwarden unlock failure did not report a concise password error"
if printf '%s' "$bad_password_output" | grep -qF "Cryptography error"; then
    fail "Bitwarden cryptography diagnostics leaked into the user-facing error"
fi
assert_no_file "$HOME/.ssh/sshwitch/current/config"
pass "bad Bitwarden password reports a concise error"

new_home bitwarden_unlock_trace
write_preferences agent
export MOCK_BW_STATUS=locked
export MOCK_BW_SESSION=trace-session-secret
export TEST_SHELL_FLAGS=-x
trace_output=$(printf 'trace-password-secret\n' | run_sync 2>&1) ||
    fail "Bitwarden unlock failed while checking debug trace safety"
unset TEST_SHELL_FLAGS
if printf '%s' "$trace_output" |
    grep -qE 'trace-password-secret|trace-session-secret|BEGIN OPENSSH PRIVATE KEY'; then
    fail "Bitwarden password, session token, or private key appeared in debug output"
fi
pass "Bitwarden secrets stay out of debug traces"

new_home setup_smoke
export SHELL=/bin/bash
printf "s\ns\ns\n2\nexport private keys\ny\nn\n" | sh "$REPO_ROOT/linux/setup.sh" >/dev/null
assert_contains "$XDG_CONFIG_HOME/sshwitch/config" "provider=bitwarden"
assert_contains "$XDG_CONFIG_HOME/sshwitch/config" "identity_backend=disk"
assert_contains "$XDG_CONFIG_HOME/sshwitch/config" "private_key_policy=export"
# The profile entry must retain $HOME for evaluation by future shells.
# shellcheck disable=SC2016
assert_contains "$HOME/.bashrc" '. "$HOME/.ssh/sshwitch-env.sh"'
assert_file "$HOME/.ssh/sshwitch-env.sh"
for test_shell in sh bash; do
    # Positional parameters are intentionally expanded by the child shell.
    # shellcheck disable=SC2016
    "$test_shell" -c '. "$1"; command -v sshwitch >/dev/null; alias sync-ssh >/dev/null' \
        sh "$HOME/.ssh/sshwitch-env.sh" ||
        fail "SSHwitch or legacy shell command was not defined for $test_shell"
done
pass "interactive setup writes version 2 preferences and one portable profile entry"

new_home daily_auto_sync_notice
export SHELL=/bin/bash
printf "s\ns\ny\n1\ny\nn\n" | sh "$REPO_ROOT/linux/setup.sh" >/dev/null
assert_contains "$XDG_CONFIG_HOME/sshwitch/config" "auto_sync=daily"
unset BW_SESSION
auto_notice=$(sh -c '. "$1"' sh "$HOME/.ssh/sshwitch-env.sh" 2>&1)
printf '%s' "$auto_notice" | grep -qF "SSHwitch automatic sync is due" ||
    fail "A due automatic sync without a session did not report the interactive action"
printf '%s\n' "$(date +%s)" >"$XDG_STATE_HOME/sshwitch/last-success"
auto_notice=$(sh -c '. "$1"' sh "$HOME/.ssh/sshwitch-env.sh" 2>&1)
[ -z "$auto_notice" ] || fail "A recent automatic sync produced shell-startup output"
printf '0\n' >"$XDG_STATE_HOME/sshwitch/last-success"
export BW_SESSION=mock-session-token
sh -c '. "$1"' sh "$HOME/.ssh/sshwitch-env.sh"
wait_count=0
while [ "$(cat "$XDG_STATE_HOME/sshwitch/last-success")" = 0 ] && [ "$wait_count" -lt 5 ]; do
    sleep 1
    wait_count=$((wait_count + 1))
done
[ "$(cat "$XDG_STATE_HOME/sshwitch/last-success")" != 0 ] ||
    fail "A due automatic sync with a session did not complete in the background"
pass "daily auto-sync due checks do not block shell startup"

new_home stamped_installer
export MOCK_UNAME_S=Darwin
export MOCK_CURL_FAILURE=1
stamped_installer="$TEST_HOME/install.sh"
sed 's/__SSHWITCH_RELEASE_VERSION__/v9.8.7/g' "$REPO_ROOT/install.sh" >"$stamped_installer"
if installer_output=$(sh "$stamped_installer" 2>&1); then
    fail "Installer unexpectedly succeeded with a failed download"
fi
printf '%s' "$installer_output" | grep -qF "Downloading SSHwitch v9.8.7" ||
    fail "Installer rejected macOS or ignored the embedded release version"
if printf '%s' "$installer_output" | grep -qF "supports Linux"; then
    fail "Installer reported macOS as unsupported"
fi
assert_no_file "$HOME/.local/share/sshwitch"
pass "stamped release installer uses its embedded version"

new_home source_installer
export MOCK_LATEST_TAG=v9.8.7
export MOCK_CURL_FAILURE=1
if installer_output=$(sh "$REPO_ROOT/install.sh" 2>&1); then
    fail "Source installer unexpectedly succeeded with a failed download"
fi
printf '%s' "$installer_output" | grep -qF "Downloading SSHwitch v9.8.7" ||
    fail "Source installer did not resolve the latest release"
assert_no_file "$HOME/.local/share/sshwitch"
pass "source installer resolves the latest release"

new_home macos_setup
export SHELL=/bin/zsh
export MOCK_UNAME_S=Darwin
mkdir -p "$HOME/Library/Containers/com.bitwarden.desktop"
setup_output=$(printf "s\ns\ns\n1\ny\nn\n" | sh "$REPO_ROOT/linux/setup.sh" 2>&1)
printf '%s' "$setup_output" | grep -qF "Detected OS: macOS" ||
    fail "Setup did not detect macOS"
expected_store_socket="$HOME/Library/Containers/com.bitwarden.desktop/Data/.bitwarden-ssh-agent.sock"
# Positional parameters are intentionally expanded by the child shell.
# shellcheck disable=SC2016
sh -c '. "$1"; [ "$SSH_AUTH_SOCK" = "$2" ]' sh \
    "$HOME/.ssh/sshwitch-env.sh" "$expected_store_socket" ||
    fail "macOS App Store agent socket was not selected"
rmdir "$HOME/Library/Containers/com.bitwarden.desktop"
# Positional parameters are intentionally expanded by the child shell.
# shellcheck disable=SC2016
sh -c '. "$1"; [ "$SSH_AUTH_SOCK" = "$2" ]' sh \
    "$HOME/.ssh/sshwitch-env.sh" "$HOME/.bitwarden-ssh-agent.sock" ||
    fail "macOS DMG agent socket was not selected"
pass "macOS setup selects the Bitwarden App Store or DMG agent socket"

new_home successful_agent_sync
write_preferences agent
timing_output=$(run_sync --timings 2>&1)
printf '%s' "$timing_output" | grep -qF "SSHwitch timings (seconds):" ||
    fail "Timing output was not reported"
assert_contains "$HOME/.ssh/config" "Include ~/.ssh/sshwitch/current/config"
assert_contains "$HOME/.ssh/sshwitch/current/config" "Host production"
assert_file "$HOME/.ssh/sshwitch/current/keys/production.pub"
assert_no_file "$HOME/.ssh/sshwitch/current/keys/production"
ssh -F "$HOME/.ssh/config" -G production >/dev/null
assert_file "$XDG_STATE_HOME/sshwitch/last-success"
pass "successful agent sync"

new_home single_agent_snapshot
write_preferences agent
export MOCK_ITEMS_MODE=git-sign
export MOCK_SSH_ADD_CALL_LOG="$TEST_HOME/ssh-add.calls"
run_sync >/dev/null
[ "$(wc -l <"$MOCK_SSH_ADD_CALL_LOG" | tr -d ' ')" = 1 ] ||
    fail "Agent identities were queried more than once per generation"
pass "agent identities are listed once per generation"

new_home cached_disk_exports
write_preferences disk
export MOCK_ITEMS_MODE=git-sign
export MOCK_BW_CALL_LOG="$TEST_HOME/bw.calls"
run_sync >/dev/null
if grep -q '^get item ' "$MOCK_BW_CALL_LOG"; then
    fail "Disk mode fetched individual Bitwarden items after listing the vault"
fi
assert_file "$HOME/.ssh/sshwitch/current/keys/production"
assert_file "$HOME/.ssh/sshwitch/current/keys/git-sign"
pass "disk exports reuse the provider response held in adapter memory"

new_home sync_ssh_brand_migration
mkdir -p "$XDG_CONFIG_HOME/sync-ssh" "$HOME/.ssh/sync-ssh/current"
printf "version=2\nprovider=bitwarden\nidentity_backend=agent\nprivate_key_policy=never\ncommit_signing=skip\nkeep_alive=skip\n" \
    >"$XDG_CONFIG_HOME/sync-ssh/config"
chmod 600 "$XDG_CONFIG_HOME/sync-ssh/config"
printf "legacy generation\n" >"$HOME/.ssh/sync-ssh/current/config"
printf "# Added by Sync-SSH\nInclude ~/.ssh/sync-ssh/current/config\n\nHost manual\n  HostName manual.example\n" \
    >"$HOME/.ssh/config"
run_sync
assert_contains "$HOME/.ssh/config" "# Added by SSHwitch"
assert_contains "$HOME/.ssh/config" "Include ~/.ssh/sshwitch/current/config"
assert_contains "$HOME/.ssh/config" "Host manual"
if grep -qF "Include ~/.ssh/sync-ssh/current/config" "$HOME/.ssh/config"; then
    fail "Legacy Sync-SSH Include remained after migration"
fi
assert_contains "$HOME/.ssh/sync-ssh/current/config" "legacy generation"
assert_file "$HOME/.ssh/sshwitch/current/keys/production.pub"
pass "legacy Sync-SSH preferences and Include migrate after successful validation"

new_home sync_ssh_brand_migration_failure
mkdir -p "$XDG_CONFIG_HOME/sync-ssh" "$HOME/.ssh/sync-ssh/current"
printf "version=2\nprovider=bitwarden\nidentity_backend=agent\nprivate_key_policy=never\ncommit_signing=skip\nkeep_alive=skip\n" \
    >"$XDG_CONFIG_HOME/sync-ssh/config"
chmod 600 "$XDG_CONFIG_HOME/sync-ssh/config"
printf "legacy generation\n" >"$HOME/.ssh/sync-ssh/current/config"
printf "# Added by Sync-SSH\nInclude ~/.ssh/sync-ssh/current/config\n" >"$HOME/.ssh/config"
legacy_main_hash=$(file_checksum "$HOME/.ssh/config")
export MOCK_FAIL_LIST=1
if run_sync >/dev/null 2>&1; then
    fail "Failed provider unexpectedly migrated the legacy installation"
fi
[ "$(file_checksum "$HOME/.ssh/config")" = "$legacy_main_hash" ] ||
    fail "Failed migration changed the active SSH config"
assert_contains "$HOME/.ssh/sync-ssh/current/config" "legacy generation"
assert_no_file "$HOME/.ssh/sshwitch/current/config"
pass "failed provider validation leaves the legacy Sync-SSH generation active"

new_home legacy_preferences
write_legacy_preferences bitwarden
run_sync
assert_file "$HOME/.ssh/sshwitch/current/keys/production.pub"
assert_no_file "$HOME/.ssh/sshwitch/current/keys/production"
pass "legacy agent_mode preferences map to the provider-neutral model"

before_hash=$(file_checksum "$HOME/.ssh/sshwitch/current/config")
export MOCK_HOSTNAME="dry-run.example.com"
run_sync --dry-run >/dev/null
dry_run_hash=$(file_checksum "$HOME/.ssh/sshwitch/current/config")
[ "$before_hash" = "$dry_run_hash" ] || fail "Dry run changed the active generation"
pass "dry run validates without publishing"
unset MOCK_HOSTNAME

export MOCK_FAIL_LIST=1
if run_sync >/dev/null 2>&1; then
    fail "Bitwarden list failure unexpectedly succeeded"
fi
after_hash=$(file_checksum "$HOME/.ssh/sshwitch/current/config")
[ "$before_hash" = "$after_hash" ] || fail "List failure changed the active generation"
pass "vault failure leaves active generation unchanged"

unset MOCK_FAIL_LIST
MOCK_HOSTNAME='example.com
  ProxyCommand touch /tmp/sshwitch-injected'
export MOCK_HOSTNAME
if run_sync >/dev/null 2>&1; then
    fail "Injected HostName unexpectedly succeeded"
fi
[ ! -e /tmp/sshwitch-injected ] || fail "Injected command was executed"
pass "metadata injection is rejected"

new_home agent_mismatch
write_preferences agent
export MOCK_AGENT_MISMATCH=1
if run_sync >/dev/null 2>&1; then
    fail "Agent mismatch unexpectedly succeeded"
fi
assert_no_file "$HOME/.ssh/sshwitch/current/config"
pass "agent identity mismatch fails before publication"

mkdir -p "$XDG_STATE_HOME/sshwitch/sync.lock"
if run_sync >/dev/null 2>&1; then
    fail "Concurrent lock unexpectedly succeeded"
fi
[ -d "$XDG_STATE_HOME/sshwitch/sync.lock" ] || fail "A failed lock attempt removed another process's lock"
rmdir "$XDG_STATE_HOME/sshwitch/sync.lock"
pass "concurrent lock ownership is preserved"

new_home duplicate_alias
write_preferences agent
export MOCK_ITEMS_MODE=duplicate
if run_sync >/dev/null 2>&1; then
    fail "Duplicate alias unexpectedly succeeded"
fi
assert_no_file "$HOME/.ssh/sshwitch/current/config"
pass "duplicate aliases are rejected"

new_home invalid_provider_schema
write_preferences agent
export MOCK_ITEMS_MODE=missing-id
if run_sync >/dev/null 2>&1; then
    fail "Invalid provider schema unexpectedly succeeded"
fi
assert_no_file "$HOME/.ssh/sshwitch/current/config"
pass "invalid canonical provider records are rejected"

new_home malformed_markers
write_preferences agent
mkdir -p "$HOME/.ssh"
printf "Host manual\n  HostName manual.example\n%s\nmanual-tail\n" \
    "# --- START SYNC-SSH MANAGED SECTION ---" >"$HOME/.ssh/config"
original_hash=$(file_checksum "$HOME/.ssh/config")
if run_sync >/dev/null 2>&1; then
    fail "Malformed markers unexpectedly succeeded"
fi
new_hash=$(file_checksum "$HOME/.ssh/config")
[ "$original_hash" = "$new_hash" ] || fail "Malformed marker handling changed manual config"
pass "malformed markers fail closed"

new_home symlinked_config
write_preferences agent
mkdir -p "$HOME/.ssh" "$HOME/dotfiles"
printf "Host manual\n  HostName manual.example\n" >"$HOME/dotfiles/ssh-config"
ln -s "../dotfiles/ssh-config" "$HOME/.ssh/config"
run_sync
[ -L "$HOME/.ssh/config" ] || fail "Sync replaced the user's SSH config symlink"
assert_contains "$HOME/dotfiles/ssh-config" "Include ~/.ssh/sshwitch/current/config"
assert_contains "$HOME/dotfiles/ssh-config" "Host manual"
pass "symlinked SSH config target is updated without replacing the link"

new_home disk_to_agent
write_preferences disk
run_sync
assert_file "$HOME/.ssh/sshwitch/current/keys/production"
write_preferences agent
run_sync
assert_no_file "$HOME/.ssh/sshwitch/current/keys/production"
assert_file "$HOME/.ssh/sshwitch/current/keys/production.pub"
pass "disk-to-agent transition removes managed private keys"

new_home git_signing_restore
write_preferences agent yes
export MOCK_ITEMS_MODE=git-sign
git config --global gpg.format openpgp
run_sync
[ "$(git config --global gpg.format)" = "ssh" ] || fail "Git signing was not enabled"
[ "$(git config --global commit.gpgsign)" = "true" ] || fail "Commit signing was not enabled"
write_preferences agent no
run_sync
[ "$(git config --global gpg.format)" = "openpgp" ] || fail "Previous gpg.format was not restored"
if git config --global --get commit.gpgsign >/dev/null 2>&1; then
    fail "Tool-owned commit.gpgsign was not removed"
fi
pass "Git signing settings are restored"

new_home git_signing_key_missing
write_preferences agent yes
export MOCK_ITEMS_MODE=git-sign
git config --global gpg.format openpgp
run_sync
[ "$(git config --global gpg.format)" = "ssh" ] || fail "Git signing was not enabled before key removal"
unset MOCK_ITEMS_MODE
missing_signing_output=$(run_sync 2>&1) ||
    fail "A missing git-sign key unexpectedly prevented SSH synchronization"
printf '%s' "$missing_signing_output" |
    grep -qF "SSHwitch-owned Git signing settings were restored" ||
    fail "A missing git-sign key did not emit the expected warning"
assert_file "$HOME/.ssh/sshwitch/current/config"
[ "$(git config --global gpg.format)" = "openpgp" ] ||
    fail "A missing git-sign key did not restore the previous gpg.format"
if git config --global --get commit.gpgsign >/dev/null 2>&1; then
    fail "A missing git-sign key left commit signing enabled"
fi
pass "missing Git signing key restores owned settings without preventing SSH synchronization"

printf "\nAll %s POSIX integration tests passed.\n" "$PASS_COUNT"
