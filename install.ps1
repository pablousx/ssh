$ErrorActionPreference = 'Stop'

# Check execution policy
$policy = Get-ExecutionPolicy
if ($policy -eq 'Restricted') {
    Write-Host "Cannot run installer due to 'Restricted' Execution Policy." -ForegroundColor Red
    Write-Host "Please run the following command to allow scripts, then try again:" -ForegroundColor Yellow
    Write-Host "Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser" -ForegroundColor Cyan
    exit 1
}

$RepoUrl = "https://raw.githubusercontent.com/pablousx/ssh/main"
$InstallDir = "$env:LOCALAPPDATA\sync-ssh"

Write-Host "Installing Bitwarden SSH Sync for Windows..." -ForegroundColor Cyan

# Create install directory
if (-not (Test-Path $InstallDir)) {
    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
}

Write-Host "Downloading scripts to $InstallDir..." -ForegroundColor Gray

# Download scripts
Invoke-WebRequest -Uri "$RepoUrl/windows/setup.ps1" -OutFile "$InstallDir\setup.ps1" -UseBasicParsing
Invoke-WebRequest -Uri "$RepoUrl/windows/sync.ps1" -OutFile "$InstallDir\sync.ps1" -UseBasicParsing

# Run setup
Write-Host "Running setup..." -ForegroundColor Gray
Set-Location $InstallDir
& "$InstallDir\setup.ps1"
