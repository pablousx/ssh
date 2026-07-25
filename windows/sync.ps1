[CmdletBinding()]
param(
    [Alias("DryRun")][switch]$SyncSshDryRun,
    [Alias("Version")][switch]$SyncSshVersion
)

$script:SyncStartMarker = "# --- START SYNC-SSH MANAGED SECTION ---"
$script:SyncEndMarker = "# --- END SYNC-SSH MANAGED SECTION ---"
$script:IncludeLine = "Include ~/.ssh/sync-ssh/current/config"

function Write-Utf8NoBom {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Content
    )
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Content, $encoding)
}

function Assert-LastExitCode {
    param([Parameter(Mandatory = $true)][string]$Operation)
    if ($LASTEXITCODE -ne 0) {
        throw "$Operation failed with exit code $LASTEXITCODE."
    }
}

function Get-SyncPaths {
    param([string]$OutputDir = "$HOME\.ssh")

    $managedRoot = Join-Path $OutputDir "sync-ssh"
    $stateDir = Join-Path $env:LOCALAPPDATA "sync-ssh-state"
    return @{
        OutputDir       = $OutputDir
        MainConfig     = Join-Path $OutputDir "config"
        ManagedRoot    = $managedRoot
        CurrentDir     = Join-Path $managedRoot "current"
        Preferences    = Join-Path (Join-Path $env:APPDATA "sync-ssh") "config.json"
        StateDir       = $stateDir
        GitStateDir    = Join-Path $stateDir "git"
        LockFile       = Join-Path $stateDir "sync.lock"
    }
}

function Resolve-MainConfigPath {
    param([hashtable]$Paths)
    if (-not (Test-Path -LiteralPath $Paths.MainConfig)) { return }
    $item = Get-Item -LiteralPath $Paths.MainConfig -Force
    if ($item.LinkType -eq "SymbolicLink") {
        $target = [string]$item.Target
        if (-not [System.IO.Path]::IsPathRooted($target)) {
            $target = Join-Path (Split-Path $item.FullName -Parent) $target
        }
        $target = [System.IO.Path]::GetFullPath($target)
        if (-not (Test-Path -LiteralPath $target)) {
            throw "SSH config symlink target does not exist: $target"
        }
        $Paths.MainConfig = $target
    }
}

function Get-Preferences {
    param([hashtable]$Paths)

    $preferences = [ordered]@{
        commit_signing = "skip"
        keep_alive     = "skip"
        agent_mode     = "bitwarden"
    }

    if (Test-Path -LiteralPath $Paths.Preferences) {
        try {
            $saved = Get-Content -LiteralPath $Paths.Preferences -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            foreach ($name in @("commit_signing", "keep_alive", "agent_mode")) {
                if ($null -ne $saved.$name -and -not [string]::IsNullOrWhiteSpace([string]$saved.$name)) {
                    $preferences[$name] = [string]$saved.$name
                }
            }
        } catch {
            throw "Unable to read preferences from $($Paths.Preferences): $($_.Exception.Message)"
        }
    } elseif (Get-Command git -ErrorAction SilentlyContinue) {
        $legacyMap = @{
            commit_signing = "sync-ssh.commit-signing"
            keep_alive     = "sync-ssh.keep-alive"
            agent_mode     = "sync-ssh.agent-mode"
        }
        foreach ($name in $legacyMap.Keys) {
            $legacy = & git config --global --get $legacyMap[$name] 2>$null
            if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($legacy)) {
                $preferences[$name] = $legacy.Trim()
            }
        }
    }

    if ($preferences.commit_signing -notin @("yes", "no", "skip")) {
        throw "Invalid commit_signing preference: $($preferences.commit_signing)"
    }
    if ($preferences.keep_alive -notin @("yes", "no", "skip")) {
        throw "Invalid keep_alive preference: $($preferences.keep_alive)"
    }
    if ($preferences.agent_mode -notin @("bitwarden", "disk")) {
        throw "Invalid agent_mode preference: $($preferences.agent_mode)"
    }
    return $preferences
}

function Enter-SyncLock {
    param([hashtable]$Paths)
    [System.IO.Directory]::CreateDirectory($Paths.StateDir) | Out-Null
    try {
        return [System.IO.File]::Open(
            $Paths.LockFile,
            [System.IO.FileMode]::CreateNew,
            [System.IO.FileAccess]::Write,
            [System.IO.FileShare]::None
        )
    } catch [System.IO.IOException] {
        throw "Another sync-ssh process is already running."
    }
}

function Ensure-Command {
    param([Parameter(Mandatory = $true)][string]$Name)
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Required command not found: $Name"
    }
}

