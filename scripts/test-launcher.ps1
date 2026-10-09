# SPDX-License-Identifier: GPL-3.0-or-later
# Exercises the complete launcher with fake tools/processes and temporary files.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$bundleRoot = Split-Path -Parent $PSScriptRoot
$launcherSource = Get-Content -LiteralPath (Join-Path $bundleRoot 'Install-ScreenShareAlert.ps1') -Raw
# Keep the real script body, but prevent its exit from terminating this test runner.
$launcherSource = $launcherSource.Replace('Set-StrictMode -Version Latest',
    ('$PSScriptRoot = $bundleRoot' + "`nSet-StrictMode -Version Latest"))
$launcherSource = $launcherSource.Replace('exit $exitCode', 'return $exitCode')
$launcher = [scriptblock]::Create($launcherSource)

function Get-Command {
    [CmdletBinding()]
    param([string] $Name)
    switch ($Name) {
        'node.exe' { return [pscustomobject]@{ Source = 'Invoke-FakeNode' } }
        'npm.cmd' { return [pscustomobject]@{ Source = 'Invoke-FakeNpm' } }
        'git.exe' { return [pscustomobject]@{ Source = 'Invoke-FakeGit' } }
        default { throw "Unexpected real tool lookup: $Name" }
    }
}
function Invoke-FakeGit {
    param([Parameter(ValueFromRemainingArguments = $true)] [string[]] $Arguments)
    $global:LASTEXITCODE = 0
    if ($Arguments[0] -eq 'rev-parse') { return 'aa5a764b7ff9cd0d433201dafcc8966e0edbebd7' }
    if ($Arguments[0] -ne 'clone' -or $Arguments -notcontains 'https://github.com/Vendicated/Vencord.git') {
        throw 'Unexpected git operation.'
    }
    $events.Add('clone')
    $clonePath = $Arguments[-1]
    New-Item -ItemType Directory -Path (Join-Path $clonePath 'scripts\build') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $clonePath 'package.json') -Value '{"name":"vencord","packageManager":"pnpm@11.9.0"}'
    Set-Content -LiteralPath (Join-Path $clonePath 'scripts\build\build.mjs') -Value '// fixture'
}
function Invoke-FakeNode {
    param([Parameter(ValueFromRemainingArguments = $true)] [string[]] $Arguments)
    $global:LASTEXITCODE = 0
    if ($Arguments[0] -eq '--version') { return 'v22.0.0' }
    if ($Arguments[0] -eq 'scripts\build\build.mjs') {
        $events.Add('build')
        $global:LASTEXITCODE = $buildResult
    } elseif ($Arguments -contains '--prepare') {
        $events.Add('prepare')
    } else {
        $events.Add('inject')
        $global:LASTEXITCODE = $injectResult
    }
}
function Invoke-FakeNpm {
    param([Parameter(ValueFromRemainingArguments = $true)] [string[]] $Arguments)
    if ($Arguments -notcontains '--frozen-lockfile') { throw 'Dependency install must preserve the lockfile.' }
    $events.Add('dependencies')
    $global:LASTEXITCODE = 0
}
function Get-Process {
    [CmdletBinding()]
    param([string] $Name)
    if ($Name -ne 'Discord') { throw 'Unexpected Discord branch.' }
    if ($script:fakeDiscordRunning) { return [pscustomobject]@{ Id = 123456 } }
}
function Stop-Process {
    [CmdletBinding()]
    param([int] $Id, [switch] $Force)
    if ($Id -ne 123456) { throw 'Attempted to stop an unexpected process.' }
    $events.Add('stop')
    $script:fakeDiscordRunning = $false
}
function Start-Process {
    [CmdletBinding()]
    param([string] $FilePath, [string[]] $ArgumentList, [string] $WindowStyle)
    if ($WindowStyle -ne 'Hidden') { throw 'Launcher helper must start hidden.' }
    $events.Add('start')
}

foreach ($scenario in @('success', 'build-failure', 'inject-failure', 'install-dependencies', 'fresh-install')) {
    $fixture = Join-Path $bundleRoot ('.test-work\' + $scenario)
    $checkout = Join-Path $fixture 'Vencord with spaces'
    $discord = Join-Path $fixture 'Discord with spaces'
    foreach ($directory in @('scripts\build', 'node_modules\esbuild', 'src\userplugins\screenShareAlert')) {
        New-Item -ItemType Directory -Path (Join-Path $checkout $directory) -Force | Out-Null
    }
    Set-Content -LiteralPath (Join-Path $checkout 'package.json') -Value '{"name":"vencord","packageManager":"pnpm@11.9.0"}'
    Set-Content -LiteralPath (Join-Path $checkout 'scripts\build\build.mjs') -Value '// fixture'
    Set-Content -LiteralPath (Join-Path $checkout 'node_modules\esbuild\package.json') -Value '{}'
    Set-Content -LiteralPath (Join-Path $checkout 'src\userplugins\screenShareAlert\index.ts') -Value '// old plugin'
    New-Item -ItemType Directory -Path (Join-Path $discord 'app-1.0.1\resources') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $discord 'app-1.0.1\resources\app.asar') -Value 'fixture'
    Set-Content -LiteralPath (Join-Path $discord 'Update.exe') -Value 'fixture'
    if ($scenario -eq 'fresh-install') { $checkout = Join-Path $fixture ('Downloaded Vencord ' + [DateTime]::UtcNow.Ticks) }
    $events = New-Object 'System.Collections.Generic.List[string]'
    $script:fakeDiscordRunning = $true
    $buildResult = if ($scenario -eq 'build-failure') { 1 } else { 0 }
    $injectResult = if ($scenario -eq 'inject-failure') { 1 } else { 0 }
    $code = & $launcher -VencordPath $checkout -DiscordPath $discord -InstallDependencies:($scenario -eq 'install-dependencies')
    $expected = switch ($scenario) {
        'success' { 'build,prepare,stop,inject,start' }
        'build-failure' { 'build' }
        'inject-failure' { 'build,prepare,stop,inject,start' }
        'install-dependencies' { 'dependencies,build,prepare,stop,inject,start' }
        'fresh-install' { 'clone,dependencies,build,prepare,stop,inject,start' }
    }
    if (($events -join ',') -ne $expected) { throw "${scenario}: expected $expected; got $($events -join ',')" }
    $expectedCode = if ($scenario -like '*failure') { 1 } else { 0 }
    if ($code -ne $expectedCode) { throw "${scenario}: unexpected exit code $code" }
    $copied = Get-Content -LiteralPath (Join-Path $checkout 'src\userplugins\screenShareAlert\index.ts') -Raw
    $original = Get-Content -LiteralPath (Join-Path $bundleRoot 'screenShareAlert\index.ts') -Raw
    if ($copied -ne $original) { throw "${scenario}: plugin source copy failed" }
    Write-Host "PASS: $scenario"
}
