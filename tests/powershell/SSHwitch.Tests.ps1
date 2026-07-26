$ErrorActionPreference = "Stop"

Describe "SSHwitch source safety" {
    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
        $script:SyncScript = Join-Path $script:RepoRoot "windows\sync.ps1"
        $openSshPath = Join-Path $env:WINDIR "System32\OpenSSH"
        if (Test-Path -LiteralPath $openSshPath) {
            $env:PATH = "$openSshPath;$env:PATH"
        }
        . $script:SyncScript
        . (Join-Path $script:RepoRoot "windows\providers\bitwarden.ps1")

        function New-TestProviderRecord {
            param(
                [string]$Name,
                [string]$Hostname,
                [string]$Role = "host"
            )
            return [pscustomobject]@{
                source_id     = $Name
                name          = $Name
                role          = $Role
                destination   = [pscustomobject]@{
                    hostname = $Hostname
                    user     = "ubuntu"
                }
                identity      = [pscustomobject]@{
                    public_key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITestFixtureOnly sshwitch-test"
                }
                git_principal = ""
                shared        = $false
            }
        }
    }

    It "writes UTF-8 without a BOM" {
        $path = Join-Path $TestDrive "utf8.txt"
        Write-Utf8NoBom -Path $path -Content "Host test`n"
        $bytes = [System.IO.File]::ReadAllBytes($path)
        if ($bytes.Length -ge 3 -and $bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191) {
            throw "Write-Utf8NoBom emitted a UTF-8 BOM."
        }
    }

    It "rejects control characters in metadata" {
        $threw = $false
        try { Assert-SafeMetadata -Value "example.com`nProxyCommand calc" -Label "HostName" }
        catch { $threw = $true }
        if (-not $threw) { throw "Control-character metadata was accepted." }
    }

    It "rejects aliases that normalize to empty" {
        $threw = $false
        try { ConvertTo-SafeAlias "@@@" }
        catch { $threw = $true }
        if (-not $threw) { throw "An empty normalized alias was accepted." }
    }

    It "normalizes aliases deterministically" {
        $alias = ConvertTo-SafeAlias "Production Server"
        if ($alias -ne "production-server") {
            throw "Unexpected normalized alias: $alias"
        }
    }

    It "accepts only the secret-free provider schema" {
        $record = New-TestProviderRecord -Name "Production Server" -Hostname "example.com"
        $envelope = [pscustomobject]@{
            schema_version = 1
            provider       = "bitwarden"
            records        = @($record)
        }
        Assert-ProviderEnvelope -Envelope $envelope -Provider "bitwarden"

        $record | Add-Member -NotePropertyName private_key -NotePropertyValue "must-not-pass"
        $threw = $false
        try { Assert-ProviderEnvelope -Envelope $envelope -Provider "bitwarden" }
        catch { $threw = $true }
        if (-not $threw) { throw "Provider schema accepted a private-key field." }
    }

    It "reports Bitwarden provider protocol capabilities" {
        $capabilities = Get-ProviderCapabilities
        if ($capabilities.protocol_version -ne 1 -or
            $capabilities.provider -ne "bitwarden" -or
            -not $capabilities.capabilities.agent -or
            -not $capabilities.capabilities.private_key_export) {
            throw "Bitwarden provider capabilities violate protocol version 1."
        }
    }

    It "normalizes Bitwarden items without exposing private keys" {
        function global:bw {
            $global:LASTEXITCODE = 0
            if ($args[0] -eq "sync") { return '{"success":true}' }
            if ($args[0] -eq "list" -and $args[1] -eq "items") {
                return @"
[{"id":"prod-id","type":5,"name":"Production","fields":[{"name":"HostName","value":"example.com"}],"sshKey":{"publicKey":"ssh-ed25519 AAAA-test","privateKey":"PRIVATE-CONFORMANCE-SECRET"}}]
"@
            }
            throw "Unexpected mock bw arguments: $args"
        }
        $envelope = Get-ProviderRecords
        Assert-ProviderEnvelope -Envelope $envelope -Provider "bitwarden"
        $json = $envelope | ConvertTo-Json -Depth 8
        if ($json -match "PRIVATE-CONFORMANCE-SECRET" -or $json -match "private_key") {
            throw "Bitwarden adapter exposed private-key material in canonical records."
        }
    }

    It "maps legacy agent_mode preferences to the provider-neutral model" {
        $preferencesPath = Join-Path $TestDrive "legacy-config.json"
        Write-Utf8NoBom -Path $preferencesPath -Content (
            '{"commit_signing":"skip","keep_alive":"skip","agent_mode":"disk"}'
        )
        $preferences = Get-Preferences -Paths @{ Preferences = $preferencesPath }
        if ($preferences.provider -ne "bitwarden" -or
            $preferences.identity_backend -ne "disk" -or
            $preferences.private_key_policy -ne "export") {
            throw "Legacy preference migration produced unexpected values."
        }
    }

    It "reads preferences from the former Sync-SSH location" {
        $legacyPreferences = Join-Path $TestDrive "sync-ssh-config.json"
        $newPreferences = Join-Path $TestDrive "sshwitch-config.json"
        Write-Utf8NoBom -Path $legacyPreferences -Content (
            '{"version":2,"provider":"bitwarden","identity_backend":"disk",' +
            '"private_key_policy":"export","commit_signing":"skip","keep_alive":"skip"}'
        )
        $preferences = Get-Preferences -Paths @{
            Preferences = $newPreferences
            LegacyPreferences = $legacyPreferences
        }
        if ($preferences.identity_backend -ne "disk" -or
            $preferences.private_key_policy -ne "export") {
            throw "Former Sync-SSH preferences were not imported."
        }
    }

    It "migrates the former Sync-SSH Include without changing manual entries" {
        $mainConfig = Join-Path $TestDrive "ssh-config"
        $stagedMain = Join-Path $TestDrive "ssh-config.staged"
        Write-Utf8NoBom -Path $mainConfig -Content (
            "# Added by Sync-SSH`n" +
            "Include ~/.ssh/sync-ssh/current/config`n`n" +
            "Host manual`n  HostName manual.example`n"
        )
        New-StagedMainConfig -Paths @{ MainConfig = $mainConfig } -Destination $stagedMain
        $content = Get-Content -LiteralPath $stagedMain -Raw
        if ($content -notmatch [regex]::Escape("# Added by SSHwitch") -or
            $content -notmatch [regex]::Escape("Include ~/.ssh/sshwitch/current/config") -or
            $content -notmatch [regex]::Escape("Host manual") -or
            $content -match [regex]::Escape("Include ~/.ssh/sync-ssh/current/config")) {
            throw "Sync-SSH Include migration produced unexpected content."
        }
    }

    It "generates an agent-mode config without a private key" {
        $temporary = Join-Path ([System.IO.Path]::GetTempPath()) ("sshwitch-test-" + [Guid]::NewGuid().ToString("N"))
        try {
            [System.IO.Directory]::CreateDirectory($temporary) | Out-Null
            function global:ssh-keygen { $global:LASTEXITCODE = 0 }
            function global:ssh { $global:LASTEXITCODE = 0 }
            function global:ssh-add {
                $global:LASTEXITCODE = 0
                return "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITestFixtureOnly sshwitch-test"
            }
            $record = New-TestProviderRecord -Name "Production Server" -Hostname "example.com"
            $staging = Join-Path $temporary "agent-stage"
            [System.IO.Directory]::CreateDirectory($staging) | Out-Null
            $preferences = [pscustomobject]@{
                provider = "bitwarden"
                identity_backend = "agent"
                private_key_policy = "never"
                keep_alive = "skip"
            }
            $result = New-GeneratedFiles -Records @($record) -Paths @{} -Preferences $preferences -StagingDir $staging
            if ($result.Processed -ne 1) { throw "Unexpected processed count." }
            if (-not (Test-Path (Join-Path $staging "keys\production-server.pub"))) {
                throw "Public key was not generated."
            }
            if (Test-Path (Join-Path $staging "keys\production-server")) {
                throw "Agent mode persisted a private key."
            }
        } finally {
            Remove-Item -LiteralPath $temporary -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "rejects an agent identity mismatch" {
        $temporary = Join-Path ([System.IO.Path]::GetTempPath()) ("sshwitch-test-" + [Guid]::NewGuid().ToString("N"))
        try {
            [System.IO.Directory]::CreateDirectory($temporary) | Out-Null
            function global:ssh-keygen { $global:LASTEXITCODE = 0 }
            function global:ssh { $global:LASTEXITCODE = 0 }
            function global:ssh-add {
                $global:LASTEXITCODE = 0
                return "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMismatchOnly sshwitch-test"
            }
            $record = New-TestProviderRecord -Name "Production Server" -Hostname "example.com"
            $staging = Join-Path $temporary "mismatch-stage"
            [System.IO.Directory]::CreateDirectory($staging) | Out-Null
            $preferences = [pscustomobject]@{
                provider = "bitwarden"
                identity_backend = "agent"
                private_key_policy = "never"
                keep_alive = "skip"
            }
            $threw = $false
            try {
                New-GeneratedFiles -Records @($record) -Paths @{} -Preferences $preferences -StagingDir $staging | Out-Null
            } catch {
                $threw = $true
            }
            if (-not $threw) { throw "Agent identity mismatch was accepted." }
        } finally {
            Remove-Item -LiteralPath $temporary -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "writes a BOM-free private key only in disk mode" {
        $temporary = Join-Path ([System.IO.Path]::GetTempPath()) ("sshwitch-test-" + [Guid]::NewGuid().ToString("N"))
        try {
            [System.IO.Directory]::CreateDirectory($temporary) | Out-Null
            function global:ssh-keygen { $global:LASTEXITCODE = 0 }
            function global:ssh { $global:LASTEXITCODE = 0 }
            function global:bw {
                $global:LASTEXITCODE = 0
                return @"
{"id":"disk-host","type":5,"name":"disk-host","sshKey":{"publicKey":"test","privateKey":"-----BEGIN OPENSSH PRIVATE KEY-----\ntest-only\n-----END OPENSSH PRIVATE KEY-----"}}
"@
            }
            $record = New-TestProviderRecord -Name "disk-host" -Hostname "example.com"
            $staging = Join-Path $temporary "disk-stage"
            [System.IO.Directory]::CreateDirectory($staging) | Out-Null
            $preferences = [pscustomobject]@{
                provider = "bitwarden"
                identity_backend = "disk"
                private_key_policy = "export"
                keep_alive = "skip"
            }
            New-GeneratedFiles -Records @($record) -Paths @{} -Preferences $preferences -StagingDir $staging | Out-Null
            $privatePath = Join-Path $staging "keys\disk-host"
            if (-not (Test-Path $privatePath)) { throw "Disk mode did not write a private key." }
            $bytes = [System.IO.File]::ReadAllBytes($privatePath)
            if ($bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191) {
                throw "Disk-mode private key contains a UTF-8 BOM."
            }
        } finally {
            Remove-Item -LiteralPath $temporary -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