function Get-BitwardenItems {
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
        $session = (& bw unlock --raw | Out-String).Trim()
        Assert-LastExitCode "Bitwarden unlock"
        if ([string]::IsNullOrWhiteSpace($session)) {
            throw "Bitwarden returned an empty session token."
        }
        $env:BW_SESSION = $session
    }

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
    return @($allItems | Where-Object { $_.type -eq 5 })
}

function Get-ItemField {
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

function Assert-SafeMetadata {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value,
        [Parameter(Mandatory = $true)][string]$Label,
        [switch]$AllowSpaces
    )
    if ($Value -match "[\x00-\x1F\x7F]") {
        throw "$Label contains a control character."
    }
    if (-not $AllowSpaces -and $Value -match "[\s#]") {
        throw "$Label contains unsupported whitespace or '#'."
    }
}

function ConvertTo-SafeAlias {
    param([Parameter(Mandatory = $true)][string]$Name)
    Assert-SafeMetadata -Value $Name -Label "SSH item name" -AllowSpaces
    $alias = (($Name.ToLowerInvariant() -replace "[^a-z0-9._-]", "-") -replace "^-+", "") -replace "-+$", ""
    if ([string]::IsNullOrWhiteSpace($alias) -or $alias -notmatch "^[a-z0-9][a-z0-9._-]*$") {
        throw "Bitwarden item '$Name' produces an invalid SSH alias."
    }
    return $alias
}

function Write-ValidatedPublicKey {
    param(
        [Parameter(Mandatory = $true)][string]$PublicKey,
        [Parameter(Mandatory = $true)][string]$Path
    )
    if ([string]::IsNullOrWhiteSpace($PublicKey)) {
        throw "Missing public key for $(Split-Path -Leaf $Path)."
    }
    Write-Utf8NoBom -Path $Path -Content ($PublicKey.Trim() + "`n")
    & ssh-keygen -lf $Path 2>$null | Out-Null
    Assert-LastExitCode "Validating public key $(Split-Path -Leaf $Path)"
}

