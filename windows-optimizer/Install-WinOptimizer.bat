@echo off
:: Creates a Start-menu and Desktop shortcut (with the WinOptimizer logo) that you can pin to the taskbar.
setlocal
set "DIR=%~dp0"
set "DIR=%DIR:~0,-1%"

if not exist "%DIR%\WinOptimizer.ps1" ( echo WinOptimizer.ps1 was not found next to this file. & pause & exit /b 1 )

echo Unblocking downloaded files...
powershell -NoProfile -ExecutionPolicy Bypass -Command "Get-ChildItem -LiteralPath '%DIR%' -File | Unblock-File" >nul 2>&1

echo Creating shortcuts...
powershell -NoProfile -ExecutionPolicy Bypass -Command "$d='%DIR%'; $ps=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'; $ico=Join-Path $d 'WinOptimizer.ico'; $w=New-Object -ComObject WScript.Shell; foreach($loc in @([Environment]::GetFolderPath('Programs'),[Environment]::GetFolderPath('Desktop'))){ $s=$w.CreateShortcut((Join-Path $loc 'WinOptimizer.lnk')); $s.TargetPath=$ps; $s.Arguments=('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"'+(Join-Path $d 'WinOptimizer.ps1')+'\"'); $s.WorkingDirectory=$d; if(Test-Path $ico){$s.IconLocation=$ico}; $s.Description='Safe, reversible Windows RAM/CPU/GPU optimizer'; $s.Save() }; Write-Host 'Created WinOptimizer shortcuts in the Start menu and on the Desktop.'"

echo.
echo Done.
echo To pin it to the taskbar: open the Start menu, type WinOptimizer,
echo right-click it and choose "Pin to taskbar".
echo.
pause
