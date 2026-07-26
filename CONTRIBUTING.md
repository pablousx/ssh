# Contributing

## Local checks

Linux and WSL changes should pass:

```sh
dash -n install.sh uninstall.sh linux/setup.sh linux/sync.sh \
  linux/providers/bitwarden.sh tests/linux/run.sh tests/mocks/bw tests/mocks/ssh-add
bash -n install.sh uninstall.sh linux/setup.sh linux/sync.sh \
  linux/providers/bitwarden.sh tests/linux/run.sh tests/mocks/bw tests/mocks/ssh-add
shellcheck install.sh uninstall.sh linux/setup.sh linux/sync.sh \
  linux/providers/bitwarden.sh tests/linux/run.sh tests/mocks/bw tests/mocks/ssh-add
tests/linux/run.sh
```

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
- Linux and Windows should produce equivalent SSH entries for the same fixture.
- Uninstall must remove only files and settings owned by SSHwitch.

Update `CHANGELOG.md` for user-visible changes.
