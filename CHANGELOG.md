# Changelog

All notable changes are documented here. Versions follow Semantic Versioning.

## [Unreleased]

### Added

- Versioned, secret-free provider record schema and Bitwarden adapters for
  Linux/WSL and Windows.
- Provider capability probing and conformance tests for schema enforcement,
  secret exclusion, CLI failure, alias collisions, metadata injection, and
  agent identity matching.
- `SSHwitchRole=git-sign` as a provider-neutral signing-role marker.

### Changed

- Renamed the project, commands, owned paths, and release archives from
  Sync-SSH to SSHwitch, with migration for existing preferences, Git state,
  profile entries, generated Include directives, and the legacy command.
- Preferences now separate `provider`, `identity_backend`, and
  `private_key_policy`; legacy `agent_mode` values remain compatible.
- Bitwarden authentication and record mapping moved out of the validation and
  publication core.
- Agent mode now fails before publication when a provider key is absent from
  the selected SSH agent.
- Generated comments use the provider-neutral SSHwitch name.

### Fixed

- Windows publication no longer passes an empty backup path to
  `System.IO.File.Replace` when the main SSH config already exists.
- Windows managed-file ACLs remain readable by OpenSSH and Git after SSH
  signing is enabled.

### Security

- Canonical provider records cannot contain private-key fields.
- Private-key retrieval is a separate capability invoked only by the explicit
  `disk`/`export` configuration.

## [1.0.0] - 2026-07-24

### Added

- Transactional, fail-closed SSH configuration generation.
- Dedicated `~/.ssh/sync-ssh/current` generation and OpenSSH `Include` entry.
- Vault metadata, alias, public-key, and generated-config validation.
- Managed cleanup when keys are removed or disk mode is disabled.
- Application-owned preferences instead of `git config` preference storage.
- Git-signing ownership tracking and restoration.
- UTF-8 without BOM on Windows PowerShell 5.1 and PowerShell 7.
- Exact-process WSL bridge lifecycle with locking and restricted socket mode.
- Versioned, checksum-verified release installers with rollback.
- Linux integration tests, PowerShell tests, CI, and release automation.
- `--dry-run` and `--version` on Linux; `-DryRun` and `-Version` on Windows.

### Changed

- Disk mode now requires explicit confirmation.
- Setup configures one shell profile using POSIX-compatible dot sourcing.
- Generated keys moved from the generic `~/.ssh/keys` directory.

### Security

- Private keys are no longer written to temporary files in agent mode.
- Newlines and control characters in vault metadata are rejected.
- Malformed legacy markers cause a safe failure instead of config truncation.
- Uninstall no longer recursively deletes a generic user key directory.
