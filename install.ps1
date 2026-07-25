$ErrorActionPreference = "Stop"

$version = if ($env:SYNC_SSH_VERSION) { $env:SYNC_SSH_VERSION } else { "v1.0.0" }
$repository = "pablousx/ssh"
$installDir = Join-Path $env:LOCALAPPDATA "sync-ssh"
$installParent = Split-Path $installDir -Parent
$backupDir = Join-Path $installParent ".sync-ssh.previous"
$newInstall = Join-Path $installParent (".sync-ssh.new." + [Guid]::NewGuid().ToString("N"))
$temporaryRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("sync-ssh-" + [Guid]::NewGuid().ToString("N"))

if ((Get-ExecutionPolicy) -eq "Restricted") {
    throw "Execution policy is Restricted. Use RemoteSigned for CurrentUser, then retry."
}

try {
    [System.IO.Directory]::CreateDirectory($temporaryRoot) | Out-Null
    $archiveName = "sync-ssh-$version.zip"
    $releaseUrl = "https://github.com/$repository/releases/download/$version"
    $archivePath = Join-Path $temporaryRoot $archiveName
    $checksumPath = "$archivePath.sha256"

    Write-Host "Downloading Sync-SSH $version..." -ForegroundColor Cyan
    Invoke-WebRequest -Uri "$releaseUrl/$archiveName" -OutFile $archivePath -UseBasicParsing
    Invoke-WebRequest -Uri "$releaseUrl/$archiveName.sha256" -OutFile $checksumPath -UseBasicParsing
    $expected = ((Get-Content -LiteralPath $checksumPath -Raw).Trim() -split "\s+")[0].ToLowerInvariant()
    $actual = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -ne $expected) {
        throw "Release checksum verification failed."
    }

    Expand-Archive -LiteralPath $archivePath -DestinationPath $temporaryRoot -Force
    $packageRoot = Join-Path $temporaryRoot "sync-ssh"
    $setupSource = Join-Path $packageRoot "windows\setup.ps1"
    $syncSource = Join-Path $packageRoot "windows\sync.ps1"
    if (-not (Test-Path -LiteralPath $setupSource) -or -not (Test-Path -LiteralPath $syncSource)) {
        throw "Release archive is missing Windows scripts."
    }

    [System.IO.Directory]::CreateDirectory($newInstall) | Out-Null
    Copy-Item -LiteralPath $setupSource -Destination (Join-Path $newInstall "setup.ps1")
    Copy-Item -LiteralPath $syncSource -Destination (Join-Path $newInstall "sync.ps1")
    [System.IO.File]::WriteAllText(
        (Join-Path $newInstall "VERSION"),
        "$version`n",
        (New-Object System.Text.UTF8Encoding($false))
    )

    if (Test-Path -LiteralPath $backupDir) {
        Remove-Item -LiteralPath $backupDir -Recurse -Force
    }
    if (Test-Path -LiteralPath $installDir) {
        Move-Item -LiteralPath $installDir -Destination $backupDir
    }
    try {
        Move-Item -LiteralPath $newInstall -Destination $installDir
        & (Join-Path $installDir "setup.ps1")
    } catch {
        if (Test-Path -LiteralPath $installDir) {
            Remove-Item -LiteralPath $installDir -Recurse -Force
        }
        if (Test-Path -LiteralPath $backupDir) {
            Move-Item -LiteralPath $backupDir -Destination $installDir
        }
        throw
    }
    if (Test-Path -LiteralPath $backupDir) {
        Remove-Item -LiteralPath $backupDir -Recurse -Force
    }
    Write-Host "Installed Sync-SSH $version." -ForegroundColor Green
} finally {
    if (Test-Path -LiteralPath $temporaryRoot) {
        Remove-Item -LiteralPath $temporaryRoot -Recurse -Force
    }
    if (Test-Path -LiteralPath $newInstall) {
        Remove-Item -LiteralPath $newInstall -Recurse -Force
    }
}
