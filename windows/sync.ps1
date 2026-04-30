# =========== Constants ===========
$SYNC_START_MARKER = "# --- START SYNC-SSH MANAGED SECTION ---"
$SYNC_END_MARKER = "# --- END SYNC-SSH MANAGED SECTION ---"

# =========== SSH Config Sync Functions ===========

function Initialize-SshConfig {
    <#
    .SYNOPSIS
    Initialize SSH configuration directories and files
    #>
    param(
        [string]$OutputDir = "$HOME\.ssh"
    )

    $KeysDir = Join-Path $OutputDir "keys"
    $SshConfig = Join-Path $OutputDir "config"

    # Create necessary directories
    if (-not (Test-Path "$HOME\.ssh")) {
        New-Item -ItemType Directory -Path "$HOME\.ssh" -Force | Out-Null
    }
    if (-not (Test-Path $KeysDir)) {
        New-Item -ItemType Directory -Path $KeysDir -Force | Out-Null
    }

    # Set strict permissions compatible with SSH
    $currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    icacls "$HOME\.ssh" /inheritance:r /grant "*S-1-5-18:(OI)(CI)F" /grant "*S-1-5-32-544:(OI)(CI)F" /grant "${currentUser}:(OI)(CI)F" | Out-Null
    icacls "$KeysDir" /inheritance:r /grant "*S-1-5-18:(OI)(CI)F" /grant "*S-1-5-32-544:(OI)(CI)F" /grant "${currentUser}:(OI)(CI)F" | Out-Null

    # Unconditionally take ownership and reset all file permissions in the keys directory recursively
    takeown /f "$KeysDir" /r /d y 2>$null | Out-Null
    icacls "$KeysDir\*" /reset /t 2>$null | Out-Null

    # Ensure the config file exists
    if (-not (Test-Path $SshConfig)) {
        New-Item -ItemType File -Path $SshConfig -Force | Out-Null
        $defaultConfig = "Host *`n  Port 22`n  AddKeysToAgent yes`n`n"
        $defaultConfig | Out-File -FilePath $SshConfig -Encoding utf8
    }
    icacls "$SshConfig" /inheritance:r /grant "*S-1-5-18:F" /grant "*S-1-5-32-544:F" /grant "${currentUser}:F" | Out-Null

    # Ensure managed markers exist
    $configContent = Get-Content -Path $SshConfig -Raw -ErrorAction SilentlyContinue
    if ([string]::IsNullOrEmpty($configContent) -or $configContent -notmatch [regex]::Escape($SYNC_START_MARKER)) {
        Write-Host "Adding managed section markers to $SshConfig" -ForegroundColor Cyan
        $markerBlock = "`n$SYNC_START_MARKER`n# This section is automatically generated. Manual changes will be lost.`n$SYNC_END_MARKER`n"
        $markerBlock | Out-File -FilePath $SshConfig -Append -Encoding utf8
    }

    # Create hard link from .ssh/config to our config file
    $linkPath = "$HOME\.ssh\config"
    $shouldCreateLink = $true

    if (Test-Path $linkPath) {
        $item = Get-Item $linkPath
        # Check if it's already a hardlink to the same file
        if ($item.FullName -eq (Get-Item $SshConfig).FullName) {
            $shouldCreateLink = $false
        } else {
            Remove-Item $linkPath -Force
        }
    }

    if ($shouldCreateLink) {
        New-Item -ItemType HardLink -Path $linkPath -Value $SshConfig -Force | Out-Null
        Write-Host "Linked $linkPath -> $SshConfig" -ForegroundColor Gray
    }

    return @{
        KeysDir = $KeysDir
        SshConfig = $SshConfig
    }
}

function Unlock-BitwardenVault {
    <#
    .SYNOPSIS
    Check and unlock Bitwarden vault if needed
    #>

    $bwStatusJson = bw status | ConvertFrom-Json
    $bwStatus = $bwStatusJson.status

    if (-not $env:BW_SESSION) {

        Write-Host "Bitwarden Vault: $bwStatus" -ForegroundColor Yellow
        Write-Host "Unlocking vault..."

        $unlockOutput = bw unlock --raw

        if ($LASTEXITCODE -eq 0) {
            $env:BW_SESSION = $unlockOutput
            Write-Host "[OK] Vault unlocked successfully!" -ForegroundColor Green
        } else {
            Write-Host "[ERROR] Failed to unlock vault" -ForegroundColor Red
            throw "Failed to unlock Bitwarden vault"
        }
    }
}

function Ensure-BitwardenCli {
    # Confirm Bitwarden CLI is available before continuing
    if (-not (Get-Command bw -ErrorAction SilentlyContinue)) {
        Write-Host "Bitwarden CLI (bw) not found." -ForegroundColor Red
        Write-Host "Install using: winget install Bitwarden.CLI" -ForegroundColor Yellow
        Write-Host "Or download a release from: https://github.com/bitwarden/clients/releases" -ForegroundColor Yellow
        throw "Missing Bitwarden CLI"
    }
}

