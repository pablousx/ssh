[CmdletBinding()]
param(
    [Alias("DryRun")][switch]$SSHwitchDryRun,
    [Alias("Version")][switch]$SSHwitchVersion
)

$script:LegacyStartMarker = "# --- START SYNC-SSH MANAGED SECTION ---"
$script:LegacyEndMarker = "# --- END SYNC-SSH MANAGED SECTION ---"
$script:IncludeLine = "Include ~/.ssh/sshwitch/current/config"
$script:LegacyIncludeLine = "Include ~/.ssh/sync-ssh/current/config"

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

function Get-SSHwitchPaths {
    param([string]$OutputDir = "$HOME\.ssh")

    $managedRoot = Join-Path $OutputDir "sshwitch"
    $stateDir = Join-Path $env:LOCALAPPDATA "sshwitch-state"
    return @{
        OutputDir       = $OutputDir
        MainConfig     = Join-Path $OutputDir "config"
        ManagedRoot    = $managedRoot
        CurrentDir     = Join-Path $managedRoot "current"
        Preferences    = Join-Path (Join-Path $env:APPDATA "sshwitch") "config.json"
        LegacyPreferences = Join-Path (Join-Path $env:APPDATA "sync-ssh") "config.json"
        StateDir       = $stateDir
        LegacyStateDir = Join-Path $env:LOCALAPPDATA "sync-ssh-state"
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
        provider       = "bitwarden"
        identity_backend = ""
        private_key_policy = ""
    }
    $legacyAgentMode = ""

    $preferencesPath = $Paths.Preferences
    if (-not (Test-Path -LiteralPath $preferencesPath) -and
        $Paths.LegacyPreferences -and
        (Test-Path -LiteralPath $Paths.LegacyPreferences)) {
        $preferencesPath = $Paths.LegacyPreferences
    }
    if (Test-Path -LiteralPath $preferencesPath) {
        try {
            $saved = Get-Content -LiteralPath $preferencesPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            foreach ($name in @(
                "commit_signing",
                "keep_alive",
                "provider",
                "identity_backend",
                "private_key_policy"
            )) {
                $property = $saved.PSObject.Properties[$name]
                if ($property -and -not [string]::IsNullOrWhiteSpace([string]$property.Value)) {
                    $preferences[$name] = [string]$property.Value
                }
            }
            $legacyProperty = $saved.PSObject.Properties["agent_mode"]
            if ($legacyProperty) { $legacyAgentMode = [string]$legacyProperty.Value }
        } catch {
            throw "Unable to read preferences from ${preferencesPath}: $($_.Exception.Message)"
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
                if ($name -eq "agent_mode") {
                    $legacyAgentMode = $legacy.Trim()
                } else {
                    $preferences[$name] = $legacy.Trim()
                }
            }
        }
    }

    if ([string]::IsNullOrWhiteSpace($preferences.identity_backend)) {
        $preferences.identity_backend = if ($legacyAgentMode -eq "disk") { "disk" } else { "agent" }
    }
    if ([string]::IsNullOrWhiteSpace($preferences.private_key_policy)) {
        $preferences.private_key_policy = if ($preferences.identity_backend -eq "disk") { "export" } else { "never" }
    }
    if ($preferences.commit_signing -notin @("yes", "no", "skip")) {
        throw "Invalid commit_signing preference: $($preferences.commit_signing)"
    }
    if ($preferences.keep_alive -notin @("yes", "no", "skip")) {
        throw "Invalid keep_alive preference: $($preferences.keep_alive)"
    }
    if ($preferences.provider -notmatch "^[a-z0-9][a-z0-9-]*$") {
        throw "Invalid provider preference: $($preferences.provider)"
    }
    $combination = "$($preferences.identity_backend):$($preferences.private_key_policy)"
    if ($combination -notin @("agent:never", "disk:export")) {
        throw "Invalid identity backend/private-key policy combination: " +
            "$($preferences.identity_backend)/$($preferences.private_key_policy)"
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
        throw "Another SSHwitch process is already running."
    }
}

function Import-LegacyState {
    param([hashtable]$Paths)
    $legacyGitState = Join-Path $Paths.LegacyStateDir "git"
    if (-not (Test-Path -LiteralPath $Paths.GitStateDir) -and
        (Test-Path -LiteralPath $legacyGitState)) {
        Copy-Item -LiteralPath $legacyGitState -Destination $Paths.GitStateDir -Recurse
    }
}

