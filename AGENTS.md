# AGENTS.md

## Project purpose

SSHwitch generates validated OpenSSH configuration from provider-managed SSH
records on Linux, macOS, WSL, and Windows. Bitwarden is the first built-in
provider.
The repository intentionally maintains two platform implementations:

- POSIX shell: `install.sh`, `uninstall.sh`, and `linux/`
- Windows PowerShell 5.1/PowerShell 7: `install.ps1`, `uninstall.ps1`, and
  `windows/`

Changes to providers, synchronization, preferences, Git signing, installation,
or uninstallation normally require equivalent behavior and tests on both
platforms.

## Skills to use

Use the smallest relevant set:

- `shell-bash`: shell design and portability work.
- `bash-lint`: ShellCheck, `shfmt`, shell quality, or pre-commit work.
- `powershell-master`: any `.ps1`, Pester, PSScriptAnalyzer, encoding, ACL, or
  Windows compatibility work.
- `gha-security-review`: any change under `.github/workflows/`, especially
  triggers, permissions, expressions, third-party actions, artifacts, or
  release credentials.

The PowerShell skill contains generic Windows editor-path advice. This checkout
is normally operated from a POSIX host, so repository tool paths remain POSIX
paths such as `/home/...` or `/Users/...`; use Windows paths only inside
PowerShell code or when invoking a native Windows process.

## Non-negotiable safety contract

Preserve all of these invariants:

1. **Fail closed.** A provider, JSON, validation, SSH, Git, or filesystem
   failure must not replace the active SSH generation.
2. **Stage before publishing.** Build and validate a complete generation before
   changing active files. Preserve rollback behavior around publication.
3. **Own a narrow namespace.** Generated files belong under
   `~/.ssh/sshwitch/`. Never recursively manage or delete generic directories
   such as `~/.ssh/keys`.
4. **Agent mode writes no private keys.** A provider CLI response may contain
   private-key fields only in adapter memory. Canonical provider records are
   secret-free, and private-key fields must not enter temporary files,
   manifests, logs, or test output.
5. **Disk mode is explicit.** It requires deliberate confirmation and writes
   private keys only into the restricted, tool-owned generation.
6. **Validate vault input.** Reject control characters, unsafe whitespace,
   missing required fields, invalid public keys, empty aliases, and normalized
   alias collisions. Do not interpolate untrusted metadata into SSH config.
7. **Preserve manual SSH config.** Maintain the exact generated `Include`,
   safely migrate only a valid legacy marker pair, and preserve symlinked config
   files.
8. **Respect lock ownership.** A process that failed to acquire a lock must
   never remove another process's lock.
9. **Own Git changes.** Save the prior global Git value and restore it only when
   the current value still matches the value written by SSHwitch.
10. **Never expose secrets.** Do not print vault JSON, session tokens, private
    keys, or generated secret-bearing paths in debug traces or CI logs.

## Architecture and owned paths

The main SSH config contains:

```sshconfig
Include ~/.ssh/sshwitch/current/config
```

The active generation is replaced as a unit:

```text
~/.ssh/sshwitch/
└── current/
    ├── config
    ├── keys/
    ├── manifest or manifest.json
    └── allowed_signers (when configured)
```

Preferences are application state, not Git configuration:

| Platform | Preferences | State |
|---|---|---|
| Linux/macOS/WSL | `${XDG_CONFIG_HOME:-~/.config}/sshwitch/config` | `${XDG_STATE_HOME:-~/.local/state}/sshwitch/` |
| Windows | `%APPDATA%\sshwitch\config.json` | `%LOCALAPPDATA%\sshwitch-state\` |

Legacy `sync-ssh.*` Git keys are migration inputs only. Do not reintroduce them
as the primary preference store.

Current preferences separate `provider`, `identity_backend`, and
`private_key_policy`. Only `agent`/`never` and `disk`/`export` combinations are
valid. Legacy `agent_mode` is a migration input only.

## Cross-platform parity

Keep these behaviors aligned:

| Behavior | POSIX (Linux/macOS/WSL) | Windows |
|---|---|---|
| Alias normalization | lowercase and replace outside `[a-z0-9._-]` | same |
| Metadata fields | case-insensitive `HostName`, `User`, `Email`/`GitEmail` | same |
| Item ordering | deterministic, case-insensitive name sort | same |
| Provider | `bitwarden` | same |
| Identity backends | `agent`, `disk` | same |
| Private-key policies | `never`, `export` | same |
| Preference values | `yes`, `no`, `skip` | same |
| Generated identity path | `~/.ssh/sshwitch/current/keys/...` | same |
| Git signing keys | four owned global settings | same |
| Failure status | nonzero and active generation preserved | same |
| Dry run | validates without publishing | same |

When fixing a platform-specific bug, decide explicitly whether the other
implementation has the same bug. Add a parity regression test when practical.

## Shell rules

- Keep executable shell scripts compatible with `dash` and Bash.
- Use `#!/bin/sh` and avoid arrays, `[[ ... ]]`, process substitution,
  Bash-only case conversion, and `local`.
- Use `set -eu`; do not add `pipefail` to POSIX scripts.
- Capture an external command's output first, check its status, then parse it.
  Do not let the last command in a pipeline hide an earlier failure.
- Quote expansions and use `printf`, not implementation-dependent `echo`
  behavior.
