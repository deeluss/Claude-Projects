@echo off
:: Runs WinOptimizer directly. The script asks for admin rights itself.
setlocal
set "DIR=%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -Command "Get-ChildItem -LiteralPath '%DIR%' -File | Unblock-File" >nul 2>&1
start "" powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%DIR%WinOptimizer.ps1"
