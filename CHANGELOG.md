# Changelog

All notable changes are documented here. Versions follow Semantic Versioning.

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
