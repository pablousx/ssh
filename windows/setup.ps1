$ErrorActionPreference = "Stop"

function Write-Utf8NoBom {
    param([string]$Path, [AllowEmptyString()][string]$Content)
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Content, $encoding)
}

function Get-CurrentPreferences {
    param([string]$Path)
    $preferences = [ordered]@{
        commit_signing = "skip"
        keep_alive     = "skip"
        provider       = "bitwarden"
        identity_backend = ""
        private_key_policy = ""
    }
    $legacyAgentMode = ""
    if (Test-Path -LiteralPath $Path) {
        $saved = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
        foreach ($name in @(
            "commit_signing",
            "keep_alive",
            "provider",
            "identity_backend",
            "private_key_policy"
        )) {
            $property = $saved.PSObject.Properties[$name]
            if ($property -and $property.Value) { $preferences[$name] = [string]$property.Value }
        }
        $legacyProperty = $saved.PSObject.Properties["agent_mode"]
        if ($legacyProperty) { $legacyAgentMode = [string]$legacyProperty.Value }
    } elseif (Get-Command git -ErrorAction SilentlyContinue) {
        $legacyMap = @{
            commit_signing = "sync-ssh.commit-signing"
            keep_alive     = "sync-ssh.keep-alive"
            agent_mode     = "sync-ssh.agent-mode"
        }
        foreach ($name in $legacyMap.Keys) {
            $value = (& git config --global --get $legacyMap[$name] 2>$null | Out-String).Trim()
            if ($LASTEXITCODE -eq 0 -and $value) {
                if ($name -eq "agent_mode") {
                    $legacyAgentMode = $value
                } else {
                    $preferences[$name] = $value
                }
            }
        }
    }
    if (-not $preferences.identity_backend) {
        $preferences.identity_backend = if ($legacyAgentMode -eq "disk") { "disk" } else { "agent" }
    }
    if (-not $preferences.private_key_policy) {
        $preferences.private_key_policy = if ($preferences.identity_backend -eq "disk") { "export" } else { "never" }
    }
    return $preferences
}

function Read-PreservedOption {
    param([string]$Prompt, [string]$Current)
    while ($true) {
        $answer = (Read-Host "$Prompt Current: $Current. (yes [y], no [n], preserve [s]) [s]").Trim().ToLowerInvariant()
        if (-not $answer) { $answer = "s" }
        switch ($answer) {
            { $_ -in @("y", "yes") } { return "yes" }
            { $_ -in @("n", "no") } { return "no" }
            { $_ -in @("s", "skip", "preserve") } { return $Current }
            default { Write-Host "Enter y, n, or s." -ForegroundColor Red }
        }
    }
}

