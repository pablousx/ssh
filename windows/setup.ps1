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
        agent_mode     = "bitwarden"
    }
    if (Test-Path -LiteralPath $Path) {
        $saved = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
        foreach ($name in @("commit_signing", "keep_alive", "agent_mode")) {
            if ($saved.$name) { $preferences[$name] = [string]$saved.$name }
        }
    } elseif (Get-Command git -ErrorAction SilentlyContinue) {
        $legacyMap = @{
            commit_signing = "sync-ssh.commit-signing"
            keep_alive     = "sync-ssh.keep-alive"
            agent_mode     = "sync-ssh.agent-mode"
        }
        foreach ($name in $legacyMap.Keys) {
            $value = (& git config --global --get $legacyMap[$name] 2>$null | Out-String).Trim()
            if ($LASTEXITCODE -eq 0 -and $value) { $preferences[$name] = $value }
        }
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
    param([Parameter(Mandatory = $true)][string]$ScriptPath)
    $profilePath = $PROFILE
    $profileDir = Split-Path $profilePath -Parent
    [System.IO.Directory]::CreateDirectory($profileDir) | Out-Null
    if (-not (Test-Path -LiteralPath $profilePath)) {
        Write-Utf8NoBom -Path $profilePath -Content ""
    }

    $sourceLine = ". `"$ScriptPath`""
    $profileContent = Get-Content -LiteralPath $profilePath -Raw -ErrorAction SilentlyContinue
    if ($profileContent -notmatch [regex]::Escape($sourceLine)) {
        [System.IO.File]::AppendAllText(
            $profilePath,
            "`r`n# Added by Bitwarden SSH Sync setup`r`n$sourceLine`r`n",
            (New-Object System.Text.UTF8Encoding($false))
        )
        Write-Host "Added Sync-SSH to PowerShell profile: $profilePath" -ForegroundColor Green
    } else {
        Write-Host "PowerShell profile is already configured." -ForegroundColor Gray
    }
}

$syncScript = Join-Path $PSScriptRoot "sync.ps1"
$preferencesDir = Join-Path $env:APPDATA "sync-ssh"
$preferencesPath = Join-Path $preferencesDir "config.json"
$current = Get-CurrentPreferences -Path $preferencesPath

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  Sync-SSH Interactive Setup" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

$gitSign = Read-PreservedOption "1. Enable Git commit signing via SSH?" $current.commit_signing
$keepAlive = Read-PreservedOption "2. Enable SSH KeepAlive?" $current.keep_alive

Write-Host "`n3. SSH key mode:" -ForegroundColor Cyan
Write-Host "   [1] Bitwarden SSH Agent (recommended)"
Write-Host "   [2] Export private keys to the tool-owned directory (higher risk)"
Write-Host "   [s] Preserve current mode ($($current.agent_mode))"
while ($true) {
    $mode = (Read-Host "Select mode (1/2/s) [s]").Trim().ToLowerInvariant()
    if (-not $mode) { $mode = "s" }
    if ($mode -eq "1") {
        $agentMode = "bitwarden"
        break
    }
    if ($mode -eq "2") {
        Write-Host "WARNING: Disk mode exports private SSH keys in plaintext with user-only ACLs." -ForegroundColor Yellow
        if ((Read-Host "Type 'export private keys' to confirm") -eq "export private keys") {
            $agentMode = "disk"
            break
        }
        Write-Host "Disk mode was not confirmed." -ForegroundColor Yellow
        continue
    }
    if ($mode -in @("s", "skip", "preserve")) {
        $agentMode = $current.agent_mode
        break
    }
    Write-Host "Enter 1, 2, or s." -ForegroundColor Red
}

Write-Host "`nConfiguration summary:" -ForegroundColor Cyan
Write-Host "  Git SSH signing: $gitSign"
Write-Host "  SSH KeepAlive:   $keepAlive"
Write-Host "  SSH key mode:    $agentMode"
$confirmation = (Read-Host "Proceed? (y/n) [y]").Trim().ToLowerInvariant()
if (-not $confirmation) { $confirmation = "y" }
if ($confirmation -notin @("y", "yes")) {
    throw "Setup aborted."
}

[System.IO.Directory]::CreateDirectory($preferencesDir) | Out-Null
$preferences = [ordered]@{
    version        = 1
    commit_signing = $gitSign
    keep_alive     = $keepAlive
    agent_mode     = $agentMode
}
$temporaryPreferences = Join-Path $preferencesDir (".config." + [Guid]::NewGuid().ToString("N"))
Write-Utf8NoBom -Path $temporaryPreferences -Content (($preferences | ConvertTo-Json) + "`n")
Move-Item -LiteralPath $temporaryPreferences -Destination $preferencesPath -Force

Add-ToProfile -ScriptPath $syncScript

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
        Write-Host "Initial sync failed. Setup remains installed; run Sync-SSH to retry." -ForegroundColor Yellow
    }
}

Write-Host "`nSetup complete." -ForegroundColor Green
Write-Host "Restart PowerShell or run: . `$PROFILE" -ForegroundColor Cyan
Write-Host "Then run: Sync-SSH" -ForegroundColor Cyan
