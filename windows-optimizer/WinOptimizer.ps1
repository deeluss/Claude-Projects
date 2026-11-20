#Requires -Version 5.1
<#
.SYNOPSIS
    WinOptimizer - a safe, reversible Windows 10/11 RAM / CPU / GPU tuner with a GUI.

.DESCRIPTION
    * Every change comes from a curated catalog (no arbitrary process killing,
      no app uninstalls, no deletion of system components).
    * Before anything is changed you get a preview listing every service,
      registry value, scheduled task and power-plan change, with its current value.
    * A System Restore point is created first (optional, on by default).
    * The original value of everything that is changed is written to a JSON
      backup in %ProgramData%\WinOptimizer\Backups and can be restored from
      the "Backup & Restore" page with one click.

    Run via Launch-WinOptimizer.bat (it handles elevation and execution policy).
#>

# ---------------------------------------------------------------------------
# 0. Elevation / host checks
# ---------------------------------------------------------------------------
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
$isAdmin   = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$isCore    = $PSVersionTable.PSEdition -eq 'Core'
$isSta     = [Threading.Thread]::CurrentThread.GetApartmentState() -eq 'STA'

if (-not $isAdmin -or $isCore -or -not $isSta) {
    # Always run under Windows PowerShell 5.1 (needed for WPF + Checkpoint-Computer), elevated, STA.
    $argList = "-NoProfile -ExecutionPolicy Bypass -STA -File `"$PSCommandPath`""
    try {
        Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList $argList -Verb RunAs | Out-Null
    } catch {
        Write-Host "Administrator rights are required. Aborted." -ForegroundColor Red
    }
    exit
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml

# ---------------------------------------------------------------------------
# 1. Paths, logging
# ---------------------------------------------------------------------------
$AppRoot    = Join-Path $env:ProgramData 'WinOptimizer'
$BackupDir  = Join-Path $AppRoot 'Backups'
$LogFile    = Join-Path $AppRoot 'WinOptimizer.log'
New-Item -ItemType Directory -Force -Path $BackupDir | Out-Null

$script:LogBox = $null
function Write-Log {
    param([string]$Message, [ValidateSet('INFO','OK','WARN','ERR')][string]$Level = 'INFO')
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'HH:mm:ss'), $Level, $Message
    try { Add-Content -Path $LogFile -Value $line -Encoding UTF8 } catch {}
    if ($script:LogBox) {
        $script:LogBox.AppendText($line + [Environment]::NewLine)
        $script:LogBox.ScrollToEnd()
        Invoke-UiRefresh
    }
}

function Invoke-UiRefresh {
    # Lets WPF repaint while long work runs on the UI thread.
    try {
        [System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke(
            [Action]{}, [System.Windows.Threading.DispatcherPriority]::Background)
    } catch {}
}

# ---------------------------------------------------------------------------
# 2. Data model (C# so WPF two-way binding + change notification work)
# ---------------------------------------------------------------------------
if (-not ('WinOpt.Tweak' -as [type])) {
    Add-Type -Language CSharp -TypeDefinition @'
using System.ComponentModel;
namespace WinOpt {
    public class Tweak : INotifyPropertyChanged {
        public event PropertyChangedEventHandler PropertyChanged;
        private void N(string p) { PropertyChangedEventHandler h = PropertyChanged; if (h != null) h(this, new PropertyChangedEventArgs(p)); }

        public string Id { get; set; }
        public string Category { get; set; }
        public string Name { get; set; }
        public string Description { get; set; }
        public string Tradeoff { get; set; }
        public string Risk { get; set; }
        public bool Recommended { get; set; }
        public object Actions { get; set; }

        private bool _sel;
        public bool IsSelected { get { return _sel; } set { _sel = value; N("IsSelected"); } }

        private bool _avail = true;
        public bool IsAvailable { get { return _avail; } set { _avail = value; N("IsAvailable"); } }

        private string _status = "";
        public string Status { get { return _status; } set { _status = value; N("Status"); N("StatusColor"); } }

        public string StatusColor { get {
            if (_status == "Applied") return "#3FB950";
            if (_status == "Not present") return "#6E7681";
            if (_status == "Partially applied") return "#D29922";
            return "#8B949E"; } }

        public string RiskColor { get {
            if (Risk == "Safe") return "#3FB950";
            if (Risk == "Moderate") return "#D29922";
            return "#F85149"; } }

        public string TradeoffText { get { return "Trade-off: " + Tradeoff; } }
    }
}
'@
}

if (-not ('WinOpt.Native' -as [type])) {
    Add-Type -Language CSharp -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace WinOpt {
    public static class Native {
        [DllImport("psapi.dll", SetLastError = true)]
        public static extern bool EmptyWorkingSet(IntPtr hProcess);
    }
}
'@
}

# ---------------------------------------------------------------------------
# 3. Low-level helpers: services, registry, tasks, power plans
# ---------------------------------------------------------------------------
$ServiceRegRoot = 'HKLM:\SYSTEM\CurrentControlSet\Services'

function Get-SvcMode([string]$Name) {
    $key = Join-Path $ServiceRegRoot $Name
    if (-not (Test-Path $key)) { return $null }
    $p = Get-ItemProperty -Path $key -ErrorAction SilentlyContinue
    if ($null -eq $p -or $null -eq $p.Start) { return $null }
    switch ([int]$p.Start) {
        2 { if ($p.DelayedAutostart -eq 1) { 'AutomaticDelayed' } else { 'Automatic' } }
        3 { 'Manual' }
        4 { 'Disabled' }
        default { 'Boot/System' }
    }
}

function Set-SvcMode([string]$Name, [string]$Mode) {
    $scArg = @{ Automatic = 'auto'; AutomaticDelayed = 'delayed-auto'; Manual = 'demand'; Disabled = 'disabled' }[$Mode]
    if (-not $scArg) { throw "Unsupported start mode '$Mode'" }
    $out = & sc.exe config $Name start= $scArg 2>&1
    if ($LASTEXITCODE -ne 0) {
        # Some services refuse sc.exe (ACL); fall back to the registry value Windows reads at boot.
        $startVal = @{ Automatic = 2; AutomaticDelayed = 2; Manual = 3; Disabled = 4 }[$Mode]
        $key = Join-Path $ServiceRegRoot $Name
        Set-ItemProperty -Path $key -Name Start -Value $startVal -Type DWord -ErrorAction Stop
        if ($Mode -eq 'AutomaticDelayed') { Set-ItemProperty -Path $key -Name DelayedAutostart -Value 1 -Type DWord }
        Write-Log "  sc.exe refused ($($out -join ' ')); wrote registry Start=$startVal instead (effective after reboot)" 'WARN'
    }
    if ($Mode -in @('Disabled','Manual')) {
        $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
        if ($svc -and $svc.Status -eq 'Running') {
            try { Stop-Service -Name $Name -Force -ErrorAction Stop; Write-Log "  stopped $Name" }
            catch { Write-Log "  could not stop $Name now (will stop after reboot): $($_.Exception.Message)" 'WARN' }
        }
    }
}

function Get-RegState([string]$Path, [string]$Name) {
    $state = [ordered]@{ Existed = $false; Value = $null; Kind = $null }
    if (Test-Path $Path) {
        $item = Get-Item -Path $Path -ErrorAction SilentlyContinue
        if ($item -and ($item.GetValueNames() -contains $Name)) {
            $state.Existed = $true
            $state.Kind    = $item.GetValueKind($Name).ToString()
            $raw = $item.GetValue($Name, $null, 'DoNotExpandEnvironmentNames')
            if ($raw -is [byte[]]) { $state.Value = @($raw | ForEach-Object { [int]$_ }) } else { $state.Value = $raw }
        }
    }
    return $state
}

function Set-RegValue([string]$Path, [string]$Name, $Value, [string]$Kind) {
    if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
    switch ($Kind) {
        'Binary'      { $Value = [byte[]]@($Value) }
        'DWord'       { $Value = [int]$Value }
        'QWord'       { $Value = [long]$Value }
        'MultiString' { $Value = [string[]]@($Value) }
    }
    New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType $Kind -Force -ErrorAction Stop | Out-Null
}

function Test-RegEquals($State, $Target) {
    if (-not $State.Existed) { return $false }
    if ($Target.Kind -eq 'Binary') { return (@($State.Value) -join ',') -eq (@($Target.Value) -join ',') }
    return "$($State.Value)" -eq "$($Target.Value)"
}

function Get-TaskState([string]$TaskPath, [string]$TaskName) {
    $t = Get-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -ErrorAction SilentlyContinue
    if (-not $t) { return $null }
    return $t.State.ToString()
}

$PowerSchemes = @{
    Ultimate = 'e9a42b02-d5df-448d-aa00-03f14749eb61'
    High     = '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'
    Balanced = '381b4222-f694-41f0-9685-ff5bb260df2e'
}

function Get-ActiveScheme {
    $o = powercfg /getactivescheme 2>$null
    if ("$o" -match '([0-9a-fA-F-]{36})\s*\((.+)\)') { return @{ Guid = $Matches[1]; Name = $Matches[2] } }
    return $null
}

function Get-AllSchemes {
    $list = @()
    foreach ($line in (powercfg /list 2>$null)) {
        if ($line -match '([0-9a-fA-F-]{36})\s*\((.+?)\)') { $list += @{ Guid = $Matches[1]; Name = $Matches[2] } }
    }
    return $list
}

function Enable-PerformanceScheme {
    $schemes = Get-AllSchemes
    # 1) Existing Ultimate Performance copy?
    $ult = $schemes | Where-Object { $_.Name -match 'Ultimate' } | Select-Object -First 1
    if (-not $ult) {
        $out = powercfg -duplicatescheme $PowerSchemes.Ultimate 2>&1
        if ("$out" -match '([0-9a-fA-F-]{36})') { $ult = @{ Guid = $Matches[1]; Name = 'Ultimate Performance' } }
    }
    if ($ult) {
        powercfg /setactive $ult.Guid | Out-Null
        if ($LASTEXITCODE -eq 0) { return "Ultimate Performance ($($ult.Guid))" }
    }
    # 2) High performance (hidden on Modern Standby laptops)
    $hp = $schemes | Where-Object { $_.Guid -eq $PowerSchemes.High } | Select-Object -First 1
    if (-not $hp) {
        $out = powercfg -duplicatescheme $PowerSchemes.High 2>&1
        if ("$out" -match '([0-9a-fA-F-]{36})') { $hp = @{ Guid = $Matches[1] } }
    }
    if ($hp) {
        powercfg /setactive $hp.Guid | Out-Null
        if ($LASTEXITCODE -eq 0) { return "High performance ($($hp.Guid))" }
    }
    throw 'This PC (likely Modern Standby) does not allow High/Ultimate power plans. Use Settings > System > Power > Power mode > Best performance instead.'
}

# ---------------------------------------------------------------------------
# 4. Action engine: describe / test / backup+apply / restore
#    Action types: Service, Reg, Task, PowerPlan
# ---------------------------------------------------------------------------
function Get-ActionDescription($a) {
    switch ($a.Type) {
        'Service' {
            $cur = Get-SvcMode $a.Name
            $disp = (Get-Service -Name $a.Name -ErrorAction SilentlyContinue).DisplayName
            if (-not $cur) { return "Service $($a.Name): not installed - skipped" }
            return "Service '$disp' ($($a.Name)): $cur  ->  $($a.Start)"
        }
        'Reg' {
            $s = Get-RegState $a.Path $a.Name
            $cur = if ($s.Existed) { if ($a.Kind -eq 'Binary') { '(binary) ' + (@($s.Value | Select-Object -First 4) -join ' ') } else { "$($s.Value)" } } else { '(not set)' }
            $new = if ($a.Kind -eq 'Binary') { '(binary) ' + (@($a.Value | Select-Object -First 4) -join ' ') } else { "$($a.Value)" }
            return "Registry $($a.Path)\$($a.Name): $cur  ->  $new"
        }
        'Task' {
            $st = Get-TaskState $a.TaskPath $a.TaskName
            if (-not $st) { return "Task $($a.TaskPath)$($a.TaskName): not present - skipped" }
            return "Scheduled task $($a.TaskPath)$($a.TaskName): $st  ->  Disabled"
        }
        'PowerPlan' {
            $cur = Get-ActiveScheme
            return "Power plan: $($cur.Name)  ->  Ultimate Performance (or High performance if unavailable)"
        }
    }
}

# Returns 'Applied' | 'NotApplied' | 'NotPresent'
function Test-Action($a) {
    switch ($a.Type) {
        'Service' {
            $cur = Get-SvcMode $a.Name
            if (-not $cur) { return 'NotPresent' }
            if ($cur -eq $a.Start) { return 'Applied' }
            if ($a.Start -eq 'Manual' -and $cur -eq 'Disabled') { return 'Applied' }
            return 'NotApplied'
        }
        'Reg' { if (Test-RegEquals (Get-RegState $a.Path $a.Name) $a) { 'Applied' } else { 'NotApplied' } }
        'Task' {
            $st = Get-TaskState $a.TaskPath $a.TaskName
            if (-not $st) { return 'NotPresent' }
            if ($st -eq 'Disabled') { 'Applied' } else { 'NotApplied' }
        }
        'PowerPlan' {
            $cur = Get-ActiveScheme
            if ($cur -and $cur.Name -match 'Ultimate|High performance|Höchstleistung') { 'Applied' } else { 'NotApplied' }
        }
    }
}

function Update-TweakStatus($t) {
    $results = @($t.Actions | ForEach-Object { Test-Action $_ })
    $present = @($results | Where-Object { $_ -ne 'NotPresent' })
    if ($present.Count -eq 0) {
        $t.Status = 'Not present'; $t.IsAvailable = $false; $t.IsSelected = $false; return
    }
    $t.IsAvailable = $true
    $applied = @($present | Where-Object { $_ -eq 'Applied' }).Count
    if ($applied -eq $present.Count) { $t.Status = 'Applied' }
    elseif ($applied -gt 0)          { $t.Status = 'Partially applied' }
    else                             { $t.Status = 'Not applied' }
}

# Captures the original state, then applies. Returns backup entry or $null.
function Invoke-Action($a) {
    switch ($a.Type) {
        'Service' {
            $cur = Get-SvcMode $a.Name
            if (-not $cur) { Write-Log "  skip service $($a.Name) (not installed)"; return $null }
            if ($cur -eq 'Boot/System') { Write-Log "  skip service $($a.Name) (boot/system driver - protected)" 'WARN'; return $null }
            if ($cur -eq $a.Start) { Write-Log "  service $($a.Name) already $cur"; return $null }
            Set-SvcMode $a.Name $a.Start
            Write-Log "  service $($a.Name): $cur -> $($a.Start)" 'OK'
            return [ordered]@{ Type = 'Service'; Name = $a.Name; Previous = $cur }
        }
        'Reg' {
            $s = Get-RegState $a.Path $a.Name
            if (Test-RegEquals $s $a) { Write-Log "  $($a.Path)\$($a.Name) already set"; return $null }
            Set-RegValue $a.Path $a.Name $a.Value $a.Kind
            Write-Log "  reg $($a.Path)\$($a.Name) set" 'OK'
            return [ordered]@{ Type = 'Reg'; Path = $a.Path; Name = $a.Name; Existed = $s.Existed; Value = $s.Value; Kind = $s.Kind }
        }
        'Task' {
            $st = Get-TaskState $a.TaskPath $a.TaskName
            if (-not $st) { Write-Log "  skip task $($a.TaskName) (not present)"; return $null }
            if ($st -eq 'Disabled') { Write-Log "  task $($a.TaskName) already disabled"; return $null }
            Disable-ScheduledTask -TaskPath $a.TaskPath -TaskName $a.TaskName -ErrorAction Stop | Out-Null
            Write-Log "  task $($a.TaskPath)$($a.TaskName) disabled" 'OK'
            return [ordered]@{ Type = 'Task'; TaskPath = $a.TaskPath; TaskName = $a.TaskName }
        }
        'PowerPlan' {
            if ((Test-Action $a) -eq 'Applied') { Write-Log '  performance power plan already active'; return $null }
            $cur = Get-ActiveScheme
            $res = Enable-PerformanceScheme
            Write-Log "  power plan -> $res" 'OK'
            return [ordered]@{ Type = 'PowerPlan'; Previous = $cur.Guid; PreviousName = $cur.Name }
        }
    }
}

function Restore-Entry($e) {
    switch ($e.Type) {
        'Service' {
            if ($e.Previous -in @('Automatic','AutomaticDelayed','Manual','Disabled')) {
                Set-SvcMode $e.Name $e.Previous
                Write-Log "  service $($e.Name) restored to $($e.Previous)" 'OK'
            }
        }
        'Reg' {
            if ($e.Existed) {
                Set-RegValue $e.Path $e.Name $e.Value $e.Kind
                Write-Log "  reg $($e.Path)\$($e.Name) restored" 'OK'
            } else {
                Remove-ItemProperty -Path $e.Path -Name $e.Name -ErrorAction SilentlyContinue
                Write-Log "  reg $($e.Path)\$($e.Name) removed (was not set before)" 'OK'
            }
        }
        'Task' {
            Enable-ScheduledTask -TaskPath $e.TaskPath -TaskName $e.TaskName -ErrorAction Stop | Out-Null
            Write-Log "  task $($e.TaskPath)$($e.TaskName) re-enabled" 'OK'
        }
        'PowerPlan' {
            powercfg /setactive $e.Previous | Out-Null
            Write-Log "  power plan restored to $($e.PreviousName)" 'OK'
        }
    }
}

function New-SafetyRestorePoint {
    $k = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore'
    $prev = Get-RegState $k 'SystemRestorePointCreationFrequency'
    try {
        try { Enable-ComputerRestore -Drive "$env:SystemDrive\" -ErrorAction Stop } catch {}
        # Windows silently skips restore points if one was made in the last 24h; lift that for this one call.
        Set-RegValue $k 'SystemRestorePointCreationFrequency' 0 'DWord'
        Checkpoint-Computer -Description "WinOptimizer - before changes $(Get-Date -Format 'yyyy-MM-dd HH:mm')" -RestorePointType MODIFY_SETTINGS -ErrorAction Stop
        return $true
    } catch {
        Write-Log "Restore point failed: $($_.Exception.Message)" 'ERR'
        return $false
    } finally {
        if ($prev.Existed) { Set-RegValue $k 'SystemRestorePointCreationFrequency' $prev.Value $prev.Kind }
        else { Remove-ItemProperty -Path $k -Name 'SystemRestorePointCreationFrequency' -ErrorAction SilentlyContinue }
    }
}

# ---------------------------------------------------------------------------
# 5. Tweak catalog
# ---------------------------------------------------------------------------
function Svc($n, $s)              { @{ Type = 'Service'; Name = $n; Start = $s } }
function Reg($p, $n, $v, $k='DWord') { @{ Type = 'Reg'; Path = $p; Name = $n; Value = $v; Kind = $k } }
function Tsk($p, $n)              { @{ Type = 'Task'; TaskPath = $p; TaskName = $n } }

function New-Tweak {
    param($Id, $Category, $Name, $Risk, [bool]$Recommended, $Description, $Tradeoff, $Actions)
    $t = New-Object WinOpt.Tweak
    $t.Id = $Id; $t.Category = $Category; $t.Name = $Name; $t.Risk = $Risk
    $t.Recommended = $Recommended; $t.Description = $Description; $t.Tradeoff = $Tradeoff
    $t.Actions = @($Actions)
    return $t
}

function Get-TweakCatalog {
    $totalKB = [int64]((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1KB)

    # Keep any existing global DirectX flags (e.g. Auto HDR / VRR) and only add SwapEffectUpgradeEnable=1.
    $dxPath = 'HKCU:\Software\Microsoft\DirectX\UserGpuPreferences'
    $dxCur  = (Get-RegState $dxPath 'DirectXUserGlobalSettings').Value
    $dxParts = @("$dxCur" -split ';' | Where-Object { $_ -and $_ -notmatch '^SwapEffectUpgradeEnable=' })
    $dxNew  = (($dxParts + 'SwapEffectUpgradeEnable=1') -join ';') + ';'

    $cdm = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'

    @(
    # ------------------------------ MEMORY ------------------------------
    New-Tweak 'telemetry' 'Memory' 'Telemetry & diagnostic data collection' 'Safe' $true `
        'Disables the Connected User Experiences and Telemetry service, the WAP push service and the compatibility-appraiser / CEIP scheduled tasks, which periodically spike CPU, disk and RAM.' `
        'Less diagnostic data is sent to Microsoft. Windows Update, Defender and the Store keep working.' @(
        (Svc 'DiagTrack' 'Disabled'), (Svc 'dmwappushservice' 'Disabled'),
        (Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' 'AllowTelemetry' 0),
        (Tsk '\Microsoft\Windows\Application Experience\' 'Microsoft Compatibility Appraiser'),
        (Tsk '\Microsoft\Windows\Application Experience\' 'ProgramDataUpdater'),
        (Tsk '\Microsoft\Windows\Customer Experience Improvement Program\' 'Consolidator'),
        (Tsk '\Microsoft\Windows\Customer Experience Improvement Program\' 'UsbCeip'),
        (Tsk '\Microsoft\Windows\Feedback\Siuf\' 'DmClient'),
        (Tsk '\Microsoft\Windows\Feedback\Siuf\' 'DmClientOnScenarioDownload'))

    New-Tweak 'widgets' 'Memory' 'Widgets / News and Interests' 'Safe' $true `
        'Turns off the Widgets board. Its WebView2 host processes commonly hold 150-400 MB even when you never open it.' `
        'The Widgets button and board disappear from the taskbar.' @(
        (Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Dsh' 'AllowNewsAndInterests' 0),
        (Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Feeds' 'EnableFeeds' 0))

    New-Tweak 'edge' 'Memory' 'Microsoft Edge Startup Boost & background mode' 'Safe' $true `
        'Stops Edge from pre-loading at sign-in and from staying resident after you close it (often several msedge.exe processes).' `
        'Edge opens ~1 s slower the first time; Edge extensions stop running once Edge is closed. Because this uses a policy, edge://settings will show "Managed by your organization" - that is expected.' @(
        (Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' 'StartupBoostEnabled' 0),
        (Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' 'BackgroundModeEnabled' 0))

    New-Tweak 'suggestions' 'Memory' 'Tips, suggestions & silently installed promo apps' 'Safe' $true `
        'Stops Windows from auto-installing sponsored Store apps and from showing tips/ads in Start, Settings and the lock screen.' `
        'No Windows tips or "suggested" apps. Already-installed promo apps are not removed.' @(
        (Reg $cdm 'SilentInstalledAppsEnabled' 0), (Reg $cdm 'SystemPaneSuggestionsEnabled' 0),
        (Reg $cdm 'SoftLandingEnabled' 0), (Reg $cdm 'SubscribedContent-338388Enabled' 0),
        (Reg $cdm 'SubscribedContent-338389Enabled' 0), (Reg $cdm 'SubscribedContent-353694Enabled' 0),
        (Reg $cdm 'SubscribedContent-353696Enabled' 0),
        (Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableWindowsConsumerFeatures' 1))

    New-Tweak 'websearch' 'Memory' 'Bing web results in Start search' 'Safe' $true `
        'Start menu search returns local results only, so SearchHost does not load web content.' `
        'You can no longer search the web directly from the Start menu.' @(
        (Reg 'HKCU:\Software\Policies\Microsoft\Windows\Explorer' 'DisableSearchBoxSuggestions' 1))

    New-Tweak 'copilot' 'Memory' 'Cortana & legacy Copilot sidebar' 'Safe' $true `
        'Applies the Cortana and Copilot "turn off" policies.' `
        'On recent Windows 11 builds Copilot is a normal app and ignores this policy - uninstall it from Settings > Apps if you do not want it.' @(
        (Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search' 'AllowCortana' 0),
        (Reg 'HKCU:\Software\Policies\Microsoft\Windows\WindowsCopilot' 'TurnOffWindowsCopilot' 1))

    New-Tweak 'rareservices' 'Memory' 'Rarely used services' 'Safe' $true `
        'Fax, Retail Demo, Remote Registry -> Disabled. Downloaded Maps Manager, Geolocation, Phone, Parental Controls, Error Reporting, Program Compatibility Assistant -> Manual (they still start on demand when something needs them).' `
        'Faxing stops working. Offline maps update only when the Maps app is used. Old programs no longer get the automatic "this program might not have installed correctly" prompt.' @(
        (Svc 'Fax' 'Disabled'), (Svc 'RetailDemo' 'Disabled'), (Svc 'RemoteRegistry' 'Disabled'),
        (Svc 'MapsBroker' 'Manual'), (Svc 'lfsvc' 'Manual'), (Svc 'PhoneSvc' 'Manual'),
        (Svc 'WpcMonSvc' 'Manual'), (Svc 'WerSvc' 'Manual'), (Svc 'PcaSvc' 'Manual'))

    New-Tweak 'xbox' 'Memory' 'Xbox services (on demand)' 'Safe' $true `
        'Sets Xbox Live Auth, Game Save, Networking and Accessory services to Manual so they only run when an Xbox app/game asks for them.' `
        'None for most users; Xbox app and Game Pass games start them automatically.' @(
        (Svc 'XblAuthManager' 'Manual'), (Svc 'XblGameSave' 'Manual'),
        (Svc 'XboxNetApiSvc' 'Manual'), (Svc 'XboxGipSvc' 'Manual'))

    New-Tweak 'backgroundapps' 'Memory' 'Store apps running in the background' 'Moderate' $false `
        'Prevents UWP/Store apps (Mail, Phone Link, Photos, Weather, ...) from running when you have not opened them.' `
        'Those apps will not deliver live notifications or update live tiles while closed. Desktop programs (Discord, Steam, etc.) are not affected.' @(
        (Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications' 'GlobalUserDisabled' 1),
        (Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search' 'BackgroundAppGlobalToggle' 0))

    New-Tweak 'sysmain' 'Memory' 'SysMain (Superfetch)' 'Moderate' $false `
        'Stops Windows preloading frequently used apps into RAM. Note: most of what SysMain fills is standby cache that Windows already counts as "Available", so the real benefit is smaller than Task Manager suggests. Mainly useful on PCs with 8 GB or less.' `
        'On a hard disk (HDD) apps will launch noticeably slower. On an SSD the difference is negligible.' @(
        (Svc 'SysMain' 'Disabled'))

    New-Tweak 'search' 'Memory' 'Windows Search indexer' 'Moderate' $false `
        'Disables the indexing service (SearchIndexer.exe), which can use 100-300 MB and disk I/O.' `
        'Start/File Explorer search becomes slow and cannot search inside file contents. Outlook desktop search will stop working. Only choose this if you rarely search.' @(
        (Svc 'WSearch' 'Disabled'))

    New-Tweak 'spooler' 'Memory' 'Print Spooler' 'Moderate' $false `
        'Disables the printing service.' `
        'You cannot print at all - including "Microsoft Print to PDF". Only choose this if you have no printer.' @(
        (Svc 'Spooler' 'Disabled'))

    New-Tweak 'svchost' 'Memory' 'Group svchost processes' 'Moderate' $false `
        "On PCs with >3.5 GB RAM Windows runs almost every service in its own svchost.exe (often 70-100 processes). Raising the split threshold to your RAM size ($([math]::Round($totalKB/1MB,1)) GB) groups them back together, cutting process count and some per-process overhead. Requires reboot." `
        'If one grouped service crashes it can take the others in its group down with it, and Task Manager shows less detail per service.' @(
        (Reg 'HKLM:\SYSTEM\CurrentControlSet\Control' 'SvcHostSplitThresholdInKB' ([int]$totalKB)))

    # ------------------------------ CPU ------------------------------
    New-Tweak 'powerplan' 'CPU' 'Ultimate / High Performance power plan' 'Moderate' $false `
        'Activates the Ultimate Performance plan (falls back to High performance). Keeps CPU clocks higher and disables core parking, reducing latency spikes.' `
        'Higher idle power draw and temperatures; noticeably shorter battery life on laptops. Not available on some Modern Standby laptops.' @(
        @{ Type = 'PowerPlan' })

    New-Tweak 'foreground' 'CPU' 'Prioritize the foreground app' 'Safe' $true `
        'Sets Win32PrioritySeparation to 0x26 (short, variable quanta with maximum foreground boost) so the window you are using gets CPU time first.' `
        'Background work (downloads unpacking, renders) can take slightly longer while you use another app.' @(
        (Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\PriorityControl' 'Win32PrioritySeparation' 38))

    New-Tweak 'mmcss' 'CPU' 'Multimedia / game scheduling (MMCSS)' 'Safe' $true `
        'Reserves less CPU for low-priority background tasks (SystemResponsiveness 20 -> 10) and raises the CPU/GPU priority of tasks registered as games.' `
        'Effect is small; background tasks get slightly less CPU while a game or audio app is active.' @(
        (Reg 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile' 'SystemResponsiveness' 10),
        (Reg 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games' 'GPU Priority' 8),
        (Reg 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games' 'Priority' 6),
        (Reg 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games' 'Scheduling Category' 'High' 'String'),
        (Reg 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games' 'SFIO Priority' 'High' 'String'))

    New-Tweak 'gamemode' 'CPU' 'Game Mode' 'Safe' $true `
        'Ensures Windows Game Mode is on: while a game runs, Windows Update installs and driver installs are deferred and the game gets scheduling priority.' `
        'None in practice.' @(
        (Reg 'HKCU:\Software\Microsoft\GameBar' 'AutoGameModeEnabled' 1),
        (Reg 'HKCU:\Software\Microsoft\GameBar' 'AllowAutoGameMode' 1))

    New-Tweak 'throttling' 'CPU' 'Disable Power Throttling (EcoQoS)' 'Moderate' $false `
        'Stops Windows from forcing background processes onto efficiency cores / low clocks. Helps when a background app (stream, encoder, Discord) stutters.' `
        'Higher power use and heat; worse battery life on laptops.' @(
        (Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\PowerThrottling' 'PowerThrottlingOff' 1))

    # ------------------------------ GPU ------------------------------
    New-Tweak 'gamedvr' 'GPU' 'Disable Game DVR background recording' 'Safe' $true `
        'Stops Xbox Game Bar from continuously capturing gameplay in the background, which costs GPU encoder time, VRAM and RAM.' `
        'Win+Alt+R / "Record that" and Game Bar clips stop working. Game Bar itself (widgets, performance overlay) still opens.' @(
        (Reg 'HKCU:\System\GameConfigStore' 'GameDVR_Enabled' 0),
        (Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR' 'AppCaptureEnabled' 0),
        (Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR' 'AllowGameDVR' 0))

    New-Tweak 'transparency' 'GPU' 'Disable transparency effects' 'Safe' $true `
        'Makes the taskbar, Start and Settings solid instead of acrylic/mica blur, reducing Desktop Window Manager (dwm.exe) GPU work.' `
        'Purely visual: no blur/translucency.' @(
        (Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' 'EnableTransparency' 0))

    New-Tweak 'animations' 'GPU' 'Reduce window & taskbar animations' 'Safe' $false `
        'Turns off minimize/maximize and taskbar animations. Makes the UI feel snappier on weaker GPUs. Takes effect after signing out.' `
        'Purely visual: windows snap instead of animating.' @(
        (Reg 'HKCU:\Control Panel\Desktop\WindowMetrics' 'MinAnimate' '0' 'String'),
        (Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'TaskbarAnimations' 0),
        (Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects' 'VisualFXSetting' 3))

    New-Tweak 'hags' 'GPU' 'Hardware-accelerated GPU scheduling' 'Moderate' $false `
        'Lets the GPU manage its own memory scheduling, reducing CPU overhead and latency. Required for DLSS Frame Generation. Needs a supported GPU (NVIDIA GTX 10-series+, AMD RX 5000+, Intel Arc) and a reboot.' `
        'A minority of games, VR setups and capture tools stutter with it on - if you notice that, restore this change.' @(
        (Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' 'HwSchMode' 2))

    New-Tweak 'windowedopt' 'GPU' 'Optimizations for windowed games' 'Moderate' $false `
        'Windows 11 feature that upgrades DirectX 10/11 games running windowed/borderless to the modern flip presentation model: lower latency and VRR support, close to exclusive fullscreen. Your other DirectX settings (Auto HDR etc.) are preserved.' `
        'A few older games may show overlay or capture glitches; restore if so.' @(
        (Reg $dxPath 'DirectXUserGlobalSettings' $dxNew 'String'))
    )
}

# ---------------------------------------------------------------------------
# 6. Startup apps (disabled the same way Task Manager does it - fully reversible)
# ---------------------------------------------------------------------------
$ProtectedStartup = 'SecurityHealth|WindowsDefender|MSASCui|ctfmon'
$DriverLike       = 'Realtek|RtkAud|Nahimic|Waves|MaxxAudio|Synaptics|ELAN|Precision|igfx|Intel|AMD|Radeon|NVIDIA|nv|Logitech|Razer|Corsair|SteelSeries|Dolby|Bluetooth|OneDrive|Tablet|Pen|Touch'

function Get-StartupTweaks {
    $sources = @(
        @{ Run = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run';             Approved = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run';   Scope = 'Current user' },
        @{ Run = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run';             Approved = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run';   Scope = 'All users' },
        @{ Run = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'; Approved = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run32'; Scope = 'All users (32-bit)' }
    )
    $items = @()
    foreach ($s in $sources) {
        if (-not (Test-Path $s.Run)) { continue }
        $key = Get-Item $s.Run
        foreach ($n in $key.GetValueNames()) {
            if (-not $n) { continue }
            $cmd = "$($key.GetValue($n))"
            $items += @{ Name = $n; Command = $cmd; Approved = $s.Approved; Scope = $s.Scope }
        }
    }
    $folders = @(
        @{ Path = [Environment]::GetFolderPath('Startup');       Approved = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder'; Scope = 'Current user (Startup folder)' },
        @{ Path = [Environment]::GetFolderPath('CommonStartup'); Approved = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder'; Scope = 'All users (Startup folder)' }
    )
    foreach ($f in $folders) {
        if (-not $f.Path -or -not (Test-Path $f.Path)) { continue }
        Get-ChildItem -Path $f.Path -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'desktop.ini' } | ForEach-Object {
            $items += @{ Name = $_.Name; Command = $_.FullName; Approved = $f.Approved; Scope = $f.Scope }
        }
    }

    $disabledBytes = @(3,0,0,0,0,0,0,0,0,0,0,0)
    foreach ($i in $items) {
        if ($i.Name -match $ProtectedStartup) { continue }
        $risk = if ("$($i.Name) $($i.Command)" -match $DriverLike) { 'Moderate' } else { 'Safe' }
        $trade = if ($risk -eq 'Moderate') {
            'Looks like a driver/hardware or sync utility. Disabling may stop features such as audio-jack detection, touchpad gestures, RGB/macros or OneDrive sync until you start it manually.'
        } else {
            'The program no longer starts at sign-in; you can still open it normally.'
        }
        $t = New-Tweak ("startup:" + $i.Approved + '|' + $i.Name) 'Startup' $i.Name $risk $false `
            ("[$($i.Scope)]  $($i.Command)") $trade @(
            (Reg $i.Approved $i.Name $disabledBytes 'Binary'))
        # Treat "odd first byte" as disabled (same convention as Task Manager).
        $st = Get-RegState $i.Approved $i.Name
        $isDisabled = $st.Existed -and $st.Kind -eq 'Binary' -and ((@($st.Value)[0] % 2) -eq 1)
        if ($isDisabled) { $t.Status = 'Already disabled'; $t.IsAvailable = $false }
        else             { $t.Status = 'Runs at sign-in' }
        $t
    }
}

