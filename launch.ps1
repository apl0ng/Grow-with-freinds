<#
.SYNOPSIS
    Launches Grow With Friends (Godot 4.7.2) on Windows.

.DESCRIPTION
    Finds a Godot 4.7 executable (GODOT env var, tools\godot\, PATH, common install folders) or downloads the
    official 4.7.2 Windows build into tools\godot\ (asks first), then runs the project from this folder.

.EXAMPLE
    .\launch.ps1                       # main menu
    .\launch.ps1 -Host -Name Alice     # host straight away
    .\launch.ps1 -Join 192.168.1.20    # join a friend's game
    .\launch.ps1 -Players 2 -Fast      # two local windows (host + client) with fast growth, for testing
    .\launch.ps1 -Editor               # open the Godot editor on the project
#>
[CmdletBinding()]
param(
    [switch]$Host,                     # host a game immediately
    [string]$Join = "",                # join this IP (or ip:port) immediately
    [string]$Name = "",                # player name
    [int]$Port = 7777,
    [switch]$Fast,                     # growth 20x, 60 s shifts (testing)
    [ValidateRange(1, 4)][int]$Players = 1,   # >1 = launch one host + (N-1) clients on this machine
    [switch]$Editor,                   # open the editor instead of playing
    [switch]$Fullscreen,
    [string]$GodotPath = ""            # explicit path to Godot_v4.7.2-stable_win64.exe
)

$ErrorActionPreference = "Stop"
$ProjectDir = $PSScriptRoot
if (-not (Test-Path (Join-Path $ProjectDir "project.godot"))) {
    throw "project.godot not found next to launch.ps1 ($ProjectDir). Run this script from the repository root."
}

$Version   = "4.7.2-stable"
$ExeName   = "Godot_v$Version" + "_win64.exe"
$ToolsDir  = Join-Path $ProjectDir "tools\godot"
$LocalExe  = Join-Path $ToolsDir $ExeName

function Find-Godot {
    if ($GodotPath -and (Test-Path $GodotPath)) { return (Resolve-Path $GodotPath).Path }
    if ($env:GODOT -and (Test-Path $env:GODOT)) { return $env:GODOT }
    if (Test-Path $LocalExe) { return $LocalExe }
    $cmd = Get-Command godot, godot4, Godot -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) { return $cmd.Source }
    $candidates = @(
        "$env:ProgramFiles\Godot\$ExeName",
        "$env:ProgramFiles\Godot\Godot.exe",
        "$env:LOCALAPPDATA\Programs\Godot\$ExeName",
        "$env:LOCALAPPDATA\Godot\$ExeName",
        "$env:USERPROFILE\scoop\apps\godot\current\godot.exe",
        "$env:USERPROFILE\Downloads\$ExeName",
        "$env:USERPROFILE\Desktop\$ExeName"
    )
    foreach ($c in $candidates) { if ($c -and (Test-Path $c)) { return $c } }
    return $null
}

function Install-Godot {
    $zipUrl = "https://github.com/godotengine/godot-builds/releases/download/$Version/Godot_v$Version" + "_win64.exe.zip"
    Write-Host "Godot $Version was not found on this machine."
    $answer = Read-Host "Download it now from github.com/godotengine (about 60 MB) into tools\godot\ ? [Y/n]"
    if ($answer -and $answer.Trim().ToLower().StartsWith("n")) {
        throw "No Godot executable. Install Godot 4.7.x, set GODOT=<path to exe>, or pass -GodotPath."
    }
    New-Item -ItemType Directory -Force -Path $ToolsDir | Out-Null
    $zip = Join-Path $ToolsDir "godot.zip"
    Write-Host "Downloading $zipUrl ..."
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -Uri $zipUrl -OutFile $zip -UseBasicParsing
    Expand-Archive -Path $zip -DestinationPath $ToolsDir -Force
    Remove-Item $zip -Force
    if (-not (Test-Path $LocalExe)) {
        $found = Get-ChildItem $ToolsDir -Filter "Godot_v*win64.exe" | Select-Object -First 1
        if (-not $found) { throw "Download finished but no Godot exe was found in $ToolsDir" }
        Move-Item $found.FullName $LocalExe -Force
    }
    Write-Host "Installed $LocalExe"
    return $LocalExe
}

$godot = Find-Godot
if (-not $godot) { $godot = Install-Godot }
Write-Host "Using Godot: $godot"

if ($Editor) {
    Start-Process -FilePath $godot -ArgumentList @("--editor", "--path", "`"$ProjectDir`"") -WorkingDirectory $ProjectDir
    return
}

function Start-Instance([string[]]$UserArgs, [int]$Index) {
    $engineArgs = @("--path", "`"$ProjectDir`"")
    if ($Fullscreen -and $Players -eq 1) {
        $engineArgs += "--fullscreen"
    } elseif ($Players -gt 1) {
        # Tile small windows so several local instances are visible at once.
        $w = 960; $h = 540
        $x = 40 + ($Index % 2) * ($w + 20)
        $y = 60 + [math]::Floor($Index / 2) * ($h + 60)
        $engineArgs += @("--resolution", "$($w)x$($h)", "--position", "$x,$y")
    }
    $all = $engineArgs
    if ($UserArgs.Count -gt 0) { $all += @("--") + $UserArgs }
    Write-Host ("Launching: " + ($all -join " "))
    Start-Process -FilePath $godot -ArgumentList $all -WorkingDirectory $ProjectDir
}

$common = @()
if ($Fast) { $common += "--fast" }
if ($Port -ne 7777) { $common += "--port=$Port" }

if ($Players -gt 1) {
    $baseName = if ($Name) { $Name } else { "Worker" }
    Start-Instance (@("--host", "--name=$baseName" + "1") + $common) 0
    Start-Sleep -Seconds 3
    for ($i = 1; $i -lt $Players; $i++) {
        Start-Instance (@("--join=127.0.0.1", "--name=$baseName" + ($i + 1)) + $common) $i
        Start-Sleep -Milliseconds 800
    }
    return
}

$userArgs = @()
if ($Host) { $userArgs += "--host" }
elseif ($Join) {
    $target = $Join
    if ($target -match "^(.+):(\d+)$") { $target = $Matches[1]; $common += "--port=$($Matches[2])" }
    $userArgs += "--join=$target"
}
if ($Name) { $userArgs += "--name=$Name" }
$userArgs += $common
Start-Instance $userArgs 0