function New-GeneratedFiles {
    param(
        [Parameter(Mandatory = $true)][object[]]$Items,
        [Parameter(Mandatory = $true)][hashtable]$Paths,
        [Parameter(Mandatory = $true)]$Preferences,
        [Parameter(Mandatory = $true)][string]$StagingDir
    )

    $keysDir = Join-Path $StagingDir "keys"
    [System.IO.Directory]::CreateDirectory($keysDir) | Out-Null
    $aliases = @{}
    $entries = New-Object System.Collections.Generic.List[string]
    $manifest = New-Object System.Collections.Generic.List[string]
    $manifest.Add("config")
    $processed = 0
    $signEmail = ""

    foreach ($item in @($Items | Sort-Object { ([string]$_.name).ToLowerInvariant() })) {
        $name = [string]$item.name
        $alias = ConvertTo-SafeAlias $name
        if ($aliases.ContainsKey($alias)) {
            throw "Multiple Bitwarden items produce the SSH alias '$alias'."
        }
        $aliases[$alias] = $true

        $hostname = Get-ItemField -Item $item -Names @("hostname")
        $user = Get-ItemField -Item $item -Names @("user")
        $email = Get-ItemField -Item $item -Names @("email", "gitemail")
        Assert-SafeMetadata -Value $hostname -Label "HostName for '$name'"
        Assert-SafeMetadata -Value $user -Label "User for '$name'"
        Assert-SafeMetadata -Value $email -Label "Email for '$name'"

        $publicKey = if ($item.sshKey) { [string]$item.sshKey.publicKey } else { "" }
        $publicPath = Join-Path $keysDir "$alias.pub"
        Write-ValidatedPublicKey -PublicKey $publicKey -Path $publicPath
        $manifest.Add("keys/$alias.pub")

        if ($alias -eq "git-sign") {
            $signEmail = $email
            if ($Preferences.agent_mode -eq "disk" -and $item.sshKey.privateKey) {
                Write-Utf8NoBom -Path (Join-Path $keysDir "git-sign") -Content ([string]$item.sshKey.privateKey).Trim() + "`n"
                $manifest.Add("keys/git-sign")
            }
            continue
        }

        if ([string]::IsNullOrWhiteSpace($hostname)) {
            throw "Bitwarden SSH item '$name' has no HostName field."
        }
        if ($item.organizationId -and $item.organizationId -ne "00000000-0000-0000-0000-000000000000") {
            Write-Host "Using organization-owned SSH item: $name" -ForegroundColor Yellow
        }

        $identitySuffix = ".pub"
        if ($Preferences.agent_mode -eq "disk") {
            $privateKey = if ($item.sshKey) { [string]$item.sshKey.privateKey } else { "" }
            if ([string]::IsNullOrWhiteSpace($privateKey)) {
                throw "Disk mode requires a private key for '$name'."
            }
            Write-Utf8NoBom -Path (Join-Path $keysDir $alias) -Content ($privateKey.Trim() + "`n")
            $manifest.Add("keys/$alias")
            $identitySuffix = ""
        }

        $entry = "`nHost $alias`n  HostName $hostname`n"
        if (-not [string]::IsNullOrWhiteSpace($user)) {
            $entry += "  User $user`n"
        }
        $entry += "  IdentityFile `"~/.ssh/sync-ssh/current/keys/$alias$identitySuffix`"`n  IdentitiesOnly yes`n"
        $entries.Add($entry)
        $processed++
    }

    if ($Preferences.keep_alive -eq "yes") {
        $entries.Add("`nHost *`n  ServerAliveInterval 60`n  ServerAliveCountMax 3`n")
    } elseif ($Preferences.keep_alive -eq "no") {
        $entries.Add("`nHost *`n  ServerAliveInterval 0`n")
    }

    $generatedConfig = Join-Path $StagingDir "config"
    Write-Utf8NoBom -Path $generatedConfig -Content ($entries -join "")

    $signPublic = Join-Path $keysDir "git-sign.pub"
    if (Test-Path -LiteralPath $signPublic) {
        if ([string]::IsNullOrWhiteSpace($signEmail) -and (Get-Command git -ErrorAction SilentlyContinue)) {
            $signEmail = (& git config --global --get user.email 2>$null | Out-String).Trim()
        }
        if (-not [string]::IsNullOrWhiteSpace($signEmail)) {
            $keyText = (Get-Content -LiteralPath $signPublic -Raw).Trim()
            Write-Utf8NoBom -Path (Join-Path $StagingDir "allowed_signers") -Content "$signEmail $keyText`n"
            $manifest.Add("allowed_signers")
        }
    }

    Write-Utf8NoBom -Path (Join-Path $StagingDir "manifest.json") -Content (
        (@{ version = 1; files = @($manifest); private_keys = ($Preferences.agent_mode -eq "disk") } |
            ConvertTo-Json -Depth 4) + "`n"
    )

    $validationAlias = @($aliases.Keys | Where-Object { $_ -ne "git-sign" } | Sort-Object | Select-Object -First 1)
    if ($validationAlias.Count -eq 0) { $validationAlias = @("sync-ssh-validation") }
    & ssh -F $generatedConfig -G $validationAlias[0] 2>$null | Out-Null
    Assert-LastExitCode "Validating generated OpenSSH configuration"

    return @{ Processed = $processed }
}

function New-StagedMainConfig {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Paths,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    $lines = @()
    if (Test-Path -LiteralPath $Paths.MainConfig) {
        $lines = @(Get-Content -LiteralPath $Paths.MainConfig)
    } else {
        $lines = @("Host *", "  Port 22", "  AddKeysToAgent yes", "  ForwardAgent no")
    }

    $startIndexes = @()
    $endIndexes = @()
    for ($index = 0; $index -lt $lines.Count; $index++) {
        if ($lines[$index] -eq $script:SyncStartMarker) { $startIndexes += $index }
        if ($lines[$index] -eq $script:SyncEndMarker) { $endIndexes += $index }
    }
    if ($startIndexes.Count -ne $endIndexes.Count -or $startIndexes.Count -gt 1) {
        throw "Malformed legacy sync-ssh markers in $($Paths.MainConfig); refusing to modify it."
    }
    if ($startIndexes.Count -eq 1) {
        if ($endIndexes[0] -le $startIndexes[0]) {
            throw "Malformed legacy sync-ssh marker ordering in $($Paths.MainConfig)."
        }
        $kept = New-Object System.Collections.Generic.List[string]
        for ($index = 0; $index -lt $lines.Count; $index++) {
            if ($index -lt $startIndexes[0] -or $index -gt $endIndexes[0]) {
                $kept.Add($lines[$index])
            }
        }
        $lines = @($kept)
    }

    $includeCount = @($lines | Where-Object { $_ -eq $script:IncludeLine }).Count
    if ($includeCount -gt 1) {
        throw "Duplicate sync-ssh Include directives found in $($Paths.MainConfig)."
    }
    if ($includeCount -eq 0) {
        $lines = @(
            "# Added by Bitwarden SSH Sync",
            $script:IncludeLine,
            ""
        ) + $lines
    }
    Write-Utf8NoBom -Path $Destination -Content (($lines -join "`n").TrimEnd() + "`n")
}