function Get-BitwardenSshKeys {
    <#
    .SYNOPSIS
    Retrieve SSH key metadata from Bitwarden
    #>

    Write-Host "Syncing Bitwarden vault..." -ForegroundColor Cyan
    bw sync 2>&1 | Out-Null

    Write-Host "Fetching items from Bitwarden..." -ForegroundColor Cyan

    # Force output to a single string to prevent array-parsing issues in PowerShell 5.1
    $itemsRaw = bw list items | Out-String

    if ([string]::IsNullOrWhiteSpace($itemsRaw)) {
        Write-Host "Warning: Bitwarden returned no items." -ForegroundColor Yellow
        return @{}
    }

    try {
        $items = $itemsRaw | ConvertFrom-Json
    } catch {
        Write-Host "Error parsing Bitwarden JSON. Try running 'bw sync' manually." -ForegroundColor Red
        return @{}
    }

    $sshItems = @($items) | Where-Object { $_.type -eq 5 }

    # Create lookup dictionary: ID -> (name, hostname, user, publicKey, email)
    $bwLookup = @{}
    foreach ($item in $sshItems) {
        # Robust field lookup
        $fields = @($item.fields)
        $hostnameField = $fields | Where-Object { $_.name -match "^HostName$" } | Select-Object -First 1
        $userField     = $fields | Where-Object { $_.name -match "^User$" } | Select-Object -First 1
        $emailField    = $fields | Where-Object { $_.name -match "^(Email|GitEmail)$" } | Select-Object -First 1

        $bwLookup[$item.id] = @{
            name           = $item.name
            hostname       = if ($hostnameField) { $hostnameField.value } else { $null }
            user           = if ($userField) { $userField.value } else { $null }
            publicKey      = if ($item.sshKey) { $item.sshKey.publicKey } else { $null }
            email          = if ($emailField) { $emailField.value } else { $null }
            organizationId = $item.organizationId
        }
    }

    Write-Host "Found $($bwLookup.Count) SSH keys in Bitwarden." -ForegroundColor Green
    return $bwLookup
}

function Sync-SSH {
    <#
    .SYNOPSIS
    Sync SSH keys from Bitwarden metadata to create SSH config
    #>
    param(
        [string]$OutputDir = "$HOME\.ssh"
    )

    try {
        Ensure-BitwardenCli

        # Initialize directories and config
        $config = Initialize-SshConfig -OutputDir $OutputDir

        # Unlock Bitwarden if needed
        Unlock-BitwardenVault

        # Get Bitwarden SSH key metadata
        $bwLookup = Get-BitwardenSshKeys

        # Process Git Signing
        $gitSign = $bwLookup.Values | Where-Object { $_.name -eq "git-sign" } | Select-Object -First 1
        if ($gitSign -and $gitSign.publicKey) {
            $signPub = Join-Path $config.KeysDir "git-sign.pub"
            $gitSign.publicKey.Trim() | Out-File -FilePath $signPub -Encoding utf8 -Force

            git config --global gpg.format ssh
            git config --global user.signingkey "$signPub"
            git config --global commit.gpgsign true
            Write-Host "Synced Git signing key: git-sign" -ForegroundColor Green
        }

        # Sync Loop
        $newManagedContent = ""
        $processedCount = 0

        foreach ($id in $bwLookup.Keys) {
            $item = $bwLookup[$id]
            if ($item.name -eq "git-sign") { continue }

            if (-not $item.publicKey -or -not $item.hostname) {
                Write-Host "Skipping '$($item.name)': Missing HostName or Public Key" -ForegroundColor Yellow
                continue
            }

            if ($item.organizationId -and $item.organizationId -ne "00000000-0000-0000-0000-000000000000") {
                Write-Host "Notice: '$($item.name)' is an Org key." -ForegroundColor Yellow
            }

            $safeName = $item.name -replace '[^a-zA-Z0-9._-]', '-' -replace '^-|-$', ''
            $pubkeyFile = Join-Path $config.KeysDir "$($safeName.ToLower()).pub"
            $item.publicKey.Trim() | Out-File -FilePath $pubkeyFile -Encoding utf8 -Force

            $entry = "`nHost $($safeName.ToLower())`n  HostName $($item.hostname)`n"
            if ($item.user) { $entry += "  User $($item.user)`n" }
            $entry += "  IdentityFile `"$pubkeyFile`"`n  IdentitiesOnly yes`n"

            $newManagedContent += $entry
            $processedCount++
        }




        # Apply SSH KeepAlive preference
        $keepAlivePref = git config sync-ssh.keep-alive
        if ($keepAlivePref -eq "yes") {
            $newManagedContent += "`nHost *`n  ServerAliveInterval 60`n  ServerAliveCountMax 3`n"
        } elseif ($keepAlivePref -eq "no") {
            $newManagedContent += "`nHost *`n  ServerAliveInterval 0`n"
        }

        # Update the config file using managed block
        $configPath = $config.SshConfig
        $currentContent = Get-Content -Path $configPath -Raw

        $replacement = "$SYNC_START_MARKER`n# This section is automatically generated. Manual changes will be lost.$newManagedContent`n$SYNC_END_MARKER"

        $startIdx = $currentContent.IndexOf($SYNC_START_MARKER)
        $endIdx = $currentContent.IndexOf($SYNC_END_MARKER)

        if ($startIdx -ge 0 -and $endIdx -gt $startIdx) {
            $before = $currentContent.Substring(0, $startIdx)
            $after = $currentContent.Substring($endIdx + $SYNC_END_MARKER.Length)
            $newFileContent = $before + $replacement + $after
            $newFileContent | Out-File -FilePath $configPath -Encoding utf8
        } else {
            # Fallback: append if markers lost for some reason (shouldn't happen due to Initialize-SshConfig)
            $replacement | Out-File -FilePath $configPath -Append -Encoding utf8
        }

        Write-Host "`n[OK] Done! Synced $processedCount SSH keys and updated managed section in config!" -ForegroundColor Green

    }
    catch {
        Write-Host "`n> Error: $_" -ForegroundColor Red
        Write-Host "> StackTrace: $($_.ScriptStackTrace)" -ForegroundColor Gray
    }
}

# If script is run directly (not dot-sourced), execute the sync
if ($MyInvocation.InvocationName -ne '.') {
    Sync-SSH
}
