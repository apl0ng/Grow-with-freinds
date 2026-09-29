#Requires -Version 5.1
<#
.SYNOPSIS
    Runs Grow With Friends (Godot 4.7.2) on Windows.

.DESCRIPTION
    Finds Godot 4.7.2 (GODOT env var, tools\godot\, PATH, the usual install folders, an extracted zip in Downloads),
    downloads the official build into tools\godot\ when nothing is found, imports the project's resources on the
    first run (the GLB models cannot load outside the editor without the .godot\ cache), then starts the game.

    One window (default) opens the main menu: press Host to open the floor, then Enter in the room to start the
    shift. Friends join by IP, or pick your floor from "Floors open nearby" on the same network.

.PARAMETER Players
    Open this many local windows (1..4): one host and the rest joining it, tiled on screen. For co-op testing.
.PARAMETER Fast
    Growth 20x faster and 60-second shifts (testing).
.PARAMETER Mute
    No sound at all (the pause menu also has a saved Sound toggle).
.PARAMETER HostGame
    Host straight away, skipping the menu. (Host is a reserved word in PowerShell, hence the name.)
.PARAMETER Join
    Join this address straight away: an IP, or IP:port.
.PARAMETER Name
    Your worker name (the menu remembers the last one).
.PARAMETER Port
    Game port (default 7777). Friends over the internet need it forwarded (UDP).
.PARAMETER Fullscreen
    Borderless fullscreen (single window only).
.PARAMETER Editor
    Open the Godot editor on the project instead of playing.
.PARAMETER Import
    Re-import resources before playing (after pulling new models).
.PARAMETER GodotPath
    Explicit path to Godot_v4.7.2-stable_win64.exe.
.PARAMETER NoDownload
    Never download Godot; fail if it is not installed.

.EXAMPLE
    .\launch.ps1                          # menu
    .\launch.ps1 -HostGame -Name Dale     # host at once
    .\launch.ps1 -Join 192.168.1.20       # join a friend
    .\launch.ps1 -Players 2 -Fast -Mute   # two silent local windows for testing
    .\launch.ps1 -Editor                  # the Godot editor

.NOTES
    Works in Windows PowerShell 5.1 and PowerShell 7. Double-clicking launch.cmd runs this with the defaults.
#>
[CmdletBinding(DefaultParameterSetName = 'Play')]
param(
    [Parameter(ParameterSetName = 'Play')] [ValidateRange(1, 4)] [int] $Players = 1,
    [Parameter(ParameterSetName = 'Play')] [switch] $Fast,
    [Parameter(ParameterSetName = 'Play')] [switch] $Mute,
    [Parameter(ParameterSetName = 'Play')] [Alias('Serve')] [switch] $HostGame,
    [Parameter(ParameterSetName = 'Play')] [string] $Join = '',
    [Parameter(ParameterSetName = 'Play')] [string] $Name = '',
    [Parameter(ParameterSetName = 'Play')] [ValidateRange(1024, 65535)] [int] $Port = 7777,
    [Parameter(ParameterSetName = 'Play')] [switch] $Fullscreen,
    [Parameter(ParameterSetName = 'Editor')] [switch] $Editor,
    [switch] $Import,
    [string] $GodotPath = '',
    [switch] $NoDownload
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --- constants -------------------------------------------------------------------------------------------------
$script:Version    = '4.7.2-stable'
$script:ExeName    = "Godot_v$($script:Version)_win64.exe"
$script:ProjectDir = $PSScriptRoot
$script:ToolsDir   = Join-Path $script:ProjectDir 'tools\godot'
$script:LocalExe   = Join-Path $script:ToolsDir $script:ExeName
$script:ZipUrl     = "https://github.com/godotengine/godot-builds/releases/download/$($script:Version)/$($script:ExeName).zip"
$script:ImportedDir = Join-Path $script:ProjectDir '.godot\imported'

# --- helpers ---------------------------------------------------------------------------------------------------
function Write-Step {
    param([string] $Text, [ConsoleColor] $Color = 'DarkGray')
    Write-Host "  $Text" -ForegroundColor $Color
}

function Test-ExeFile {
    param([string] $Path)
    return (-not [string]::IsNullOrWhiteSpace($Path)) -and (Test-Path -LiteralPath $Path -PathType Leaf)
}

function Find-Godot {
    <# The first Godot 4.7.2 executable found, or $null. Folders that merely share the exe's name are skipped. #>
    if (Test-ExeFile $GodotPath) { return (Resolve-Path -LiteralPath $GodotPath).Path }
    if (Test-ExeFile $env:GODOT) { return $env:GODOT }
    if (Test-ExeFile $script:LocalExe) { return $script:LocalExe }
    $onPath = Get-Command godot, godot4, Godot -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($onPath) { return $onPath.Source }
    $downloads = Join-Path $env:USERPROFILE 'Downloads'
    $candidates = @(
        (Join-Path $env:ProgramFiles "Godot\$($script:ExeName)"),
        (Join-Path $env:ProgramFiles 'Godot\Godot.exe'),
        (Join-Path $env:LOCALAPPDATA "Programs\Godot\$($script:ExeName)"),
        (Join-Path $env:LOCALAPPDATA "Godot\$($script:ExeName)"),
        (Join-Path $env:USERPROFILE 'scoop\apps\godot\current\godot.exe'),
        (Join-Path $downloads $script:ExeName),
        (Join-Path $downloads "$($script:ExeName)\$($script:ExeName)"),   # zip extracted into a folder named like the exe
        (Join-Path $env:USERPROFILE "Desktop\$($script:ExeName)"),
        (Join-Path $env:USERPROFILE "OneDrive\Desktop\$($script:ExeName)")
    )
    foreach ($candidate in $candidates) { if (Test-ExeFile $candidate) { return $candidate } }
    if (Test-Path $downloads) {
        $found = Get-ChildItem -Path $downloads -Filter 'Godot_v4.7*_win64.exe' -File -Recurse -Depth 2 -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -notlike '*_console.exe' } | Sort-Object Name -Descending | Select-Object -First 1
        if ($found) { return $found.FullName }
    }
    return $null
}

