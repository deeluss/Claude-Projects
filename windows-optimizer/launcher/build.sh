#!/usr/bin/env bash
# Builds WinOptimizer.exe (icon + admin manifest + embedded script/icon).
# Needs: apt-get install mono-mcs mono-devel
# On Windows: csc /target:winexe /win32icon:WinOptimizer.ico /resource:WinOptimizer.ps1,WinOptimizer.ps1 /resource:WinOptimizer.ico,WinOptimizer.ico /r:System.Windows.Forms.dll /out:WinOptimizer.exe launcher\Launcher.cs
set -euo pipefail
cd "$(dirname "$0")/.."
mcs -target:winexe -platform:anycpu -optimize+ -sdk:4.5 \
    -win32icon:WinOptimizer.ico \
    -resource:WinOptimizer.ps1,WinOptimizer.ps1 \
    -resource:WinOptimizer.ico,WinOptimizer.ico \
    -r:System.Windows.Forms.dll \
    -out:WinOptimizer.exe launcher/Launcher.cs
echo "Built WinOptimizer.exe"
