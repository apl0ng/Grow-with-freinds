<#
.SYNOPSIS
    Launches Grow With Friends (Godot 4.7.2) on Windows.

.DESCRIPTION
    Finds a Godot 4.7 executable (GODOT env var, tools\godot\, PATH, common install folders, an extracted zip in
    Downloads) or downloads the official 4.7.2 Windows build into tools\godot\ (asks first when a console is
    attached), imports the project's resources on the first run (Godot needs a .godot\ cache before it can load the
    GLB models outside the editor), then runs the project from this folder.

.EXAMPLE
    .\launch.ps1                       # main menu
    .\launch.ps1 -HostGame -Name Alice # host straight away
    .\launch.ps1 -Join 192.168.1.20    # join a friend's game
    .\launch.ps1 -Players 2 -Fast      # two local windows (host + client) with fast growth, for testing
    .\launch.ps1 -Editor               # open the Godot editor on the project
    .\launch.ps1 -Import               # re-import resources (after pulling new models) and then play
#>
[CmdletBinding()]
param(
    [Alias("Serve")][switch]$HostGame, # host a game immediately ($Host is reserved in PowerShell)
    [string]$Join = "",                # join this IP (or ip:port) immediately
    [string]$Name = "",                # player name
    [int]$Port = 7777,
    [switch]$Fast,                     # growth 20x, 60 s shifts (testing)
    [ValidateRange(1, 4)][int]$Players = 1,   # >1 = launch one host + (N-1) clients on this machine
    [switch]$Editor,                   # open the editor instead of playing
    [switch]$Fullscreen,
    [switch]$Import,                   # force a headless resource import before playing
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

function Test-Exe([string]$Path) {
    return ($Path -and (Test-Path -LiteralPath $Path -PathType Leaf))
}

function Find-Godot {
    if (Test-Exe $GodotPath) { return (Resolve-Path -LiteralPath $GodotPath).Path }
    if (Test-Exe $env:GODOT) { return $env:GODOT }
    if (Test-Exe $LocalExe) { return $LocalExe }
    $cmd = Get-Command godot, godot4, Godot -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) { return $cmd.Source }
    $candidates = @(
        "$env:ProgramFiles\Godot\$ExeName",
        "$env:ProgramFiles\Godot\Godot.exe",
        "$env:LOCALAPPDATA\Programs\Godot\$ExeName",
        "$env:LOCALAPPDATA\Godot\$ExeName",
        "$env:USERPROFILE\scoop\apps\godot\current\godot.exe",
        "$env:USERPROFILE\Downloads\$ExeName",
        "$env:USERPROFILE\Downloads\$ExeName\$ExeName",    # zip extracted into a folder named like the exe
        "$env:USERPROFILE\Desktop\$ExeName",
        "$env:USERPROFILE\OneDrive\Desktop\$ExeName"
    )
    foreach ($c in $candidates) { if (Test-Exe $c) { return $c } }
    # Any other 4.7.x editor build lying in Downloads (not the small *_console.exe wrapper).
    $dl = Join-Path $env:USERPROFILE "Downloads"
    if (Test-Path $dl) {
        $found = Get-ChildItem -Path $dl -Filter "Godot_v4.7*_win64.exe" -File -Recurse -Depth 2 -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -notlike "*_console.exe" } | Sort-Object Name -Descending | Select-Object -First 1
        if ($found) { return $found.FullName }
    }
    return $null
}

function Install-Godot {
    $zipUrl = "https://github.com/godotengine/godot-builds/releases/download/$Version/Godot_v$Version" + "_win64.exe.zip"
    Write-Host "Godot $Version was not found on this machine."
    $answer = ""
    try {
        $answer = Read-Host "Download it now from github.com/godotengine (about 60 MB) into tools\godot\ ? [Y/n]"
    } catch {
        # No interactive console (double-click with no terminal, or a script host): download without asking.
        Write-Host "No console to ask on; downloading."
    }
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
    if (-not (Test-Exe $LocalExe)) {
        $found = Get-ChildItem $ToolsDir -Filter "Godot_v*win64.exe" -File | Where-Object { $_.Name -notlike "*_console.exe" } | Select-Object -First 1
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

# First run (or -Import): build the .godot\ cache. Without it the game cannot load its imported GLB models when run
# outside the editor. --import starts the editor headless, imports everything, and quits.
$importedDir = Join-Path $ProjectDir ".godot\imported"
if ($Import -or -not (Test-Path $importedDir)) {
    Write-Host "Importing resources (first run; this takes a minute) ..."
    $p = Start-Process -FilePath $godot -ArgumentList @("--headless", "--path", "`"$ProjectDir`"", "--import") `
        -WorkingDirectory $ProjectDir -Wait -PassThru -WindowStyle Hidden
    if (-not (Test-Path $importedDir)) {
        throw "Resource import failed (exit $($p.ExitCode)); $importedDir was not created."
    }
    Write-Host "Import done (exit $($p.ExitCode))."
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
    # Note: inside @( ... ) the comma binds tighter than +, so the names are built with ${} / $() interpolation.
    Start-Instance (@("--host", "--name=${baseName}1") + $common) 0
    Start-Sleep -Seconds 3
    for ($i = 1; $i -lt $Players; $i++) {
        Start-Instance (@("--join=127.0.0.1", "--name=$baseName$($i + 1)") + $common) $i
        Start-Sleep -Milliseconds 800
    }
    return
}

$userArgs = @()
if ($HostGame) { $userArgs += "--host" }
elseif ($Join) {
    $target = $Join
    if ($target -match "^(.+):(\d+)$") { $target = $Matches[1]; $common += "--port=$($Matches[2])" }
    $userArgs += "--join=$target"
}
if ($Name) { $userArgs += "--name=$Name" }
$userArgs += $common
Start-Instance $userArgs 0
