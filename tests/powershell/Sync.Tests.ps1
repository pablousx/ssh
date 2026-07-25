$ErrorActionPreference = "Stop"

Describe "Sync-SSH source safety" {
    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
        $script:SyncScript = Join-Path $script:RepoRoot "windows\sync.ps1"
        $openSshPath = Join-Path $env:WINDIR "System32\OpenSSH"
        if (Test-Path -LiteralPath $openSshPath) {
            $env:PATH = "$openSshPath;$env:PATH"
        }
        . $script:SyncScript
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

    It "generates an agent-mode config without a private key" {
        $temporary = Join-Path ([System.IO.Path]::GetTempPath()) ("sync-ssh-test-" + [Guid]::NewGuid().ToString("N"))
        try {
            [System.IO.Directory]::CreateDirectory($temporary) | Out-Null
            function global:ssh-keygen { $global:LASTEXITCODE = 0 }
            function global:ssh { $global:LASTEXITCODE = 0 }
            $item = [pscustomobject]@{
                type = 5
                name = "Production Server"
                fields = @(
                    [pscustomobject]@{ name = "HostName"; value = "example.com" },
                    [pscustomobject]@{ name = "User"; value = "ubuntu" }
                )
                sshKey = [pscustomobject]@{
                    publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITestFixtureOnly sync-ssh-test"
                    privateKey = "-----BEGIN OPENSSH PRIVATE KEY-----`ntest-only`n-----END OPENSSH PRIVATE KEY-----"
                }
                organizationId = $null
            }
            $staging = Join-Path $temporary "agent-stage"
            [System.IO.Directory]::CreateDirectory($staging) | Out-Null
            $preferences = [pscustomobject]@{ agent_mode = "bitwarden"; keep_alive = "skip" }
            $result = New-GeneratedFiles -Items @($item) -Paths @{} -Preferences $preferences -StagingDir $staging
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

    It "writes a BOM-free private key only in disk mode" {
        $temporary = Join-Path ([System.IO.Path]::GetTempPath()) ("sync-ssh-test-" + [Guid]::NewGuid().ToString("N"))
        try {
            [System.IO.Directory]::CreateDirectory($temporary) | Out-Null
            function global:ssh-keygen { $global:LASTEXITCODE = 0 }
            function global:ssh { $global:LASTEXITCODE = 0 }
            $item = [pscustomobject]@{
                type = 5
                name = "disk-host"
                fields = @([pscustomobject]@{ name = "HostName"; value = "example.com" })
                sshKey = [pscustomobject]@{
                    publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITestFixtureOnly sync-ssh-test"
                    privateKey = "-----BEGIN OPENSSH PRIVATE KEY-----`ntest-only`n-----END OPENSSH PRIVATE KEY-----"
                }
                organizationId = $null
            }
            $staging = Join-Path $temporary "disk-stage"
            [System.IO.Directory]::CreateDirectory($staging) | Out-Null
            $preferences = [pscustomobject]@{ agent_mode = "disk"; keep_alive = "skip" }
            New-GeneratedFiles -Items @($item) -Paths @{} -Preferences $preferences -StagingDir $staging | Out-Null
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
