# SPDX-License-Identifier: GPL-3.0-or-later
# Portable tools stay beside this launcher; only the current process uses their PATH.
function Get-WindowsArchitecture {
    $architecture = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString().ToLowerInvariant()
    if ($architecture -notin @('x64', 'arm64', 'x86')) { throw "Unsupported Windows architecture: $architecture" }
    return $architecture
}

function Get-UsableNode {
    param([string] $NodePath, [switch] $RequireNpm)
    if (-not $NodePath) { return $null }
    try {
        $versionText = (& $NodePath --version).Trim()
        if ($LASTEXITCODE -ne 0 -or $versionText -notmatch '^v(\d+\.\d+\.\d+)$') { return $null }
        $version = [version] $Matches[1]
        if ($version.Major -lt 22) { return $null }
        $npmPath = Join-Path (Split-Path -Parent $NodePath) 'npm.cmd'
        if ($RequireNpm -and -not (Test-Path -LiteralPath $npmPath -PathType Leaf)) { return $null }
        return [pscustomobject]@{ NodePath = $NodePath; NpmPath = $npmPath; Version = $version }
    } catch { return $null }
}

function Test-UsableGit {
    param([string] $GitPath)
    if (-not $GitPath) { return $false }
    try {
        $version = & $GitPath --version
        return $LASTEXITCODE -eq 0 -and $version -match '^git version '
    } catch { return $false }
}

function Save-VerifiedArchive {
    param([string] $Uri, [string] $Sha256, [string] $DownloadDirectory)
    if ($Sha256 -notmatch '^[a-fA-F0-9]{64}$') { throw 'The download has no valid SHA-256 checksum.' }
    $fileName = [System.IO.Path]::GetFileName(([uri] $Uri).AbsolutePath)
    if ($fileName -notmatch '^[a-zA-Z0-9_.-]+\.zip$') { throw 'Unexpected archive filename.' }
    New-Item -ItemType Directory -Path $DownloadDirectory -Force | Out-Null
    $archive = Join-Path $DownloadDirectory $fileName
    if (Test-Path -LiteralPath $archive -PathType Leaf) {
        if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -eq $Sha256) { return $archive }
    }
    $partial = $archive + '.partial'
    Write-Host "Downloading $fileName..."
    Invoke-WebRequest -Uri $Uri -UseBasicParsing -OutFile $partial -TimeoutSec 180 -Headers @{ 'User-Agent' = 'ScreenShareAlert installer' }
    if ((Get-FileHash -LiteralPath $partial -Algorithm SHA256).Hash -ne $Sha256) {
        Remove-Item -LiteralPath $partial -Force
        throw "Checksum verification failed for $fileName. The archive was not extracted or run."
    }
    Move-Item -LiteralPath $partial -Destination $archive -Force
    return $archive
}

function Install-PortableNode {
    param([string] $ToolRoot, [string] $Architecture)
    $checksums = (Invoke-WebRequest -Uri 'https://nodejs.org/dist/latest-v22.x/SHASUMS256.txt' -UseBasicParsing -TimeoutSec 90).Content
    $pattern = '(?m)^(?<hash>[a-fA-F0-9]{64})\s+(?<file>node-v22\.\d+\.\d+-win-' + [regex]::Escape($Architecture) + '\.zip)\s*$'
    $match = [regex]::Match($checksums, $pattern)
    if (-not $match.Success) { throw "An official Node.js 22 ZIP/checksum for $Architecture could not be found." }
    $fileName = $match.Groups['file'].Value
    $version = [regex]::Match($fileName, '^node-(v22\.\d+\.\d+)-').Groups[1].Value
    $archive = Save-VerifiedArchive -Uri "https://nodejs.org/dist/$version/$fileName" -Sha256 $match.Groups['hash'].Value -DownloadDirectory (Join-Path $ToolRoot 'downloads')
    $nodeRoot = Join-Path $ToolRoot 'node'
    Expand-Archive -LiteralPath $archive -DestinationPath $nodeRoot -Force
    $nodePath = Join-Path (Join-Path $nodeRoot ([System.IO.Path]::GetFileNameWithoutExtension($fileName))) 'node.exe'
    $runtime = Get-UsableNode -NodePath $nodePath -RequireNpm
    if (-not $runtime) { throw 'The downloaded Node.js runtime or its included npm could not be started.' }
    return $runtime
}

