# SSHwitch

SSHwitch builds a validated OpenSSH configuration from provider-managed SSH
records on Linux, macOS, WSL, and Windows. Bitwarden is the first built-in
provider.

It uses the provider's SSH agent by default. An explicitly confirmed disk
identity backend is available for environments that require exported private
keys.

## How it works

For every SSH record returned by the configured provider:

1. The item name becomes the SSH alias after deterministic sanitization.
2. The custom `HostName` field becomes the destination host.
3. The optional custom `User` field becomes the SSH user.
4. The public key selects the corresponding identity from the configured agent.

For example, an item named `Production Server` with `HostName=prod.example.com`
and `User=ubuntu` produces:

```sshconfig
Host production-server
  HostName prod.example.com
  User ubuntu
  IdentityFile "~/.ssh/sshwitch/current/keys/production-server.pub"
  IdentitiesOnly yes
```

The main `~/.ssh/config` receives one exact include:

```sshconfig
Include ~/.ssh/sshwitch/current/config
```

Manual SSH entries remain outside the generated file.

## Safety properties

- A failed provider command, parse, validation, or filesystem operation leaves
  the active generation unchanged.
- Provider records must match the versioned, secret-free canonical schema.
- Vault-derived metadata containing control characters or unsafe whitespace is
  rejected.
- Duplicate normalized aliases are rejected.
- Public keys and the generated OpenSSH config are validated before publishing.
- Concurrent syncs are blocked by a lock.
- Agent mode never persists private keys.
- Agent mode verifies that every provider public key is available from the
  selected SSH agent before publication.
- Switching from disk mode to agent mode replaces the complete generation,
  removing managed private-key files.
- Windows files are written as UTF-8 without BOM on Windows PowerShell 5.1 and
  PowerShell 7.
- Uninstall removes only the dedicated tool-owned directory and exact profile or
  SSH configuration entries.

See [SECURITY.md](SECURITY.md) for the trust model and vulnerability reporting.

## Provider architecture

Provider adapters authenticate, list SSH records, and optionally export one
private key when the explicit disk policy permits it. The core owns all
normalization, validation, agent matching, generation, Git configuration,
staging, and publication.

Adapters return a version 1 envelope defined by
[`providers/record.schema.json`](providers/record.schema.json). The envelope can
contain public keys and validated metadata but cannot contain private-key
fields. Private-key export is a separate provider capability and is never
called when `private_key_policy=never`.

The current preferences are:

| Preference | Current values | Purpose |
|---|---|---|
| `provider` | `bitwarden` | Record source adapter |
| `identity_backend` | `agent`, `disk` | How OpenSSH uses the identity |
| `private_key_policy` | `never`, `export` | Whether the provider may export private keys |

Only `agent`/`never` and `disk`/`export` are accepted. Existing
`agent_mode=bitwarden` and `agent_mode=disk` preferences are mapped at runtime;
running setup writes the version 2 preference format.

## Bitwarden item setup

Create an item of type **SSH Key** with:

| Value | Required | Purpose |
|---|---:|---|
| Item name | Yes | SSH alias, after sanitization |
| `HostName` custom field | Yes for host entries | Server hostname or IP |
| `User` custom field | No | SSH username |
| `Email` or `GitEmail` custom field | No | Principal for `allowed_signers` on `git-sign` |
| `SSHwitchRole=git-sign` | No | Marks any named item as the Git signing identity |

The legacy reserved item name `git-sign` remains supported. A
`SSHwitchRole=git-sign` field can instead mark an item with any display name as
the signing identity. The previous `SyncSSHRole` field remains accepted during
migration. Signing identities are not emitted as SSH hosts.

Alias normalization lowercases the item name, replaces characters outside
`a-z`, `0-9`, `.`, `_`, and `-` with `-`, and trims leading/trailing dashes.
Sync fails if two names normalize to the same alias.

## Prerequisites

All platforms require:

