$ErrorActionPreference = 'Stop'

$InstallDir   = "$env:LOCALAPPDATA\sync-ssh"
$SyncScript   = Join-Path $InstallDir "sync.ps1"
$SyncStartMarker = "# --- START SYNC-SSH MANAGED SECTION ---"
$SyncEndMarker   = "# --- END SYNC-SSH MANAGED SECTION ---"

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  Sync-SSH Uninstaller" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host

function Confirm-Action {
    param([string]$Prompt)
    $answer = Read-Host "$Prompt (y/n) [n]"
    return ($answer.Trim().ToLower() -eq 'y' -or $answer.Trim().ToLower() -eq 'yes')
}

# 1. Remove the dot-source line from $PROFILE
Write-Host "Removing PowerShell profile entry..." -ForegroundColor Gray
if (Test-Path $PROFILE) {
    $profileContent = Get-Content -Path $PROFILE -Raw -ErrorAction SilentlyContinue
    if ($profileContent -match [regex]::Escape($SyncScript)) {
        # Filter out lines referencing sync-ssh
        $newLines = (Get-Content -Path $PROFILE) | Where-Object {
            $_ -notmatch [regex]::Escape($SyncScript) -and
            $_ -notmatch "# Added by Bitwarden SSH Sync setup"
        }
        $newLines | Set-Content -Path $PROFILE -Encoding UTF8
        Write-Host "  Cleaned: $PROFILE" -ForegroundColor Green
    } else {
        Write-Host "  No Sync-SSH entry found in $PROFILE" -ForegroundColor Gray
    }
} else {
    Write-Host "  Profile not found at $PROFILE, skipping." -ForegroundColor Gray
}

# 2. Remove the install directory
if (Test-Path $InstallDir) {
    Remove-Item -Recurse -Force $InstallDir
    Write-Host "Removed: $InstallDir" -ForegroundColor Green
}

# 3. Optionally remove synced public keys
Write-Host
$keysDir = "$HOME\.ssh\keys"
if (Confirm-Action "Remove synced public keys from $keysDir?") {
    if (Test-Path $keysDir) {
        Remove-Item -Recurse -Force $keysDir
        Write-Host "  Removed: $keysDir" -ForegroundColor Green
    } else {
        Write-Host "  $keysDir not found, skipping." -ForegroundColor Gray
    }
}

# 4. Optionally remove the managed block from ~/.ssh/config
Write-Host
$sshConfig = "$HOME\.ssh\config"
if (Confirm-Action "Remove the managed SSH config block from $sshConfig?") {
    if (Test-Path $sshConfig) {
        $lines = Get-Content -Path $sshConfig
        $result = @()
        $skip = $false
        foreach ($line in $lines) {
            if ($line -eq $SyncStartMarker) { $skip = $true; continue }
            if ($line -eq $SyncEndMarker)   { $skip = $false; continue }
            if (-not $skip) { $result += $line }
        }
        $result | Set-Content -Path $sshConfig -Encoding UTF8
        Write-Host "  Managed block removed from $sshConfig" -ForegroundColor Green
    } else {
        Write-Host "  $sshConfig not found, skipping." -ForegroundColor Gray
    }
}

# 5. Optionally remove git config entries
Write-Host
if (Confirm-Action "Remove Sync-SSH git config entries (sync-ssh.* globals)?") {
    $gitKeys = @('sync-ssh.commit-signing', 'sync-ssh.keep-alive', 'sync-ssh.agent-mode')
    foreach ($key in $gitKeys) {
        git config --global --unset $key 2>$null
    }
    Write-Host "  Git config entries removed." -ForegroundColor Green
}

Write-Host
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  Sync-SSH has been uninstalled." -ForegroundColor Cyan
Write-Host "  Restart PowerShell to apply changes." -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