function Save-GitPreviousValue {
    param(
        [hashtable]$Paths,
        [string]$Key,
        [string]$Slug,
        [string]$Owned
    )
    [System.IO.Directory]::CreateDirectory($Paths.GitStateDir) | Out-Null
    $statePath = Join-Path $Paths.GitStateDir "$Slug.json"
    if (-not (Test-Path -LiteralPath $statePath)) {
        $previous = (& git config --global --get $Key 2>$null | Out-String).Trim()
        $present = ($LASTEXITCODE -eq 0)
        Write-Utf8NoBom -Path $statePath -Content (
            (@{ key = $Key; present = $present; previous = $previous; owned = $Owned } |
                ConvertTo-Json -Compress) + "`n"
        )
    } else {
        $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
        $state.owned = $Owned
        Write-Utf8NoBom -Path $statePath -Content (($state | ConvertTo-Json -Compress) + "`n")
    }
}

function Set-OwnedGitValue {
    param([hashtable]$Paths, [string]$Key, [string]$Slug, [string]$Value)
    Save-GitPreviousValue -Paths $Paths -Key $Key -Slug $Slug -Owned $Value
    & git config --global $Key $Value
    Assert-LastExitCode "Setting Git configuration '$Key'"
}

function Restore-OwnedGitValue {
    param([hashtable]$Paths, [string]$Slug)
    $statePath = Join-Path $Paths.GitStateDir "$Slug.json"
    if (-not (Test-Path -LiteralPath $statePath)) { return }
    $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
    $current = (& git config --global --get $state.key 2>$null | Out-String).Trim()
    if ($current -eq $state.owned) {
        if ($state.present) {
            & git config --global $state.key ([string]$state.previous)
        } else {
            & git config --global --unset-all $state.key 2>$null
        }
    } else {
        Write-Host "Preserving user-modified Git setting: $($state.key)" -ForegroundColor Yellow
    }
    Remove-Item -LiteralPath $statePath -Force
}

function Update-GitSigning {
    param([hashtable]$Paths, $Preferences)
    if ($Preferences.commit_signing -eq "skip") { return }
    Ensure-Command git

    if ($Preferences.commit_signing -eq "yes") {
        $signingKey = Join-Path $Paths.CurrentDir "keys\git-sign.pub"
        if (-not (Test-Path -LiteralPath $signingKey)) {
            throw "Git signing is enabled, but no 'git-sign' public key was found."
        }
        Set-OwnedGitValue $Paths "gpg.format" "gpg-format" "ssh"
        Set-OwnedGitValue $Paths "user.signingkey" "user-signingkey" $signingKey
        Set-OwnedGitValue $Paths "commit.gpgsign" "commit-gpgsign" "true"
        $allowed = Join-Path $Paths.CurrentDir "allowed_signers"
        if (Test-Path -LiteralPath $allowed) {
            Set-OwnedGitValue $Paths "gpg.ssh.allowedSignersFile" "allowed-signers-file" $allowed
        }
    } else {
        Restore-OwnedGitValue $Paths "allowed-signers-file"
        Restore-OwnedGitValue $Paths "commit-gpgsign"
        Restore-OwnedGitValue $Paths "user-signingkey"
        Restore-OwnedGitValue $Paths "gpg-format"
    }
}

function Publish-GeneratedFiles {
    param(
        [hashtable]$Paths,
        [string]$StagingDir,
        [string]$StagedMain
    )
    [System.IO.Directory]::CreateDirectory($Paths.ManagedRoot) | Out-Null
    $previous = Join-Path $Paths.ManagedRoot ".previous"
    if (Test-Path -LiteralPath $previous) {
        Remove-Item -LiteralPath $previous -Recurse -Force
    }
    if (Test-Path -LiteralPath $Paths.CurrentDir) {
        Move-Item -LiteralPath $Paths.CurrentDir -Destination $previous
    }
    try {
        Move-Item -LiteralPath $StagingDir -Destination $Paths.CurrentDir
    } catch {
        if (Test-Path -LiteralPath $previous) {
            Move-Item -LiteralPath $previous -Destination $Paths.CurrentDir
        }
        throw
    }

    $backup = Join-Path $Paths.StateDir "config.pre-sync-ssh"
    if ((Test-Path -LiteralPath $Paths.MainConfig) -and -not (Test-Path -LiteralPath $backup)) {
        Copy-Item -LiteralPath $Paths.MainConfig -Destination $backup
    }
    try {
        if (Test-Path -LiteralPath $Paths.MainConfig) {
            [System.IO.File]::Replace($StagedMain, $Paths.MainConfig, $null, $true)
        } else {
            [System.IO.File]::Move($StagedMain, $Paths.MainConfig)
        }
    } catch {
        if (Test-Path -LiteralPath $Paths.CurrentDir) {
            Remove-Item -LiteralPath $Paths.CurrentDir -Recurse -Force
        }
        if (Test-Path -LiteralPath $previous) {
            Move-Item -LiteralPath $previous -Destination $Paths.CurrentDir
        }
        throw
    }
    if (Test-Path -LiteralPath $previous) {
        Remove-Item -LiteralPath $previous -Recurse -Force
    }
}

