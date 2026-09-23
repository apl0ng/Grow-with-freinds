@echo off
rem Double-click launcher: runs launch.ps1 with any arguments passed through.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0launch.ps1" %*