function Ensure-Command {
    param([Parameter(Mandatory = $true)][string]$Name)
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Required command not found: $Name"
    }
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
        throw "Provider item '$Name' produces an invalid SSH alias."
    }
    return $alias
}

function Assert-ExactProperties {
    param(
        [Parameter(Mandatory = $true)]$Object,
        [Parameter(Mandatory = $true)][string[]]$Expected,
        [Parameter(Mandatory = $true)][string]$Label
    )
    $actual = @($Object.PSObject.Properties.Name | Sort-Object)
    $wanted = @($Expected | Sort-Object)
    if (($actual -join "`n") -ne ($wanted -join "`n")) {
        throw "$Label contains unsupported or missing properties."
    }
}

function Assert-ProviderEnvelope {
    param(
        [Parameter(Mandatory = $true)]$Envelope,
        [Parameter(Mandatory = $true)][string]$Provider
    )

    Assert-ExactProperties $Envelope @("schema_version", "provider", "records") "Provider envelope"
    if ($Envelope.schema_version -ne 1 -or [string]$Envelope.provider -ne $Provider) {
        throw "Provider '$Provider' returned an unsupported record schema."
    }
    foreach ($record in @($Envelope.records)) {
        Assert-ExactProperties $record @(
            "source_id", "name", "role", "destination", "identity",
            "git_principal", "shared"
        ) "Provider record"
        Assert-ExactProperties $record.destination @("hostname", "user") "Provider destination"
        Assert-ExactProperties $record.identity @("public_key") "Provider identity"
        foreach ($textField in @(
            $record.source_id,
            $record.name,
            $record.destination.hostname,
            $record.destination.user,
            $record.identity.public_key,
            $record.git_principal
        )) {
            if ($textField -isnot [string]) {
                throw "Provider record text fields must be strings."
            }
            Assert-SafeMetadata -Value ([string]$textField) -Label "Provider text" -AllowSpaces
        }
        if ([string]::IsNullOrWhiteSpace([string]$record.source_id) -or
            [string]::IsNullOrWhiteSpace([string]$record.name) -or
            [string]::IsNullOrWhiteSpace([string]$record.identity.public_key)) {
            throw "Provider record contains an empty required field."
        }
        if ([string]$record.role -notin @("host", "git-sign")) {
            throw "Provider record contains an unsupported role."
        }
        if ($record.shared -isnot [bool]) {
            throw "Provider record shared flag must be boolean."
        }
    }
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

function Assert-AgentIdentityAvailable {
    param([Parameter(Mandatory = $true)][string]$PublicKeyPath)

    $publicParts = ((Get-Content -LiteralPath $PublicKeyPath -Raw).Trim() -split "\s+")
    if ($publicParts.Count -lt 2) {
        throw "Unable to identify a provider public key."
    }
    $expected = "$($publicParts[0]) $($publicParts[1])"
    $agentRaw = (& ssh-add -L 2>$null | Out-String)
    Assert-LastExitCode "Listing identities from the selected SSH agent"
    $matched = $false
    foreach ($line in @($agentRaw -split "\r?\n")) {
        $parts = @($line.Trim() -split "\s+")
        if ($parts.Count -ge 2 -and "$($parts[0]) $($parts[1])" -eq $expected) {
            $matched = $true
            break
        }
    }
    if (-not $matched) {
        throw "A provider public key is not available from the selected SSH agent."
    }
}

function New-GeneratedFiles {
    param(
        [Parameter(Mandatory = $true)][object[]]$Records,
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

    foreach ($record in @($Records | Sort-Object { ([string]$_.name).ToLowerInvariant() })) {
        $name = [string]$record.name
        $alias = if ([string]$record.role -eq "git-sign") { "git-sign" } else { ConvertTo-SafeAlias $name }
        if ($aliases.ContainsKey($alias)) {
            throw "Multiple provider items produce the SSH alias '$alias'."
        }
        $aliases[$alias] = $true

        $hostname = [string]$record.destination.hostname
        $user = [string]$record.destination.user
        $email = [string]$record.git_principal
        Assert-SafeMetadata -Value $hostname -Label "HostName for '$name'"
        Assert-SafeMetadata -Value $user -Label "User for '$name'"
        Assert-SafeMetadata -Value $email -Label "Email for '$name'"

        $publicKey = [string]$record.identity.public_key
        $publicPath = Join-Path $keysDir "$alias.pub"
        Write-ValidatedPublicKey -PublicKey $publicKey -Path $publicPath
        if ($Preferences.identity_backend -eq "agent") {
            Assert-AgentIdentityAvailable -PublicKeyPath $publicPath
        }
        $manifest.Add("keys/$alias.pub")

        if ([string]$record.role -eq "git-sign") {
            $signEmail = $email
            if ($Preferences.private_key_policy -eq "export") {
                $privatePath = Join-Path $keysDir "git-sign"
                if (Export-ProviderPrivateKey -SourceId ([string]$record.source_id) -Destination $privatePath) {
                    $manifest.Add("keys/git-sign")
                }
            }
            continue
        }

        if ([string]::IsNullOrWhiteSpace($hostname)) {
            throw "Provider SSH item '$name' has no HostName field."
        }
        if ($record.shared) {
            Write-Host "Using shared provider SSH item: $name" -ForegroundColor Yellow
        }

        $identitySuffix = ".pub"
        if ($Preferences.private_key_policy -eq "export") {
            $privatePath = Join-Path $keysDir $alias
            if (-not (Export-ProviderPrivateKey -SourceId ([string]$record.source_id) -Destination $privatePath)) {
                throw "Disk identity backend requires a private key for '$name'."
            }
            $manifest.Add("keys/$alias")
            $identitySuffix = ""
        }

        $entry = "`nHost $alias`n  HostName $hostname`n"
        if (-not [string]::IsNullOrWhiteSpace($user)) {
            $entry += "  User $user`n"
        }
        $entry += "  IdentityFile `"~/.ssh/sshwitch/current/keys/$alias$identitySuffix`"`n  IdentitiesOnly yes`n"
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
        (@{
            version = 2
            provider = [string]$Preferences.provider
            identity_backend = [string]$Preferences.identity_backend
            private_key_policy = [string]$Preferences.private_key_policy
            files = @($manifest)
            private_keys = ($Preferences.private_key_policy -eq "export")
        } |
            ConvertTo-Json -Depth 4) + "`n"
    )

    $validationAlias = @($aliases.Keys | Where-Object { $_ -ne "git-sign" } | Sort-Object | Select-Object -First 1)
    if ($validationAlias.Count -eq 0) { $validationAlias = @("sshwitch-validation") }
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
        if ($lines[$index] -eq $script:LegacyStartMarker) { $startIndexes += $index }
        if ($lines[$index] -eq $script:LegacyEndMarker) { $endIndexes += $index }
    }
    if ($startIndexes.Count -ne $endIndexes.Count -or $startIndexes.Count -gt 1) {
        throw "Malformed legacy Sync-SSH markers in $($Paths.MainConfig); refusing to modify it."
    }
    if ($startIndexes.Count -eq 1) {
        if ($endIndexes[0] -le $startIndexes[0]) {
            throw "Malformed legacy Sync-SSH marker ordering in $($Paths.MainConfig)."
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
    $legacyIncludeCount = @($lines | Where-Object { $_ -eq $script:LegacyIncludeLine }).Count
    if (($includeCount + $legacyIncludeCount) -gt 1) {
        throw "Duplicate SSHwitch or legacy Sync-SSH Include directives found in $($Paths.MainConfig)."
    }
    if ($legacyIncludeCount -eq 1) {
        for ($index = 0; $index -lt $lines.Count; $index++) {
            if ($lines[$index] -eq $script:LegacyIncludeLine) {
                $lines[$index] = $script:IncludeLine
                if ($index -gt 0 -and
                    $lines[$index - 1] -in @("# Added by Sync-SSH", "# Added by Bitwarden SSH Sync")) {
                    $lines[$index - 1] = "# Added by SSHwitch"
                }
                break
            }
        }
    } elseif ($includeCount -eq 0) {
        $lines = @(
            "# Added by SSHwitch",
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
    $replaceBackup = $null
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

    $backup = Join-Path $Paths.StateDir "config.pre-sshwitch"
    if ((Test-Path -LiteralPath $Paths.MainConfig) -and -not (Test-Path -LiteralPath $backup)) {
        Copy-Item -LiteralPath $Paths.MainConfig -Destination $backup
    }
    try {
        if (Test-Path -LiteralPath $Paths.MainConfig) {
            $replaceBackup = Join-Path (
                Split-Path $Paths.MainConfig -Parent
            ) (".sshwitch-config.backup." + [Guid]::NewGuid().ToString("N"))
            [System.IO.File]::Replace(
                $StagedMain,
                $Paths.MainConfig,
                $replaceBackup,
                $true
            )
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
    } finally {
        if ($replaceBackup -and (Test-Path -LiteralPath $replaceBackup)) {
            Remove-Item -LiteralPath $replaceBackup -Force -ErrorAction SilentlyContinue
        }
    }
    if (Test-Path -LiteralPath $previous) {
        Remove-Item -LiteralPath $previous -Recurse -Force
    }
}

function Set-ManagedPermissions {
    param([hashtable]$Paths)
    $currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    & icacls $Paths.ManagedRoot /inheritance:r /grant:r "*S-1-5-18:(OI)(CI)F" "*S-1-5-32-544:(OI)(CI)F" "${currentUser}:(OI)(CI)F" /t | Out-Null
    Assert-LastExitCode "Securing the SSHwitch managed directory"
}

function SSHwitch {
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

    $paths = Get-SSHwitchPaths -OutputDir $OutputDir
    $lock = $null
    $stagingDir = $null
    $stagedMain = $null

    try {
        Ensure-Command ssh
        Ensure-Command ssh-keygen
        Resolve-MainConfigPath -Paths $paths
        $preferences = Get-Preferences -Paths $paths
        $providerAdapter = Join-Path $PSScriptRoot "providers\$($preferences.provider).ps1"
        if (-not (Test-Path -LiteralPath $providerAdapter)) {
            throw "Unsupported provider: $($preferences.provider)"
        }
        . $providerAdapter
        $providerCapabilities = Get-ProviderCapabilities
        Assert-ExactProperties $providerCapabilities @(
            "protocol_version", "provider", "capabilities"
        ) "Provider capability probe"
        Assert-ExactProperties $providerCapabilities.capabilities @(
            "agent", "private_key_export"
        ) "Provider capabilities"
        if ($providerCapabilities.protocol_version -ne 1 -or
            [string]$providerCapabilities.provider -ne $preferences.provider -or
            $providerCapabilities.capabilities.agent -isnot [bool] -or
            $providerCapabilities.capabilities.private_key_export -isnot [bool]) {
            throw "Provider '$($preferences.provider)' returned an invalid capability probe."
        }
        if ($preferences.identity_backend -eq "agent" -and
            -not $providerCapabilities.capabilities.agent) {
            throw "Provider '$($preferences.provider)' does not support the agent identity backend."
        }
        if ($preferences.private_key_policy -eq "export" -and
            -not $providerCapabilities.capabilities.private_key_export) {
            throw "Provider '$($preferences.provider)' does not support private-key export."
        }
        Assert-ProviderRequirements
        if ($preferences.identity_backend -eq "agent") {
            Ensure-Command ssh-add
        }
        $lock = Enter-SyncLock -Paths $paths
        Import-LegacyState -Paths $paths
        Connect-Provider
        $providerEnvelope = Get-ProviderRecords
        Assert-ProviderEnvelope -Envelope $providerEnvelope -Provider $preferences.provider

        [System.IO.Directory]::CreateDirectory($paths.OutputDir) | Out-Null
        [System.IO.Directory]::CreateDirectory($paths.ManagedRoot) | Out-Null
        $stagingDir = Join-Path $paths.ManagedRoot (".staging." + [Guid]::NewGuid().ToString("N"))
        [System.IO.Directory]::CreateDirectory($stagingDir) | Out-Null
        $result = New-GeneratedFiles `
            -Records @($providerEnvelope.records) `
            -Paths $paths `
            -Preferences $preferences `
            -StagingDir $stagingDir

        $stagedMain = Join-Path (Split-Path $paths.MainConfig -Parent) (".sshwitch-config." + [Guid]::NewGuid().ToString("N"))
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
        Write-Host (
            "[OK] Synced $($result.Processed) SSH hosts from $($preferences.provider) " +
            "using the $($preferences.identity_backend) identity backend."
        ) -ForegroundColor Green
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

function Sync-SSH {
    [CmdletBinding()]
    param(
        [string]$OutputDir = "$HOME\.ssh",
        [switch]$DryRun,
        [switch]$Version
    )
    Write-Warning "Sync-SSH is deprecated; use SSHwitch."
    SSHwitch -OutputDir $OutputDir -DryRun:$DryRun -Version:$Version
}

if ($MyInvocation.InvocationName -ne ".") {
    try {
        SSHwitch -DryRun:$SSHwitchDryRun -Version:$SSHwitchVersion
    } catch {
        Write-Host "[ERROR] $($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }
}
