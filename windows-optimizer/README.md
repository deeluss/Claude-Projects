# WinOptimizer

A GUI tool for Windows 10/11 that turns off background features you don't need, to cut RAM use. It also has CPU and GPU latency tweaks. Every change is shown to you before it is applied, and every change can be undone.

> **Antivirus flags this as a virus — is it safe?** Yes. It's an unsigned tool that automates Windows settings, which heuristics mistake for malware. The code is open and readable, nothing is hidden, and nothing is obfuscated to dodge detection. Full explanation: [Why antivirus flags it](#why-antivirus-flags-it-and-why-thats-expected).

## Made for beginners

Most debloat tools are scripts you run in a black terminal window, firing off dozens of changes at once with names only a power user understands. WinOptimizer is built so someone who has never touched the registry can use it safely:

- **It's a real app, not a command line.** A clean window with clearly labelled pages — no commands to type, no scripts to read first.
- **Plain-English explanations.** Every option says what it does *and* what you give up, in one sentence. No jargon required.
- **Colour-coded risk.** Green **Safe**, amber **Moderate**, red **Advanced** badges tell you at a glance how cautious to be. Safe options are ticked for you; risky ones never are.
- **One button for the nervous.** **Quick optimize** applies only the safe, recommended settings — tick nothing, click once, done.
- **Nothing happens by surprise.** Clicking *Review & apply* shows you the exact list of changes (old value → new value) *before* anything is touched. You can still back out.
- **One-click undo.** Every change is saved to a backup; the **Backup & Restore** page puts things back exactly as they were. A System Restore point is offered too. Removed apps come with a direct link to reinstall them.
- **Familiar numbers.** The dashboard shows RAM and CPU the same way Task Manager does, so you're not learning a new dashboard.
- **Search everywhere.** Long lists have a search box, so you can find "dark mode" or "Copilot" without scrolling.

In short: you can click **Quick optimize** and be done, or explore every toggle knowing each one is explained, labelled by risk, previewed before it runs, and reversible.


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

## Why antivirus flags it (and why that's expected)

**Short version:** WinOptimizer is almost certainly flagged as a *false positive*. Antivirus is reacting to **what kind of program it is**, not to anything malicious inside it. If you don't trust that, don't take my word for it — the entire thing is plain, readable source code you can inspect before running.

### What triggers the flag

A security scanner doesn't "read" a program and decide it's evil. It looks at characteristics and plays the odds. WinOptimizer ticks several boxes that *also* describe real malware:

| Trait | Why WinOptimizer has it | Why malware also has it |
|---|---|---|
| **Unsigned** | A code-signing certificate costs money and ID verification | Malware authors don't buy certificates either |
| **No reputation** | It's a small project very few machines have ever seen | New malware is also "never seen before" |
| **Runs PowerShell** | That's how it changes services, the registry and apps | Script-based droppers do the same |
| **Asks for admin** | It genuinely needs it to change the system | So does anything trying to damage the system |
| **(.exe) unpacks a hidden script** | The .exe bundles the script and runs it quietly | This is the classic "dropper" pattern |

Because of that last point, scanners give it a **generic, pattern-based label** — names like `Wacatac`, `Sabsik`, or `Bearfoos`. These are not "we found known malware"; they're "this *looks like* the kind of thing malware does." They're well known for firing on unsigned, self-built utilities — debloat tools, modding tools, game trainers, and the like.

### What is *not* happening

- **No hidden or obfuscated code.** Everything is readable PowerShell. Obfuscating it to slip past antivirus is exactly what malware does, so it is deliberately **not** done here — even though that means the occasional false positive.
- **No network exfiltration.** It doesn't send your data anywhere. The only outbound actions are optional and obvious (a DNS change you pick, or downloading an app you choose).
- **Nothing irreversible without warning.** Every setting change is previewed, backed up, and reversible from the Backup & Restore page.

### How to run it anyway

