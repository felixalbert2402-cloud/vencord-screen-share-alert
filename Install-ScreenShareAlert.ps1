# SPDX-License-Identifier: GPL-3.0-or-later
# Windows PowerShell 5.1 or newer. Run as your normal Windows user.
[CmdletBinding()]
param(
    [string] $VencordPath,
    [ValidateSet('stable', 'ptb', 'canary')]
    [string] $Branch = 'stable',
    [string] $DiscordPath,
    [switch] $InstallDependencies,
    [switch] $DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-Checked {
    param([string] $Command, [string[]] $CommandArguments)
    & $Command @CommandArguments
    if ($LASTEXITCODE -ne 0) {
        throw "$Command failed with exit code $LASTEXITCODE. See the output above."
    }
}

function Test-VencordCheckout {
    param([string] $Path)
    $packageFile = Join-Path $Path 'package.json'
    if (-not (Test-Path -LiteralPath $packageFile -PathType Leaf)) { return $false }
    $package = Get-Content -LiteralPath $packageFile -Raw | ConvertFrom-Json
    return $package.name -eq 'vencord' -and (Test-Path -LiteralPath (Join-Path $Path 'scripts\build\build.mjs'))
}

function Stop-SelectedDiscord {
    param([string] $ProcessName)
    $processes = @(Get-Process -Name $ProcessName -ErrorAction SilentlyContinue)
    foreach ($process in $processes) {
        Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
    }
    $deadline = (Get-Date).AddSeconds(10)
    while (@(Get-Process -Name $ProcessName -ErrorAction SilentlyContinue).Count -gt 0) {
        if ((Get-Date) -ge $deadline) { throw "Could not close $ProcessName. Quit it from the system tray, then try again." }
        Start-Sleep -Milliseconds 200
    }
}

function Start-SelectedDiscord {
    param([string] $Path, [string] $ExecutableName)
    $updater = Join-Path $Path 'Update.exe'
    if (Test-Path -LiteralPath $updater -PathType Leaf) {
        Start-Process -FilePath $updater -ArgumentList @('--processStart', $ExecutableName) -WindowStyle Hidden
    } else {
        $app = Get-ChildItem -LiteralPath $Path -Directory |
            Where-Object { $_.Name -like 'app-*' -and (Test-Path -LiteralPath (Join-Path $_.FullName $ExecutableName)) } |
            Sort-Object Name -Descending | Select-Object -First 1
        if (-not $app) { throw "Could not find $ExecutableName to restart Discord." }
        Start-Process -FilePath (Join-Path $app.FullName $ExecutableName) -WindowStyle Hidden
    }
}

$discordStopped = $false
$exitCode = 0
try {
    $manifest = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'manifest.json') -Raw | ConvertFrom-Json
    $sourcePlugin = Join-Path $PSScriptRoot 'screenShareAlert\index.ts'
    if (-not (Test-Path -LiteralPath $sourcePlugin -PathType Leaf)) {
        throw 'Plugin source is missing. Extract the entire ZIP before running the installer.'
    }

    if (-not $VencordPath) {
        $parent = Split-Path -Parent $PSScriptRoot
        if (Test-VencordCheckout $parent) { $VencordPath = $parent }
        else { $VencordPath = Join-Path $PSScriptRoot 'Vencord' }
    }
    $VencordPath = [System.IO.Path]::GetFullPath($VencordPath)

    $discordNames = @{ stable = 'Discord'; ptb = 'DiscordPTB'; canary = 'DiscordCanary' }
    $processName = $discordNames[$Branch]
    $executableName = "$processName.exe"
    if (-not $DiscordPath) { $DiscordPath = Join-Path $env:LOCALAPPDATA $processName }
    $DiscordPath = [System.IO.Path]::GetFullPath($DiscordPath)
    if (-not (Test-Path -LiteralPath $DiscordPath -PathType Container)) {
        throw "Discord $Branch was not found at $DiscordPath. Install Discord first, or use -DiscordPath."
    }
    $apps = @(Get-ChildItem -LiteralPath $DiscordPath -Directory |
        Where-Object { $_.Name -like 'app-*' -and (Test-Path -LiteralPath (Join-Path $_.FullName 'resources\app.asar')) })
    if ($apps.Count -eq 0) { throw "$DiscordPath is not a supported Discord desktop installation." }

    $node = (Get-Command node.exe -ErrorAction Stop).Source
    $nodeVersionText = (& $node --version).Trim().TrimStart('v')
    $nodeVersion = [version] $nodeVersionText
    $cloneNeeded = -not (Test-Path -LiteralPath $VencordPath)
    $dependenciesNeeded = $cloneNeeded -or $InstallDependencies -or
        -not (Test-Path -LiteralPath (Join-Path $VencordPath 'node_modules\esbuild\package.json'))
    if ($nodeVersion.Major -lt 18 -or ($dependenciesNeeded -and $nodeVersion.Major -lt 22)) {
        throw 'Install Node.js 22 or newer from https://nodejs.org, then reopen this launcher. An existing build with installed dependencies can use Node.js 18 or newer.'
    }
    if (-not $cloneNeeded -and -not (Test-VencordCheckout $VencordPath)) {
        throw "$VencordPath already exists but is not a Vencord source checkout. Choose another -VencordPath."
    }
    if ($cloneNeeded) { $git = (Get-Command git.exe -ErrorAction Stop).Source }
    if ($dependenciesNeeded) { $npm = (Get-Command npm.cmd -ErrorAction Stop).Source }

    Write-Host "ScreenShareAlert $($manifest.version)"
    Write-Host "Vencord: $VencordPath"
    Write-Host "Discord: $DiscordPath ($Branch)"
    if ($DryRun) {
        Write-Host "Dry run: clone needed = $cloneNeeded; install dependencies = $dependenciesNeeded."
        Write-Host 'Would back up/copy the plugin, build Vencord, close Discord, inject, and restart Discord.'
        Write-Host 'No files or processes changed.'
        return
    }

    if ($cloneNeeded) {
        Write-Host "Downloading official Vencord source ($($manifest.vencordRef))..."
        Invoke-Checked $git @('clone', '--depth', '1', '--branch', $manifest.vencordRef,
            'https://github.com/Vendicated/Vencord.git', $VencordPath)
        Push-Location -LiteralPath $VencordPath
        try {
            $revision = (& $git rev-parse HEAD).Trim()
            if ($LASTEXITCODE -ne 0 -or $revision -ne $manifest.vencordRevision) {
                throw 'The downloaded Vencord tag does not match the tested revision.'
            }
        } finally { Pop-Location }
    }

    Push-Location -LiteralPath $VencordPath
    try {
        if ($dependenciesNeeded) {
            $package = Get-Content -LiteralPath 'package.json' -Raw | ConvertFrom-Json
            if ($package.packageManager -notmatch '^pnpm@\d+\.\d+\.\d+$') {
                throw 'The Vencord checkout has an unsupported package manager declaration.'
            }
            Write-Host 'Installing build dependencies with the pnpm version specified by Vencord...'
            Invoke-Checked $npm @('exec', '--yes', "--package=$($package.packageManager)", '--',
                'pnpm', 'install', '--frozen-lockfile')
        }

        $targetDirectory = Join-Path $VencordPath 'src\userplugins\screenShareAlert'
        if (Test-Path -LiteralPath $targetDirectory) {
            $backupParent = Join-Path $PSScriptRoot ('plugin-backups\' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
            New-Item -ItemType Directory -Path $backupParent -Force | Out-Null
            Copy-Item -LiteralPath $targetDirectory -Destination (Join-Path $backupParent 'screenShareAlert') -Recurse
            Write-Host "Existing ScreenShareAlert backed up to $backupParent"
        }
        New-Item -ItemType Directory -Path $targetDirectory -Force | Out-Null
        Copy-Item -LiteralPath $sourcePlugin -Destination (Join-Path $targetDirectory 'index.ts') -Force

        Write-Host 'Building Vencord with ScreenShareAlert...'
        Invoke-Checked $node @('scripts\build\build.mjs')
        $injectHelper = Join-Path $PSScriptRoot 'scripts\inject.cjs'
        # Download the official installer before closing Discord, to reduce downtime.
        Invoke-Checked $node @($injectHelper, $VencordPath, $DiscordPath, '--prepare')
        Write-Host 'Closing Discord (this disconnects any active call)...'
        $discordStopped = $true
        Stop-SelectedDiscord $processName
        Write-Host 'Injecting the custom Vencord build...'
        Invoke-Checked $node @($injectHelper, $VencordPath, $DiscordPath)
        Write-Host 'Installation succeeded. Restarting Discord...'
        Start-SelectedDiscord $DiscordPath $executableName
        $discordStopped = $false
        Write-Host 'Enable ScreenShareAlert in Discord: User Settings > Vencord > Plugins.'
        Write-Host 'Keep the Vencord source folder in place: Discord loads this build from it.'
    } finally { Pop-Location }
} catch {
    Write-Host "Installation failed: $($_.Exception.Message)" -ForegroundColor Red
    $exitCode = 1
} finally {
    if ($discordStopped) {
        try {
            Write-Host 'Restarting Discord after the failed installation...'
            Start-SelectedDiscord $DiscordPath $executableName
        } catch {
            Write-Host "Could not restart Discord automatically: $($_.Exception.Message)" -ForegroundColor Red
        }
    }
}
exit $exitCode
