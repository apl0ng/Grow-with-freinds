<#
.SYNOPSIS
    Builds a shareable Windows build of Grow With Friends (export\GrowWithFriends.exe + a zip).

.DESCRIPTION
    Uses the "Windows Desktop" preset in export_presets.cfg. Needs the Godot 4.7.2 export templates
    (about 1 GB once, in %APPDATA%\Godot\export_templates\4.7.2.stable\); with -DownloadTemplates the script fetches
    the official templates archive from github.com/godotengine and installs just the Windows ones.
    Friends run the exe (no Godot needed); one of you hosts, the others join by IP (port 7777 must be reachable).

.EXAMPLE
    .\tools\export.ps1                      # export (asks to download the templates when missing)
    .\tools\export.ps1 -DownloadTemplates   # download the templates without asking, then export
    .\tools\export.ps1 -Debug               # a debug build (console window, verbose errors)
#>
[CmdletBinding()]
param(
    [switch]$DownloadTemplates,
    [switch]$Debug,
    [string]$GodotPath = ""
)

$ErrorActionPreference = "Stop"
$ProjectDir = Split-Path -Parent $PSScriptRoot
if (-not (Test-Path (Join-Path $ProjectDir "project.godot"))) { throw "project.godot not found above tools\ ($ProjectDir)." }
$Version = "4.7.2-stable"
$TemplatesDir = Join-Path $env:APPDATA "Godot\export_templates\4.7.2.stable"
$OutDir = Join-Path $ProjectDir "export"
$OutExe = Join-Path $OutDir "GrowWithFriends.exe"
$Preset = "Windows Desktop"

function Test-Exe([string]$Path) { return ($Path -and (Test-Path -LiteralPath $Path -PathType Leaf)) }

function Find-Godot {
    if (Test-Exe $GodotPath) { return (Resolve-Path -LiteralPath $GodotPath).Path }
    if (Test-Exe $env:GODOT) { return $env:GODOT }
    $exeName = "Godot_v$Version" + "_win64.exe"
    $candidates = @(
        (Join-Path $ProjectDir "tools\godot\$exeName"),
        "$env:USERPROFILE\Downloads\$exeName\$exeName",
        "$env:USERPROFILE\Downloads\$exeName",
        "$env:ProgramFiles\Godot\$exeName",
        "$env:LOCALAPPDATA\Programs\Godot\$exeName"
    )
    foreach ($c in $candidates) { if (Test-Exe $c) { return $c } }
    $cmd = Get-Command godot, godot4, Godot -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) { return $cmd.Source }
    throw "Godot $Version not found. Run .\launch.ps1 once (it downloads Godot), set GODOT=<exe>, or pass -GodotPath."
}

function Install-Templates {
    $needed = @("windows_release_x86_64.exe", "windows_debug_x86_64.exe", "windows_release_x86_64_console.exe", "windows_debug_x86_64_console.exe")
    $missing = $needed | Where-Object { -not (Test-Exe (Join-Path $TemplatesDir $_)) }
    if (-not $missing) { return }
    $url = "https://github.com/godotengine/godot-builds/releases/download/$Version/Godot_v$Version" + "_export_templates.tpz"
    if (-not $DownloadTemplates) {
        Write-Host "The Godot $Version export templates are not installed ($TemplatesDir)."
        $answer = ""
        try { $answer = Read-Host "Download them now from github.com/godotengine (about 1 GB, once)? [y/N]" } catch { }
        if (-not ($answer -and $answer.Trim().ToLower().StartsWith("y"))) {
            throw "No export templates. Re-run with -DownloadTemplates, or install them from the Godot editor (Editor > Manage Export Templates)."
        }
    }
    $tmp = Join-Path $env:TEMP "godot_templates_$Version"
    New-Item -ItemType Directory -Force -Path $tmp | Out-Null
    $tpz = Join-Path $tmp "templates.tpz"
    Write-Host "Downloading $url ..."
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -Uri $url -OutFile $tpz -UseBasicParsing
    $zip = Join-Path $tmp "templates.zip"
    Copy-Item $tpz $zip -Force
    Write-Host "Extracting the Windows templates ..."
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [System.IO.Compression.ZipFile]::OpenRead($zip)
    try {
        New-Item -ItemType Directory -Force -Path $TemplatesDir | Out-Null
        foreach ($entry in $archive.Entries) {
            $leaf = Split-Path $entry.FullName -Leaf
            if ($needed -contains $leaf -or $leaf -eq "version.txt") {
                [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, (Join-Path $TemplatesDir $leaf), $true)
            }
        }
    } finally { $archive.Dispose() }
    Remove-Item $tmp -Recurse -Force
    Write-Host "Templates installed in $TemplatesDir"
}

$godot = Find-Godot
Write-Host "Using Godot: $godot"
Install-Templates
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$mode = if ($Debug) { "--export-debug" } else { "--export-release" }
Write-Host "Exporting ($mode) to $OutExe ..."
$p = Start-Process -FilePath $godot -ArgumentList @("--headless", "--path", "`"$ProjectDir`"", $mode, "`"$Preset`"", "`"$OutExe`"") -WorkingDirectory $ProjectDir -Wait -PassThru -WindowStyle Hidden
if ($p.ExitCode -ne 0 -or -not (Test-Exe $OutExe)) { throw "Export failed (exit $($p.ExitCode)). Run it without -WindowStyle Hidden in the script, or export from the editor, to see the message." }
$zipOut = Join-Path $OutDir "GrowWithFriends-win64.zip"
if (Test-Path $zipOut) { Remove-Item $zipOut -Force }
Compress-Archive -Path (Join-Path $OutDir "GrowWithFriends*.exe") -DestinationPath $zipOut
Write-Host "Done: $OutExe"
Write-Host "Share:  $zipOut  (friends unzip and run; one hosts, the others join by IP on port 7777)"