- [Bitwarden Desktop](https://bitwarden.com/download/) with SSH Agent enabled;
- [Bitwarden CLI](https://bitwarden.com/help/cli/) (`bw`), logged in with
  `bw login`;
- OpenSSH client tools (`ssh`, `ssh-add`, and `ssh-keygen`).

Linux, macOS, and WSL additionally require:

- POSIX `sh`;
- `jq`;
- `curl` and `tar` for the release installer;
- `sha256sum` on Linux/WSL or the macOS-provided `shasum`.

WSL agent mode additionally requires:

- `socat`;
- a trusted `npiperelay.exe` build available on `PATH`.

Git is required only when Git commit signing is enabled.

## Installation

Installers download the tagged release archive, verify its SHA-256 checksum,
stage it, and restore the previous installation if setup fails.

### Linux, macOS, and WSL

```sh
curl -fsSL https://github.com/pablousx/sshwitch/releases/latest/download/install.sh | sh
```

This installs the latest published release. To pin a specific release, replace
`vX.Y.Z` with the version you want:

```sh
curl -fsSL https://github.com/pablousx/sshwitch/releases/download/vX.Y.Z/install.sh | sh
```

### Windows

```powershell
irm https://github.com/pablousx/sshwitch/releases/latest/download/install.ps1 | iex
```

This installs the latest published release. To pin a specific release, replace
`vX.Y.Z` with the version you want:

```powershell
irm https://github.com/pablousx/sshwitch/releases/download/vX.Y.Z/install.ps1 | iex
```

If the execution policy is `Restricted`, review the scripts and use an
appropriate CurrentUser policy before installation.

### Manual development installation

Linux, macOS, or WSL:

```sh
git clone https://github.com/pablousx/sshwitch "$HOME/ssh"
cd "$HOME/ssh"
./linux/setup.sh
```

Windows:

```powershell
git clone https://github.com/pablousx/sshwitch "$HOME\ssh"
Set-Location "$HOME\ssh"
.\windows\setup.ps1
```

Setup preserves existing preferences when `s` is selected. Disk mode requires
typing an explicit confirmation phrase.

## Usage

Linux, macOS, and WSL:

```sh
sshwitch
sshwitch --dry-run
sshwitch --version
```

Windows:

```powershell
SSHwitch
SSHwitch -DryRun
SSHwitch -Version
```

A dry run authenticates with the configured provider, generates and validates a staging
generation, and reports success without replacing active SSH or Git settings.

## Git SSH signing

During setup, enable Git SSH signing and add a Bitwarden SSH key item named
`git-sign`, or set `SSHwitchRole=git-sign` on another SSH key item. The optional
`Email` or `GitEmail` field becomes the principal in the generated
`allowed_signers` file; the global Git email is used as a fallback.

When enabled, SSHwitch owns these global Git settings:

- `gpg.format`
- `user.signingkey`
- `commit.gpgsign`
- `gpg.ssh.allowedSignersFile`, when a principal is available

The previous value and whether it existed are recorded before modification.
Disabling the feature or uninstalling restores a setting only if it still
contains the value written by SSHwitch. User-modified values are preserved.
If signing is enabled but no `git-sign` public key is available, SSHwitch warns
and still syncs the SSH host configuration without changing Git settings.

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

If the Windows agent or the bridge restarts:

```sh
reset-ssh-agent
```

The reset helper terminates only the recorded bridge PID; it does not broadly
kill other `npiperelay.exe` processes.

## macOS agent socket

[Bitwarden uses different sockets for its two macOS
distributions](https://bitwarden.com/help/ssh-agent/). SSHwitch prefers an
active socket; when neither socket exists yet, the App Store application
container selects the App Store path and the `.dmg` path is the fallback:

```text
App Store: ~/Library/Containers/com.bitwarden.desktop/Data/.bitwarden-ssh-agent.sock
.dmg:      ~/.bitwarden-ssh-agent.sock
```

Keep Bitwarden Desktop open with SSH Agent enabled before running `sshwitch`.

## Files and state

Linux, macOS, and WSL:

| Path | Purpose |
|---|---|
| `~/.ssh/sshwitch/current/` | Active generated config, keys, and manifest |
| `~/.config/sshwitch/config` | Preferences, or `$XDG_CONFIG_HOME` |
| `~/.local/state/sshwitch/` | Lock, backups, bridge PID, and Git restoration state |
| `~/.ssh/sshwitch-env.sh` | Shell functions and agent environment |

Windows:

| Path | Purpose |
|---|---|
| `~\.ssh\sshwitch\current\` | Active generated config, keys, and manifest |
| `%APPDATA%\sshwitch\config.json` | Preferences |
| `%LOCALAPPDATA%\sshwitch-state\` | Lock, backups, and Git restoration state |
| `%LOCALAPPDATA%\sshwitch\` | Installed scripts |

### Migration from Sync-SSH

Running SSHwitch setup imports existing preferences and Git-restoration state
from the former `sync-ssh` directories. The first successful sync replaces the
old `Include ~/.ssh/sync-ssh/current/config` with the SSHwitch Include only
after a complete new generation passes validation. The former `sync-ssh`
command remains as a deprecated shell alias or PowerShell wrapper.

Legacy managed blocks are migrated only when exactly one correctly ordered
start/end marker pair exists. Malformed markers cause sync to stop without
editing the file.

## Uninstallation

Linux, macOS, and WSL:

```sh
curl -fsSL https://github.com/pablousx/sshwitch/releases/latest/download/uninstall.sh | sh
```

Windows:

```powershell
irm https://github.com/pablousx/sshwitch/releases/latest/download/uninstall.ps1 | iex
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
enabled. Sync deliberately fails before publication when a provider public key
is missing from the agent. Inspect:

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
CI covers the shared POSIX implementation on Linux and macOS, including `dash`
and Bash syntax checks on Linux, plus Windows PowerShell 5.1, PowerShell 7,
PSScriptAnalyzer, and Pester.

Every non-release push to `main` evaluates Conventional Commit messages since
the latest release and opens or updates a SemVer release pull request. Merging
that release pull request does not start another proposal run. The proposed
version uses these rules:

| Commit | Version change |
|---|---|
| `fix: ...` | Patch, for example `1.1.0` to `1.1.1` |
| `feat: ...` | Minor, for example `1.1.0` to `1.2.0` |
| `feat!: ...`, `fix!: ...`, or a `BREAKING CHANGE:` footer | Major, for example `1.1.0` to `2.0.0` |

The release pull request updates `VERSION` and `CHANGELOG.md`. Merging it into
`main` runs the publishing workflow, which creates the matching `vX.Y.Z` tag
and publishes `.tar.gz` and `.zip` packages plus SHA-256 files consumed by the
installers. Installer and uninstaller scripts are attached as release assets,
and the release notes include version-pinned POSIX and Windows installation
commands. Publishing is idempotent and never moves an existing tag.

## License

[MIT](LICENSE)
