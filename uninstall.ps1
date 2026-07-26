$ErrorActionPreference = "Stop"

$installDir = Join-Path $env:LOCALAPPDATA "sshwitch"
$legacyInstallDir = Join-Path $env:LOCALAPPDATA "sync-ssh"
$managedRoot = Join-Path (Join-Path $HOME ".ssh") "sshwitch"
$legacyManagedRoot = Join-Path (Join-Path $HOME ".ssh") "sync-ssh"
$mainConfig = Join-Path (Join-Path $HOME ".ssh") "config"
$preferencesDir = Join-Path $env:APPDATA "sshwitch"
$legacyPreferencesDir = Join-Path $env:APPDATA "sync-ssh"
$stateDir = Join-Path $env:LOCALAPPDATA "sshwitch-state"
$legacyStateDir = Join-Path $env:LOCALAPPDATA "sync-ssh-state"
$gitStateDir = Join-Path $stateDir "git"
$legacyGitStateDir = Join-Path $legacyStateDir "git"
$includeLine = "Include ~/.ssh/sshwitch/current/config"
$legacyIncludeLine = "Include ~/.ssh/sync-ssh/current/config"
$startMarker = "# --- START SYNC-SSH MANAGED SECTION ---"
$endMarker = "# --- END SYNC-SSH MANAGED SECTION ---"

if (Test-Path -LiteralPath $mainConfig) {
    $mainConfigItem = Get-Item -LiteralPath $mainConfig -Force
    if ($mainConfigItem.LinkType -eq "SymbolicLink") {
        $target = [string]$mainConfigItem.Target
        if (-not [System.IO.Path]::IsPathRooted($target)) {
            $target = Join-Path (Split-Path $mainConfigItem.FullName -Parent) $target
        }
        $mainConfig = [System.IO.Path]::GetFullPath($target)
    }
}

function Write-Utf8NoBom {
    param([string]$Path, [AllowEmptyString()][string]$Content)
    [System.IO.File]::WriteAllText($Path, $Content, (New-Object System.Text.UTF8Encoding($false)))
}

function Confirm-Action {
    param([string]$Prompt)
    $answer = (Read-Host "$Prompt (y/n) [n]").Trim().ToLowerInvariant()
    return $answer -in @("y", "yes")
}

function Restore-OwnedGitValue {
    param([string]$Slug)
    $statePath = Join-Path $gitStateDir "$Slug.json"
    if (-not (Test-Path -LiteralPath $statePath)) {
        $statePath = Join-Path $legacyGitStateDir "$Slug.json"
    }
    if (-not (Test-Path -LiteralPath $statePath)) { return }
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        Write-Host "Git is unavailable; preserving restoration state: $statePath" -ForegroundColor Yellow
        return
    }

    $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
    $current = (& git config --global --get $state.key 2>$null | Out-String).Trim()
    if ($current -eq $state.owned) {
        if ($state.present) {
            & git config --global $state.key ([string]$state.previous)
        } else {
            & git config --global --unset-all $state.key 2>$null
        }
    } else {
        Write-Host "Preserving user-modified Git setting: $($state.key)" -ForegroundColor Yellow
    }
    Remove-Item -LiteralPath $statePath -Force
}

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  SSHwitch Uninstaller" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

