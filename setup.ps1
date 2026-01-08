# =========== SSH Config Setup Script ===========

function Add-ToProfile {
    <#
    .SYNOPSIS
    Add sync.ps1 to PowerShell profile if not already present
    #>
    param(
        [string]$ScriptPath = "$PSScriptRoot\sync.ps1"
    )

    $profilePath = "$HOME\Documents\PowerShell\Profile.ps1"
    $sourceLine = ". $ScriptPath"

    # Create profile directory if it doesn't exist
    $profileDir = Split-Path $profilePath -Parent
    if (-not (Test-Path $profileDir)) {
        New-Item -ItemType Directory -Path $profileDir -Force | Out-Null
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
        Write-Host "✅ Added Sync-SSH to PowerShell profile: $profilePath" -ForegroundColor Green
        Write-Host "   Restart PowerShell or run: . `$PROFILE" -ForegroundColor Cyan
    } else {
        Write-Host "ℹ️  Sync-SSH already in profile, skipping." -ForegroundColor Gray
    }
}

# Main setup execution
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  SSH Config with Bitwarden - Setup" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

# Add to PowerShell profile
Add-ToProfile

Write-Host "`n✅ Setup complete!" -ForegroundColor Green
Write-Host "   Run 'Sync-SSH' to sync your SSH keys" -ForegroundColor Cyan
Write-Host "   Or restart PowerShell and it will be available globally`n" -ForegroundColor Cyan
