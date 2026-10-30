@echo off
"%~dp0runtime\powershell\pwsh.exe" -NoLogo -NoProfile -File "%~dp0usb-terminal\Connect-HoloLens.ps1" %*