function Install-Godot {
    <# Downloads the official 4.7.2 Windows build into tools\godot\ (asks first when a console is attached). #>
    if ($NoDownload) { throw "Godot $($script:Version) was not found. Install it, set GODOT=<exe>, or pass -GodotPath." }
    Write-Host "Godot $($script:Version) was not found on this machine." -ForegroundColor Yellow
    $answer = ''
    try { $answer = Read-Host 'Download it now from github.com/godotengine (about 60 MB) into tools\godot\ ? [Y/n]' }
    catch { Write-Step 'No console to ask on; downloading.' }
    if ($answer -and $answer.Trim().ToLower().StartsWith('n')) {
        throw 'No Godot executable. Install Godot 4.7.x, set GODOT=<path to exe>, or pass -GodotPath.'
    }
    New-Item -ItemType Directory -Force -Path $script:ToolsDir | Out-Null
    $zip = Join-Path $script:ToolsDir 'godot.zip'
    Write-Step "Downloading $($script:ZipUrl)" 'Cyan'
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -Uri $script:ZipUrl -OutFile $zip -UseBasicParsing
    Expand-Archive -Path $zip -DestinationPath $script:ToolsDir -Force
    Remove-Item $zip -Force
    if (-not (Test-ExeFile $script:LocalExe)) {
        $found = Get-ChildItem $script:ToolsDir -Filter 'Godot_v*win64.exe' -File |
            Where-Object { $_.Name -notlike '*_console.exe' } | Select-Object -First 1
        if (-not $found) { throw "Download finished but no Godot exe was found in $($script:ToolsDir)" }
        Move-Item $found.FullName $script:LocalExe -Force
    }
    Write-Step "Installed $($script:LocalExe)" 'Green'
    return $script:LocalExe
}