function Set-ManagedPermissions {
    param([hashtable]$Paths)
    $currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    & icacls $Paths.ManagedRoot /inheritance:r /grant:r "*S-1-5-18:(OI)(CI)F" "*S-1-5-32-544:(OI)(CI)F" "${currentUser}:(OI)(CI)F" /t | Out-Null
    Assert-LastExitCode "Securing the sync-ssh managed directory"
}

function Sync-SSH {
    [CmdletBinding()]
    param(
        [string]$OutputDir = "$HOME\.ssh",
        [switch]$DryRun,
        [switch]$Version
    )

    $ErrorActionPreference = "Stop"
    if ($Version) {
        $versionFile = Join-Path $PSScriptRoot "VERSION"
        if (-not (Test-Path -LiteralPath $versionFile)) {
            $versionFile = Join-Path (Split-Path $PSScriptRoot -Parent) "VERSION"
        }
        if (Test-Path -LiteralPath $versionFile) {
            Write-Output (Get-Content -LiteralPath $versionFile -Raw).Trim()
        } else {
            Write-Output "development"
        }
        return
    }

    $paths = Get-SyncPaths -OutputDir $OutputDir
    $lock = $null
    $stagingDir = $null
    $stagedMain = $null

    try {
        Ensure-Command bw
        Ensure-Command ssh
        Ensure-Command ssh-keygen
        Resolve-MainConfigPath -Paths $paths
        $preferences = Get-Preferences -Paths $paths
        $lock = Enter-SyncLock -Paths $paths
        $items = Get-BitwardenItems

        [System.IO.Directory]::CreateDirectory($paths.OutputDir) | Out-Null
        [System.IO.Directory]::CreateDirectory($paths.ManagedRoot) | Out-Null
        $stagingDir = Join-Path $paths.ManagedRoot (".staging." + [Guid]::NewGuid().ToString("N"))
        [System.IO.Directory]::CreateDirectory($stagingDir) | Out-Null
        $result = New-GeneratedFiles -Items $items -Paths $paths -Preferences $preferences -StagingDir $stagingDir

        $stagedMain = Join-Path (Split-Path $paths.MainConfig -Parent) (".sync-ssh-config." + [Guid]::NewGuid().ToString("N"))
        New-StagedMainConfig -Paths $paths -Destination $stagedMain
        if ($preferences.commit_signing -eq "yes") {
            Ensure-Command git
            if (-not (Test-Path -LiteralPath (Join-Path $stagingDir "keys\git-sign.pub"))) {
                throw "Git signing is enabled, but no 'git-sign' public key was found."
            }
        }
        if ($DryRun) {
            Write-Host "Dry run successful: generated configuration passed validation; active files were not changed." -ForegroundColor Cyan
            return
        }

        Publish-GeneratedFiles -Paths $paths -StagingDir $stagingDir -StagedMain $stagedMain
        $stagingDir = $null
        $stagedMain = $null

        Set-ManagedPermissions -Paths $paths
        Update-GitSigning -Paths $paths -Preferences $preferences
        Write-Host "[OK] Synced $($result.Processed) SSH hosts using $($preferences.agent_mode) mode." -ForegroundColor Green
    } finally {
        if ($stagingDir -and (Test-Path -LiteralPath $stagingDir)) {
            Remove-Item -LiteralPath $stagingDir -Recurse -Force
        }
        if ($stagedMain -and (Test-Path -LiteralPath $stagedMain)) {
            Remove-Item -LiteralPath $stagedMain -Force
        }
        if ($lock) {
            $lock.Dispose()
            Remove-Item -LiteralPath $paths.LockFile -Force -ErrorAction SilentlyContinue
        }
    }
}

if ($MyInvocation.InvocationName -ne ".") {
    try {
        Sync-SSH -DryRun:$SyncSshDryRun -Version:$SyncSshVersion
    } catch {
        Write-Host "[ERROR] $($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }
}
