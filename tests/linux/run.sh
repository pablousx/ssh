#!/bin/sh
set -eu

REPO_ROOT=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd -P)
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
    mkdir -p "$TEST_HOME/.config/sync-ssh" "$TEST_HOME/.local/state"
    chmod 700 "$TEST_HOME" "$TEST_HOME/.config/sync-ssh" "$TEST_HOME/.local/state"
    export HOME="$TEST_HOME"
    export XDG_CONFIG_HOME="$TEST_HOME/.config"
    export XDG_STATE_HOME="$TEST_HOME/.local/state"
    export GIT_CONFIG_GLOBAL="$TEST_HOME/gitconfig"
    export BW_SESSION="mock-session-token"
    unset MOCK_FAIL_SYNC MOCK_FAIL_LIST MOCK_INVALID_JSON MOCK_ITEMS_MODE MOCK_HOSTNAME
}

write_preferences() {
    mode=$1
    signing=${2:-skip}
    printf "commit_signing=%s\nkeep_alive=skip\nagent_mode=%s\n" "$signing" "$mode" \
        >"$XDG_CONFIG_HOME/sync-ssh/config"
    chmod 600 "$XDG_CONFIG_HOME/sync-ssh/config"
}

run_sync() {
    # TEST_SHELL_FLAGS intentionally expands into shell options such as "-x".
    # shellcheck disable=SC2086
    PATH="$REPO_ROOT/tests/mocks:$PATH" sh ${TEST_SHELL_FLAGS:-} "$REPO_ROOT/linux/sync.sh" "$@"
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

new_home setup_smoke
export SHELL=/bin/bash
printf "s\ns\n2\nexport private keys\ny\nn\n" | sh "$REPO_ROOT/linux/setup.sh" >/dev/null
assert_contains "$XDG_CONFIG_HOME/sync-ssh/config" "agent_mode=disk"
assert_contains "$HOME/.bashrc" '. "$HOME/.ssh/sync-ssh-env.sh"'
assert_file "$HOME/.ssh/sync-ssh-env.sh"
pass "interactive setup writes application preferences and one portable profile entry"

new_home successful_agent_sync
write_preferences bitwarden
run_sync
assert_contains "$HOME/.ssh/config" "Include ~/.ssh/sync-ssh/current/config"
assert_contains "$HOME/.ssh/sync-ssh/current/config" "Host production"
assert_file "$HOME/.ssh/sync-ssh/current/keys/production.pub"
assert_no_file "$HOME/.ssh/sync-ssh/current/keys/production"
ssh -F "$HOME/.ssh/config" -G production >/dev/null
pass "successful agent sync"

before_hash=$(sha256sum "$HOME/.ssh/sync-ssh/current/config" | awk '{print $1}')
export MOCK_HOSTNAME="dry-run.example.com"
run_sync --dry-run >/dev/null
dry_run_hash=$(sha256sum "$HOME/.ssh/sync-ssh/current/config" | awk '{print $1}')
[ "$before_hash" = "$dry_run_hash" ] || fail "Dry run changed the active generation"
pass "dry run validates without publishing"
unset MOCK_HOSTNAME

export MOCK_FAIL_LIST=1
if run_sync >/dev/null 2>&1; then
    fail "Bitwarden list failure unexpectedly succeeded"
fi
after_hash=$(sha256sum "$HOME/.ssh/sync-ssh/current/config" | awk '{print $1}')
[ "$before_hash" = "$after_hash" ] || fail "List failure changed the active generation"
pass "vault failure leaves active generation unchanged"

unset MOCK_FAIL_LIST
MOCK_HOSTNAME='example.com
  ProxyCommand touch /tmp/sync-ssh-injected'
export MOCK_HOSTNAME
if run_sync >/dev/null 2>&1; then
    fail "Injected HostName unexpectedly succeeded"
fi
[ ! -e /tmp/sync-ssh-injected ] || fail "Injected command was executed"
pass "metadata injection is rejected"

mkdir -p "$XDG_STATE_HOME/sync-ssh/sync.lock"
if run_sync >/dev/null 2>&1; then
    fail "Concurrent lock unexpectedly succeeded"
fi
[ -d "$XDG_STATE_HOME/sync-ssh/sync.lock" ] || fail "A failed lock attempt removed another process's lock"
rmdir "$XDG_STATE_HOME/sync-ssh/sync.lock"
pass "concurrent lock ownership is preserved"

new_home duplicate_alias
write_preferences bitwarden
export MOCK_ITEMS_MODE=duplicate
if run_sync >/dev/null 2>&1; then
    fail "Duplicate alias unexpectedly succeeded"
fi
assert_no_file "$HOME/.ssh/sync-ssh/current/config"
pass "duplicate aliases are rejected"

new_home malformed_markers
write_preferences bitwarden
mkdir -p "$HOME/.ssh"
printf "Host manual\n  HostName manual.example\n%s\nmanual-tail\n" \
    "# --- START SYNC-SSH MANAGED SECTION ---" >"$HOME/.ssh/config"
original_hash=$(sha256sum "$HOME/.ssh/config" | awk '{print $1}')
if run_sync >/dev/null 2>&1; then
    fail "Malformed markers unexpectedly succeeded"
fi
new_hash=$(sha256sum "$HOME/.ssh/config" | awk '{print $1}')
[ "$original_hash" = "$new_hash" ] || fail "Malformed marker handling changed manual config"
pass "malformed markers fail closed"

new_home symlinked_config
write_preferences bitwarden
mkdir -p "$HOME/.ssh" "$HOME/dotfiles"
printf "Host manual\n  HostName manual.example\n" >"$HOME/dotfiles/ssh-config"
ln -s "$HOME/dotfiles/ssh-config" "$HOME/.ssh/config"
run_sync
[ -L "$HOME/.ssh/config" ] || fail "Sync replaced the user's SSH config symlink"
assert_contains "$HOME/dotfiles/ssh-config" "Include ~/.ssh/sync-ssh/current/config"
assert_contains "$HOME/dotfiles/ssh-config" "Host manual"
pass "symlinked SSH config target is updated without replacing the link"

new_home disk_to_agent
write_preferences disk
run_sync
assert_file "$HOME/.ssh/sync-ssh/current/keys/production"
write_preferences bitwarden
run_sync
assert_no_file "$HOME/.ssh/sync-ssh/current/keys/production"
assert_file "$HOME/.ssh/sync-ssh/current/keys/production.pub"
pass "disk-to-agent transition removes managed private keys"

new_home git_signing_restore
write_preferences bitwarden yes
export MOCK_ITEMS_MODE=git-sign
git config --global gpg.format openpgp
run_sync
[ "$(git config --global gpg.format)" = "ssh" ] || fail "Git signing was not enabled"
[ "$(git config --global commit.gpgsign)" = "true" ] || fail "Commit signing was not enabled"
write_preferences bitwarden no
run_sync
[ "$(git config --global gpg.format)" = "openpgp" ] || fail "Previous gpg.format was not restored"
if git config --global --get commit.gpgsign >/dev/null 2>&1; then
    fail "Tool-owned commit.gpgsign was not removed"
fi
pass "Git signing settings are restored"

printf "\nAll %s Linux integration tests passed.\n" "$PASS_COUNT"