$syncScript = Join-Path $installDir "sync.ps1"
if (Test-Path -LiteralPath $PROFILE) {
    $lines = @(Get-Content -LiteralPath $PROFILE)
    $filteredList = New-Object System.Collections.Generic.List[string]
    for ($index = 0; $index -lt $lines.Count; $index++) {
        if ($lines[$index] -in @(
                "# Added by Bitwarden SSH Sync setup",
                "# Added by Sync-SSH setup",
                "# Added by SSHwitch setup"
            ) -and
            $index + 1 -lt $lines.Count -and
            $lines[$index + 1] -match '^\.\s+"[^"]+[\\/]sync\.ps1"$') {
            $index++
            continue
        }
        if ($lines[$index] -eq ". `"$syncScript`"") { continue }
        $filteredList.Add($lines[$index])
    }
    $filtered = @($filteredList)
    if ($filtered.Count -ne $lines.Count) {
        Write-Utf8NoBom -Path $PROFILE -Content (($filtered -join "`r`n").TrimEnd() + "`r`n")
        Write-Host "Cleaned PowerShell profile: $PROFILE" -ForegroundColor Green
    }
}

if (Test-Path -LiteralPath $installDir) {
    Remove-Item -LiteralPath $installDir -Recurse -Force
}
if (Test-Path -LiteralPath $legacyInstallDir) {
    Remove-Item -LiteralPath $legacyInstallDir -Recurse -Force
}

if (Confirm-Action "Remove SSHwitch and legacy Sync-SSH generated configuration and keys?") {
    if (Test-Path -LiteralPath $managedRoot) {
        Remove-Item -LiteralPath $managedRoot -Recurse -Force
        Write-Host "Removed tool-owned SSH files." -ForegroundColor Green
    }
    if (Test-Path -LiteralPath $legacyManagedRoot) {
        Remove-Item -LiteralPath $legacyManagedRoot -Recurse -Force
    }
}

if (Confirm-Action "Remove SSHwitch/legacy Sync-SSH Include lines or managed block from $mainConfig?") {
    if (Test-Path -LiteralPath $mainConfig) {
        $lines = @(Get-Content -LiteralPath $mainConfig)
        $starts = @()
        $ends = @()
        for ($index = 0; $index -lt $lines.Count; $index++) {
            if ($lines[$index] -eq $startMarker) { $starts += $index }
            if ($lines[$index] -eq $endMarker) { $ends += $index }
        }
        if ($starts.Count -ne $ends.Count -or $starts.Count -gt 1) {
            Write-Host "Malformed legacy markers found; refusing to edit $mainConfig." -ForegroundColor Red
        } elseif ($starts.Count -eq 1 -and $ends[0] -le $starts[0]) {
            Write-Host "Malformed legacy marker ordering; refusing to edit $mainConfig." -ForegroundColor Red
        } else {
            $result = New-Object System.Collections.Generic.List[string]
            for ($index = 0; $index -lt $lines.Count; $index++) {
                if ($starts.Count -eq 1 -and $index -ge $starts[0] -and $index -le $ends[0]) { continue }
                if ($lines[$index] -eq $includeLine) { continue }
                if ($lines[$index] -eq $legacyIncludeLine) { continue }
                if ($lines[$index] -eq "# Added by Bitwarden SSH Sync") { continue }
                if ($lines[$index] -eq "# Added by Sync-SSH") { continue }
                if ($lines[$index] -eq "# Added by SSHwitch") { continue }
                $result.Add($lines[$index])
            }
            Write-Utf8NoBom -Path $mainConfig -Content ((@($result) -join "`r`n").TrimEnd() + "`r`n")
            Write-Host "Removed SSHwitch configuration from $mainConfig." -ForegroundColor Green
        }
    }
}

if (Confirm-Action "Restore Git settings previously changed by SSHwitch?") {
    Restore-OwnedGitValue "allowed-signers-file"
    Restore-OwnedGitValue "commit-gpgsign"
    Restore-OwnedGitValue "user-signingkey"
    Restore-OwnedGitValue "gpg-format"
}

if (Get-Command git -ErrorAction SilentlyContinue) {
    foreach ($legacyKey in @(
        "sync-ssh.commit-signing",
        "sync-ssh.keep-alive",
        "sync-ssh.agent-mode",
        "sync-ssh.export-private-keys"
    )) {
        & git config --global --unset-all $legacyKey 2>$null
    }
}

if (Test-Path -LiteralPath $preferencesDir) {
    Remove-Item -LiteralPath $preferencesDir -Recurse -Force
}
if (Test-Path -LiteralPath $legacyPreferencesDir) {
    Remove-Item -LiteralPath $legacyPreferencesDir -Recurse -Force
}
if ((Test-Path -LiteralPath $stateDir) -and
    -not (Get-ChildItem -LiteralPath $stateDir -Force -ErrorAction SilentlyContinue | Select-Object -First 1)) {
    Remove-Item -LiteralPath $stateDir -Force
}
if ((Test-Path -LiteralPath $legacyStateDir) -and
    -not (Get-ChildItem -LiteralPath $legacyStateDir -Force -ErrorAction SilentlyContinue | Select-Object -First 1)) {
    Remove-Item -LiteralPath $legacyStateDir -Force
}

Write-Host "`nSSHwitch has been uninstalled. Restart PowerShell to remove loaded functions." -ForegroundColor Cyan
