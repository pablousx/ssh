# Bitwarden SSH Sync

Bitwarden SSH Sync builds a validated OpenSSH configuration from Bitwarden SSH
key items on Linux, WSL, and Windows.

It supports the Bitwarden SSH Agent by default. An explicitly confirmed disk
mode is available for environments that require exported private keys.

## How it works

For every Bitwarden item of type **SSH Key**:

1. The item name becomes the SSH alias after deterministic sanitization.
2. The custom `HostName` field becomes the destination host.
3. The optional custom `User` field becomes the SSH user.
4. The public key selects the corresponding identity from the Bitwarden agent.

For example, an item named `Production Server` with `HostName=prod.example.com`
and `User=ubuntu` produces:

```sshconfig
Host production-server
  HostName prod.example.com
  User ubuntu
  IdentityFile "~/.ssh/sync-ssh/current/keys/production-server.pub"
  IdentitiesOnly yes
```

The main `~/.ssh/config` receives one exact include:

```sshconfig
Include ~/.ssh/sync-ssh/current/config
```

Manual SSH entries remain outside the generated file.

## Safety properties

- A failed Bitwarden command, parse, validation, or filesystem operation leaves
  the active generation unchanged.
- Vault-derived metadata containing control characters or unsafe whitespace is
  rejected.
- Duplicate normalized aliases are rejected.
- Public keys and the generated OpenSSH config are validated before publishing.
- Concurrent syncs are blocked by a lock.
- Agent mode never persists private keys.
- Switching from disk mode to agent mode replaces the complete generation,
  removing managed private-key files.
- Windows files are written as UTF-8 without BOM on Windows PowerShell 5.1 and
  PowerShell 7.
- Uninstall removes only the dedicated tool-owned directory and exact profile or
  SSH configuration entries.

See [SECURITY.md](SECURITY.md) for the trust model and vulnerability reporting.

## Bitwarden item setup

Create an item of type **SSH Key** with:

| Value | Required | Purpose |
|---|---:|---|
| Item name | Yes | SSH alias, after sanitization |
| `HostName` custom field | Yes for host entries | Server hostname or IP |
| `User` custom field | No | SSH username |
| `Email` or `GitEmail` custom field | No | Principal for `allowed_signers` on `git-sign` |

The reserved item name `git-sign` is used for Git SSH signing and is not emitted
as an SSH host.

Alias normalization lowercases the item name, replaces characters outside
`a-z`, `0-9`, `.`, `_`, and `-` with `-`, and trims leading/trailing dashes.
Sync fails if two names normalize to the same alias.

## Prerequisites

All platforms require:

