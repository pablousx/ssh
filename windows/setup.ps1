# =========== SSH Config Setup Script ===========

function Add-ToProfile {
    <#
    .SYNOPSIS
    Add sync.ps1 to PowerShell profile if not already present
    #>
    param(
        [string]$ScriptPath = "$PSScriptRoot\sync.ps1"
    )

    $profilePath = $PROFILE
    $sourceLine = ". $ScriptPath"

    # Create profile directory if it doesn't exist
    $profileDir = Split-Path $profilePath -Parent
    if (-not (Test-Path $profileDir)) {
        [void][System.IO.Directory]::CreateDirectory($profileDir)
        Write-Host "Created profile directory: $profileDir" -ForegroundColor Green
    }

    # Create profile file if it doesn't exist
    if (-not (Test-Path $profilePath)) {
        New-Item -ItemType File -Path $profilePath -Force | Out-Null
        Write-Host "Created profile file: $profilePath" -ForegroundColor Green
    }

    # Check if line already exists
    $profileContent = Get-Content -Path $profilePath -Raw -ErrorAction SilentlyContinue

    if (-not ($profileContent -match [regex]::Escape($sourceLine))) {
        # Add to profile
        "`n$sourceLine" | Out-File -FilePath $profilePath -Append -Encoding utf8
        Write-Host "[OK] Added Sync-SSH to PowerShell profile: $profilePath" -ForegroundColor Green
        Write-Host "   Restart PowerShell or run: . `$PROFILE" -ForegroundColor Cyan
    } else {
        Write-Host "[INFO] Sync-SSH already in profile, skipping." -ForegroundColor Gray
    }
}

function Prompt-Option {
    param(
        [string]$PromptText,
        [string]$DefaultVal
    )

    while ($true) {
        $input = Read-Host "$PromptText (enable [e], disable [d], skip [s]) [default: $DefaultVal]"
        $input = $input.ToLower().Trim()
        if ([string]::IsNullOrWhiteSpace($input)) { $input = $DefaultVal }

        switch ($input) {
            "e" { return "enable" }
            "enable" { return "enable" }
            "d" { return "disable" }
            "disable" { return "disable" }
            "s" { return "skip" }
            "skip" { return "skip" }
            default { Write-Host "Invalid option. Please use 'e', 'd', or 's'." -ForegroundColor Red }
        }
    }
}

# Main setup execution
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  Sync-SSH Interactive Setup" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Detected OS: Windows`n" -ForegroundColor Cyan

$gitSign = Prompt-Option "1. Git Commit Signing via SSH" "skip"
$keepAlive = Prompt-Option "2. SSH KeepAlive" "skip"

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "Final Confirmation:" -ForegroundColor Cyan
Write-Host "  OS:               Windows" -ForegroundColor Cyan
Write-Host "  Git SSH Signing:  $gitSign" -ForegroundColor Cyan
Write-Host "  SSH KeepAlive:    $keepAlive" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

$confirm = Read-Host "`nProceed with these settings? (y/n) [default: y]"
$confirm = $confirm.ToLower().Trim()
if ([string]::IsNullOrWhiteSpace($confirm)) { $confirm = "y" }

if ($confirm -ne "y" -and $confirm -ne "yes") {
    Write-Host "Setup aborted." -ForegroundColor Yellow
    exit 1
}

# Persist preferences
git config --global sync-ssh.commit-signing $gitSign
git config --global sync-ssh.keep-alive $keepAlive

# Add to PowerShell profile
Add-ToProfile

Write-Host "`nSetup complete!" -ForegroundColor Green
Write-Host "   Run 'Sync-SSH' to sync your SSH keys" -ForegroundColor Cyan
Write-Host "   Or restart PowerShell and it will be available globally" -ForegroundColor Cyan

# Finally ask if user wants to sync right away
$runSync = Read-Host "`nDo you want to sync SSH keys right away? (y/n) [default: n]"
$runSync = $runSync.ToLower().Trim()
if ($runSync -eq "y" -or $runSync -eq "yes") {
    Write-Host "Running sync..." -ForegroundColor Cyan
    & "$PSScriptRoot\sync.ps1"
}
