#!/bin/sh
set -eu

VERSION="${SSHWITCH_VERSION:-${SYNC_SSH_VERSION:-v1.0.0}}"
REPOSITORY="pablousx/sshwitch"
INSTALL_PARENT="$HOME/.local/share"
INSTALL_DIR="$INSTALL_PARENT/sshwitch"
LEGACY_INSTALL_DIR="$INSTALL_PARENT/sync-ssh"
STAGING_ROOT=""
NEW_INSTALL=""
BACKUP_DIR="$INSTALL_PARENT/.sshwitch.previous"

cleanup() {
    [ -z "$STAGING_ROOT" ] || [ ! -d "$STAGING_ROOT" ] || rm -rf -- "$STAGING_ROOT"
    [ -z "$NEW_INSTALL" ] || [ ! -d "$NEW_INSTALL" ] || rm -rf -- "$NEW_INSTALL"
}
trap cleanup 0
trap 'exit 1' HUP INT TERM

for command_name in curl tar sha256sum; do
    command -v "$command_name" >/dev/null 2>&1 || {
        printf "Error: required command not found: %s\n" "$command_name" >&2
        exit 1
    }
done

case "$(uname -s)" in
    Linux) ;;
    *) printf "This installer supports Linux and WSL only.\n" >&2; exit 1 ;;
esac

archive_name="sshwitch-$VERSION.tar.gz"
release_url="https://github.com/$REPOSITORY/releases/download/$VERSION"
STAGING_ROOT=$(mktemp -d)
chmod 700 "$STAGING_ROOT"

printf "Downloading SSHwitch %s...\n" "$VERSION"
curl -fsSL "$release_url/$archive_name" -o "$STAGING_ROOT/$archive_name"
curl -fsSL "$release_url/$archive_name.sha256" -o "$STAGING_ROOT/$archive_name.sha256"
(
    cd "$STAGING_ROOT"
    sha256sum -c "$archive_name.sha256"
)

tar -xzf "$STAGING_ROOT/$archive_name" -C "$STAGING_ROOT"
[ -f "$STAGING_ROOT/sshwitch/linux/setup.sh" ] &&
    [ -f "$STAGING_ROOT/sshwitch/linux/sync.sh" ] &&
    [ -f "$STAGING_ROOT/sshwitch/linux/providers/bitwarden.sh" ] || {
        printf "Release archive is missing Linux scripts.\n" >&2
        exit 1
    }

mkdir -p "$INSTALL_PARENT"
NEW_INSTALL="$INSTALL_PARENT/.sshwitch.new.$$"
mkdir "$NEW_INSTALL"
cp "$STAGING_ROOT/sshwitch/linux/setup.sh" "$NEW_INSTALL/setup.sh"
cp "$STAGING_ROOT/sshwitch/linux/sync.sh" "$NEW_INSTALL/sync.sh"
mkdir "$NEW_INSTALL/providers"
cp "$STAGING_ROOT/sshwitch/linux/providers/bitwarden.sh" "$NEW_INSTALL/providers/bitwarden.sh"
printf '%s\n' "$VERSION" >"$NEW_INSTALL/VERSION"
chmod 700 "$NEW_INSTALL"
chmod 755 "$NEW_INSTALL/setup.sh" "$NEW_INSTALL/sync.sh" "$NEW_INSTALL/providers/bitwarden.sh"
chmod 700 "$NEW_INSTALL/providers"
chmod 600 "$NEW_INSTALL/VERSION"

[ ! -e "$BACKUP_DIR" ] || rm -rf -- "$BACKUP_DIR"
if [ -d "$INSTALL_DIR" ]; then
    mv "$INSTALL_DIR" "$BACKUP_DIR"
fi
if ! mv "$NEW_INSTALL" "$INSTALL_DIR"; then
    [ ! -d "$BACKUP_DIR" ] || mv "$BACKUP_DIR" "$INSTALL_DIR"
    printf "Unable to publish the new installation.\n" >&2
    exit 1
fi
NEW_INSTALL=""

if ! "$INSTALL_DIR/setup.sh" </dev/tty; then
    rm -rf -- "$INSTALL_DIR"
    [ ! -d "$BACKUP_DIR" ] || mv "$BACKUP_DIR" "$INSTALL_DIR"
    printf "Setup failed; the previous installation was restored.\n" >&2
    exit 1
fi
[ ! -d "$BACKUP_DIR" ] || rm -rf -- "$BACKUP_DIR"
[ ! -d "$LEGACY_INSTALL_DIR" ] || rm -rf -- "$LEGACY_INSTALL_DIR"

printf "Installed SSHwitch %s.\n" "$VERSION"