function Add-ToProfile {
    param(
        [Parameter(Mandatory = $true)][string]$ScriptPath,
        [string]$LegacyScriptPath
    )
    $profilePath = $PROFILE
    $profileDir = Split-Path $profilePath -Parent
    [System.IO.Directory]::CreateDirectory($profileDir) | Out-Null
    if (-not (Test-Path -LiteralPath $profilePath)) {
        Write-Utf8NoBom -Path $profilePath -Content ""
    }

    $lines = @(Get-Content -LiteralPath $profilePath -ErrorAction SilentlyContinue)
    $filtered = New-Object System.Collections.Generic.List[string]
    for ($index = 0; $index -lt $lines.Count; $index++) {
        if ($lines[$index] -in @("# Added by Bitwarden SSH Sync setup", "# Added by Sync-SSH setup") -and
            $index + 1 -lt $lines.Count -and
            $LegacyScriptPath -and
            $lines[$index + 1] -eq ". `"$LegacyScriptPath`"") {
            $index++
            continue
        }
        if ($LegacyScriptPath -and $lines[$index] -eq ". `"$LegacyScriptPath`"") { continue }
        $filtered.Add($lines[$index])
    }
    if ($filtered.Count -ne $lines.Count) {
        Write-Utf8NoBom -Path $profilePath -Content ((@($filtered) -join "`r`n").TrimEnd() + "`r`n")
    }

    $sourceLine = ". `"$ScriptPath`""
    $profileContent = Get-Content -LiteralPath $profilePath -Raw -ErrorAction SilentlyContinue
    if ($profileContent -notmatch [regex]::Escape($sourceLine)) {
        [System.IO.File]::AppendAllText(
            $profilePath,
            "`r`n# Added by SSHwitch setup`r`n$sourceLine`r`n",
            (New-Object System.Text.UTF8Encoding($false))
        )
        Write-Host "Added SSHwitch to PowerShell profile: $profilePath" -ForegroundColor Green
    } else {
        Write-Host "PowerShell profile is already configured." -ForegroundColor Gray
    }
}

$syncScript = Join-Path $PSScriptRoot "sync.ps1"
$legacySyncScript = Join-Path (Join-Path $env:LOCALAPPDATA "sync-ssh") "sync.ps1"
$preferencesDir = Join-Path $env:APPDATA "sshwitch"
$preferencesPath = Join-Path $preferencesDir "config.json"
$legacyPreferencesPath = Join-Path (Join-Path $env:APPDATA "sync-ssh") "config.json"
$preferencesSource = if ((Test-Path -LiteralPath $preferencesPath) -or
    -not (Test-Path -LiteralPath $legacyPreferencesPath)) {
    $preferencesPath
} else {
    $legacyPreferencesPath
}
$current = Get-CurrentPreferences -Path $preferencesSource
if ($current.provider -notmatch "^[a-z0-9][a-z0-9-]*$") {
    throw "Invalid provider preference: $($current.provider)"
}
$currentCombination = "$($current.identity_backend):$($current.private_key_policy)"
if ($currentCombination -notin @("agent:never", "disk:export")) {
    throw "Invalid identity backend/private-key policy combination: " +
        "$($current.identity_backend)/$($current.private_key_policy)"
}

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Source provider: $($current.provider)" -ForegroundColor Gray
Write-Host "  SSHwitch Interactive Setup" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

$gitSign = Read-PreservedOption "1. Enable Git commit signing via SSH?" $current.commit_signing
$keepAlive = Read-PreservedOption "2. Enable SSH KeepAlive?" $current.keep_alive

Write-Host "`n3. Identity backend:" -ForegroundColor Cyan
Write-Host "   [1] $($current.provider) SSH Agent (recommended)"
Write-Host "   [2] Export private keys to the tool-owned directory (higher risk)"
Write-Host "   [s] Preserve current backend ($($current.identity_backend))"
while ($true) {
    $mode = (Read-Host "Select mode (1/2/s) [s]").Trim().ToLowerInvariant()
    if (-not $mode) { $mode = "s" }
    if ($mode -eq "1") {
        $identityBackend = "agent"
        $privateKeyPolicy = "never"
        break
    }
    if ($mode -eq "2") {
        Write-Host "WARNING: Disk mode exports private SSH keys in plaintext with user-only ACLs." -ForegroundColor Yellow
        if ((Read-Host "Type 'export private keys' to confirm") -eq "export private keys") {
            $identityBackend = "disk"
            $privateKeyPolicy = "export"
            break
        }
        Write-Host "Disk mode was not confirmed." -ForegroundColor Yellow
        continue
    }
    if ($mode -in @("s", "skip", "preserve")) {
        $identityBackend = $current.identity_backend
        $privateKeyPolicy = $current.private_key_policy
        break
    }
    Write-Host "Enter 1, 2, or s." -ForegroundColor Red
}

Write-Host "`nConfiguration summary:" -ForegroundColor Cyan
Write-Host "  Git SSH signing: $gitSign"
Write-Host "  SSH KeepAlive:   $keepAlive"
Write-Host "  Provider:        $($current.provider)"
Write-Host "  Identity backend: $identityBackend"
Write-Host "  Private keys:    $privateKeyPolicy"
$confirmation = (Read-Host "Proceed? (y/n) [y]").Trim().ToLowerInvariant()
if (-not $confirmation) { $confirmation = "y" }
if ($confirmation -notin @("y", "yes")) {
    throw "Setup aborted."
}

[System.IO.Directory]::CreateDirectory($preferencesDir) | Out-Null
$stateDir = Join-Path $env:LOCALAPPDATA "sshwitch-state"
$legacyStateDir = Join-Path $env:LOCALAPPDATA "sync-ssh-state"
[System.IO.Directory]::CreateDirectory($stateDir) | Out-Null
$gitStateDir = Join-Path $stateDir "git"
$legacyGitStateDir = Join-Path $legacyStateDir "git"
if (-not (Test-Path -LiteralPath $gitStateDir) -and
    (Test-Path -LiteralPath $legacyGitStateDir)) {
    Copy-Item -LiteralPath $legacyGitStateDir -Destination $gitStateDir -Recurse
}
$preferences = [ordered]@{
    version        = 2
    provider       = $current.provider
    identity_backend = $identityBackend
    private_key_policy = $privateKeyPolicy
    commit_signing = $gitSign
    keep_alive     = $keepAlive
}
$temporaryPreferences = Join-Path $preferencesDir (".config." + [Guid]::NewGuid().ToString("N"))
Write-Utf8NoBom -Path $temporaryPreferences -Content (($preferences | ConvertTo-Json) + "`n")
Move-Item -LiteralPath $temporaryPreferences -Destination $preferencesPath -Force

Add-ToProfile -ScriptPath $syncScript -LegacyScriptPath $legacySyncScript

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

$runSync = (Read-Host "`nRun a sync now? (y/n) [n]").Trim().ToLowerInvariant()
if ($runSync -in @("y", "yes")) {
    $powerShellExecutable = (Get-Process -Id $PID).Path
    & $powerShellExecutable -NoLogo -NoProfile -ExecutionPolicy Bypass -File $syncScript
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Initial sync failed. Setup remains installed; run SSHwitch to retry." -ForegroundColor Yellow
    }
}

Write-Host "`nSetup complete." -ForegroundColor Green
Write-Host "Restart PowerShell or run: . `$PROFILE" -ForegroundColor Cyan
Write-Host "Then run: SSHwitch" -ForegroundColor Cyan
