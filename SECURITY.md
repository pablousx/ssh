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

SSHwitch treats the selected local provider adapter, its CLI, and the user's
unlocked provider store as trusted. Provider output is still required to match
the versioned canonical schema before metadata is written to OpenSSH
configuration. The schema is secret-free and rejects extra fields, including
private-key fields. Generated files are staged, validated, and published only
after all required commands succeed.

Agent mode does not invoke the provider's private-key export capability or
write private keys. A native provider CLI may return a secret-bearing response
to its adapter; the adapter must keep it in memory and strip private fields
before crossing the canonical-record boundary. Agent mode also verifies that
each provider public key is available from the selected agent before
publication. The disk identity backend invokes a separate provider export
capability, intentionally writes private keys into the tool-owned generation,
and requires an explicit setup confirmation. Switching back to agent mode
replaces the complete generation and removes those managed private-key files.
The Bitwarden adapter may retain one provider response in process memory during
an explicit disk-mode generation so it can export multiple keys without
re-querying the CLI. That response is cleared after generation and is never
written to canonical-record files, timing output, logs, or application state.

Daily automatic sync never stores provider credentials. It starts a child only
when the current shell already has `BW_SESSION`, and the child inherits that
environment for its lifetime. If the session is absent, locked, or invalid,
automatic sync fails without prompting and without changing the active
generation. The last-success state contains only an epoch timestamp.

The project owns only:

- `~/.ssh/sshwitch/`;
- its exact `Include ~/.ssh/sshwitch/current/config` line;
- its application preference and state directories;
- Git settings for which it has recorded previous values.

During migration, the prior `sync-ssh` preference, state, installation, profile,
and generated directories are also treated as narrowly owned legacy paths.
SSHwitch recognizes only the exact former Include and marker strings.

Installers verify release archive checksums. Published installer assets embed
their exact `vX.Y.Z` tag; an unstamped development copy resolves the latest tag
from GitHub before downloading an archive. Conventional Commits on `main`
produce a reviewed SemVer release pull request that updates `VERSION` and the
changelog. Merging that pull request causes the release workflow to build and
smoke-test the installers, archives, and checksums before creating the matching
tag and release. Existing versions are not republished and existing tags are
never moved. Users with stricter supply-chain requirements should download a
release and checksum separately, inspect the scripts, and run the platform
setup script locally.

## Supported versions

Security fixes are provided for the latest tagged release.
