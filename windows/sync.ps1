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
    $currentUser = $env:USERNAME
    icacls "$HOME\.ssh" /inheritance:r /grant "*S-1-5-18:F" /grant "*S-1-5-32-544:F" /grant "${currentUser}:F" | Out-Null
    icacls "$KeysDir" /inheritance:r /grant "*S-1-5-18:F" /grant "*S-1-5-32-544:F" /grant "${currentUser}:F" | Out-Null

    # Take ownership and reset individual key permissions to inherit from strict folder permissions
    if (Test-Path "$KeysDir\*.pub") {
        takeown /f "$KeysDir\*.pub" | Out-Null
        icacls "$KeysDir\*.pub" /reset | Out-Null
    }

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

function Get-SshAgentKeys {
    <#
    .SYNOPSIS
    Retrieve public keys from ssh-agent
    #>

    $keys = ssh-add -L 2>&1

    if ($LASTEXITCODE -ne 0) {
        Write-Host "Error: Could not retrieve keys from SSH agent" -ForegroundColor Red
        Write-Host "Make sure you have keys loaded with: ssh-add" -ForegroundColor Yellow
        throw "SSH agent error"
    }

    return $keys
}

function Get-SshConfigEntry {
    <#
    .SYNOPSIS
    Generate SSH config entry for a key
    #>
    param(
        [string]$KeyData,
        [string]$Type,
        [string]$Comment,
        [hashtable]$BwLookup,
        [string]$KeysDir
    )

    # Match comment with Bitwarden entry
    $bwMatch = $BwLookup[$Comment]

    if (-not $bwMatch) {
        Write-Host "Skipping key '$Comment': No matching item found in Bitwarden." -ForegroundColor Yellow
        return $null
    }

    $missingAttrs = @()
    if (-not $bwMatch.hostname) { $missingAttrs += "HostName" }
    if (-not $bwMatch.user) { $missingAttrs += "User" }

    if ($missingAttrs.Count -gt 0) {
        Write-Host "Skipping key '$Comment': Missing custom field(s) in Bitwarden: $($missingAttrs -join ', ')" -ForegroundColor Yellow
        return $null
    }

    $hostname = $bwMatch.hostname
    $user = $bwMatch.user


    # Sanitize Host alias (safeName)
    $safeName = $Comment -replace '[^a-zA-Z0-9._-]', '-'
    $safeName = $safeName.ToLower().Trim('-')

    if ([string]::IsNullOrWhiteSpace($safeName)) { $safeName = "ssh-key-" + (Get-Random) }

    $pubkeyFile = Join-Path $KeysDir "$safeName.pub"

    # Save public key if content changed
    $newPubContent = "$KeyData $Type $Comment"
    $shouldWrite = $true
    if (Test-Path $pubkeyFile) {
        $currentPubContent = Get-Content -Path $pubkeyFile -Raw -ErrorAction SilentlyContinue
        if ($currentPubContent -and $currentPubContent.Trim() -eq $newPubContent.Trim()) {
            $shouldWrite = $false
        }
    }

    if ($shouldWrite) {
        $newPubContent | Out-File -FilePath $pubkeyFile -Encoding utf8 -Force
    }

    # Build config entry
    $entry = "`nHost $safeName`n"
    $entry += "  HostName $hostname`n"
    if ($user) {
        $entry += "  User $user`n"
    }
    $entry += "  IdentityFile $pubkeyFile`n"
    $entry += "  IdentitiesOnly yes`n"

    return $entry
}

function Sync-SSH {
    <#
    .SYNOPSIS
    Sync SSH keys from ssh-agent with Bitwarden metadata to create SSH config
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
        if ([string]::IsNullOrEmpty($commitSignPref)) { $commitSignPref = "enable" }

        if ($commitSignPref -eq "disable") {
            Write-Host "Git SSH commit signing is disabled via preference." -ForegroundColor Yellow
            git config --global commit.gpgsign false
        } elseif ($commitSignPref -eq "skip") {
            Write-Host "Skipping Git SSH commit signing configuration." -ForegroundColor Cyan
        } elseif ($commitSignPref -eq "enable") {
            $gitSignMatch = $bwLookup["git-sign"]
            if ($gitSignMatch -and $gitSignMatch.publicKey) {
                $signPub = Join-Path $config.KeysDir "git-sign.pub"
                $newSignPubContent = $gitSignMatch.publicKey.Trim()
                $shouldWriteSign = $true
                if (Test-Path $signPub) {
                    $currentSignPub = Get-Content -Path $signPub -Raw -ErrorAction SilentlyContinue
                    if ($currentSignPub -and $currentSignPub.Trim() -eq $newSignPubContent) {
                        $shouldWriteSign = $false
                    }
                }

                if ($shouldWriteSign) {
                    $newSignPubContent | Out-File -FilePath $signPub -Encoding utf8 -Force
                }

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

                        icacls "$allowedFile" /inheritance:r /grant "*S-1-5-18:F" /grant "*S-1-5-32-544:F" /grant "${currentUser}:F" | Out-Null

                        Write-Host "Updated $allowedFile for $signingEmail" -ForegroundColor Green
                    }
                } else {
                    Write-Host "Email not found in Bitwarden and Git user.email not set. Skipping allowed_signers update." -ForegroundColor Yellow
                }
            }
        }

        # Get keys from ssh-agent
        $keys = Get-SshAgentKeys

        # Process each key
        $newManagedContent = ""
        $processedCount = 0

        foreach ($key in $keys) {
            $line = $key.ToString().Trim()

            if ($line -and -not $line.StartsWith("The agent has no identities")) {
                $parts = $line -split '\s+', 3

                if ($parts.Count -ge 3) {
                    if ($parts[2] -eq "git-sign") { continue }
                    $entry = Get-SshConfigEntry -KeyData $parts[0] -Type $parts[1] -Comment $parts[2] `

                        -BwLookup $bwLookup -KeysDir $config.KeysDir
                    if ($entry) {
                        $newManagedContent += $entry
                        $processedCount++
                    }
                }
            }
        }

        # Apply SSH KeepAlive preference
        $keepAlivePref = git config sync-ssh.keep-alive
        if ($keepAlivePref -eq "enable") {
            $newManagedContent += "`nHost *`n  ServerAliveInterval 60`n  ServerAliveCountMax 3`n"
        } elseif ($keepAlivePref -eq "disable") {
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