# ---------------------------------------------------------------------------
# 7. System stats
# ---------------------------------------------------------------------------
function Get-MemStats {
    $os = Get-CimInstance Win32_OperatingSystem
    $totalMB = [math]::Round($os.TotalVisibleMemorySize / 1KB)
    $freeMB  = [math]::Round($os.FreePhysicalMemory / 1KB)
    @{ TotalMB = $totalMB; UsedMB = $totalMB - $freeMB; FreeMB = $freeMB; Pct = [math]::Round((($totalMB - $freeMB) / $totalMB) * 100, 1) }
}

function Get-CpuLoad {
    $v = (Get-CimInstance Win32_Processor | Measure-Object -Property LoadPercentage -Average).Average
    if ($null -eq $v) { 0 } else { [math]::Round($v) }
}

function Get-TopProcesses {
    Get-Process | Group-Object ProcessName | ForEach-Object {
        [pscustomobject]@{
            Name  = $_.Name
            Count = $_.Count
            MB    = [math]::Round((($_.Group | Measure-Object WorkingSet64 -Sum).Sum) / 1MB)
        }
    } | Sort-Object MB -Descending | Select-Object -First 15
}

function Invoke-TrimWorkingSets {
    $n = 0
    foreach ($p in Get-Process) {
        try { if ([WinOpt.Native]::EmptyWorkingSet($p.Handle)) { $n++ } } catch {}
    }
    return $n
}

