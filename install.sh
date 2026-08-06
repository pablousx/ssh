#!/bin/sh
set -eu

RELEASE_VERSION='__SSHWITCH_RELEASE_VERSION__'
VERSION="${SSHWITCH_VERSION:-${SYNC_SSH_VERSION:-$RELEASE_VERSION}}"
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

if [ "$VERSION" = "$RELEASE_VERSION" ]; then
    printf "Error: installer release version was not embedded. Set SSHWITCH_VERSION explicitly.\n" >&2
    exit 1
fi

for command_name in curl tar; do
    command -v "$command_name" >/dev/null 2>&1 || {
        printf "Error: required command not found: %s\n" "$command_name" >&2
        exit 1
    }
done

if command -v sha256sum >/dev/null 2>&1; then
    CHECKSUM_COMMAND="sha256sum"
elif command -v shasum >/dev/null 2>&1; then
    CHECKSUM_COMMAND="shasum"
else
    printf "Error: required command not found: sha256sum or shasum\n" >&2
    exit 1
fi

case "$(uname -s)" in
    Linux|Darwin) ;;
    *) printf "This installer supports Linux, WSL, and macOS only.\n" >&2; exit 1 ;;
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
    if [ "$CHECKSUM_COMMAND" = "sha256sum" ]; then
        sha256sum -c "$archive_name.sha256"
    else
        shasum -a 256 -c "$archive_name.sha256"
    fi
)

tar -xzf "$STAGING_ROOT/$archive_name" -C "$STAGING_ROOT"
[ -f "$STAGING_ROOT/sshwitch/linux/setup.sh" ] &&
    [ -f "$STAGING_ROOT/sshwitch/linux/sync.sh" ] &&
    [ -f "$STAGING_ROOT/sshwitch/linux/providers/bitwarden.sh" ] || {
        printf "Release archive is missing POSIX scripts.\n" >&2
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
