#!/usr/bin/env bash
# Builds WinOptimizer.exe (requires the Mono C# compiler: apt-get install mono-mcs mono-devel).
# On Windows you can instead run: csc /target:winexe /resource:..\WinOptimizer.ps1,WinOptimizer.ps1 /r:System.Windows.Forms.dll /out:..\WinOptimizer.exe Launcher.cs
set -euo pipefail
cd "$(dirname "$0")"
mcs -target:winexe -platform:anycpu -optimize+ -sdk:4.5 \
    -resource:../WinOptimizer.ps1,WinOptimizer.ps1 \
    -r:System.Windows.Forms.dll \
    -out:../WinOptimizer.exe Launcher.cs
echo "Built ../WinOptimizer.exe"
