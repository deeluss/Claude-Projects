# WinOptimizer

A GUI tool for Windows 10/11 that turns off background features you don't need, to cut RAM use. It also has CPU and GPU latency tweaks. Every change is shown to you before it is applied, and every change can be undone.

## How to run

1. Put `WinOptimizer.ps1` and `Launch-WinOptimizer.bat` in the same folder.
2. Double-click **`Launch-WinOptimizer.bat`** and accept the UAC prompt. The tool needs admin rights to change services and HKLM settings.
3. Tick what you want on each page, click **Review & apply…**, read the preview, then confirm.
4. Restart Windows when it asks.

Run it from your own (administrator) Windows account. If you elevate with a *different* admin account's password, the per-user settings (HKCU) get applied to that account instead of yours.

## Pages

| Page | What it does |
|---|---|
| Dashboard | Live RAM and CPU usage, the active power plan, the top processes by memory, and the RAM change since your last apply |
| Memory / RAM | Telemetry, Widgets, Edge background/Startup Boost, ads and suggestions, Bing in Start, Copilot/Cortana policies, rarely used services, Xbox services, background Store apps, SysMain, the Search indexer, Print Spooler, svchost grouping |
| Startup apps | Lists everything that launches at sign-in. Disabling works the same way as in Task Manager. Windows Security is hidden and is never touched |
| CPU | Ultimate/High Performance plan, foreground priority, MMCSS game scheduling, Game Mode, Power Throttling |
| GPU | Turns off Game DVR background recording, transparency and animations. Also covers hardware-accelerated GPU scheduling and the windowed-game optimizations |
| Backup & Restore | Restores any earlier apply in one click, creates a restore point, and opens System Restore |

## Safety design

- **Curated list only.** The tool does not kill processes, uninstall apps, delete files, or touch drivers/boot services. It refuses to change boot/system-start services.
- **Labelled.** Each item has a **Safe** (green) or **Moderate** (yellow) badge, a plain description, and a *Trade-off* line that says what you lose. Moderate items are never pre-selected.
- **Preview.** Before anything changes, you see every service, registry value, scheduled task and power-plan change, with its *current → new* value.
- **System Restore point.** One is created first. This is on by default, and the tool temporarily lifts Windows' "one per 24 h" limit to do it.
- **JSON backup.** The original value of everything changed is saved to `%ProgramData%\WinOptimizer\Backups\backup-*.json`. **Backup & Restore** puts those values back exactly. The backup file is written even if an apply fails halfway.
- **Services are not deleted.** They are only set to *Manual* (they still start on demand) or *Disabled*.
- **Log** at `%ProgramData%\WinOptimizer\WinOptimizer.log`.

## What to expect (honest numbers)

On a fresh install, most avoidable RAM use comes from startup apps, Widgets (WebView2), Edge Startup Boost/background mode, Store apps running in the background, and telemetry/indexing services. Disabling those usually saves **a few hundred MB to roughly 1–1.5 GB** of RAM in use after a reboot. How much depends heavily on what is installed: OEM utilities, launchers and RGB software are often the biggest wins and appear on the **Startup apps** page.

Things to know:
- "Unused RAM is wasted RAM." Windows fills spare memory with *standby cache*, and it releases that cache instantly when an app needs it. Task Manager counts this cache as *Available*, not *In use*. Any tool that claims to "free" this cache is only making a number look better.
- **Trim RAM now** really does lower the in-use figure, but only for a short time, because pages come back as apps touch them. That is why it is labelled *temporary*.
- The CPU/GPU tweaks mostly make frame times smoother and lower latency. They will **not** add large amounts of average FPS. No tweak can stand in for drivers or hardware.
