# Security Policy

## Reporting a vulnerability

Please do not open a public issue for a vulnerability that could expose vault
data, private keys, SSH agent access, or command execution. Use GitHub's private
security advisory feature for this repository.

Include:

- affected version and platform;
- reproduction steps using non-production credentials;
- the expected and observed behavior;
- whether private-key material or SSH configuration was modified.

## Security model

Sync-SSH treats the local Bitwarden CLI and the user's unlocked vault as trusted.
Vault metadata is still validated before it is written to OpenSSH configuration.
Generated files are staged, validated, and published only after all required
commands succeed.

Agent mode does not write private keys to disk. Disk mode intentionally exports
private keys into the tool-owned directory and requires an explicit setup
confirmation. Switching back to agent mode replaces the complete generation and
removes those managed private-key files.

The project owns only:

- `~/.ssh/sync-ssh/`;
- its exact `Include ~/.ssh/sync-ssh/current/config` line;
- its application preference and state directories;
- Git settings for which it has recorded previous values.

Installers verify release archive checksums. Users with stricter supply-chain
requirements should download a release and checksum separately, inspect the
scripts, and run the platform setup script locally.

## Supported versions

Security fixes are provided for the latest tagged release.
