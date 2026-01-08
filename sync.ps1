# =========== SSH Config Sync Functions ===========

function Initialize-SshConfig {
    <#
    .SYNOPSIS
    Initialize SSH configuration directories and files
    #>
    param(
        [string]$OutputDir = "$HOME\ssh"
    )

    $KeysDir = Join-Path $OutputDir "keys"
    $SshConfig = Join-Path $OutputDir "config"

    # Create necessary directories
    New-Item -ItemType Directory -Path "$HOME\.ssh" -Force | Out-Null
    New-Item -ItemType Directory -Path $KeysDir -Force | Out-Null

    # Backup existing config if present
    if (-not (Test-Path $SshConfig)) {
        New-Item -ItemType File -Path $SshConfig -Force | Out-Null
    } else {
        $now = Get-Date -Format "yyyyMMdd_HHmmss"
        Move-Item -Path "$SshConfig" -Destination "$SshConfig_$now.bak" -ErrorAction SilentlyContinue
    }

    # Add default Host * configuration
    $configContent = Get-Content -Path $SshConfig -Raw -ErrorAction SilentlyContinue
    if (-not ($configContent -match "Host \*")) {
        $defaultConfig = @"
Host *
  Port 22
  AddKeysToAgent yes

"@
        $defaultConfig | Out-File -FilePath $SshConfig -Encoding utf8 -NoNewline
        if ($configContent) {
            $configContent | Out-File -FilePath $SshConfig -Append -Encoding utf8 -NoNewline
        }
    }

    # Create hard link from .ssh/config to our config file
    $linkPath = "$HOME\.ssh\config"
    if (Test-Path $linkPath) {
        Remove-Item $linkPath -Force
    }
    cmd /c mklink /H "$linkPath" "$SshConfig" | Out-Null

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

    if ($bwStatus -ne 'unlocked') {
        Write-Host "Bitwarden Vault: $bwStatus" -ForegroundColor Yellow
        Write-Host "Unlocking vault..."

        $unlockOutput = bw unlock --raw

        if ($LASTEXITCODE -eq 0) {
            $env:BW_SESSION = $unlockOutput
            Write-Host "✅ Vault unlocked successfully!" -ForegroundColor Green
        } else {
            Write-Host "❌ Failed to unlock vault" -ForegroundColor Red
            throw "Failed to unlock Bitwarden vault"
        }
    }
}

function Get-BitwardenSshKeys {
    <#
    .SYNOPSIS
    Retrieve SSH key metadata from Bitwarden
    #>

    Write-Host "Syncing Bitwarden vault..."
    bw sync 2>&1 | Out-Null

    $items = bw list items | ConvertFrom-Json
    $sshItems = $items | Where-Object { $_.type -eq 5 }

    # Create lookup dictionary: name -> (hostname, user)
    $bwLookup = @{}
    foreach ($item in $sshItems) {
        $hostnameField = $item.fields | Where-Object { $_.name -eq "HostName" }
        $userField = $item.fields | Where-Object { $_.name -eq "User" }

        $bwLookup[$item.name] = @{
            hostname = if ($hostnameField) { $hostnameField.value } else { $null }
            user = if ($userField) { $userField.value } else { $null }
        }
    }

    Write-Host "Found $($sshItems.Count) SSH keys in Bitwarden."
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

function Update-SshConfigEntry {
    <#
    .SYNOPSIS
    Add SSH config entry for a key
    #>
    param(
        [string]$KeyData,
        [string]$Type,
        [string]$Comment,
        [hashtable]$BwLookup,
        [string]$KeysDir,
        [string]$SshConfig
    )

    # Match comment with Bitwarden entry
    $bwMatch = $BwLookup[$Comment]

    if ($bwMatch -and $bwMatch.hostname) {
        $hostname = $bwMatch.hostname
        $user = $bwMatch.user
    } else {
        $hostname = $Comment
        $user = $null
    }

    # Sanitize filename
    $safeName = $Comment -replace '[\/:\\*?"<>|]', '_'
    $safeName = $safeName.ToLower()
    $pubkeyFile = Join-Path $KeysDir "$safeName.pub"

    # Save public key
    "$KeyData $Type $Comment" | Out-File -FilePath $pubkeyFile -Encoding utf8 -Force

    Write-Host "Host: $hostname"
    Write-Host "> Saved public key: $pubkeyFile"

    # Read existing config
    $configContent = Get-Content -Path $SshConfig -Raw -ErrorAction SilentlyContinue

    # Create config entry using safeName as Host alias
    if (-not ($configContent -match "Host $([regex]::Escape($safeName))")) {
        $configEntry = @"

Host $safeName
  HostName $hostname
  IdentityFile $pubkeyFile
  IdentitiesOnly yes
"@
        if ($user) {
            $configEntry += "`n  User $user"
        }

        $configEntry | Out-File -FilePath $SshConfig -Append -Encoding utf8
        Write-Host "> Added SSH config for $safeName" -ForegroundColor Green
    } else {
        Write-Host ">  SSH config for $safeName already exists, skipping." -ForegroundColor Gray
    }
}

function Sync-SSH {
    <#
    .SYNOPSIS
    Sync SSH keys from ssh-agent with Bitwarden metadata to create SSH config
    .PARAMETER OutputDir
    Directory to store SSH config and keys (default: ~/ssh)
    .EXAMPLE
    Sync-SSH
    Sync-SSH -OutputDir "C:\Users\MyUser\.ssh"
    #>
    param(
        [string]$OutputDir = "$HOME\ssh"
    )

    try {
        # Initialize directories and config
        $config = Initialize-SshConfig -OutputDir $OutputDir

        # Unlock Bitwarden if needed
        Unlock-BitwardenVault

        # Get Bitwarden SSH key metadata
        $bwLookup = Get-BitwardenSshKeys

        # Get keys from ssh-agent
        $keys = Get-SshAgentKeys

        # Process each key
        $processedCount = 0
        $keys | ForEach-Object {
            $line = $_.ToString().Trim()

            if ($line -and -not $line.StartsWith("The agent has no identities")) {
                $parts = $line -split '\s+', 3

                if ($parts.Count -ge 3) {
                    Update-SshConfigEntry -KeyData $parts[0] -Type $parts[1] -Comment $parts[2] `
                        -BwLookup $bwLookup -KeysDir $config.KeysDir -SshConfig $config.SshConfig
                    $processedCount++
                }
            }
        }

        Write-Host "`n✅ Done! Saved $processedCount SSH keys and updated config!" -ForegroundColor Green
    }
    catch {
        Write-Host "`n❌ Error: $_" -ForegroundColor Red
        exit 1
    }
}

# Export function for module usage
# Export-ModuleMember -Function Sync-SSH

# If script is run directly (not dot-sourced), execute the sync
if ($MyInvocation.InvocationName -ne '.') {
    Sync-SSH
}