- **Use the script, not the .exe.** `WinOptimizer.ps1` is plain text and is far less likely to be quarantined than the bundled `.exe` (which looks like a dropper). Right-click it → *Run with PowerShell*. It's the same app.
- **Or allow the .exe.** Windows Security → *Virus & threat protection* → *Manage settings* → *Exclusions* → add the folder.
- **Help everyone:** if you trust it, report the false positive to Microsoft via the *Windows Defender Security Intelligence → Submit a sample* page. Enough reports retrain the model.

### The only real cure

The flag goes away for good only with a **code-signing certificate** issued to a verified publisher (roughly $200+/year). That's the honest fix, and it's the one thing a free tool can't fake. Everything short of that — including setting the file's "Company" to a name — does **not** make Windows trust it.

## Pages


| Page | What it does |
|---|---|
| Dashboard | Live RAM and CPU usage (same figures as Task Manager), the active power plan, and top processes by memory and CPU. **Double-click a process** to end it now, or pause it (block it from relaunching) for 1h / 6h / 12h / 1d / 3d / 7d / 1 month / permanently. A **Quick optimize** button applies the recommended settings |
| Memory / RAM | Telemetry, Widgets, Edge background/Startup Boost, ads and suggestions, Bing in Start, Copilot/Cortana policies, rarely used services, Xbox services, background Store apps, SysMain, the Search indexer, Print Spooler, svchost grouping |
| Remove bloatware | Uninstalls preinstalled apps that are on a curated list (News, Clipchamp, Solitaire, Candy Crush, Teams, Xbox apps, etc.), plus **Microsoft Edge** and **OneDrive**. Only apps actually found on the PC are shown, and nothing is pre-selected |
| Explorer & UI | Classic right-click menu, show file extensions/hidden files, dark mode, taskbar cleanup (remove Widgets/Chat/Task View, left-align), open Explorer to This PC |
| Privacy & AI | Disable Recall, Copilot and app AI (Paint/Notepad/Edge), advertising ID, activity history, tailored experiences; disable NVIDIA telemetry; block telemetry servers via the hosts file; set DNS to Cloudflare or AdGuard |
| Windows Update | Stop forced restarts, notify-before-download, defer feature updates a year, exclude drivers, or disable auto-updates entirely (advanced) |
| Paused Tasks | Lists apps you paused from the Dashboard and lets you lift the pause early |
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

## New in this version

- **Explorer & UI, Privacy & AI, Windows Update** pages — dozens of reversible registry tweaks (classic context menu, dark mode, disable Recall/Copilot/app-AI, telemetry and update control).
- **Block telemetry servers** (hosts file) and **DNS changer** (Cloudflare / AdGuard), both reversible from Backup & Restore.
- **End task & pause apps**: double-click a process on the Dashboard to stop it, or pause it so it cannot relaunch for a set time (or permanently). Pausing uses Image File Execution Options and an auto-expiry scheduled task; a **Paused Tasks** page lists active pauses and lifts them early. System-critical processes are protected from pausing.
- **Presets**: export your ticked changes to a `.json` file and import it on another PC (buttons on Backup & Restore).

## What to expect (honest numbers)

On a fresh install, most avoidable RAM use comes from startup apps, Widgets (WebView2), Edge Startup Boost/background mode, Store apps running in the background, and telemetry/indexing services. Disabling those usually saves **a few hundred MB to roughly 1–1.5 GB** of RAM in use after a reboot. How much depends heavily on what is installed: OEM utilities, launchers and RGB software are often the biggest wins and appear on the **Startup apps** page.

Things to know:
- "Unused RAM is wasted RAM." Windows fills spare memory with *standby cache*, and it releases that cache instantly when an app needs it. Task Manager counts this cache as *Available*, not *In use*. Any tool that claims to "free" this cache is only making a number look better.
- **Trim RAM now** really does lower the in-use figure, but only for a short time, because pages come back as apps touch them. That is why it is labelled *temporary*.
- The CPU/GPU tweaks mostly make frame times smoother and lower latency. They will **not** add large amounts of average FPS. No tweak can stand in for drivers or hardware.
