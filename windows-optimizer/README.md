# WinOptimizer

A GUI tool for Windows 10/11 that turns off background features you don't need, to cut RAM use. It also has CPU and GPU latency tweaks. Every change is shown to you before it is applied, and every change can be undone.

## How to run

Two ways, depending on what you care about more.

### A) WinOptimizer.exe (one file, pinnable)
Download **`WinOptimizer.exe`** and double-click it. The script and icon are bundled inside; it asks for admin rights itself. To pin it: right-click the .exe (or its Start-menu entry) -> *Pin to taskbar*.

Trade-off: because it is an **unsigned** program that runs PowerShell, Defender/SmartScreen is **likely to flag it** (see below). File -> Properties -> Details shows **Company: deeluss**, but UAC will still say *Unknown publisher* - a verified publisher needs a paid certificate (see *Publisher & signing*).

### B) The script (least likely to be flagged)
Download `WinOptimizer.ps1`, `WinOptimizer.ico`, `Install-WinOptimizer.bat` and `Launch-WinOptimizer.bat` into one folder, then:
- double-click **`Install-WinOptimizer.bat`** to make a pinnable shortcut (with the logo), or
- double-click **`Launch-WinOptimizer.bat`** to run it once.

Either way, accept the **UAC prompt** and run it from your own administrator account.

## Publisher & signing

- The .exe's metadata lists **deeluss** as the Company (visible in Properties -> Details).
- That is **not** the same as a *verified publisher*. The name Windows shows in the UAC prompt and SmartScreen only appears when the file is **code-signed with a certificate issued to that name** by a trusted authority - which costs money and requires identity verification. Without it, UAC says *Unknown publisher* no matter what the metadata says.
- A **self-signed** certificate named "deeluss" would put your name on the signature, but every other PC would still treat it as untrusted (*Unknown publisher*) unless it installs your certificate, and it does **not** stop Defender. So it is cosmetic. If you want that anyway, or you obtain a real certificate, the file can be signed with `signtool` (Windows) or `osslsigncode` (Linux/macOS).

## Why antivirus may warn you

If Defender (or another AV) flags the download, it is almost certainly a **false positive**:

- The detection fires on the *shape* of the file, not on malicious code. An unsigned program that runs PowerShell to change services, the registry and installed apps looks, to a heuristic, exactly like a "dropper". Generic machine-learning verdicts such as `Wacatac`, `Sabsik` or `Bearfoos` are the usual labels, and they have a high false-positive rate on unsigned self-built tools.
- The **.exe is the most likely to be flagged** because it unpacks and runs a hidden script - the textbook dropper pattern. The readable **`.ps1` (option B) is less likely to trip it**. If AV blocks the .exe, use the script.
- There is deliberately **no obfuscation or AV-evasion** here, because disguising a tool that changes system settings is exactly what real malware does. The source is plain text - read it before running.
- If you trust it, report the false positive to Microsoft at the Windows Defender Security Intelligence "Submit a sample" page, or add the file to Defender's exclusions.

## Pages

| Page | What it does |
|---|---|
| Dashboard | Live RAM and CPU usage (same figures as Task Manager), the active power plan, top processes by memory and CPU, and a **Quick optimize** button that applies only the safe, recommended settings |
| Memory / RAM | Telemetry, Widgets, Edge background/Startup Boost, ads and suggestions, Bing in Start, Copilot/Cortana policies, rarely used services, Xbox services, background Store apps, SysMain, the Search indexer, Print Spooler, svchost grouping |
| Remove bloatware | Uninstalls preinstalled apps that are on a curated list (News, Clipchamp, Solitaire, Candy Crush, Teams, Xbox apps, etc.), plus **Microsoft Edge** and **OneDrive**. Only apps actually found on the PC are shown, and nothing is pre-selected |
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
- **It never restarts your PC for you.** After applying, it recommends a restart and leaves it to you.
- **Search.** Each list page has a search box to filter long lists by name.
- **Looks native.** The window uses your Windows accent colour.
- **Log** at `%ProgramData%\WinOptimizer\WinOptimizer.log`.

## Removing bloatware: how it works and its limits

- **Allow-list only.** Only apps in a fixed list can be removed. On top of that, a protected list means the Microsoft Store, App Installer/winget, the VCLibs/.NET/UI.Xaml frameworks, Windows Security, Xbox sign-in, shell components, codecs, Photos, Calculator, Notepad, Terminal and Snipping Tool can never be removed, even if a pattern would match them.
- **Thorough.** Store apps are removed for every user *and* de-provisioned, so Windows doesn't reinstall them for new accounts.
- **Verified.** After removing, the tool lists the installed packages again and reports which apps are really gone and which are still there. It never assumes success.
- **Background work.** Uninstalls run on a background thread, so the window stays responsive.
- **Reinstalling.** An uninstall can't be undone with one click. Removed apps are recorded in the backup, and **Backup & Restore** shows a button for each one that opens its Microsoft Store page (or the Edge/OneDrive download page).
- **Microsoft Edge** (marked *Advanced*):
  - You can only select it if another browser is installed.
  - The **Edge WebView2 Runtime is always kept**, because Widgets, Teams, Outlook and many launchers need it.
  - Microsoft officially allows removing Edge only in the EU/EEA. Elsewhere the tool uses the same workaround other open-source debloat tools use: two temporary markers that it removes again straight after.
  - It also sets the documented Edge Update policy that stops Edge being silently reinstalled.
  - Some Windows builds still refuse the uninstall. When that happens, the tool tells you instead of claiming success.
  - A major Windows feature update can bring Edge back.
- **OneDrive:** files marked "online-only" won't open on the PC after uninstalling. They stay safe in your OneDrive account. Mark the folder *Always keep on this device* first if you need the files offline.

## What to expect (honest numbers)

On a fresh install, most avoidable RAM use comes from startup apps, Widgets (WebView2), Edge Startup Boost/background mode, Store apps running in the background, and telemetry/indexing services. Disabling those usually saves **a few hundred MB to roughly 1–1.5 GB** of RAM in use after a reboot. How much depends heavily on what is installed: OEM utilities, launchers and RGB software are often the biggest wins and appear on the **Startup apps** page.

Things to know:
- "Unused RAM is wasted RAM." Windows fills spare memory with *standby cache*, and it releases that cache instantly when an app needs it. Task Manager counts this cache as *Available*, not *In use*. Any tool that claims to "free" this cache is only making a number look better.
- **Trim RAM now** really does lower the in-use figure, but only for a short time, because pages come back as apps touch them. That is why it is labelled *temporary*.
- The CPU/GPU tweaks mostly make frame times smoother and lower latency. They will **not** add large amounts of average FPS. No tweak can stand in for drivers or hardware.