- [Bitwarden Desktop](https://bitwarden.com/download/) with SSH Agent enabled;
- [Bitwarden CLI](https://bitwarden.com/help/cli/) (`bw`), logged in with
  `bw login`;
- OpenSSH client tools (`ssh` and `ssh-keygen`).

Linux and WSL additionally require:

- POSIX `sh`;
- `jq`;
- `curl`, `tar`, and `sha256sum` for the release installer.

WSL agent mode additionally requires:

- `socat`;
- a trusted `npiperelay.exe` build available on `PATH`.

Git is required only when Git commit signing is enabled.

## Installation

Installers download the tagged release archive, verify its SHA-256 checksum,
stage it, and restore the previous installation if setup fails.

### Linux and WSL

```sh
curl -fsSL https://raw.githubusercontent.com/pablousx/ssh/v1.0.0/install.sh | sh
```

To install a different release with a downloaded installer:

```sh
SYNC_SSH_VERSION=v1.1.0 sh install.sh
```

### Windows

```powershell
irm https://raw.githubusercontent.com/pablousx/ssh/v1.0.0/install.ps1 | iex
```

To select another release:

```powershell
$env:SYNC_SSH_VERSION = "v1.1.0"
.\install.ps1
```

If the execution policy is `Restricted`, review the scripts and use an
appropriate CurrentUser policy before installation.

### Manual development installation

Linux or WSL:

```sh
git clone https://github.com/pablousx/ssh "$HOME/ssh"
cd "$HOME/ssh"
./linux/setup.sh
```

Windows:

```powershell
git clone https://github.com/pablousx/ssh "$HOME\ssh"
Set-Location "$HOME\ssh"
.\windows\setup.ps1
```

Setup preserves existing preferences when `s` is selected. Disk mode requires
typing an explicit confirmation phrase.

## Usage

Linux and WSL:

```sh
sync-ssh
sync-ssh --dry-run
sync-ssh --version
```

Windows:

```powershell
Sync-SSH
Sync-SSH -DryRun
Sync-SSH -Version
```

A dry run authenticates with Bitwarden, generates and validates a staging
generation, and reports success without replacing active SSH or Git settings.

## Git SSH signing

During setup, enable Git SSH signing and add a Bitwarden SSH key item named
`git-sign`. The optional `Email` or `GitEmail` field becomes the principal in
the generated `allowed_signers` file; the global Git email is used as a
fallback.

When enabled, Sync-SSH owns these global Git settings:

- `gpg.format`
- `user.signingkey`
- `commit.gpgsign`
- `gpg.ssh.allowedSignersFile`, when a principal is available

The previous value and whether it existed are recorded before modification.
Disabling the feature or uninstalling restores a setting only if it still
contains the value written by Sync-SSH. User-modified values are preserved.

## WSL agent bridge

Setup creates shell helpers that manage one exact `socat` child process through
a PID file and lock. The Unix socket is created with mode `600`.

```text
Linux ssh
  -> ~/.bitwarden-ssh-agent.sock
  -> socat
  -> npiperelay.exe
  -> Windows OpenSSH agent pipe
  -> Bitwarden Desktop
```

If Bitwarden or the bridge restarts:

```sh
reset-ssh-agent
```

The reset helper terminates only the recorded bridge PID; it does not broadly
kill other `npiperelay.exe` processes.

## Files and state

Linux and WSL:

| Path | Purpose |
|---|---|
| `~/.ssh/sync-ssh/current/` | Active generated config, keys, and manifest |
| `~/.config/sync-ssh/config` | Preferences, or `$XDG_CONFIG_HOME` |
| `~/.local/state/sync-ssh/` | Lock, backups, bridge PID, and Git restoration state |
| `~/.ssh/sync-ssh-env.sh` | Shell functions and agent environment |

Windows:

| Path | Purpose |
|---|---|
| `~\.ssh\sync-ssh\current\` | Active generated config, keys, and manifest |
| `%APPDATA%\sync-ssh\config.json` | Preferences |
| `%LOCALAPPDATA%\sync-ssh-state\` | Lock, backups, and Git restoration state |
| `%LOCALAPPDATA%\sync-ssh\` | Installed scripts |

Legacy managed blocks are migrated only when exactly one correctly ordered
start/end marker pair exists. Malformed markers cause sync to stop without
editing the file.

## Uninstallation

Linux and WSL:

```sh
curl -fsSL https://raw.githubusercontent.com/pablousx/ssh/v1.0.0/uninstall.sh | sh
```

Windows:

```powershell
irm https://raw.githubusercontent.com/pablousx/ssh/v1.0.0/uninstall.ps1 | iex
```

The uninstallers ask before removing generated SSH files, the include/legacy
block, or restoring Git settings. They do not delete the legacy generic
`~/.ssh/keys` directory because it may contain unrelated user files.

## Troubleshooting

### Bitwarden reports `unauthenticated`

Run:

```sh
bw login
```

Then retry sync.

### The SSH agent has no identities

Confirm that Bitwarden Desktop is open, the vault is unlocked, and SSH Agent is
enabled. Then inspect:

```sh
ssh-add -L
```

On WSL, run `reset-ssh-agent` before retrying.

### Sync reports a duplicate alias

Rename one of the Bitwarden items so the normalized names differ. Sync will not
choose one key or overwrite another.

### Sync reports malformed legacy markers

Back up `~/.ssh/config`, then correct or remove the old
`START/END SYNC-SSH MANAGED SECTION` pair. Sync deliberately refuses to guess
which manual lines belong to a malformed block.

## Development

See [CONTRIBUTING.md](CONTRIBUTING.md) for checks and behavioral requirements.
CI covers `dash`, Bash, Linux integration cases, Windows PowerShell 5.1,
PowerShell 7, PSScriptAnalyzer, and Pester.

Releases are created from `v*` tags. The tag must match `VERSION`; the workflow
publishes `.tar.gz` and `.zip` packages plus SHA-256 files consumed by the
installers.

## License

[MIT](LICENSE)
