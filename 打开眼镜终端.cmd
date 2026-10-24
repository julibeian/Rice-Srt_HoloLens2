@echo off
"%~dp0runtime\powershell\pwsh.exe" -NoLogo -NoProfile -File "%~dp0Connect-HoloLens.ps1" %*