# ---------------------------------------------------------------------------
# 8. UI (WPF)
# ---------------------------------------------------------------------------
[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="WinOptimizer" Width="1180" Height="760" MinWidth="980" MinHeight="620"
        WindowStartupLocation="CenterScreen" Background="#0D1117" FontFamily="Segoe UI" FontSize="13"
        Foreground="#E6EDF3">
  <Window.Resources>
    <Style TargetType="GridViewColumnHeader">
      <Setter Property="Background" Value="#161B22"/>
      <Setter Property="Foreground" Value="#8B949E"/>
      <Setter Property="BorderBrush" Value="#30363D"/>
      <Setter Property="HorizontalContentAlignment" Value="Left"/>
      <Setter Property="Padding" Value="6,4"/>
    </Style>

    <Style x:Key="Btn" TargetType="Button">
      <Setter Property="Foreground" Value="#E6EDF3"/>
      <Setter Property="Background" Value="#21262D"/>
      <Setter Property="BorderBrush" Value="#30363D"/>
      <Setter Property="Padding" Value="14,7"/>
      <Setter Property="Margin" Value="0,0,8,0"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="b" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="1" CornerRadius="6" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Opacity" Value="0.85"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter TargetName="b" Property="Opacity" Value="0.4"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="PrimaryBtn" TargetType="Button" BasedOn="{StaticResource Btn}">
      <Setter Property="Background" Value="#238636"/>
      <Setter Property="BorderBrush" Value="#2EA043"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
    </Style>

    <Style TargetType="CheckBox">
      <Setter Property="Foreground" Value="#E6EDF3"/>
      <Setter Property="VerticalAlignment" Value="Top"/>
    </Style>

    <Style TargetType="TabItem">
      <Setter Property="Foreground" Value="#8B949E"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TabItem">
            <Border x:Name="bd" Background="Transparent" CornerRadius="6" Padding="14,10" Margin="8,2">
              <ContentPresenter ContentSource="Header" />
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsSelected" Value="True">
                <Setter TargetName="bd" Property="Background" Value="#1F2937"/>
                <Setter Property="Foreground" Value="#E6EDF3"/>
              </Trigger>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter Property="Foreground" Value="#E6EDF3"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <DataTemplate x:Key="TweakTemplate">
      <Border Background="#161B22" BorderBrush="#30363D" BorderThickness="1" CornerRadius="8" Padding="14,12" Margin="0,0,0,8">
        <Grid>
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/>
          </Grid.ColumnDefinitions>
          <CheckBox IsChecked="{Binding IsSelected, Mode=TwoWay, UpdateSourceTrigger=PropertyChanged}"
                    IsEnabled="{Binding IsAvailable}" Margin="0,3,14,0"/>
          <StackPanel Grid.Column="1">
            <TextBlock Text="{Binding Name}" FontSize="14" FontWeight="SemiBold" Foreground="#E6EDF3" TextTrimming="CharacterEllipsis"/>
            <TextBlock Text="{Binding Description}" TextWrapping="Wrap" Foreground="#8B949E" Margin="0,4,0,0"/>
            <TextBlock Text="{Binding TradeoffText}" TextWrapping="Wrap" Foreground="#D2A8FF" Margin="0,4,0,0" FontSize="12"/>
          </StackPanel>
          <StackPanel Grid.Column="2" Margin="14,0,0,0" MinWidth="110">
            <Border Background="{Binding RiskColor}" CornerRadius="9" Padding="9,2" HorizontalAlignment="Right">
              <TextBlock Text="{Binding Risk}" Foreground="#0D1117" FontWeight="Bold" FontSize="11"/>
            </Border>
            <TextBlock Text="{Binding Status}" Foreground="{Binding StatusColor}" FontSize="11" Margin="0,6,0,0" HorizontalAlignment="Right"/>
          </StackPanel>
        </Grid>
      </Border>
    </DataTemplate>
  </Window.Resources>

  <Grid>
    <Grid.RowDefinitions>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>

    <TabControl x:Name="Tabs" TabStripPlacement="Left" Background="#0D1117" BorderThickness="0" Padding="0">
      <TabControl.Template>
        <ControlTemplate TargetType="TabControl">
          <Grid>
            <Grid.ColumnDefinitions><ColumnDefinition Width="230"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
            <Border Background="#161B22" BorderBrush="#30363D" BorderThickness="0,0,1,0">
              <DockPanel>
                <StackPanel DockPanel.Dock="Top" Margin="22,22,10,18">
                  <TextBlock Text="WinOptimizer" FontSize="20" FontWeight="Bold" Foreground="#E6EDF3"/>
                  <TextBlock Text="safe &amp; reversible tuning" Foreground="#8B949E" FontSize="12"/>
                </StackPanel>
                <StackPanel IsItemsHost="True" DockPanel.Dock="Top"/>
                <TextBlock DockPanel.Dock="Bottom" VerticalAlignment="Bottom" Margin="22,0,10,18" TextWrapping="Wrap"
                           Foreground="#6E7681" FontSize="11"
                           Text="Every change is backed up and can be undone from Backup &amp; Restore."/>
              </DockPanel>
            </Border>
            <ContentPresenter Grid.Column="1" ContentSource="SelectedContent" Margin="26,22,26,10"/>
          </Grid>
        </ControlTemplate>
      </TabControl.Template>

      <!-- DASHBOARD -->
      <TabItem Header="Dashboard">
        <Grid>
          <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
          <StackPanel>
            <TextBlock Text="Dashboard" FontSize="24" FontWeight="SemiBold"/>
            <TextBlock x:Name="SysInfo" Foreground="#8B949E" Margin="0,2,0,16"/>
          </StackPanel>
          <UniformGrid Grid.Row="1" Columns="3" Margin="0,0,0,16">
            <Border Background="#161B22" BorderBrush="#30363D" BorderThickness="1" CornerRadius="10" Padding="18" Margin="0,0,10,0">
              <StackPanel>
                <TextBlock Text="MEMORY IN USE" Foreground="#8B949E" FontSize="11" FontWeight="SemiBold"/>
                <TextBlock x:Name="RamText" FontSize="28" FontWeight="Bold" Margin="0,6,0,6" Text="-"/>
                <ProgressBar x:Name="RamBar" Height="8" Maximum="100" Background="#21262D" Foreground="#2F81F7" BorderThickness="0"/>
                <TextBlock x:Name="RamSub" Foreground="#8B949E" FontSize="12" Margin="0,6,0,0"/>
              </StackPanel>
            </Border>
            <Border Background="#161B22" BorderBrush="#30363D" BorderThickness="1" CornerRadius="10" Padding="18" Margin="5,0,5,0">
              <StackPanel>
                <TextBlock Text="CPU LOAD" Foreground="#8B949E" FontSize="11" FontWeight="SemiBold"/>
                <TextBlock x:Name="CpuText" FontSize="28" FontWeight="Bold" Margin="0,6,0,6" Text="-"/>
                <ProgressBar x:Name="CpuBar" Height="8" Maximum="100" Background="#21262D" Foreground="#A371F7" BorderThickness="0"/>
                <TextBlock x:Name="PlanText" Foreground="#8B949E" FontSize="12" Margin="0,6,0,0"/>
              </StackPanel>
            </Border>
            <Border Background="#161B22" BorderBrush="#30363D" BorderThickness="1" CornerRadius="10" Padding="18" Margin="10,0,0,0">
              <StackPanel>
                <TextBlock Text="SINCE LAST APPLY" Foreground="#8B949E" FontSize="11" FontWeight="SemiBold"/>
                <TextBlock x:Name="DeltaText" FontSize="28" FontWeight="Bold" Margin="0,6,0,6" Text="-"/>
                <TextBlock x:Name="DeltaSub" Foreground="#8B949E" FontSize="12" TextWrapping="Wrap"
                           Text="Apply tweaks, then reboot, to see the real difference."/>
              </StackPanel>
            </Border>
          </UniformGrid>
          <Border Grid.Row="2" Background="#161B22" BorderBrush="#30363D" BorderThickness="1" CornerRadius="10" Padding="16">
            <DockPanel>
              <DockPanel DockPanel.Dock="Top" Margin="0,0,0,10">
                <Button x:Name="BtnRefreshProc" DockPanel.Dock="Right" Content="Refresh" Style="{StaticResource Btn}" Margin="0"/>
                <TextBlock Text="Top processes by memory (grouped)" FontSize="15" FontWeight="SemiBold" VerticalAlignment="Center"/>
              </DockPanel>
              <ListView x:Name="ProcList" Background="Transparent" BorderThickness="0" Foreground="#E6EDF3">
                <ListView.View>
                  <GridView>
                    <GridViewColumn Header="Process" Width="320" DisplayMemberBinding="{Binding Name}"/>
                    <GridViewColumn Header="Instances" Width="100" DisplayMemberBinding="{Binding Count}"/>
                    <GridViewColumn Header="Working set (MB)" Width="160" DisplayMemberBinding="{Binding MB}"/>
                  </GridView>
                </ListView.View>
              </ListView>
            </DockPanel>
          </Border>
        </Grid>
      </TabItem>

      <!-- MEMORY -->
      <TabItem Header="Memory / RAM">
        <DockPanel>
          <StackPanel DockPanel.Dock="Top" Margin="0,0,0,12">
            <TextBlock Text="Memory / RAM" FontSize="24" FontWeight="SemiBold"/>
            <TextBlock Foreground="#8B949E" TextWrapping="Wrap" Margin="0,2,0,10"
                       Text="Background services, features and processes Windows runs by default. Green = safe for virtually everyone. Yellow = read the trade-off first. Nothing is uninstalled."/>
            <WrapPanel>
              <Button x:Name="BtnMemRec"  Content="Select recommended" Style="{StaticResource Btn}"/>
              <Button x:Name="BtnMemNone" Content="Select none" Style="{StaticResource Btn}"/>
              <Button x:Name="BtnTrim"    Content="Trim RAM now (temporary)" Style="{StaticResource Btn}"
                      ToolTip="Asks every process to release unused pages. Windows reclaims them as apps need them again, so the effect is short-lived. Changes nothing permanently."/>
            </WrapPanel>
          </StackPanel>
          <ScrollViewer VerticalScrollBarVisibility="Auto"><ItemsControl x:Name="MemList" ItemTemplate="{StaticResource TweakTemplate}"/></ScrollViewer>
        </DockPanel>
      </TabItem>

      <!-- STARTUP -->
      <TabItem Header="Startup apps">
        <DockPanel>
          <StackPanel DockPanel.Dock="Top" Margin="0,0,0,12">
            <TextBlock Text="Startup apps" FontSize="24" FontWeight="SemiBold"/>
            <TextBlock Foreground="#8B949E" TextWrapping="Wrap" Margin="0,2,0,10"
                       Text="Programs that launch at sign-in - usually the single biggest source of avoidable RAM use. Ticked items are disabled exactly the way Task Manager does it (nothing is deleted). Windows Security is hidden and never touched."/>
            <WrapPanel>
              <Button x:Name="BtnStartNone" Content="Select none" Style="{StaticResource Btn}"/>
              <Button x:Name="BtnStartReload" Content="Reload list" Style="{StaticResource Btn}"/>
            </WrapPanel>
          </StackPanel>
          <ScrollViewer VerticalScrollBarVisibility="Auto"><ItemsControl x:Name="StartList" ItemTemplate="{StaticResource TweakTemplate}"/></ScrollViewer>
        </DockPanel>
      </TabItem>

      <!-- CPU -->
      <TabItem Header="CPU">
        <DockPanel>
          <StackPanel DockPanel.Dock="Top" Margin="0,0,0,12">
            <TextBlock Text="CPU" FontSize="24" FontWeight="SemiBold"/>
            <TextBlock Foreground="#8B949E" TextWrapping="Wrap" Margin="0,2,0,10"
                       Text="Scheduling and power settings that favour responsiveness and games. Gains are real but modest - typically smoother frame times rather than higher average FPS."/>
            <WrapPanel>
              <Button x:Name="BtnCpuRec"  Content="Select recommended" Style="{StaticResource Btn}"/>
              <Button x:Name="BtnCpuNone" Content="Select none" Style="{StaticResource Btn}"/>
            </WrapPanel>
          </StackPanel>
          <ScrollViewer VerticalScrollBarVisibility="Auto"><ItemsControl x:Name="CpuList" ItemTemplate="{StaticResource TweakTemplate}"/></ScrollViewer>
        </DockPanel>
      </TabItem>

      <!-- GPU -->
      <TabItem Header="GPU">
        <DockPanel>
          <StackPanel DockPanel.Dock="Top" Margin="0,0,0,12">
            <TextBlock Text="GPU" FontSize="24" FontWeight="SemiBold"/>
            <TextBlock x:Name="GpuInfo" Foreground="#8B949E" TextWrapping="Wrap" Margin="0,2,0,10"/>
            <WrapPanel>
              <Button x:Name="BtnGpuRec"  Content="Select recommended" Style="{StaticResource Btn}"/>
              <Button x:Name="BtnGpuNone" Content="Select none" Style="{StaticResource Btn}"/>
            </WrapPanel>
          </StackPanel>
          <ScrollViewer VerticalScrollBarVisibility="Auto"><ItemsControl x:Name="GpuList" ItemTemplate="{StaticResource TweakTemplate}"/></ScrollViewer>
        </DockPanel>
      </TabItem>

      <!-- RESTORE -->
      <TabItem Header="Backup &amp; Restore">
        <DockPanel>
          <StackPanel DockPanel.Dock="Top" Margin="0,0,0,12">
            <TextBlock Text="Backup &amp; Restore" FontSize="24" FontWeight="SemiBold"/>
            <TextBlock Foreground="#8B949E" TextWrapping="Wrap" Margin="0,2,0,10"
                       Text="Each time you apply changes, the previous value of everything touched is saved here. Restoring puts those exact values back. For a full rollback you can also use the System Restore point created before applying (rstrui.exe)."/>
            <WrapPanel>
              <Button x:Name="BtnRestore"      Content="Restore selected backup" Style="{StaticResource PrimaryBtn}"/>
              <Button x:Name="BtnRestorePoint" Content="Create restore point now" Style="{StaticResource Btn}"/>
              <Button x:Name="BtnOpenSysRestore" Content="Open System Restore" Style="{StaticResource Btn}"/>
              <Button x:Name="BtnOpenFolder"   Content="Open backup folder" Style="{StaticResource Btn}"/>
            </WrapPanel>
          </StackPanel>
          <ListBox x:Name="BackupList" Background="#161B22" BorderBrush="#30363D" Foreground="#E6EDF3" Padding="6"/>
        </DockPanel>
      </TabItem>
    </TabControl>

    <!-- Bottom bar: log + apply -->
    <Border Grid.Row="1" Background="#161B22" BorderBrush="#30363D" BorderThickness="0,1,0,0" Padding="16,10">
      <Grid>
        <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
        <TextBox x:Name="LogBox" Height="92" IsReadOnly="True" Background="#0D1117" Foreground="#8B949E" BorderBrush="#30363D"
                 FontFamily="Consolas" FontSize="11" VerticalScrollBarVisibility="Auto" TextWrapping="NoWrap" Padding="6"/>
        <StackPanel Grid.Column="1" Margin="16,0,0,0" VerticalAlignment="Center">
          <TextBlock x:Name="SelCount" Foreground="#8B949E" HorizontalAlignment="Right" Margin="0,0,0,8" Text="0 changes selected"/>
          <Button x:Name="BtnApply" Content="Review &amp; apply..." Style="{StaticResource PrimaryBtn}" Margin="0" Padding="22,10" FontSize="14"/>
        </StackPanel>
      </Grid>
    </Border>
  </Grid>
</Window>
'@

$window = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xaml))
$ui = @{}
foreach ($n in 'Tabs','SysInfo','RamText','RamBar','RamSub','CpuText','CpuBar','PlanText','DeltaText','DeltaSub','ProcList','BtnRefreshProc',
               'MemList','BtnMemRec','BtnMemNone','BtnTrim','StartList','BtnStartNone','BtnStartReload',
               'CpuList','BtnCpuRec','BtnCpuNone','GpuList','GpuInfo','BtnGpuRec','BtnGpuNone',
               'BackupList','BtnRestore','BtnRestorePoint','BtnOpenSysRestore','BtnOpenFolder','LogBox','SelCount','BtnApply') {
    $ui[$n] = $window.FindName($n)
}
$script:LogBox = $ui.LogBox

