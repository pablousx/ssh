function Get-ProviderCapabilities {
    return [pscustomobject]@{
        protocol_version = 1
        provider         = "bitwarden"
        capabilities     = [pscustomobject]@{
            agent              = $true
            private_key_export = $true
        }
    }
}

function Assert-ProviderRequirements {
    Ensure-Command bw
}

function Connect-Provider {
    $statusRaw = (& bw status | Out-String)
    Assert-LastExitCode "Bitwarden status"
    try {
        $status = ($statusRaw | ConvertFrom-Json -ErrorAction Stop).status
    } catch {
        throw "Bitwarden returned an invalid status response."
    }

    if ($status -eq "unauthenticated") {
        throw "Bitwarden is not logged in. Run 'bw login' first."
    }
    if ($status -eq "locked" -or [string]::IsNullOrWhiteSpace($env:BW_SESSION)) {
        Write-Host "Unlocking Bitwarden vault..." -ForegroundColor Cyan
        $securePassword = Read-Host "Master password" -AsSecureString
        $credential = New-Object System.Management.Automation.PSCredential(
            "sshwitch",
            $securePassword
        )
        $env:SSHWITCH_BW_PASSWORD = $credential.GetNetworkCredential().Password
        try {
            $session = (& bw unlock --raw --passwordenv SSHWITCH_BW_PASSWORD 2>$null |
                Out-String).Trim()
            if ($LASTEXITCODE -ne 0) {
                throw "Unable to unlock Bitwarden vault. Check your master password and try again."
            }
        } finally {
            Remove-Item Env:SSHWITCH_BW_PASSWORD -ErrorAction SilentlyContinue
            $credential = $null
            $securePassword = $null
        }
        if ([string]::IsNullOrWhiteSpace($session)) {
            throw "Bitwarden returned an empty session token."
        }
        $env:BW_SESSION = $session
    }
}

function Get-BitwardenField {
    param(
        [Parameter(Mandatory = $true)]$Item,
        [Parameter(Mandatory = $true)][string[]]$Names
    )
    $field = @($Item.fields) | Where-Object {
        $candidate = [string]$_.name
        $Names -contains $candidate.ToLowerInvariant()
    } | Select-Object -First 1
    if ($field) { return [string]$field.value }
    return ""
}

function Get-ProviderRecords {
    Write-Host "Syncing Bitwarden vault..." -ForegroundColor Cyan
    & bw sync 2>$null | Out-Null
    Assert-LastExitCode "Bitwarden sync"

    Write-Host "Fetching SSH key items..." -ForegroundColor Cyan
    $itemsRaw = (& bw list items | Out-String)
    Assert-LastExitCode "Listing Bitwarden items"
    try {
        $allItems = @($itemsRaw | ConvertFrom-Json -ErrorAction Stop)
    } catch {
        throw "Bitwarden returned invalid item JSON."
    }

    $records = New-Object System.Collections.Generic.List[object]
    foreach ($item in @($allItems | Where-Object { $_.type -eq 5 })) {
        $name = [string]$item.name
        $roleField = Get-BitwardenField -Item $item -Names @("sshwitchrole", "syncsshrole", "role")
        $normalized = (($name.ToLowerInvariant() -replace "[^a-z0-9._-]", "-") -replace "^-+", "") -replace "-+$", ""
        $role = if ($roleField.ToLowerInvariant() -eq "git-sign" -or
            ([string]::IsNullOrWhiteSpace($roleField) -and $normalized -eq "git-sign")) {
            "git-sign"
        } else {
            "host"
        }
        $shared = -not [string]::IsNullOrWhiteSpace([string]$item.organizationId) -and
            [string]$item.organizationId -ne "00000000-0000-0000-0000-000000000000"
        $records.Add([pscustomobject]@{
            source_id     = [string]$item.id
            name          = $name
            role          = $role
            destination   = [pscustomobject]@{
                hostname = Get-BitwardenField -Item $item -Names @("hostname")
                user     = Get-BitwardenField -Item $item -Names @("user")
            }
            identity      = [pscustomobject]@{
                public_key = if ($item.sshKey) { [string]$item.sshKey.publicKey } else { "" }
            }
            git_principal = Get-BitwardenField -Item $item -Names @("email", "gitemail")
            shared        = $shared
        })
    }

    return [pscustomobject]@{
        schema_version = 1
        provider       = "bitwarden"
        records        = @($records | ForEach-Object { $_ })
    }
}

function Export-ProviderPrivateKey {
    param(
        [Parameter(Mandatory = $true)][string]$SourceId,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    $itemRaw = (& bw get item $SourceId | Out-String)
    Assert-LastExitCode "Retrieving Bitwarden SSH item for private-key export"
    try {
        $item = $itemRaw | ConvertFrom-Json -ErrorAction Stop
    } catch {
        throw "Bitwarden returned invalid item JSON during private-key export."
    }
    $privateKey = if ($item.type -eq 5 -and $item.sshKey) {
        [string]$item.sshKey.privateKey
    } else {
        ""
    }
    if ([string]::IsNullOrWhiteSpace($privateKey)) {
        return $false
    }
    Write-Utf8NoBom -Path $Destination -Content ($privateKey.Trim() + "`n")
    return $true
}
