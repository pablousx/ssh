# Contributing

## Local checks

Linux, macOS, and WSL changes should pass:

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

On macOS, use `sh -n` in place of `dash -n` when `dash` is unavailable. The
same integration suite runs in the macOS CI job.

Windows changes should pass in both Windows PowerShell 5.1 and PowerShell 7:

```powershell
Invoke-ScriptAnalyzer -Path . -Recurse
Invoke-Pester tests/powershell/SSHwitch.Tests.ps1
```

Do not use a real provider store in automated tests. Extend `tests/mocks/bw`
and add a failure-path regression test instead.

## Behavioral contract

- Any external-command or parse failure must leave the active SSH generation
  unchanged.
- Provider-derived SSH values must not contain control characters or unsupported
  whitespace.
- Agent mode must never invoke private-key export or persist private keys.
- Provider output must satisfy the canonical secret-free schema.
- Agent identities must match provider public keys before publication.
- Sync must reject duplicate normalized aliases.
- Linux, macOS, and Windows should produce equivalent SSH entries for the same
  fixture.
- Uninstall must remove only files and settings owned by SSHwitch.

Update `CHANGELOG.md` for user-visible changes.

## Releases

Set `VERSION` to the next `X.Y.Z` value and finalize that version's changelog
entry in the same commit. When the commit reaches `main`, the release workflow
creates the matching immutable `vX.Y.Z` tag, archives, checksums, and GitHub
release. The installer and uninstaller scripts are attached to the release, and
its notes prepend exact version-pinned installation commands. If that release
already exists, the workflow exits without republishing it or moving its tag.
