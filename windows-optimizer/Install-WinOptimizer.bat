@echo off
:: Creates a Start-menu and Desktop shortcut you can pin to the taskbar.
setlocal
set "DIR=%~dp0"
set "DIR=%DIR:~0,-1%"

echo Unblocking downloaded files...
powershell -NoProfile -ExecutionPolicy Bypass -Command "Get-ChildItem -LiteralPath '%DIR%' -File | Unblock-File" >nul 2>&1

echo Creating shortcuts...
powershell -NoProfile -ExecutionPolicy Bypass -Command "$d='%DIR%'; $exe=Join-Path $d 'WinOptimizer.exe'; $ps1=Join-Path $d 'WinOptimizer.ps1'; $ico=Join-Path $d 'WinOptimizer.ico'; $w=New-Object -ComObject WScript.Shell; foreach($loc in @([Environment]::GetFolderPath('Programs'),[Environment]::GetFolderPath('Desktop'))){ $s=$w.CreateShortcut((Join-Path $loc 'WinOptimizer.lnk')); if(Test-Path $exe){ $s.TargetPath=$exe; $s.IconLocation=$exe } else { $s.TargetPath=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'; $s.Arguments=('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"'+$ps1+'\"'); if(Test-Path $ico){$s.IconLocation=$ico} }; $s.WorkingDirectory=$d; $s.Description='Safe, reversible Windows RAM/CPU/GPU optimizer'; $s.Save() }; Write-Host 'Created WinOptimizer shortcuts in the Start menu and on the Desktop.'"

echo.
echo Done. To pin it: open the Start menu, type WinOptimizer,
echo right-click it and choose "Pin to taskbar".
echo.
pause