function Install-PortableGit {
    param([string] $ToolRoot, [string] $Architecture)
    $release = Invoke-RestMethod -Uri 'https://api.github.com/repos/git-for-windows/git/releases/latest' -TimeoutSec 90 -Headers @{ 'User-Agent' = 'ScreenShareAlert installer' }
    $suffix = switch ($Architecture) { 'x64' { '64-bit' }; 'arm64' { 'arm64' }; 'x86' { '32-bit' } }
    $assets = @($release.assets | Where-Object { $_.name -match ('^MinGit-[\d.]+-' + $suffix + '\.zip$') })
    if ($assets.Count -ne 1) { throw "An official MinGit ZIP for $Architecture could not be found." }
    $asset = $assets[0]
    if ($asset.browser_download_url -notmatch '^https://github\.com/git-for-windows/git/releases/download/') {
        throw 'The Git download does not come from the official Git for Windows repository.'
    }
    $digestProperty = $asset.PSObject.Properties['digest']
    if (-not $digestProperty -or $digestProperty.Value -notmatch '^sha256:([a-fA-F0-9]{64})$') {
        throw 'GitHub did not provide a SHA-256 digest for this Git download.'
    }
    $sha256 = $Matches[1]
    $archive = Save-VerifiedArchive -Uri $asset.browser_download_url -Sha256 $sha256 -DownloadDirectory (Join-Path $ToolRoot 'downloads')
    $gitRoot = Join-Path (Join-Path $ToolRoot 'git') ([System.IO.Path]::GetFileNameWithoutExtension($asset.name))
    Expand-Archive -LiteralPath $archive -DestinationPath $gitRoot -Force
    $gitPath = Join-Path $gitRoot 'cmd\git.exe'
    if (-not (Test-UsableGit $gitPath)) { throw 'The downloaded Git executable could not be started.' }
    return $gitPath
}

function Get-BuildTools {
    param([string] $ToolRoot, [switch] $RequireNpm, [switch] $DryRun)
    $runtime = $null
    $cachedNodeRoot = Join-Path $ToolRoot 'node'
    if (Test-Path -LiteralPath $cachedNodeRoot -PathType Container) {
        foreach ($directory in (Get-ChildItem -LiteralPath $cachedNodeRoot -Directory | Sort-Object Name -Descending)) {
            $runtime = Get-UsableNode -NodePath (Join-Path $directory.FullName 'node.exe') -RequireNpm:$RequireNpm
            if ($runtime) { break }
        }
    }
    if (-not $runtime) {
        $command = Get-Command node.exe -CommandType Application -ErrorAction SilentlyContinue
        if ($command) { $runtime = Get-UsableNode -NodePath $command.Source -RequireNpm:$RequireNpm }
    }

    $gitPath = $null
    $cachedGitRoot = Join-Path $ToolRoot 'git'
    if (Test-Path -LiteralPath $cachedGitRoot -PathType Container) {
        foreach ($directory in (Get-ChildItem -LiteralPath $cachedGitRoot -Directory | Sort-Object Name -Descending)) {
            $candidate = Join-Path $directory.FullName 'cmd\git.exe'
            if (Test-UsableGit $candidate) { $gitPath = $candidate; break }
        }
    }
    if (-not $gitPath) {
        $command = Get-Command git.exe -CommandType Application -ErrorAction SilentlyContinue
        if ($command -and (Test-UsableGit $command.Source)) { $gitPath = $command.Source }
    }
    $downloadNode = -not [bool] $runtime
    $downloadGit = -not [bool] $gitPath
    if (-not $DryRun -and ($downloadNode -or $downloadGit)) {
        # Windows PowerShell 5.1 may otherwise negotiate an obsolete TLS version.
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12
        $architecture = Get-WindowsArchitecture
        if ($downloadNode) {
            Write-Host 'Node.js 22+ (with npm when needed) was not found. Setting up a portable copy...'
            $runtime = Install-PortableNode -ToolRoot $ToolRoot -Architecture $architecture
        }
        if ($downloadGit) {
            Write-Host 'Git was not found. Setting up a portable copy...'
            $gitPath = Install-PortableGit -ToolRoot $ToolRoot -Architecture $architecture
        }
    }
    return [pscustomobject]@{
        NodePath = $(if ($runtime) { $runtime.NodePath } else { $null })
        NpmPath = $(if ($runtime) { $runtime.NpmPath } else { $null })
        GitPath = $gitPath
        DownloadNode = $downloadNode
        DownloadGit = $downloadGit
    }
}