# ---------------------------------------------------------------------------
# 9. State + UI wiring
# ---------------------------------------------------------------------------
$script:Catalog   = @()
$script:Startup   = @()
$script:BaselineMB = $null

function Get-AllTweaks { @($script:Catalog) + @($script:Startup) }

function Update-SelCount {
    $n = @(Get-AllTweaks | Where-Object { $_.IsSelected }).Count
    $ui.SelCount.Text = "$n change$(if ($n -ne 1) {'s'}) selected"
    $ui.BtnApply.IsEnabled = $n -gt 0
}

function Register-SelectionWatch($tweaks) {
    foreach ($t in $tweaks) {
        $t.add_PropertyChanged({ param($s, $e) if ($e.PropertyName -eq 'IsSelected') { Update-SelCount } })
    }
}

function Load-Catalog {
    $script:Catalog = @(Get-TweakCatalog)
    foreach ($t in $script:Catalog) {
        Update-TweakStatus $t
        $t.IsSelected = $t.Recommended -and $t.IsAvailable -and $t.Status -ne 'Applied'
    }
    Register-SelectionWatch $script:Catalog
    $ui.MemList.ItemsSource = @($script:Catalog | Where-Object Category -eq 'Memory')
    $ui.CpuList.ItemsSource = @($script:Catalog | Where-Object Category -eq 'CPU')
    $ui.GpuList.ItemsSource = @($script:Catalog | Where-Object Category -eq 'GPU')
}