- Use restrictive permissions and cleanup traps for temporary state.
- Destructive paths must be explicit, validated, and inside a tool-owned
  directory.

## PowerShell rules

- Support both Windows PowerShell 5.1 and PowerShell 7 unless a documented
  release decision changes the compatibility floor.
- Write SSH config and key files through `Write-Utf8NoBom`. Never use
  `Out-File -Encoding utf8` or Windows PowerShell 5.1 `Set-Content -Encoding
  UTF8` for OpenSSH files.
- Set terminating error behavior for PowerShell cmdlets and explicitly inspect
  `$LASTEXITCODE` after native commands.
- Use `Join-Path`, literal paths, typed/validated parameters, `try`/`catch`, and
  `finally` cleanup.
- Restrict ACL changes to the tool-owned directory. Never reset ACLs across the
  user's whole `.ssh` tree.
- A directly invoked script must return a nonzero process exit code on failure;
  a dot-sourced script must expose functions without running a sync.

## GitHub Actions and release rules

- Keep workflow permissions minimal and explicit.
- Pin third-party actions to a full commit SHA with a version comment.
- Do not execute fork-controlled content in a privileged
  `pull_request_target` context.
- Do not interpolate attacker-controlled `${{ }}` expressions directly into
  `run:` blocks.
- Keep release artifacts deterministic in structure:
  `sshwitch-vX.Y.Z.tar.gz` and `.zip`, each with a matching `.sha256`.
- Attach `install.sh`, `install.ps1`, `uninstall.sh`, and `uninstall.ps1` to
  every release, and prepend exact version-pinned POSIX and Windows install
  commands to the generated release notes.
- `VERSION` contains `X.Y.Z`; release tags are `vX.Y.Z` and must match it.
- A new `VERSION` on `main` automatically creates its immutable matching tag
  and release. Existing releases must be skipped without moving their tags.
- Do not commit, tag, push, or publish a release unless the user explicitly
  authorizes that repository/release action.

## Required validation

Run the relevant subset during iteration and the full set before handoff.

### Linux, macOS, and WSL

```sh
dash -n install.sh uninstall.sh linux/setup.sh linux/sync.sh \
  linux/providers/bitwarden.sh tests/linux/run.sh tests/mocks/bw \
  tests/mocks/curl tests/mocks/ssh-add tests/mocks/uname
bash -n install.sh uninstall.sh linux/setup.sh linux/sync.sh \
  linux/providers/bitwarden.sh tests/linux/run.sh tests/mocks/bw \
  tests/mocks/curl tests/mocks/ssh-add tests/mocks/uname
shellcheck install.sh uninstall.sh linux/setup.sh linux/sync.sh \
  linux/providers/bitwarden.sh tests/linux/run.sh tests/mocks/bw \
  tests/mocks/curl tests/mocks/ssh-add tests/mocks/uname
tests/linux/run.sh
```

On macOS, use `sh -n` when `dash` is unavailable. The integration suite must
also pass in the macOS CI job.

The integration suite must use `tests/mocks/bw`; never point tests at a real
vault or the user's real home directory.

### PowerShell

Run in both Windows PowerShell 5.1 and PowerShell 7:

```powershell
Invoke-ScriptAnalyzer -Path . -Recurse
Invoke-Pester tests/powershell/SSHwitch.Tests.ps1
```

At minimum, parse every `.ps1` file with
`System.Management.Automation.Language.Parser` when PSScriptAnalyzer is not
locally available.

### Repository checks

```sh
git diff --check
```

Also parse changed workflow YAML and review workflow changes using
`gha-security-review`.

## Regression-test expectations

Add or update tests for any behavior change. High-value cases include:

- Bitwarden sync/list failure leaves the active generation unchanged.
- Provider capability or canonical-schema violations fail before publication.
- Agent identities must match the provider public keys before publication.
- Agent-mode canonical records and tests never contain private-key material.
- Invalid JSON and empty/missing fields fail safely.
- Newline or directive injection is rejected.
- Duplicate normalized aliases are rejected.
- Malformed/reversed/duplicate legacy markers are not edited.
- A symlinked SSH config remains a symlink.
- Disk-to-agent transitions remove managed private keys.
- Concurrent lock failure preserves the existing lock.
- Git settings restore prior values but preserve later user edits.
- Windows-generated files have no UTF-8 BOM.
- Setup and uninstall are idempotent and touch only owned paths.

## Documentation

Update `README.md` and `CHANGELOG.md` for user-visible changes. Update
`SECURITY.md` whenever the trust boundary, secret handling, installation
integrity, or owned filesystem scope changes. Keep examples identical to actual
paths, flags, preference values, and release artifact names.

## Working-tree discipline

- Existing changes belong to the user. Do not revert unrelated edits.
- Do not run the real installers, uninstallers, setup, or sync against the
  user's home during tests.
- Do not commit generated keys, vault fixtures containing real data, temporary
  release archives, session values, or logs.
- Avoid broad destructive Git or filesystem commands.

## Definition of done

A change is complete only when:

1. the safety contract still holds;
2. Linux, macOS, and Windows behavior is intentionally aligned;
3. relevant regression tests exist;
4. local syntax/tests pass, with unavailable checks called out;
5. documentation matches the implementation;
6. `git diff --check` is clean;
7. no real vault data, private key, or session token entered the worktree or
   logs.
