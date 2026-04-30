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
    $items = bw list items | ConvertFrom-Json
    $sshItems = $items | Where-Object { $_.type -eq 5 }

    # Create lookup dictionary: name -> (hostname, user, publicKey, email)
    $bwLookup = @{}
    foreach ($item in $sshItems) {
        $hostnameField = $item.fields | Where-Object { $_.name -eq "HostName" }
        $userField = $item.fields | Where-Object { $_.name -eq "User" }
        $emailField = $item.fields | Where-Object { $_.name -eq "Email" -or $_.name -eq "GitEmail" }

        $bwLookup[$item.name] = @{
            hostname = if ($hostnameField) { $hostnameField.value } else { $null }
            user = if ($userField) { $userField.value } else { $null }
            publicKey = if ($item.sshKey) { $item.sshKey.publicKey } else { $null }
            email = if ($emailField) { $emailField.value } else { $null }
        }
    }

    Write-Host "Found $($sshItems.Count) SSH keys in Bitwarden." -ForegroundColor Green
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

        # Process git-sign key based on preference
        $commitSignPref = git config sync-ssh.commit-signing
        if ([string]::IsNullOrWhiteSpace($commitSignPref)) { $commitSignPref = "yes" }

        switch ($commitSignPref.ToLower().Trim()) {
            { $_ -in "no", "false" } {
                Write-Host "Git SSH commit signing is disabled via preference." -ForegroundColor Yellow
                git config --global commit.gpgsign false
            }
            "skip" {
                Write-Host "Skipping Git SSH commit signing configuration." -ForegroundColor Cyan
            }
            default {
                $gitSignMatch = $null
                foreach ($k in $bwLookup.Keys) {
                    if ($k.ToString().Trim().ToLower() -eq "git-sign") {
                        $gitSignMatch = $bwLookup[$k]
                        break
                    }
                }

                if ($gitSignMatch) {
                    if ($gitSignMatch.publicKey) {
                        $signPub = Join-Path $config.KeysDir "git-sign.pub"
                        $newSignPubContent = $gitSignMatch.publicKey.Trim()
                        if (Test-Path $signPub) {
                            Remove-Item -Path $signPub -Force -ErrorAction SilentlyContinue
                        }
                        $newSignPubContent | Out-File -FilePath $signPub -Encoding utf8 -Force

                        Write-Host "Synced Git signing key from Bitwarden: git-sign" -ForegroundColor Green

                        Write-Host "Configuring Git SSH signing with key: git-sign" -ForegroundColor Cyan
                        git config --global gpg.format ssh
                        git config --global user.signingkey "$signPub"
                        git config --global commit.gpgsign true
                        git config --global gpg.ssh.allowedSignersFile "$HOME\.ssh\allowed_signers"

                        # Determine email for allowed_signers
                        $signingEmail = $gitSignMatch.email
                        if (-not $signingEmail) { $signingEmail = git config user.email }

                        if ($signingEmail) {
                            $pubContent = $gitSignMatch.publicKey.Trim()
                            $parts = $pubContent -split '\s+'
                            if ($parts.Count -ge 2) {
                                $keyType = $parts[0]
                                $keyBlob = $parts[1]
                                $allowedFile = "$HOME\.ssh\allowed_signers"

                                $newEntry = "$signingEmail $keyType $keyBlob"

                                if (Test-Path $allowedFile) {
                                    $lines = Get-Content -Path $allowedFile
                                    $filteredLines = $lines | Where-Object { $_ -notmatch [regex]::Escape($signingEmail) }
                                    $filteredLines + $newEntry | Out-File -FilePath $allowedFile -Encoding utf8 -Force
                                } else {
                                    $newEntry | Out-File -FilePath $allowedFile -Encoding utf8 -Force
                                }

                                $currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
                                icacls "$allowedFile" /inheritance:r /grant "*S-1-5-18:F" /grant "*S-1-5-32-544:F" /grant "${currentUser}:F" | Out-Null

                                Write-Host "Updated $allowedFile for $signingEmail" -ForegroundColor Green
                            }
                        } else {
                            Write-Host "Email not found in Bitwarden and Git user.email not set. Skipping allowed_signers update." -ForegroundColor Yellow
                        }
                    } else {
                        Write-Host "Warning: Found Bitwarden item 'git-sign', but its Public Key field is empty." -ForegroundColor Yellow
                    }
                } else {
                    Write-Host "Warning: Git SSH signing is enabled, but no Bitwarden item named 'git-sign' was found." -ForegroundColor Yellow
                    Write-Host "Available item names in Bitwarden: $($bwLookup.Keys -join ', ')" -ForegroundColor Gray
                }
            }
        }

        # Process each key directly from Bitwarden data
        $newManagedContent = ""
        $processedCount = 0

        Write-Host "Processing SSH keys from Bitwarden vault..." -ForegroundColor Cyan

        foreach ($itemName in $bwLookup.Keys) {
            # Skip git-sign key as it is processed separately
            if ($itemName -eq "git-sign") { continue }

            $item = $bwLookup[$itemName]
            
            if (-not $item.publicKey) {
                continue
            }

            $missingAttrs = @()
            if (-not $item.hostname) { $missingAttrs += "HostName" }
            if (-not $item.user) { $missingAttrs += "User" }

            if ($missingAttrs.Count -gt 0) {
                Write-Host "Skipping key '$itemName': Missing custom field(s) in Bitwarden: $($missingAttrs -join ', ')" -ForegroundColor Yellow
                continue
            }

            $hostname = $item.hostname
            $user = $item.user

            # Sanitize Host alias (safeName)
            $safeName = $itemName -replace '[^a-zA-Z0-9._-]', '-'
            $safeName = $safeName.ToLower().Trim('-')
            if ([string]::IsNullOrWhiteSpace($safeName)) { $safeName = "ssh-key-" + (Get-Random) }

            $pubkeyFile = Join-Path $config.KeysDir "$safeName.pub"

            # Save public key (overwrite securely by deleting existing one first)
            if (Test-Path $pubkeyFile) {
                Remove-Item -Path $pubkeyFile -Force -ErrorAction SilentlyContinue
            }
            $item.publicKey.Trim() | Out-File -FilePath $pubkeyFile -Encoding utf8 -Force

            # Build config entry
            $entry = "`nHost $safeName`n"
            $entry += "  HostName $hostname`n"
            if ($user) {
                $entry += "  User $user`n"
            }
            $entry += "  IdentityFile $pubkeyFile`n"
            $entry += "  IdentitiesOnly yes`n"

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