function Load-Startup {
    $script:Startup = @(Get-StartupTweaks)
    Register-SelectionWatch $script:Startup
    $ui.StartList.ItemsSource = $script:Startup
    Write-Log "Found $($script:Startup.Count) startup entries."
}

function Load-Backups {
    $ui.BackupList.Items.Clear()
    Get-ChildItem -Path $BackupDir -Filter 'backup-*.json' -ErrorAction SilentlyContinue | Sort-Object Name -Descending | ForEach-Object {
        $count = 0
        try { $count = @((Get-Content $_.FullName -Raw | ConvertFrom-Json).Entries).Count } catch {}
        $item = New-Object System.Windows.Controls.ListBoxItem
        $item.Content = "{0}    -    {1} change(s)" -f $_.LastWriteTime.ToString('yyyy-MM-dd  HH:mm:ss'), $count
        $item.Tag = $_.FullName
        $item.Padding = New-Object System.Windows.Thickness(8,6,8,6)
        $ui.BackupList.Items.Add($item) | Out-Null
    }
}

function Set-Selection($category, [bool]$recommendedOnly, [bool]$none) {
    foreach ($t in ($script:Catalog | Where-Object Category -eq $category)) {
        if ($none) { $t.IsSelected = $false }
        else { $t.IsSelected = $t.IsAvailable -and $t.Recommended -and $t.Status -ne 'Applied' }
    }
}