function Invoke-ResourceImport {
    <# Builds the .godot\ cache headless (first run, or -Import). #>
    param([string] $Godot)
    Write-Step 'Importing resources (first run; about ten seconds)...' 'Cyan'
    $args = @('--headless', '--path', "`"$($script:ProjectDir)`"", '--import')
    $proc = Start-Process -FilePath $Godot -ArgumentList $args -WorkingDirectory $script:ProjectDir -Wait -PassThru -WindowStyle Hidden
    if (-not (Test-Path $script:ImportedDir)) {
        throw "Resource import failed (exit $($proc.ExitCode)); $($script:ImportedDir) was not created."
    }
    Write-Step "Import done (exit $($proc.ExitCode))." 'Green'
}

function Get-WindowPlacement {
    <# Engine args that tile up to four 960x540 windows so every local instance stays visible. #>
    param([int] $Index)
    $w = 960; $h = 540
    $x = 40 + ($Index % 2) * ($w + 20)
    $y = 60 + [math]::Floor($Index / 2) * ($h + 60)
    return @('--resolution', "$($w)x$($h)", '--position', "$x,$y")
}

function Start-GameInstance {
    <# Launches one game window. $UserArgs go after "--" (the game reads them: --host, --join=IP, --name=, --fast...). #>
    param([string] $Godot, [string[]] $UserArgs, [int] $Index = 0)
    $engineArgs = @('--path', "`"$($script:ProjectDir)`"")
    if ($Fullscreen -and $Players -eq 1) { $engineArgs += '--fullscreen' }
    elseif ($Players -gt 1) { $engineArgs += Get-WindowPlacement -Index $Index }
    $all = $engineArgs
    if ($UserArgs.Count -gt 0) { $all += @('--') + $UserArgs }
    Write-Step ("Launching: " + ($all -join ' '))
    Start-Process -FilePath $Godot -ArgumentList $all -WorkingDirectory $script:ProjectDir | Out-Null
}

# --- main ------------------------------------------------------------------------------------------------------
if (-not (Test-Path (Join-Path $script:ProjectDir 'project.godot'))) {
    throw "project.godot not found next to launch.ps1 ($($script:ProjectDir)). Run this script from the repository root."
}

Write-Host ''
Write-Host 'GROW WITH FRIENDS' -ForegroundColor White
Write-Host "  PowerShell $($PSVersionTable.PSVersion) - $($script:ProjectDir)" -ForegroundColor DarkGray

$godot = Find-Godot
if (-not $godot) { $godot = Install-Godot }
Write-Step "Godot: $godot"

if ($PSCmdlet.ParameterSetName -eq 'Editor') {
    Start-Process -FilePath $godot -ArgumentList @('--editor', '--path', "`"$($script:ProjectDir)`"") -WorkingDirectory $script:ProjectDir | Out-Null
    Write-Step 'Editor opened.' 'Green'
    return
}

if ($Import -or -not (Test-Path $script:ImportedDir)) { Invoke-ResourceImport -Godot $godot }

# Arguments every window gets.
$common = @()
if ($Fast) { $common += '--fast' }
if ($Mute) { $common += '--mute' }
if ($Port -ne 7777) { $common += "--port=$Port" }

if ($Players -gt 1) {
    $baseName = if ($Name) { $Name } else { 'Worker' }
    Start-GameInstance -Godot $godot -UserArgs (@('--host', "--name=${baseName}1") + $common) -Index 0
    Start-Sleep -Seconds 3   # let the host bind its port before the first client knocks
    for ($i = 1; $i -lt $Players; $i++) {
        Start-GameInstance -Godot $godot -UserArgs (@('--join=127.0.0.1', "--name=$baseName$($i + 1)") + $common) -Index $i
        Start-Sleep -Milliseconds 800
    }
    Write-Host ''
    Write-Host "  $Players windows: window 1 hosts, press Enter there to start the shift." -ForegroundColor Green
    return
}

$userArgs = @()
if ($HostGame) { $userArgs += '--host' }
elseif ($Join) {
    $target = $Join
    if ($target -match '^(.+):(\d+)$') { $target = $Matches[1]; $common += "--port=$($Matches[2])" }
    $userArgs += "--join=$target"
}
if ($Name) { $userArgs += "--name=$Name" }
$userArgs += $common
Start-GameInstance -Godot $godot -UserArgs $userArgs

Write-Host ''
Write-Host '  In the menu: Host opens the floor; friends join by IP or from "Floors open nearby".' -ForegroundColor Green
Write-Host '  In the room: Enter starts the shift (host) - WASD move - E use - Q drop - RMB throw - F shove' -ForegroundColor DarkGray
Write-Host '               MMB ping - T chat - V talk - Esc break' -ForegroundColor DarkGray
