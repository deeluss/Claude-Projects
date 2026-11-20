@echo off
:: WinOptimizer launcher - requests admin rights, then starts the GUI in Windows PowerShell 5.1.
setlocal
set "SCRIPT=%~dp0WinOptimizer.ps1"
if not exist "%SCRIPT%" (
    echo WinOptimizer.ps1 was not found next to this launcher.
    pause
    exit /b 1
)

:: Unblock the file in case it was downloaded from the internet (Mark-of-the-Web).
powershell.exe -NoProfile -Command "Unblock-File -LiteralPath '%SCRIPT%'" >nul 2>&1

net session >nul 2>&1
if %errorlevel% neq 0 (
    powershell.exe -NoProfile -Command "Start-Process powershell.exe -Verb RunAs -ArgumentList '-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File \"%SCRIPT%\"'"
    exit /b
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%SCRIPT%"