function Update-Stats {
    try {
        $m = Get-MemStats
        $ui.RamText.Text = '{0:N1} / {1:N1} GB' -f ($m.UsedMB / 1024), ($m.TotalMB / 1024)
        $ui.RamBar.Value = $m.Pct
        $ui.RamSub.Text  = "$($m.Pct)% used  -  $([math]::Round($m.FreeMB/1024,1)) GB available"
        $c = Get-CpuLoad
        $ui.CpuText.Text = "$c %"
        $ui.CpuBar.Value = $c
        $plan = Get-ActiveScheme
        if ($plan) { $ui.PlanText.Text = "Power plan: $($plan.Name)" }
        if ($null -ne $script:BaselineMB) {
            $d = $script:BaselineMB - $m.UsedMB
            $ui.DeltaText.Text = if ($d -ge 0) { "-$d MB" } else { "+$([math]::Abs($d)) MB" }
        }
    } catch {}
}

function Update-Processes { try { $ui.ProcList.ItemsSource = @(Get-TopProcesses) } catch {} }

# ---------- Preview / confirm dialog ----------
function Show-Preview($selected) {
    $sb = New-Object System.Text.StringBuilder
    foreach ($cat in 'Memory','Startup','CPU','GPU') {
        $group = @($selected | Where-Object Category -eq $cat)
        if (-not $group.Count) { continue }
        [void]$sb.AppendLine("==== $cat ====")
        foreach ($t in $group) {
            [void]$sb.AppendLine("[$($t.Risk)] $($t.Name)")
            [void]$sb.AppendLine("    Trade-off: $($t.Tradeoff)")
            foreach ($a in $t.Actions) { [void]$sb.AppendLine("    - " + (Get-ActionDescription $a)) }
            [void]$sb.AppendLine()
        }
    }

    $dlgXaml = [xml]@'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Review changes" Width="900" Height="640" WindowStartupLocation="CenterOwner"
        Background="#0D1117" Foreground="#E6EDF3" FontFamily="Segoe UI" FontSize="13">
  <DockPanel Margin="20">
    <StackPanel DockPanel.Dock="Top" Margin="0,0,0,12">
      <TextBlock Text="Review exactly what will change" FontSize="20" FontWeight="SemiBold"/>
      <TextBlock x:Name="Summary" Foreground="#8B949E" TextWrapping="Wrap" Margin="0,4,0,0"/>
    </StackPanel>
    <StackPanel DockPanel.Dock="Bottom" Margin="0,12,0,0">
      <CheckBox x:Name="ChkRp" IsChecked="True" Foreground="#E6EDF3" Margin="0,0,0,12"
                Content="Create a System Restore point first (recommended, can take up to a minute)"/>
      <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
        <Button x:Name="Cancel" Content="Cancel" Style="{DynamicResource Btn}" IsCancel="True"/>
        <Button x:Name="Ok" Content="Apply changes" Style="{DynamicResource PrimaryBtn}" Margin="0"/>
      </StackPanel>
    </StackPanel>
    <TextBox x:Name="Details" IsReadOnly="True" FontFamily="Consolas" FontSize="12" Background="#161B22" Foreground="#E6EDF3"
             BorderBrush="#30363D" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto" Padding="8"/>
  </DockPanel>
</Window>
'@
    $dlg = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $dlgXaml))
    $dlg.Owner = $window
    $dlg.Resources.MergedDictionaries.Add($window.Resources)
    $script:PreviewDlg = $dlg
    $mod = @($selected | Where-Object Risk -ne 'Safe').Count
    $dlg.FindName('Summary').Text = "$($selected.Count) item(s) selected, $mod of them marked Moderate. Current value -> new value is shown for every setting. Original values are saved to a backup you can restore at any time."
    $dlg.FindName('Details').Text = $sb.ToString()
    $script:PreviewResult = $null
    $dlg.FindName('Ok').add_Click({
        $script:PreviewResult = @{ RestorePoint = [bool]$script:PreviewDlg.FindName('ChkRp').IsChecked }
        $script:PreviewDlg.DialogResult = $true
    })
    [void]$dlg.ShowDialog()
    return $script:PreviewResult
}

# ---------- Apply ----------
function Invoke-Apply {
    $selected = @(Get-AllTweaks | Where-Object { $_.IsSelected -and $_.IsAvailable })
    if (-not $selected.Count) { return }
    $choice = Show-Preview $selected
    if (-not $choice) { Write-Log 'Cancelled - nothing was changed.'; return }

    $window.Cursor = [System.Windows.Input.Cursors]::Wait
    $ui.BtnApply.IsEnabled = $false
    try {
        $script:BaselineMB = (Get-MemStats).UsedMB

        if ($choice.RestorePoint) {
            Write-Log 'Creating System Restore point (the window may pause briefly)...'
            if (New-SafetyRestorePoint) { Write-Log 'Restore point created.' 'OK' }
            else {
                $r = [System.Windows.MessageBox]::Show(
                    "A System Restore point could not be created (System Protection may be off or blocked by policy).`n`nA JSON backup of every change will still be saved and can be restored from this app.`n`nContinue anyway?",
                    'WinOptimizer', 'YesNo', 'Warning')
                if ($r -ne 'Yes') { Write-Log 'Aborted by user - nothing was changed.'; return }
            }
        }

        $entries = New-Object System.Collections.ArrayList
        $backupPath = Join-Path $BackupDir ("backup-{0}.json" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
        $errors = 0
        try {
            foreach ($t in $selected) {
                Write-Log "> $($t.Name)"
                foreach ($a in $t.Actions) {
                    try {
                        $e = Invoke-Action $a
                        if ($e) { [void]$entries.Add($e) }
                    } catch {
                        $errors++
                        Write-Log "  FAILED: $($_.Exception.Message)" 'ERR'
                    }
                }
                $t.IsSelected = $false
            }
        } finally {
            # Always persist the backup, even if something above threw.
            if ($entries.Count) {
                @{ Created = (Get-Date).ToString('o'); Computer = $env:COMPUTERNAME; Entries = @($entries) } |
                    ConvertTo-Json -Depth 6 | Set-Content -Path $backupPath -Encoding UTF8
                Write-Log "Backup saved: $backupPath" 'OK'
            }
        }

        foreach ($t in $script:Catalog) { Update-TweakStatus $t }
        Load-Startup
        Load-Backups
        Start-Sleep -Milliseconds 1500
        Update-Stats
        $ui.DeltaSub.Text = 'Measured right after applying. Most savings (services, startup apps, svchost grouping) only fully show after a reboot.'

        $msg = "Done. $($entries.Count) setting(s) changed, $errors error(s).`n`nA restart is recommended so that service, startup and scheduler changes take full effect.`n`nRestart now?"
        $r = [System.Windows.MessageBox]::Show($msg, 'WinOptimizer', 'YesNo', 'Information')
        if ($r -eq 'Yes') { Restart-Computer -Force }
    } finally {
        $window.Cursor = $null
        Update-SelCount
    }
}

# ---------- Restore ----------
function Invoke-Restore {
    $item = $ui.BackupList.SelectedItem
    if (-not $item) { [System.Windows.MessageBox]::Show('Select a backup first.', 'WinOptimizer') | Out-Null; return }
    $path = $item.Tag
    $r = [System.Windows.MessageBox]::Show("Restore all settings saved in:`n$path`n`nThis puts every value back to what it was before that apply.", 'WinOptimizer', 'OKCancel', 'Question')
    if ($r -ne 'OK') { return }
    $data = Get-Content $path -Raw | ConvertFrom-Json
    $list = @($data.Entries)
    [array]::Reverse($list)
    Write-Log "Restoring $($list.Count) setting(s) from $path"
    $errors = 0
    foreach ($e in $list) {
        try { Restore-Entry $e } catch { $errors++; Write-Log "  FAILED: $($_.Exception.Message)" 'ERR' }
    }
    Rename-Item -Path $path -NewName ([IO.Path]::GetFileName($path) -replace '^backup-', 'restored-') -ErrorAction SilentlyContinue
    foreach ($t in $script:Catalog) { Update-TweakStatus $t }
    Load-Startup
    Load-Backups
    [System.Windows.MessageBox]::Show("Restore finished with $errors error(s). Restart Windows to complete it.", 'WinOptimizer') | Out-Null
}

# ---------- Events ----------
$ui.BtnApply.add_Click({ Invoke-Apply })
$ui.BtnMemRec.add_Click({ Set-Selection 'Memory' $true $false })
$ui.BtnMemNone.add_Click({ Set-Selection 'Memory' $false $true })
$ui.BtnCpuRec.add_Click({ Set-Selection 'CPU' $true $false })
$ui.BtnCpuNone.add_Click({ Set-Selection 'CPU' $false $true })
$ui.BtnGpuRec.add_Click({ Set-Selection 'GPU' $true $false })
$ui.BtnGpuNone.add_Click({ Set-Selection 'GPU' $false $true })
$ui.BtnStartNone.add_Click({ foreach ($t in $script:Startup) { $t.IsSelected = $false } })
$ui.BtnStartReload.add_Click({ Load-Startup; Update-SelCount })
$ui.BtnRefreshProc.add_Click({ Update-Processes })
$ui.BtnTrim.add_Click({
    $before = (Get-MemStats).UsedMB
    $n = Invoke-TrimWorkingSets
    Start-Sleep -Milliseconds 800
    $after = (Get-MemStats).UsedMB
    Write-Log "Trimmed $n processes: in-use RAM $before MB -> $after MB. This is temporary; Windows pages memory back in as apps need it." 'OK'
    Update-Stats; Update-Processes
})
$ui.BtnRestore.add_Click({ Invoke-Restore })
$ui.BtnRestorePoint.add_Click({
    Write-Log 'Creating System Restore point...'
    if (New-SafetyRestorePoint) { Write-Log 'Restore point created.' 'OK' }
})
$ui.BtnOpenSysRestore.add_Click({ Start-Process "$env:SystemRoot\System32\rstrui.exe" })
$ui.BtnOpenFolder.add_Click({ Start-Process explorer.exe $BackupDir })

$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromSeconds(3)
$script:Tick = 0
$timer.add_Tick({
    Update-Stats
    $script:Tick++
    if ($script:Tick % 4 -eq 0 -and $ui.Tabs.SelectedIndex -eq 0) { Update-Processes }
})

$window.add_Loaded({
    Write-Log "WinOptimizer started. Log: $LogFile"
    try {
        $os  = Get-CimInstance Win32_OperatingSystem
        $cpu = (Get-CimInstance Win32_Processor | Select-Object -First 1).Name.Trim()
        $ui.SysInfo.Text = "$($os.Caption) (build $($os.BuildNumber))  -  $cpu"
        $gpus = (Get-CimInstance Win32_VideoController | ForEach-Object { $_.Name }) -join ', '
        $ui.GpuInfo.Text = "Detected: $gpus.  These settings reduce background GPU work and latency. They do not overclock or change driver settings - for that use your GPU vendor's control panel."
    } catch {}
    Load-Catalog
    Load-Startup
    Load-Backups
    Update-SelCount
    Update-Stats
    Update-Processes
    $timer.Start()
})
$window.add_Closed({ $timer.Stop() })

[void]$window.ShowDialog()
