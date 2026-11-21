﻿#Requires -Version 5.1
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
    $argList = "-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File `"$PSCommandPath`""
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
        public string Group { get; set; }
        public bool Recommended { get; set; }
        public object Actions { get; set; }

        private bool _sel;
        public bool IsSelected { get { return _sel; } set { _sel = value; N("IsSelected"); } }

        private bool _avail = true;
        public bool IsAvailable { get { return _avail; } set { _avail = value; N("IsAvailable"); } }

        private string _status = "";
        public string Status { get { return _status; } set { _status = value; N("Status"); N("StatusColor"); } }

        public string StatusColor { get {
            if (_status == "Applied" || _status == "Already disabled") return "#34D399";
            if (_status == "Not present") return "#5C667A";
            if (_status == "Partially applied") return "#FBBF24";
            if (_status == "Install another browser first") return "#F87171";
            return "#8C96A8"; } }

        public string RiskColor { get {
            if (Risk == "Safe") return "#34D399";
            if (Risk == "Moderate") return "#FBBF24";
            return "#F87171"; } }

        public string RiskBg { get {
            if (Risk == "Safe") return "#1F34D399";
            if (Risk == "Moderate") return "#1FFBBF24";
            return "#26F87171"; } }

        public string TradeoffText { get { return "Trade-off: " + Tradeoff; } }
    }
}
'@
}

if (-not ('WinOpt.Collector' -as [type])) {
    Add-Type -Language CSharp -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text.RegularExpressions;
using System.Threading;

namespace WinOpt {
    public class ProcRow {
        public string Name { get; set; }
        public int Count { get; set; }
        public long MB { get; set; }
        public double Cpu { get; set; }
        public string CpuText { get { return Cpu < 0.05 ? "0 %" : Cpu.ToString("0.0") + " %"; } }
    }

    public class MemInfo {
        public long TotalMB;
        public long AvailMB;
        public long UsedMB;
        public double Pct;
    }

    public class Snapshot {
        public MemInfo Mem;
        public double Cpu;          // -1 = not sampled yet
        public string CpuSource;
        public string PowerPlan;    // "guid|name"
        public List<ProcRow> Procs;
        public int ProcVersion;
        public bool ProcApproximate;
    }

    // Collects all dashboard data on a thread-pool timer so the UI thread never blocks.
    public static class Collector {
        [StructLayout(LayoutKind.Sequential)]
        private class MEMORYSTATUSEX {
            public uint dwLength; public uint dwMemoryLoad;
            public ulong ullTotalPhys; public ulong ullAvailPhys;
            public ulong ullTotalPageFile; public ulong ullAvailPageFile;
            public ulong ullTotalVirtual; public ulong ullAvailVirtual; public ulong ullAvailExtendedVirtual;
            public MEMORYSTATUSEX() { dwLength = (uint)Marshal.SizeOf(typeof(MEMORYSTATUSEX)); }
        }
        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool GlobalMemoryStatusEx([In, Out] MEMORYSTATUSEX buf);
        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool GetSystemTimes(out long idle, out long kernel, out long user);
        [DllImport("powrprof.dll")]
        private static extern uint PowerGetActiveScheme(IntPtr root, out IntPtr guid);
        [DllImport("powrprof.dll")]
        private static extern uint PowerReadFriendlyName(IntPtr root, IntPtr scheme, IntPtr sub, IntPtr setting, IntPtr buffer, ref uint size);
        [DllImport("kernel32.dll")]
        private static extern IntPtr LocalFree(IntPtr h);
        [DllImport("psapi.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool EmptyWorkingSet(IntPtr h);

        // ---------- memory (same source as Task Manager: In use = Total - Available) ----------
        public static MemInfo ReadMemory() {
            MEMORYSTATUSEX m = new MEMORYSTATUSEX();
            if (!GlobalMemoryStatusEx(m)) return null;
            MemInfo r = new MemInfo();
            r.TotalMB = (long)(m.ullTotalPhys / 1048576UL);
            r.AvailMB = (long)(m.ullAvailPhys / 1048576UL);
            r.UsedMB  = r.TotalMB - r.AvailMB;
            r.Pct     = r.TotalMB > 0 ? Math.Round(r.UsedMB * 100.0 / r.TotalMB, 1) : 0;
            return r;
        }

        // ---------- active power plan (no powercfg.exe process spawn) ----------
        public static string GetActivePlan() {
            IntPtr p;
            if (PowerGetActiveScheme(IntPtr.Zero, out p) != 0) return null;
            try {
                Guid g = (Guid)Marshal.PtrToStructure(p, typeof(Guid));
                uint size = 0;
                PowerReadFriendlyName(IntPtr.Zero, p, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, ref size);
                string name = "";
                if (size > 0) {
                    IntPtr buf = Marshal.AllocHGlobal((int)size);
                    try {
                        if (PowerReadFriendlyName(IntPtr.Zero, p, IntPtr.Zero, IntPtr.Zero, buf, ref size) == 0)
                            name = Marshal.PtrToStringUni(buf);
                    } finally { Marshal.FreeHGlobal(buf); }
                }
                return g.ToString() + "|" + name;
            } finally { LocalFree(p); }
        }

        // ---------- CPU ----------
        // Task Manager (Win10 1903+/Win11) shows "% Processor Utility", which accounts for boost clocks.
        // Fall back to GetSystemTimes deltas (= "% Processor Time") if that counter is unavailable.
        private static PerformanceCounter utilCounter;
        private static bool utilTried;
        private static long lastIdle, lastKernel, lastUser;

        private static double ReadCpu(out string source) {
            if (!utilTried) {
                utilTried = true;
                try {
                    utilCounter = new PerformanceCounter("Processor Information", "% Processor Utility", "_Total", true);
                    utilCounter.NextValue();
                    source = "Processor Utility";
                    return -1;
                } catch { utilCounter = null; }
            }
            if (utilCounter != null) {
                try {
                    source = "Processor Utility";
                    return Math.Round(Math.Min(100.0, Math.Max(0.0, utilCounter.NextValue())), 0);
                } catch { utilCounter = null; }
            }
            source = "Processor Time";
            long idle, kernel, user;
            if (!GetSystemTimes(out idle, out kernel, out user)) return -1;
            bool first = lastKernel == 0;
            long di = idle - lastIdle, dk = kernel - lastKernel, du = user - lastUser;
            lastIdle = idle; lastKernel = kernel; lastUser = user;
            if (first) return -1;
            long total = dk + du;           // kernel time includes idle time
            if (total <= 0) return 0;
            return Math.Round(Math.Max(0.0, Math.Min(100.0, (total - di) * 100.0 / total)), 0);
        }

        // ---------- processes ----------
        // Memory = "Working Set - Private", the same figure as Task Manager's Memory column.
        // (Process.WorkingSet64 includes shared DLL pages and over-counts multi-process apps heavily.)
        private static Dictionary<string, CounterSample> prevCpu = new Dictionary<string, CounterSample>();
        private static readonly Regex instSuffix = new Regex(@"#\d+$");

        private static List<ProcRow> ReadProcs(out bool approximate) {
            approximate = false;
            Dictionary<string, ProcRow> groups = new Dictionary<string, ProcRow>(StringComparer.OrdinalIgnoreCase);
            try {
                InstanceDataCollectionCollection all = new PerformanceCounterCategory("Process").ReadCategory();
                InstanceDataCollection ws  = all["Working Set - Private"];
                InstanceDataCollection ids = all["ID Process"];
                InstanceDataCollection cpu = all["% Processor Time"];
                if (ws == null) throw new InvalidOperationException("Working Set - Private counter missing");
                Dictionary<string, CounterSample> next = new Dictionary<string, CounterSample>();
                int cores = Math.Max(1, Environment.ProcessorCount);
                foreach (InstanceData d in ws.Values) {
                    string inst = d.InstanceName;
                    if (inst == "_Total" || inst == "Idle") continue;
                    string baseName = instSuffix.Replace(inst, "");
                    long pid = (ids != null && ids.Contains(inst)) ? ids[inst].RawValue : -1;
                    double c = 0;
                    if (cpu != null && cpu.Contains(inst)) {
                        CounterSample cur = cpu[inst].Sample;
                        string key = pid.ToString() + ":" + baseName;
                        CounterSample old;
                        if (prevCpu.TryGetValue(key, out old)) c = CounterSample.Calculate(old, cur) / cores;
                        next[key] = cur;
                    }
                    ProcRow row;
                    if (!groups.TryGetValue(baseName, out row)) { row = new ProcRow(); row.Name = baseName; groups[baseName] = row; }
                    row.Count++;
                    row.MB += d.RawValue;
                    if (c > 0) row.Cpu += c;
                }
                prevCpu = next;
            } catch {
                approximate = true;
                groups.Clear();
                foreach (Process p in Process.GetProcesses()) {
                    try {
                        ProcRow row;
                        if (!groups.TryGetValue(p.ProcessName, out row)) { row = new ProcRow(); row.Name = p.ProcessName; groups[p.ProcessName] = row; }
                        row.Count++;
                        row.MB += p.WorkingSet64;
                    } catch { } finally { p.Dispose(); }
                }
            }
            List<ProcRow> list = new List<ProcRow>(groups.Values);
            foreach (ProcRow r in list) { r.MB = r.MB / 1048576; if (r.Cpu > 100) r.Cpu = 100; }
            list.Sort(delegate(ProcRow a, ProcRow b) { return b.MB.CompareTo(a.MB); });
            if (list.Count > 25) list.RemoveRange(25, list.Count - 25);
            return list;
        }

        public static int TrimAll() {
            int n = 0;
            foreach (Process p in Process.GetProcesses()) {
                try { if (EmptyWorkingSet(p.Handle)) n++; } catch { } finally { p.Dispose(); }
            }
            return n;
        }

        // ---------- background loop ----------
        private static Timer timer;
        private static int busy;
        private static int tick;
        private static volatile Snapshot current;
        private static volatile bool procRequest = true;
        private static volatile bool planRequest = true;
        private static int procVersion;
        private static List<ProcRow> lastProcs = new List<ProcRow>();
        private static bool lastApprox;
        private static string plan;

        public static volatile bool WantProcs = true;
        public static Snapshot Current { get { return current; } }
        public static void RequestProcs() { procRequest = true; }
        public static void RequestPlan() { planRequest = true; }

        public static void Start() {
            if (timer == null) timer = new Timer(Tick, null, 0, 1000);
        }
        public static void Stop() {
            if (timer != null) { timer.Dispose(); timer = null; }
        }

        private static void Tick(object state) {
            if (Interlocked.Exchange(ref busy, 1) == 1) return;   // previous sample still running
            try {
                Snapshot s = new Snapshot();
                s.Mem = ReadMemory();
                string src;
                s.Cpu = ReadCpu(out src);
                s.CpuSource = src;
                if (plan == null || planRequest || tick % 15 == 0) {
                    planRequest = false;
                    try { plan = GetActivePlan(); } catch { }
                }
                s.PowerPlan = plan;
                if (procRequest || (WantProcs && tick % 3 == 0)) {
                    procRequest = false;
                    bool approx;
                    lastProcs = ReadProcs(out approx);
                    lastApprox = approx;
                    procVersion++;
                }
                s.Procs = lastProcs;
                s.ProcVersion = procVersion;
                s.ProcApproximate = lastApprox;
                current = s;
                tick++;
            } catch { }
            finally { Interlocked.Exchange(ref busy, 0); }
        }
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
        $vn = if ($Name -eq '(Default)') { '' } else { $Name }
        if ($item -and ($item.GetValueNames() -contains $vn)) {
            $state.Existed = $true
            $state.Kind    = $item.GetValueKind($vn).ToString()
            $raw = $item.GetValue($vn, $null, 'DoNotExpandEnvironmentNames')
            if ($raw -is [byte[]]) { $state.Value = @($raw | ForEach-Object { [int]$_ }) } else { $state.Value = $raw }
        }
    }
    return $state
}

function Set-RegValue([string]$Path, [string]$Name, $Value, [string]$Kind) {
    if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
    if ($Name -eq '(Default)') { Set-Item -Path $Path -Value "$Value"; return }
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

# Task Scheduler COM API: much faster than the ScheduledTasks cmdlets (no CIM/module load).
$script:TaskSvc = $null
function Get-TaskObject([string]$TaskPath, [string]$TaskName) {
    if (-not $script:TaskSvc) {
        $script:TaskSvc = New-Object -ComObject 'Schedule.Service'
        $script:TaskSvc.Connect()
    }
    $folder = $TaskPath.TrimEnd('\')
    if (-not $folder) { $folder = '\' }
    try { return $script:TaskSvc.GetFolder($folder).GetTask($TaskName) } catch { return $null }
}

function Get-TaskState([string]$TaskPath, [string]$TaskName) {
    $t = Get-TaskObject $TaskPath $TaskName
    if (-not $t) { return $null }
    if ($t.Enabled) { 'Enabled' } else { 'Disabled' }
}

function Set-TaskEnabled([string]$TaskPath, [string]$TaskName, [bool]$Enabled) {
    $t = Get-TaskObject $TaskPath $TaskName
    if (-not $t) { throw "Task $TaskPath$TaskName not found" }
    $t.Enabled = $Enabled
}

$PowerSchemes = @{
    Ultimate = 'e9a42b02-d5df-448d-aa00-03f14749eb61'
    High     = '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'
    Balanced = '381b4222-f694-41f0-9685-ff5bb260df2e'
}

function Get-ActiveScheme {
    # Native PowerGetActiveScheme - no powercfg.exe process per call.
    $v = [WinOpt.Collector]::GetActivePlan()
    if (-not $v) { return $null }
    $parts = $v -split '\|', 2
    return @{ Guid = $parts[0]; Name = $parts[1] }
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
        'Appx'     { return 'UNINSTALL for all users (and stop it reinstalling for new accounts): ' + (@($a.Found) -join ', ') }
        'Edge'     { return 'UNINSTALL Microsoft Edge system-wide and block Edge Update from reinstalling it. Edge WebView2 Runtime is kept.' }
        'OneDrive' { return 'UNINSTALL the OneDrive sync client. Files in your OneDrive cloud account are not deleted.' }
        'Hosts'    { return 'Block ' + (@($a.Domains).Count) + ' telemetry domains in the hosts file (0.0.0.0): ' + ((@($a.Domains) | Select-Object -First 3) -join ', ') + ', ...' }
        'Dns'      { return 'Set DNS on all active network adapters to ' + $a.Label + ' (' + (@($a.Servers) -join ', ') + '). Reverts to automatic (DHCP).' }
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
        'Hosts' { if (Get-HostsBlocked) { 'Applied' } else { 'NotApplied' } }
        'Dns'   { if (Test-DnsApplied $a.Servers) { 'Applied' } else { 'NotApplied' } }
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
            Set-TaskEnabled $a.TaskPath $a.TaskName $false
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
        'Hosts' {
            if (Get-HostsBlocked) { Write-Log '  telemetry hosts block already present'; return $null }
            Set-HostsBlocked $a.Domains $true
            Write-Log "  blocked $(@($a.Domains).Count) telemetry domains in the hosts file" 'OK'
            return [ordered]@{ Type = 'Hosts' }
        }
        'Dns' {
            if ((Test-Action $a) -eq 'Applied') { Write-Log '  DNS already set'; return $null }
            $prev = Set-DnsServers $a.Servers
            Write-Log "  DNS -> $($a.Label) on $(@($prev).Count) adapter(s)" 'OK'
            return [ordered]@{ Type = 'Dns'; Previous = @($prev) }
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
                $rn = if ($e.Name -eq '(Default)') { '(default)' } else { $e.Name }
                Remove-ItemProperty -Path $e.Path -Name $rn -ErrorAction SilentlyContinue
                Write-Log "  reg $($e.Path)\$($e.Name) removed (was not set before)" 'OK'
            }
        }
        'Task' {
            Set-TaskEnabled $e.TaskPath $e.TaskName $true
            Write-Log "  task $($e.TaskPath)$($e.TaskName) re-enabled" 'OK'
        }
        'PowerPlan' {
            powercfg /setactive $e.Previous | Out-Null
            Write-Log "  power plan restored to $($e.PreviousName)" 'OK'
        }
        'Hosts' { Set-HostsBlocked @() $false; Write-Log '  telemetry hosts block removed' 'OK' }
        'Dns' {
            foreach ($pp in @($e.Previous)) {
                try {
                    if (@($pp.Servers).Count) { Set-DnsClientServerAddress -InterfaceIndex $pp.Index -ServerAddresses @($pp.Servers) -ErrorAction Stop }
                    else { Set-DnsClientServerAddress -InterfaceIndex $pp.Index -ResetServerAddresses -ErrorAction Stop }
                } catch {}
            }
            Write-Log '  DNS restored' 'OK'
        }
    }
}

# ---------------------------------------------------------------------------
# 4b. Hosts-file telemetry blocking + DNS helpers
# ---------------------------------------------------------------------------
$HostsFile  = "$env:SystemRoot\System32\drivers\etc\hosts"
$HostsBegin = '# >>> WinOptimizer telemetry block'
$HostsEnd   = '# <<< WinOptimizer telemetry block'
$TelemetryDomains = @(
    'vortex.data.microsoft.com','vortex-win.data.microsoft.com','telecommand.telemetry.microsoft.com',
    'oca.telemetry.microsoft.com','sqm.telemetry.microsoft.com','watson.telemetry.microsoft.com',
    'telemetry.microsoft.com','settings-sandbox.data.microsoft.com','vortex-sandbox.data.microsoft.com',
    'watson.ppe.telemetry.microsoft.com','telemetry.appex.bing.net','telemetry.urs.microsoft.com',
    'settings-win.data.microsoft.com','v10.vortex-win.data.microsoft.com','v10.events.data.microsoft.com',
    'v20.events.data.microsoft.com','functional.events.data.microsoft.com','browser.events.data.msn.com'
)
function Get-HostsBlocked {
    if (-not (Test-Path $HostsFile)) { return $false }
    try { return ((Get-Content $HostsFile -Raw -ErrorAction Stop) -match [regex]::Escape($HostsBegin)) } catch { return $false }
}
function Set-HostsBlocked([string[]]$domains, [bool]$on) {
    $lines = @(); if (Test-Path $HostsFile) { $lines = @(Get-Content $HostsFile -ErrorAction SilentlyContinue) }
    $out = New-Object System.Collections.ArrayList; $skip = $false
    foreach ($l in $lines) {
        if ($l -eq $HostsBegin) { $skip = $true; continue }
        if ($l -eq $HostsEnd)   { $skip = $false; continue }
        if (-not $skip) { [void]$out.Add($l) }
    }
    if ($on) {
        [void]$out.Add($HostsBegin)
        foreach ($d in $domains) { [void]$out.Add("0.0.0.0 $d"); [void]$out.Add("0.0.0.0 www.$d") }
        [void]$out.Add($HostsEnd)
    }
    Set-Content -Path $HostsFile -Value $out -Encoding ASCII -Force
}
function Get-UpAdapters {
    try { return @(Get-NetAdapter -Physical -ErrorAction Stop | Where-Object { $_.Status -eq 'Up' }) } catch { return @() }
}
function Test-DnsApplied([string[]]$servers) {
    $ad = Get-UpAdapters; if (-not $ad.Count) { return $false }
    foreach ($a in $ad) {
        $cur = @((Get-DnsClientServerAddress -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).ServerAddresses)
        if ((@($cur) -join ',') -ne (@($servers) -join ',')) { return $false }
    }
    return $true
}
function Set-DnsServers([string[]]$servers) {
    $prev = @()
    foreach ($a in Get-UpAdapters) {
        $cur = @((Get-DnsClientServerAddress -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).ServerAddresses)
        $prev += @{ Index = $a.ifIndex; Servers = $cur }
        try { Set-DnsClientServerAddress -InterfaceIndex $a.ifIndex -ServerAddresses $servers -ErrorAction Stop } catch {}
    }
    return $prev
}

# ---------------------------------------------------------------------------
# 5. Tweak catalog
# ---------------------------------------------------------------------------
function Svc($n, $s)              { @{ Type = 'Service'; Name = $n; Start = $s } }
function Reg($p, $n, $v, $k='DWord') { @{ Type = 'Reg'; Path = $p; Name = $n; Value = $v; Kind = $k } }
function Tsk($p, $n)              { @{ Type = 'Task'; TaskPath = $p; TaskName = $n } }
function Hst($domains)            { @{ Type = 'Hosts'; Domains = @($domains) } }
function Dns($servers, $label)    { @{ Type = 'Dns'; Servers = @($servers); Label = $label } }

function New-Tweak {
    param($Id, $Category, $Name, $Risk, [bool]$Recommended, $Description, $Tradeoff, $Actions)
    $t = New-Object WinOpt.Tweak
    $t.Id = $Id; $t.Category = $Category; $t.Name = $Name; $t.Risk = $Risk
    $t.Recommended = $Recommended; $t.Description = $Description; $t.Tradeoff = $Tradeoff
    $t.Actions = @($Actions)
    return $t
}

function Get-TweakCatalog {
    $totalKB = [int64]([WinOpt.Collector]::ReadMemory().TotalMB * 1024)

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

    # ------------------------------ EXPLORER & UI ------------------------------
    New-Tweak 'ctxmenu' 'UI' 'Classic right-click menu (Windows 10 style)' 'Safe' $true `
        'Restores the full right-click context menu instead of the trimmed Windows 11 one that hides options behind "Show more options".' `
        'Explorer restarts to apply. Purely behavioural.' @(
        (Reg 'HKCU:\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32' '(Default)' '' 'String'))

    New-Tweak 'fileext' 'UI' 'Show file extensions' 'Safe' $true `
        'Shows extensions like .exe and .txt so you can spot files disguised as documents.' 'None.' @(
        (Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'HideFileExt' 0))

    New-Tweak 'hidden' 'UI' 'Show hidden files' 'Safe' $false `
        'Shows hidden files and folders in File Explorer.' 'None.' @(
        (Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'Hidden' 1))

    New-Tweak 'darkmode' 'UI' 'Dark mode (apps + system)' 'Safe' $true `
        'Switches Windows and built-in apps to the dark theme.' 'Purely visual.' @(
        (Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' 'AppsUseLightTheme' 0),
        (Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' 'SystemUsesLightTheme' 0))

    New-Tweak 'taskbaralign' 'UI' 'Taskbar: align to the left' 'Safe' $false `
        'Moves the taskbar icons and Start button to the left (Windows 10 style).' 'None.' @(
        (Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'TaskbarAl' 0))

    New-Tweak 'taskbarwidgets' 'UI' 'Taskbar: remove Widgets button' 'Safe' $true `
        'Hides the Widgets (weather) button from the taskbar.' 'None.' @(
        (Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'TaskbarDa' 0))

    New-Tweak 'taskbarchat' 'UI' 'Taskbar: remove Chat / Teams button' 'Safe' $true `
        'Hides the Chat (Microsoft Teams) button from the taskbar.' 'None.' @(
        (Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'TaskbarMn' 0))

    New-Tweak 'taskview' 'UI' 'Taskbar: remove Task View button' 'Safe' $false `
        'Hides the Task View button. Win+Tab still works.' 'None.' @(
        (Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'ShowTaskViewButton' 0))

    New-Tweak 'searchbox' 'UI' 'Taskbar: shrink search to an icon' 'Safe' $false `
        'Replaces the wide taskbar search box with a small search icon.' 'None.' @(
        (Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search' 'SearchboxTaskbarMode' 1))

    New-Tweak 'endtask' 'UI' 'Taskbar: add "End task" to right-click' 'Safe' $true `
        'Adds an End task option when you right-click a running app on the taskbar.' 'None.' @(
        (Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced\TaskbarDeveloperSettings' 'TaskbarEndTask' 1))

    New-Tweak 'explorerthispc' 'UI' 'Open File Explorer to This PC' 'Safe' $false `
        'File Explorer opens to This PC instead of Home / Quick access.' 'None.' @(
        (Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'LaunchTo' 1))

    # ------------------------------ PRIVACY & AI ------------------------------
    New-Tweak 'recall' 'Privacy' 'Disable Windows Recall (AI screen snapshots)' 'Safe' $true `
        'Turns off Recall, which periodically screenshots everything you do so AI can search it.' 'The Recall timeline is unavailable.' @(
        (Reg 'HKCU:\Software\Policies\Microsoft\Windows\WindowsAI' 'DisableAIDataAnalysis' 1),
        (Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI' 'DisableAIDataAnalysis' 1))

    New-Tweak 'paintai' 'Privacy' 'Disable Paint AI (Cocreator / Image Creator)' 'Safe' $true `
        'Removes the generative-AI buttons from Paint.' 'Paint still works normally.' @(
        (Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Paint' 'DisableCocreator' 1),
        (Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Paint' 'DisableGenerativeFill' 1),
        (Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Paint' 'DisableImageCreator' 1))

    New-Tweak 'notepadai' 'Privacy' 'Disable Notepad AI (Rewrite)' 'Safe' $true `
        'Removes the AI Rewrite feature from Notepad.' 'Notepad still works normally.' @(
        (Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsNotepad' 'DisableAIFeatures' 1))

    New-Tweak 'edgeai' 'Privacy' 'Disable Edge Copilot / sidebar AI' 'Safe' $true `
        'Turns off the Copilot sidebar in Microsoft Edge.' 'Edge shows "Managed by your organization".' @(
        (Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' 'HubsSidebarEnabled' 0),
        (Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' 'DiscoverPageContextEnabled' 0))

    New-Tweak 'advertisingid' 'Privacy' 'Disable advertising ID' 'Safe' $true `
        'Stops apps using your advertising ID to profile you across apps.' 'Ads become less personalised.' @(
        (Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo' 'Enabled' 0),
        (Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AdvertisingInfo' 'DisabledByGroupPolicy' 1))

    New-Tweak 'activityhistory' 'Privacy' 'Disable activity history / Timeline' 'Safe' $true `
        'Stops Windows collecting and uploading your activity history.' 'Timeline is unavailable.' @(
        (Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' 'EnableActivityFeed' 0),
        (Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' 'PublishUserActivities' 0),
        (Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' 'UploadUserActivities' 0))

    New-Tweak 'tailored' 'Privacy' 'Disable tailored experiences' 'Safe' $true `
        'Stops Windows using your diagnostic data to show tailored tips and ads.' 'None.' @(
        (Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Privacy' 'TailoredExperiencesWithDiagnosticDataEnabled' 0))

    New-Tweak 'apptracking' 'Privacy' 'Disable app-launch tracking' 'Safe' $false `
        'Stops Windows tracking which apps you open for Start suggestions.' 'None.' @(
        (Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'Start_TrackProgs' 0))

    New-Tweak 'nvtelemetry' 'Privacy' 'Disable NVIDIA telemetry' 'Safe' $false `
        'Disables the NVIDIA telemetry container service (only if present).' 'Your NVIDIA driver still works.' @(
        (Svc 'NvTelemetryContainer' 'Disabled'))

    New-Tweak 'telemetryhosts' 'Privacy' 'Block telemetry servers (hosts file)' 'Moderate' $false `
        'Adds Microsoft telemetry domains to the hosts file pointing at 0.0.0.0 so the PC cannot reach them.' `
        'A future Windows update could add new domains. Fully reversible from Backup & Restore.' @(
        (Hst $TelemetryDomains))

    New-Tweak 'dnscloudflare' 'Privacy' 'Set DNS to Cloudflare (1.1.1.1)' 'Moderate' $false `
        'Points all active network adapters at Cloudflare DNS - often faster and more private than your ISP.' `
        'On a hotel/captive-portal wifi you may need to revert. Reversible to automatic (DHCP).' @(
        (Dns @('1.1.1.1','1.0.0.1') 'Cloudflare'))

    New-Tweak 'dnsadguard' 'Privacy' 'Set DNS to AdGuard (blocks ads/trackers)' 'Moderate' $false `
        'Points all active adapters at AdGuard DNS, which blocks many ad and tracker domains network-wide.' `
        'Some sites relying on tracked content may misbehave. Reversible to automatic (DHCP).' @(
        (Dns @('94.140.14.14','94.140.15.15') 'AdGuard'))

    # ------------------------------ WINDOWS UPDATE ------------------------------
    New-Tweak 'noautoreboot' 'Update' 'No automatic restart while signed in' 'Safe' $true `
        'Windows will not automatically reboot to finish updates while you are logged in.' 'You still need to restart eventually.' @(
        (Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' 'NoAutoRebootWithLoggedOnUsers' 1))

    New-Tweak 'notifyupdates' 'Update' 'Notify before downloading updates' 'Safe' $false `
        'Windows asks before downloading and installing updates instead of doing it automatically.' `
        'You must remember to install updates yourself - keep up with security patches.' @(
        (Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' 'NoAutoUpdate' 0),
        (Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' 'AUOptions' 2))

    New-Tweak 'deferfeature' 'Update' 'Defer feature updates (1 year)' 'Moderate' $false `
        'Holds back big Windows version upgrades for 365 days so you are not an early tester.' 'You still receive monthly security updates.' @(
        (Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' 'DeferFeatureUpdates' 1),
        (Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' 'DeferFeatureUpdatesPeriodInDays' 365))

    New-Tweak 'nodrivers' 'Update' 'Exclude drivers from Windows Update' 'Moderate' $false `
        'Stops Windows Update replacing your drivers - use the vendor''s installer instead.' 'You update drivers yourself.' @(
        (Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' 'ExcludeWUDriversInQualityUpdate' 1))

    New-Tweak 'disableupdates' 'Update' 'Disable automatic updates entirely' 'Advanced' $false `
        'Turns off automatic Windows Updates completely.' `
        'RISK: your PC stops getting security patches until you re-enable this and check for updates manually. Reversible.' @(
        (Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' 'NoAutoUpdate' 1))
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
    # GlobalMemoryStatusEx: identical to Task Manager ("In use" = total - available).
    $m = [WinOpt.Collector]::ReadMemory()
    @{ TotalMB = $m.TotalMB; UsedMB = $m.UsedMB; FreeMB = $m.AvailMB; Pct = $m.Pct }
}

function Invoke-TrimWorkingSets { [WinOpt.Collector]::TrimAll() }

# ---------------------------------------------------------------------------
# 7b. Process control: end task + timed "pause" (block relaunch for a while)
# ---------------------------------------------------------------------------
# Blocking uses Image File Execution Options: an app with a "Debugger" pointed at a
# harmless stub (systray.exe, which just exits) will not launch. A scheduled task lifts
# the block when the pause expires; the Paused Tasks page can lift it early.
$IFEO        = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options'
$PauseStub   = "$env:SystemRoot\System32\systray.exe"
$PausedFile  = Join-Path $AppRoot 'paused.json'
# Never allow pausing these - blocking them could lock you out of the PC.
$ProtectedExe = '^(explorer|winlogon|csrss|wininit|services|lsass|smss|dwm|svchost|taskmgr|systemsettings|sihost|ctfmon|powershell|cmd|conhost|runtimebroker|startmenuexperiencehost|searchhost|shellexperiencehost|applicationframehost|fontdrvhost|dllhost|WinOptimizer)\.exe$'

function Read-PausedApps {
    if (-not (Test-Path $PausedFile)) { return @() }
    try { return @((Get-Content $PausedFile -Raw | ConvertFrom-Json)) } catch { return @() }
}
function Write-PausedApps($list) {
    @($list) | ConvertTo-Json -Depth 4 | Set-Content -Path $PausedFile -Encoding UTF8
}
function Get-ActivePauses {
    # Only entries whose IFEO block still exists, refreshed back to the file.
    $live = @(Read-PausedApps | Where-Object { $_.Exe -and (Test-Path (Join-Path $IFEO $_.Exe)) })
    Write-PausedApps $live
    return $live
}
function Stop-AppNow([string]$procName) {
    $n = 0
    Get-Process -Name $procName -ErrorAction SilentlyContinue | ForEach-Object {
        try { $_.Kill(); $n++ } catch {}
    }
    return $n
}
function Resume-App([string]$exe) {
    try { Remove-Item -LiteralPath (Join-Path $IFEO $exe) -Recurse -Force -ErrorAction SilentlyContinue } catch {}
    try { Unregister-ScheduledTask -TaskName "WinOptimizer-Unpause-$exe" -Confirm:$false -ErrorAction SilentlyContinue } catch {}
    Write-PausedApps @(Read-PausedApps | Where-Object { $_.Exe -ne $exe })
    Write-Log "Resumed $exe (pause lifted)" 'OK'
}
function Pause-App([string]$procName, $until) {
    # $until: a [datetime] for a timed pause, or $null for a permanent pause (lift from Paused Tasks).
    $exe = if ($procName -match '\.exe$') { $procName } else { "$procName.exe" }
    if ($exe -match $ProtectedExe) { throw "$exe is a protected system process and cannot be paused." }
    $key = Join-Path $IFEO $exe
    if (-not (Test-Path $key)) { New-Item -Path $key -Force | Out-Null }
    Set-ItemProperty -Path $key -Name 'Debugger' -Value $PauseStub -Type String -Force
    $killed = Stop-AppNow $procName
    $taskName = "WinOptimizer-Unpause-$exe"
    try { Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue } catch {}
    if ($until) {
        # Schedule automatic unblock at $until (SYSTEM, highest).
        $cmd = "Remove-Item -LiteralPath '$key' -Recurse -Force -EA SilentlyContinue; Unregister-ScheduledTask -TaskName '$taskName' -Confirm:`$false -EA SilentlyContinue"
        try {
            $act = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -WindowStyle Hidden -Command `"$cmd`""
            $trg = New-ScheduledTaskTrigger -Once -At $until
            $prn = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
            Register-ScheduledTask -TaskName $taskName -Action $act -Trigger $trg -Principal $prn -Force -ErrorAction Stop | Out-Null
        } catch {
            Write-Log "  warning: could not schedule auto-unpause ($($_.Exception.Message)). Lift it manually from Paused Tasks." 'WARN'
        }
    }
    $untilStr = $null; if ($until) { $untilStr = $until.ToString('o') }
    $list = @(Read-PausedApps | Where-Object { $_.Exe -ne $exe })
    $list += @{ Exe = $exe; Proc = $procName; Until = $untilStr }
    Write-PausedApps $list
    $msg = if ($until) { "until $($until.ToString('g'))" } else { 'permanently (until you lift it)' }
    Write-Log "Paused $exe $msg (killed $killed running instance(s))" 'OK'
}
# Human label -> timespan for the pause durations.
$PauseDurations = [ordered]@{
    '1 hour'   = ([TimeSpan]::FromHours(1));  '6 hours'  = ([TimeSpan]::FromHours(6))
    '12 hours' = ([TimeSpan]::FromHours(12)); '1 day'    = ([TimeSpan]::FromDays(1))
    '3 days'   = ([TimeSpan]::FromDays(3));   '7 days'   = ([TimeSpan]::FromDays(7))
    '1 month'  = ([TimeSpan]::FromDays(30))
}

function Get-SystemSummary {
    # Registry reads instead of WMI: instant.
    $cv    = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue
    $build = [int]$cv.CurrentBuild
    # ProductName still says "Windows 10" on Windows 11, so derive the major version from the build number.
    $name  = if ($build -ge 22000) { $cv.ProductName -replace 'Windows 10', 'Windows 11' } else { $cv.ProductName }
    $ver   = if ($cv.DisplayVersion) { " $($cv.DisplayVersion)" } else { '' }
    $cpu   = (Get-ItemProperty 'HKLM:\HARDWARE\DESCRIPTION\System\CentralProcessor\0' -ErrorAction SilentlyContinue).ProcessorNameString
    $gpus  = @()
    $cls   = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}'
    Get-ChildItem $cls -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -match '^\d{4}$' } | ForEach-Object {
        $d = (Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue).DriverDesc
        if ($d -and $gpus -notcontains $d -and $d -notmatch 'Basic Display|Basic Render|Remote Display|Virtual') { $gpus += $d }
    }
    @{ Os = "$name$ver (build $build)"; Cpu = "$cpu".Trim(); Gpus = ($gpus -join ', ') }
}

# ---------------------------------------------------------------------------
# 7b. Bloatware - a curated allow-list of removable apps (never a wildcard sweep)
# ---------------------------------------------------------------------------
# Hard guard: these are NEVER removed, even if a pattern below were to match them.
# Store, App Installer/winget, frameworks/runtimes, security, sign-in, shell hosts, codecs, core inbox tools.
$ProtectedAppx = '^(Microsoft\.WindowsStore|Microsoft\.StorePurchaseApp|Microsoft\.DesktopAppInstaller|Microsoft\.VCLibs\..*|Microsoft\.UI\.Xaml\..*|Microsoft\.NET\..*|Microsoft\.WindowsAppRuntime\..*|Microsoft\.Services\.Store\.Engagement|Microsoft\.SecHealthUI|Microsoft\.XboxIdentityProvider|Microsoft\.Xbox\.TCUI|Microsoft\.AAD\.BrokerPlugin|Microsoft\.AccountsControl|Microsoft\.Windows\..*Host|Microsoft\.WindowsTerminal|Microsoft\.WindowsCalculator|Microsoft\.WindowsNotepad|Microsoft\.Windows\.Photos|Microsoft\.ScreenSketch|Microsoft\.Paint|Microsoft\..*Extension.*|Microsoft\.MicrosoftEdge.*|MicrosoftWindows\.Client\..*|Microsoft\.LanguageExperiencePack.*|windows\..*)$'

$G_MS    = 'Microsoft apps'
$G_XBOX  = 'Xbox & gaming'
$G_3P    = 'Preinstalled third-party apps'
$G_CORE  = 'Microsoft Edge & OneDrive'
$StoreBack = 'Reinstall any time from the Microsoft Store (Backup & Restore gives you a direct link).'

function B($Group, $Id, $Name, $Risk, [bool]$Rec, [string[]]$Patterns, $Desc, $Trade) {
    @{ Group = $Group; Id = $Id; Name = $Name; Risk = $Risk; Rec = $Rec; Patterns = $Patterns; Desc = $Desc; Trade = $Trade }
}

$BloatDefs = @(
    (B $G_MS 'news'        'News & Weather'                 'Safe' $true  @('Microsoft.BingNews','Microsoft.BingWeather') 'Preinstalled MSN news and weather apps.' $StoreBack),
    (B $G_MS 'bingsearch'  'Bing Search'                    'Safe' $true  @('Microsoft.BingSearch') 'Standalone Bing search app.' $StoreBack),
    (B $G_MS 'tips'        'Tips & Get Help'                'Safe' $true  @('Microsoft.Getstarted','Microsoft.GetHelp') 'Windows tips and the Get Help support app.' 'A few built-in troubleshooter links will open the Microsoft support website instead.'),
    (B $G_MS 'solitaire'   'Microsoft Solitaire Collection' 'Safe' $true  @('Microsoft.MicrosoftSolitaireCollection') 'Ad-supported card games.' $StoreBack),
    (B $G_MS 'officehub'   'Microsoft 365 (Office) hub'     'Safe' $true  @('Microsoft.MicrosoftOfficeHub') 'The Office launcher/advert app only. Installed Word, Excel, etc. are NOT affected.' $StoreBack),
    (B $G_MS 'clipchamp'   'Clipchamp'                      'Safe' $true  @('Clipchamp.Clipchamp') 'Web-based video editor.' $StoreBack),
    (B $G_MS 'todo'        'Microsoft To Do'                'Safe' $true  @('Microsoft.Todos') 'Task list app.' ('Your lists stay in your Microsoft account. ' + $StoreBack)),
    (B $G_MS 'feedback'    'Feedback Hub'                   'Safe' $true  @('Microsoft.WindowsFeedbackHub') 'App for sending feedback to Microsoft.' $StoreBack),
    (B $G_MS 'maps'        'Windows Maps'                   'Safe' $true  @('Microsoft.WindowsMaps') 'Offline maps app.' $StoreBack),
    (B $G_MS 'people'      'People'                         'Safe' $true  @('Microsoft.People') 'Legacy contacts app.' $StoreBack),
    (B $G_MS 'skype'       'Skype'                          'Safe' $true  @('Microsoft.SkypeApp') 'Skype (retired by Microsoft in 2025).' $StoreBack),
    (B $G_MS 'movies'      'Movies & TV'                    'Safe' $true  @('Microsoft.ZuneVideo') 'Legacy video store/player.' 'Videos still play in Media Player or any other player.'),
    (B $G_MS 'automate'    'Power Automate'                 'Safe' $true  @('Microsoft.PowerAutomateDesktop') 'Desktop automation tool.' $StoreBack),
    (B $G_MS 'devhome'     'Dev Home'                       'Safe' $true  @('Microsoft.Windows.DevHome') 'Developer dashboard (discontinued by Microsoft).' $StoreBack),
    (B $G_MS 'threed'      '3D apps (Paint 3D, 3D Viewer, Mixed Reality)' 'Safe' $true @('Microsoft.MSPaint','Microsoft.Microsoft3DViewer','Microsoft.MixedReality.Portal','Microsoft.Print3D') 'Legacy 3D apps. Classic Paint is not affected.' $StoreBack),
    (B $G_MS 'legacy'      'Legacy promo apps'              'Safe' $true  @('Microsoft.Wallet','Microsoft.Messaging','Microsoft.OneConnect') 'Wallet, Messaging and Mobile Plans leftovers.' $StoreBack),
    (B $G_MS 'cortana'     'Cortana'                        'Safe' $true  @('Microsoft.549981C3F5F10') 'Discontinued voice assistant.' $StoreBack),
    (B $G_MS 'copilot'     'Copilot app'                    'Safe' $true  @('Microsoft.Copilot') 'The Copilot AI app.' $StoreBack),
    (B $G_MS 'family'      'Microsoft Family Safety'        'Safe' $true  @('MicrosoftCorporationII.MicrosoftFamily') 'Parental-controls companion app.' ('Family settings on your Microsoft account are not changed. ' + $StoreBack)),
    (B $G_MS 'teams'       'Microsoft Teams'                'Moderate' $false @('MicrosoftTeams','MSTeams') 'Teams chat app (personal and work/school).' ('Keep it if you use Teams for work or school. ' + $StoreBack)),
    (B $G_MS 'mail'        'Mail, Calendar & new Outlook'   'Moderate' $false @('microsoft.windowscommunicationsapps','Microsoft.OutlookForWindows') 'Built-in email and calendar apps.' ('You will need another mail client or webmail. ' + $StoreBack)),
    (B $G_MS 'media'       'Media Player'                   'Moderate' $false @('Microsoft.ZuneMusic') 'The default music/video player on Windows 11 (Groove Music on Windows 10).' 'Install another player (e.g. VLC) first, or media files will have nothing to open them.'),
    (B $G_MS 'phonelink'   'Phone Link'                     'Moderate' $false @('Microsoft.YourPhone','MicrosoftWindows.CrossDevice') 'Connects an Android/iPhone to the PC.' ('Phone notifications, texts and photos on the PC stop working. ' + $StoreBack)),
    (B $G_MS 'quickassist' 'Quick Assist'                   'Moderate' $false @('MicrosoftCorporationII.QuickAssist') 'Remote-help tool.' ('Nobody can give you remote help through Quick Assist (also a common scam tool). ' + $StoreBack)),

    (B $G_XBOX 'xboxapp'   'Xbox app'                       'Moderate' $false @('Microsoft.GamingApp','Microsoft.XboxApp') 'The Xbox PC app.' 'Required for PC Game Pass and installing Xbox PC games. Xbox sign-in for games is kept.'),
    (B $G_XBOX 'gamebar'   'Xbox Game Bar'                  'Moderate' $false @('Microsoft.XboxGamingOverlay','Microsoft.XboxGameOverlay','Microsoft.XboxSpeechToTextOverlay') 'Win+G overlay, game capture and performance widgets.' ('Pressing the Xbox button on a controller may show a "you will need a new app" prompt. ' + $StoreBack)),

    (B $G_3P 'kinggames'   'Candy Crush & other King games' 'Safe' $true  @('king.com.*') 'Preinstalled ad-supported games.' ('Game progress is tied to your King account. ' + $StoreBack)),
    (B $G_3P 'spotify'     'Spotify'                        'Safe' $false @('SpotifyAB.SpotifyMusic') 'Spotify Store app (often preinstalled).' ('Your account and playlists are unaffected. ' + $StoreBack)),
    (B $G_3P 'disney'      'Disney+'                        'Safe' $false @('Disney.37853FA22FAF4') 'Streaming app.' $StoreBack),
    (B $G_3P 'netflix'     'Netflix'                        'Safe' $false @('*Netflix*') 'Streaming app.' $StoreBack),
    (B $G_3P 'prime'       'Prime Video'                    'Safe' $false @('AmazonVideo.PrimeVideo') 'Streaming app.' $StoreBack),
    (B $G_3P 'tiktok'      'TikTok'                         'Safe' $false @('*TikTok*') 'Social app.' $StoreBack),
    (B $G_3P 'instagram'   'Instagram'                      'Safe' $false @('*Instagram*') 'Social app.' $StoreBack),
    (B $G_3P 'facebook'    'Facebook'                       'Safe' $false @('Facebook.*') 'Social app.' $StoreBack),
    (B $G_3P 'linkedin'    'LinkedIn'                       'Safe' $false @('*LinkedIn*') 'Social app.' $StoreBack)
)

function Get-OtherBrowsers {
    $names = @()
    foreach ($k in 'HKLM:\SOFTWARE\Clients\StartMenuInternet', 'HKCU:\SOFTWARE\Clients\StartMenuInternet', 'HKLM:\SOFTWARE\WOW6432Node\Clients\StartMenuInternet') {
        if (-not (Test-Path $k)) { continue }
        Get-ChildItem $k -ErrorAction SilentlyContinue | ForEach-Object {
            $n = (Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue).'(default)'
            if (-not $n) { $n = $_.PSChildName }
            if ($n -notmatch 'Edge|Internet Explorer|IEXPLORE') { $names += $n }
        }
    }
    @($names | Sort-Object -Unique)
}

function Get-OneDriveExe {
    foreach ($p in "$env:LOCALAPPDATA\Microsoft\OneDrive\OneDrive.exe", "$env:ProgramFiles\Microsoft OneDrive\OneDrive.exe", "${env:ProgramFiles(x86)}\Microsoft OneDrive\OneDrive.exe") {
        if (Test-Path $p) { return $p }
    }
    return $null
}

$EdgeExe = Join-Path ${env:ProgramFiles(x86)} 'Microsoft\Edge\Application\msedge.exe'

function Get-BloatTweaks($Installed, $Provisioned) {
    $Installed   = @($Installed)
    $names = @((@($Installed) + @($Provisioned)) | Where-Object { $_ -and $_ -notmatch $ProtectedAppx } | Sort-Object -Unique)
    foreach ($d in $BloatDefs) {
        $found = @($names | Where-Object { $n = $_; @($d.Patterns | Where-Object { $n -like $_ }).Count -gt 0 })
        if (-not $found.Count) { continue }
        $inst = @($found | Where-Object { $Installed -contains $_ })
        $t = New-Tweak $d.Id 'Bloat' $d.Name $d.Risk $d.Rec $d.Desc $d.Trade @(@{ Type = 'Appx'; Patterns = $d.Patterns; Found = $found })
        $t.Group = $d.Group
        $t.Status = if ($inst.Count) { 'Installed' } else { 'Staged for new users' }
        $t
    }

    if (Test-Path $EdgeExe) {
        $others = @(Get-OtherBrowsers)
        $t = New-Tweak 'edge' 'Bloat' 'Microsoft Edge browser' 'Advanced' $false `
            'Uninstalls the Edge browser for all users and blocks Edge Update from silently reinstalling it. The Edge WebView2 Runtime is deliberately kept - Widgets, Teams, Outlook, many game launchers and other apps need it to work.' `
            'Microsoft only officially allows this in the EU/EEA; elsewhere the same workaround other open-source debloat tools use is applied, and some builds still refuse (you will be told). A major Windows feature update can bring Edge back. Reinstall any time from microsoft.com/edge.' `
            @(@{ Type = 'Edge' })
        $t.Group = $G_CORE
        if ($others.Count) {
            $t.Status = 'Installed'
            $t.Description += "  Other browser found: $($others -join ', ')."
        } else {
            $t.Status = 'Install another browser first'
            $t.IsAvailable = $false
        }
        $t
    }

    if (Get-OneDriveExe) {
        $t = New-Tweak 'onedrive' 'Bloat' 'OneDrive' 'Moderate' $false `
            'Uninstalls the OneDrive sync client, which runs at every sign-in and syncs Desktop/Documents/Pictures in the background.' `
            'IMPORTANT: files marked "online-only" (cloud icon) will not open on this PC afterwards. They stay safe in your OneDrive account online. Right-click your OneDrive folder > "Always keep on this device" first if you need them offline.' `
            @(@{ Type = 'OneDrive' })
        $t.Group = $G_CORE
        $t.Status = 'Installed'
        $t
    }
}

# ---------------------------------------------------------------------------
# 7c. Background jobs. These run in a separate runspace so the window never freezes.
#     They must be self-contained: they cannot call functions defined in this script.
# ---------------------------------------------------------------------------
$ScanJob = {
    param($sync, $arg)
    try {
        $sync.Installed   = @(Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue | ForEach-Object { $_.Name } | Sort-Object -Unique)
        $sync.Provisioned = @(Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue | ForEach-Object { $_.DisplayName } | Sort-Object -Unique)
    } catch {
        $sync.Error = $_.Exception.Message
    } finally {
        $sync.Done = $true
    }
}

$RestorePointJob = {
    param($sync, $desc)
    try {
        $k = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore'
        $prev = (Get-ItemProperty $k -Name SystemRestorePointCreationFrequency -ErrorAction SilentlyContinue).SystemRestorePointCreationFrequency
        try { Enable-ComputerRestore -Drive "$env:SystemDrive\" -ErrorAction Stop } catch {}
        # Windows silently skips a restore point if one was made in the last 24 h; lift that for this one call.
        New-ItemProperty $k -Name SystemRestorePointCreationFrequency -Value 0 -PropertyType DWord -Force | Out-Null
        try {
            Checkpoint-Computer -Description $desc -RestorePointType MODIFY_SETTINGS -ErrorAction Stop
            $sync.Ok = $true
        } catch {
            $sync.Error = $_.Exception.Message
        } finally {
            if ($null -eq $prev) { Remove-ItemProperty $k -Name SystemRestorePointCreationFrequency -ErrorAction SilentlyContinue }
            else { New-ItemProperty $k -Name SystemRestorePointCreationFrequency -Value $prev -PropertyType DWord -Force | Out-Null }
        }
    } catch {
        $sync.Error = $_.Exception.Message
    } finally {
        $sync.Done = $true
    }
}

$RemovalJob = {
    param($sync, $arg)
    function L([string]$m) { $sync.Log.Enqueue($m) }
    function Test-Match([string]$name, $patterns) {
        foreach ($p in @($patterns)) { if ($p -and $name -like $p) { return $true } }
        return $false
    }
    function Split-Command([string]$s) {
        $s = $s.Trim()
        if ($s -match '^"([^"]+)"\s*(.*)$' -or $s -match '^(.+?\.exe)\s*(.*)$') { return @($Matches[1], $Matches[2].Trim()) }
        return @($s, '')
    }
    try {
        $protected = $arg.Protected
        $items = @($arg.Items)
        $prov = @()
        $allPkgs = @()
        if (@($items | Where-Object { $_.Kind -eq 'Appx' }).Count) {
            L 'Reading installed and provisioned app packages...'
            $allPkgs = @(Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue)
            $prov    = @(Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue)
        }

        foreach ($it in $items) {
            $r = @{ Id = $it.Id; Kind = $it.Kind; Display = $it.Display; Patterns = $it.Patterns; Ok = $false; Changed = $false; Message = ''; Families = @() }
            L "> $($it.Display)"
            try {
                if ($it.Kind -eq 'Appx') {
                    $pkgs = @($allPkgs | Where-Object { (Test-Match $_.Name $it.Patterns) -and $_.Name -notmatch $protected -and -not $_.NonRemovable } |
                              Sort-Object PackageFullName -Unique)
                    foreach ($p in $pkgs) {
                        try {
                            Remove-AppxPackage -Package $p.PackageFullName -AllUsers -ErrorAction Stop
                            L "  removed $($p.Name)"
                            $r.Families += $p.PackageFamilyName
                        } catch {
                            L "  could not remove $($p.Name): $($_.Exception.Message)"
                        }
                    }
                    # Remove the provisioned copy too, otherwise Windows reinstalls it for new user accounts.
                    foreach ($pp in @($prov | Where-Object { (Test-Match $_.DisplayName $it.Patterns) -and $_.DisplayName -notmatch $protected })) {
                        try {
                            Remove-AppxProvisionedPackage -Online -PackageName $pp.PackageName -ErrorAction Stop | Out-Null
                            L "  de-provisioned $($pp.DisplayName)"
                            $r.Changed = $true
                        } catch {
                            L "  could not de-provision $($pp.DisplayName): $($_.Exception.Message)"
                        }
                    }
                    $r.Families = @($r.Families | Sort-Object -Unique)
                }
                elseif ($it.Kind -eq 'Edge') {
                    $appDir  = Join-Path ${env:ProgramFiles(x86)} 'Microsoft\Edge\Application'
                    $edgeExe = Join-Path $appDir 'msedge.exe'
                    if (-not (Test-Path $edgeExe)) {
                        $r.Ok = $true; $r.Message = 'Edge was not installed.'
                    } else {
                        $cmd = (Get-ItemProperty 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge' -ErrorAction SilentlyContinue).UninstallString
                        if (-not $cmd) {
                            $setup = Get-ChildItem (Join-Path $appDir '*\Installer\setup.exe') -ErrorAction SilentlyContinue | Sort-Object FullName -Descending | Select-Object -First 1
                            if ($setup) { $cmd = "`"$($setup.FullName)`" --uninstall --msedge --channel=stable --system-level --verbose-logging" }
                        }
                        if (-not $cmd) { throw "Edge's uninstaller (setup.exe) was not found." }
                        $exe, $edgeArgs = Split-Command $cmd
                        Get-Process msedge -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

                        # Outside the EEA the uninstaller refuses unless these two markers exist.
                        # Both are temporary and are removed again right after the uninstaller exits.
                        $devKey     = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdateDev'
                        $hadDevKey  = Test-Path $devKey
                        $stubDir    = Join-Path $env:SystemRoot 'SystemApps\Microsoft.MicrosoftEdge_8wekyb3d8bbwe'
                        $stub       = Join-Path $stubDir 'MicrosoftEdge.exe'
                        $hadStubDir = Test-Path $stubDir
                        $hadStub    = Test-Path $stub
                        $exitCode   = $null
                        try {
                            try { New-Item $devKey -Force | Out-Null; New-ItemProperty $devKey -Name AllowUninstall -Value 1 -PropertyType DWord -Force | Out-Null }
                            catch { L "  note: could not set the AllowUninstall marker: $($_.Exception.Message)" }
                            try { if (-not $hadStub) { New-Item $stub -ItemType File -Force | Out-Null } }
                            catch { L "  note: could not create the legacy Edge marker: $($_.Exception.Message)" }
                            L '  running the Edge uninstaller (can take a minute)...'
                            $proc = Start-Process -FilePath $exe -ArgumentList "$edgeArgs --force-uninstall" -Wait -PassThru -WindowStyle Hidden
                            $exitCode = $proc.ExitCode
                            L "  uninstaller exit code: $exitCode"
                        } finally {
                            if (-not $hadStub)    { Remove-Item $stub -Force -ErrorAction SilentlyContinue }
                            if (-not $hadStubDir) { Remove-Item $stubDir -Recurse -Force -ErrorAction SilentlyContinue }
                            if ($hadDevKey) { Remove-ItemProperty $devKey -Name AllowUninstall -ErrorAction SilentlyContinue }
                            else { Remove-Item $devKey -Recurse -Force -ErrorAction SilentlyContinue }
                        }
                        Start-Sleep -Seconds 3
                        if (Test-Path $edgeExe) {
                            $r.Message = "Microsoft's uninstaller refused (exit code $exitCode). Edge is still installed. Its background and startup features can still be turned off on the Memory / RAM page."
                        } else {
                            # Documented Edge Update policy: stop Edge Update from silently reinstalling Edge Stable.
                            $pol = 'HKLM:\SOFTWARE\Policies\Microsoft\EdgeUpdate'
                            New-Item $pol -Force | Out-Null
                            New-ItemProperty $pol -Name 'Install{56EB18F8-B008-4CBD-B6D2-8C97FE7E9062}' -Value 0 -PropertyType DWord -Force | Out-Null
                            foreach ($lnk in "$env:PUBLIC\Desktop\Microsoft Edge.lnk", "$env:USERPROFILE\Desktop\Microsoft Edge.lnk",
                                             "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\Microsoft Edge.lnk",
                                             "$env:APPDATA\Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar\Microsoft Edge.lnk") {
                                Remove-Item $lnk -Force -ErrorAction SilentlyContinue
                            }
                            $r.Ok = $true; $r.Changed = $true
                            $r.Message = 'Removed. WebView2 Runtime kept.'
                            L '  Edge removed; WebView2 Runtime kept'
                        }
                    }
                }
                elseif ($it.Kind -eq 'OneDrive') {
                    $exes = @("$env:LOCALAPPDATA\Microsoft\OneDrive\OneDrive.exe", "$env:ProgramFiles\Microsoft OneDrive\OneDrive.exe", "${env:ProgramFiles(x86)}\Microsoft OneDrive\OneDrive.exe")
                    $cmds = @()
                    foreach ($k in 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\OneDriveSetup.exe',
                                   'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\OneDriveSetup.exe',
                                   'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\OneDriveSetup.exe') {
                        $u = (Get-ItemProperty $k -ErrorAction SilentlyContinue).UninstallString
                        if ($u) { $cmds += $u }
                    }
                    if (-not $cmds.Count) {
                        foreach ($s in "$env:SystemRoot\System32\OneDriveSetup.exe", "$env:SystemRoot\SysWOW64\OneDriveSetup.exe") {
                            if (Test-Path $s) { $cmds += "`"$s`" /uninstall"; break }
                        }
                    }
                    if (-not $cmds.Count) { throw "OneDrive's uninstaller was not found." }
                    Get-Process OneDrive -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
                    foreach ($c in $cmds) {
                        $exe, $odArgs = Split-Command $c
                        if (-not $odArgs) { $odArgs = '/uninstall' }
                        L "  running OneDrive uninstaller..."
                        $proc = Start-Process -FilePath $exe -ArgumentList $odArgs -Wait -PassThru -WindowStyle Hidden
                        L "  exit code: $($proc.ExitCode)"
                    }
                    Start-Sleep -Seconds 2
                    $left = @($exes | Where-Object { Test-Path $_ })
                    if ($left.Count) { $r.Message = "OneDrive is still present ($($left -join ', '))." }
                    else {
                        $r.Ok = $true; $r.Changed = $true
                        $r.Message = 'Removed. Your OneDrive folder and cloud files were not deleted.'
                    }
                }
            } catch {
                $r.Message = $_.Exception.Message
                L "  FAILED: $($r.Message)"
            }
            [void]$sync.Results.Add($r)
        }

        # Verify Store-app removals against a fresh package list - report what is actually gone.
        $appx = @($sync.Results | Where-Object { $_.Kind -eq 'Appx' })
        if ($appx.Count) {
            L 'Verifying removals...'
            $after = @(Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue)
            foreach ($r in $appx) {
                $left = @($after | Where-Object { (Test-Match $_.Name $r.Patterns) -and $_.Name -notmatch $protected } | ForEach-Object { $_.Name } | Sort-Object -Unique)
                if ($left.Count) { $r.Ok = $false; $r.Message = "Still installed: $($left -join ', ')" }
                else { $r.Ok = $true; $r.Message = 'Removed.' }
            }
        }
    } catch {
        $sync.Error = $_.Exception.Message
    } finally {
        $sync.Done = $true
    }
}

# ---------------------------------------------------------------------------
# 8. UI (WPF)
# ---------------------------------------------------------------------------
$xamlRaw = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="WinOptimizer" Width="1260" Height="824" MinWidth="1040" MinHeight="660"
        WindowStartupLocation="CenterScreen" Foreground="#1C2A3A"
        FontFamily="Segoe UI Variable Text, Segoe UI" FontSize="13"
        UseLayoutRounding="True" SnapsToDevicePixels="True" TextOptions.TextFormattingMode="Display">
  <Window.Background>
    <LinearGradientBrush StartPoint="0,0" EndPoint="0.35,1">
      <GradientStop Color="#E6F0FC" Offset="0"/>
      <GradientStop Color="#F4F8FD" Offset="0.5"/>
      <GradientStop Color="#FFFFFF" Offset="1"/>
    </LinearGradientBrush>
  </Window.Background>
  <Window.Resources>
    <FontFamily x:Key="Icons">Segoe Fluent Icons, Segoe MDL2 Assets</FontFamily>
    <FontFamily x:Key="TitleFont">Segoe UI Semilight, Segoe UI Light, Segoe UI</FontFamily>
    <SolidColorBrush x:Key="Accent" Color="__ACCENT__"/>
    <SolidColorBrush x:Key="AccentDark" Color="__ACCENTDARK__"/>
    <SolidColorBrush x:Key="AccentLight" Color="__ACCENTLIGHT__"/>
    <SolidColorBrush x:Key="Ink" Color="#1C2A3A"/>
    <SolidColorBrush x:Key="Muted" Color="#64748B"/>
    <SolidColorBrush x:Key="Faint" Color="#93A3B6"/>
    <SolidColorBrush x:Key="CardBrush" Color="#FFFFFF"/>
    <SolidColorBrush x:Key="CardBorder" Color="#E4EBF4"/>

    <LinearGradientBrush x:Key="HeroGrad" StartPoint="0,0" EndPoint="1,1">
      <GradientStop Color="#EAF3FF" Offset="0"/>
      <GradientStop Color="#F7FBFF" Offset="1"/>
    </LinearGradientBrush>

    <!-- Buttons -->
    <Style x:Key="Btn" TargetType="Button">
      <Setter Property="Foreground" Value="#243244"/>
      <Setter Property="Background" Value="#FFFFFF"/>
      <Setter Property="BorderBrush" Value="#D4DEEB"/>
      <Setter Property="Padding" Value="14,8"/>
      <Setter Property="Margin" Value="0,0,8,8"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="b" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="1" CornerRadius="8" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Background" Value="#F1F6FC"/></Trigger>
              <Trigger Property="IsPressed" Value="True"><Setter TargetName="b" Property="Background" Value="#E6EEF8"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter TargetName="b" Property="Opacity" Value="0.4"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="PrimaryBtn" TargetType="Button" BasedOn="{StaticResource Btn}">
      <Setter Property="Background" Value="{StaticResource Accent}"/>
      <Setter Property="BorderBrush" Value="Transparent"/>
      <Setter Property="Foreground" Value="White"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="b" Background="{TemplateBinding Background}" CornerRadius="8" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Background" Value="{StaticResource AccentDark}"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter TargetName="b" Property="Opacity" Value="0.4"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- Search box with watermark + magnifier -->
    <Style x:Key="Search" TargetType="TextBox">
      <Setter Property="Foreground" Value="#1C2A3A"/>
      <Setter Property="CaretBrush" Value="#1C2A3A"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TextBox">
            <Border Background="#FFFFFF" BorderBrush="#D4DEEB" BorderThickness="1" CornerRadius="8" Padding="10,7">
              <DockPanel>
                <TextBlock Text="&#xE721;" FontFamily="{StaticResource Icons}" Foreground="#9AA7B8" FontSize="13"
                           DockPanel.Dock="Left" Margin="0,0,8,0" VerticalAlignment="Center"/>
                <Grid>
                  <TextBlock x:Name="wm" Text="{TemplateBinding Tag}" Foreground="#9AA7B8" VerticalAlignment="Center" Visibility="Collapsed"/>
                  <ScrollViewer x:Name="PART_ContentHost" VerticalAlignment="Center"/>
                </Grid>
              </DockPanel>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="Text" Value=""><Setter TargetName="wm" Property="Visibility" Value="Visible"/></Trigger>
              <Trigger Property="IsKeyboardFocused" Value="True"><Setter Property="BorderBrush" Value="{StaticResource Accent}"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- Toggle switch -->
    <Style x:Key="Switch" TargetType="CheckBox">
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="CheckBox">
            <Grid Background="Transparent">
              <Border x:Name="Track" Width="46" Height="24" CornerRadius="12" Background="#D9E2EE" BorderBrush="#C4D1E2" BorderThickness="1"/>
              <Ellipse x:Name="Knob" Width="16" Height="16" Fill="#FFFFFF" HorizontalAlignment="Left" Margin="5,0,0,0">
                <Ellipse.Effect><DropShadowEffect BlurRadius="4" ShadowDepth="0.5" Opacity="0.3" Color="#4A5A70"/></Ellipse.Effect>
              </Ellipse>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="Track" Property="Background" Value="{StaticResource Accent}"/>
                <Setter TargetName="Track" Property="BorderBrush" Value="Transparent"/>
                <Setter TargetName="Knob" Property="Margin" Value="25,0,0,0"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.4"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- Slim scrollbars -->
    <Style TargetType="ScrollBar">
      <Setter Property="Width" Value="10"/><Setter Property="MinWidth" Value="10"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ScrollBar">
            <Track x:Name="PART_Track" Orientation="Vertical" IsDirectionReversed="True" Width="6" HorizontalAlignment="Center">
              <Track.Thumb>
                <Thumb><Thumb.Template><ControlTemplate TargetType="Thumb"><Border Background="#C2D0E0" CornerRadius="3"/></ControlTemplate></Thumb.Template></Thumb>
              </Track.Thumb>
            </Track>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
      <Style.Triggers>
        <Trigger Property="Orientation" Value="Horizontal">
          <Setter Property="Width" Value="Auto"/><Setter Property="MinWidth" Value="0"/><Setter Property="Height" Value="10"/><Setter Property="MinHeight" Value="10"/>
          <Setter Property="Template">
            <Setter.Value>
              <ControlTemplate TargetType="ScrollBar">
                <Track x:Name="PART_Track" Orientation="Horizontal" Height="6" VerticalAlignment="Center">
                  <Track.Thumb><Thumb><Thumb.Template><ControlTemplate TargetType="Thumb"><Border Background="#C2D0E0" CornerRadius="3"/></ControlTemplate></Thumb.Template></Thumb></Track.Thumb>
                </Track>
              </ControlTemplate>
            </Setter.Value>
          </Setter>
        </Trigger>
      </Style.Triggers>
    </Style>

    <Style x:Key="Meter" TargetType="ProgressBar">
      <Setter Property="Height" Value="8"/><Setter Property="Maximum" Value="100"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ProgressBar">
            <Grid>
              <Border x:Name="PART_Track" Background="#E8EEF6" CornerRadius="4"/>
              <Border x:Name="PART_Indicator" Background="{TemplateBinding Foreground}" CornerRadius="4" HorizontalAlignment="Left"/>
            </Grid>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- Sidebar nav -->
    <Style TargetType="TabItem">
      <Setter Property="Foreground" Value="#5A6A7E"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TabItem">
            <Grid Margin="12,2">
              <Border x:Name="bd" Background="Transparent" CornerRadius="8" Padding="14,10">
                <ContentPresenter ContentSource="Header"/>
              </Border>
              <Border x:Name="bar" Width="3" CornerRadius="2" HorizontalAlignment="Left" Margin="0,9"
                      Background="{StaticResource Accent}" Visibility="Collapsed"/>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="Background" Value="#EAF1FA"/>
                <Setter Property="Foreground" Value="#1C2A3A"/>
              </Trigger>
              <Trigger Property="IsSelected" Value="True">
                <Setter TargetName="bd" Property="Background" Value="{StaticResource AccentLight}"/>
                <Setter TargetName="bar" Property="Visibility" Value="Visible"/>
                <Setter Property="Foreground" Value="{StaticResource AccentDark}"/>
                <Setter Property="FontWeight" Value="SemiBold"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="Card" TargetType="Border">
      <Setter Property="Background" Value="#FFFFFF"/>
      <Setter Property="BorderBrush" Value="#E4EBF4"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="CornerRadius" Value="12"/>
      <Setter Property="Effect"><Setter.Value><DropShadowEffect BlurRadius="14" ShadowDepth="2" Opacity="0.07" Color="#2B4A73"/></Setter.Value></Setter>
    </Style>

    <Style x:Key="PageTitle" TargetType="TextBlock">
      <Setter Property="FontSize" Value="28"/><Setter Property="FontFamily" Value="{StaticResource TitleFont}"/><Setter Property="Foreground" Value="#152235"/>
    </Style>
    <Style x:Key="PageSub" TargetType="TextBlock">
      <Setter Property="Foreground" Value="#64748B"/><Setter Property="TextWrapping" Value="Wrap"/>
      <Setter Property="MaxWidth" Value="880"/><Setter Property="HorizontalAlignment" Value="Left"/>
      <Setter Property="LineHeight" Value="20"/><Setter Property="Margin" Value="0,6,0,14"/>
    </Style>
    <Style x:Key="StatLabel" TargetType="TextBlock">
      <Setter Property="Foreground" Value="#7686A0"/><Setter Property="FontSize" Value="11"/><Setter Property="FontWeight" Value="Bold"/>
    </Style>

    <Style TargetType="GridViewColumnHeader">
      <Setter Property="Foreground" Value="#8094AC"/><Setter Property="FontSize" Value="11"/><Setter Property="FontWeight" Value="Bold"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="GridViewColumnHeader">
            <Border Background="Transparent" BorderBrush="#EAEFF6" BorderThickness="0,0,0,1" Padding="8,0,8,8"><ContentPresenter HorizontalAlignment="Left"/></Border>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="ListViewItem">
      <Setter Property="Foreground" Value="#243244"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ListViewItem">
            <Border x:Name="b" Background="Transparent" CornerRadius="6" Padding="0,6">
              <GridViewRowPresenter Columns="{TemplateBinding GridView.ColumnCollection}" Content="{TemplateBinding Content}"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Background" Value="#F2F7FC"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="ListBoxItem">
      <Setter Property="Foreground" Value="#243244"/><Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ListBoxItem">
            <Border x:Name="b" Background="#FFFFFF" BorderBrush="#E4EBF4" BorderThickness="1" CornerRadius="10" Padding="16,12" Margin="0,0,0,8"><ContentPresenter/></Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="BorderBrush" Value="#C2D4EA"/></Trigger>
              <Trigger Property="IsSelected" Value="True">
                <Setter TargetName="b" Property="BorderBrush" Value="{StaticResource Accent}"/>
                <Setter TargetName="b" Property="Background" Value="{StaticResource AccentLight}"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- One card per tweak / app -->
    <DataTemplate x:Key="TweakTemplate">
      <Border Style="{StaticResource Card}" Padding="20,16" Margin="0,0,14,10">
        <Grid>
          <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
          <StackPanel>
            <WrapPanel>
              <TextBlock Text="{Binding Name}" FontSize="15" FontWeight="SemiBold" Foreground="#152235" VerticalAlignment="Center" Margin="0,0,10,0"/>
              <Border Background="{Binding RiskBg}" CornerRadius="10" Padding="9,2" VerticalAlignment="Center">
                <TextBlock Text="{Binding Risk}" Foreground="{Binding RiskColor}" FontSize="11" FontWeight="Bold"/>
              </Border>
            </WrapPanel>
            <TextBlock Text="{Binding Description}" TextWrapping="Wrap" Foreground="#5A6A7E" Margin="0,7,0,0" LineHeight="19"/>
            <Grid Margin="0,9,0,0">
              <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
              <TextBlock Text="&#xE946;" FontFamily="{StaticResource Icons}" Foreground="#8A79D6" FontSize="12" Margin="0,3,8,0"/>
              <TextBlock Grid.Column="1" Text="{Binding Tradeoff}" TextWrapping="Wrap" Foreground="#6B5FB0" FontSize="12" LineHeight="18"/>
            </Grid>
          </StackPanel>
          <StackPanel Grid.Column="1" Margin="28,0,0,0" MinWidth="130">
            <CheckBox Style="{StaticResource Switch}" HorizontalAlignment="Right"
                      IsChecked="{Binding IsSelected, Mode=TwoWay, UpdateSourceTrigger=PropertyChanged}" IsEnabled="{Binding IsAvailable}"/>
            <TextBlock Text="{Binding Status}" Foreground="{Binding StatusColor}" FontSize="11" Margin="0,10,0,0"
                       HorizontalAlignment="Right" TextAlignment="Right" TextWrapping="Wrap" MaxWidth="170"/>
          </StackPanel>
        </Grid>
      </Border>
    </DataTemplate>
  </Window.Resources>

  <Grid>
    <Grid.RowDefinitions><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>

    <TabControl x:Name="Tabs" TabStripPlacement="Left" BorderThickness="0" Padding="0" Background="Transparent">
      <TabControl.Template>
        <ControlTemplate TargetType="TabControl">
          <Grid>
            <Grid.ColumnDefinitions><ColumnDefinition Width="248"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
            <Border Background="#F6F9FD" BorderBrush="#E4EBF4" BorderThickness="0,0,1,0">
              <DockPanel>
                <StackPanel DockPanel.Dock="Top" Orientation="Horizontal" Margin="22,26,12,26">
                  <Border Width="42" Height="42" CornerRadius="11">
                    <Border.Background>
                      <LinearGradientBrush StartPoint="0,0" EndPoint="0,1">
                        <GradientStop Color="#3896E8" Offset="0"/><GradientStop Color="#0A6ED2" Offset="1"/>
                      </LinearGradientBrush>
                    </Border.Background>
                    <TextBlock Text="&#xEC4A;" FontFamily="{StaticResource Icons}" Foreground="White" FontSize="21" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                  </Border>
                  <StackPanel Margin="12,0,0,0" VerticalAlignment="Center">
                    <TextBlock Text="WinOptimizer" FontSize="20" FontFamily="{StaticResource TitleFont}" Foreground="#152235"/>
                    <TextBlock Text="Safe, reversible tuning" FontSize="11" Foreground="#8094AC"/>
                  </StackPanel>
                </StackPanel>
                <Border DockPanel.Dock="Bottom" Margin="16,0,16,18" Padding="14,12" CornerRadius="10" Background="#ECFDF3" BorderBrush="#CBEFD8" BorderThickness="1">
                  <Grid>
                    <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                    <TextBlock Text="&#xEA18;" FontFamily="{StaticResource Icons}" Foreground="#16A34A" FontSize="16" Margin="0,1,10,0"/>
                    <TextBlock Grid.Column="1" TextWrapping="Wrap" Foreground="#3F7A54" FontSize="11" LineHeight="16"
                               Text="Every setting change is backed up and can be undone from Backup &amp; Restore."/>
                  </Grid>
                </Border>
                <StackPanel IsItemsHost="True"/>
              </DockPanel>
            </Border>
            <ContentPresenter Grid.Column="1" ContentSource="SelectedContent" Margin="32,26,20,14"/>
          </Grid>
        </ControlTemplate>
      </TabControl.Template>

      <!-- DASHBOARD -->
      <TabItem>
        <TabItem.Header><StackPanel Orientation="Horizontal">
          <TextBlock Text="&#xE80F;" FontFamily="{StaticResource Icons}" FontSize="16" Width="30" VerticalAlignment="Center"/>
          <TextBlock Text="Dashboard" FontSize="14" VerticalAlignment="Center"/></StackPanel></TabItem.Header>
        <Grid Margin="0,0,14,0">
          <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>

          <Border CornerRadius="16" Padding="28,24" Margin="0,0,0,18" Background="{StaticResource HeroGrad}" BorderBrush="#DCEAFB" BorderThickness="1">
            <Grid>
              <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
              <StackPanel>
                <TextBlock Text="Your PC at a glance" FontSize="28" FontFamily="{StaticResource TitleFont}" Foreground="#152235"/>
                <TextBlock x:Name="SysInfo" Foreground="#4C6180" Margin="0,8,0,0" TextWrapping="Wrap" Text="Loading..."/>
                <TextBlock x:Name="GpuLine" Foreground="#6B7E98" FontSize="12" Margin="0,3,0,0" TextWrapping="Wrap"/>
              </StackPanel>
              <StackPanel Grid.Column="1" VerticalAlignment="Center" Margin="20,0,0,0">
                <Button x:Name="BtnQuick" Style="{StaticResource PrimaryBtn}" Margin="0" Padding="20,11">
                  <TextBlock Text="Quick optimize"/>
                </Button>
                <TextBlock Text="Safe, recommended settings only" Foreground="#6B7E98" FontSize="11" Margin="0,8,0,0" HorizontalAlignment="Center"/>
              </StackPanel>
            </Grid>
          </Border>

          <UniformGrid Grid.Row="1" Columns="3" Margin="0,0,0,18">
            <Border Style="{StaticResource Card}" Padding="22,18" Margin="0,0,9,0">
              <StackPanel>
                <StackPanel Orientation="Horizontal">
                  <TextBlock Text="&#xE964;" FontFamily="{StaticResource Icons}" Foreground="{StaticResource Accent}" Margin="0,0,8,0"/>
                  <TextBlock Text="MEMORY IN USE" Style="{StaticResource StatLabel}"/>
                </StackPanel>
                <TextBlock x:Name="RamText" FontSize="29" FontWeight="SemiBold" Foreground="#152235" Margin="0,10,0,10" Text="-"/>
                <ProgressBar x:Name="RamBar" Style="{StaticResource Meter}" Foreground="{StaticResource Accent}"/>
                <TextBlock x:Name="RamSub" Foreground="#7686A0" FontSize="12" Margin="0,10,0,0"/>
              </StackPanel>
            </Border>
            <Border Style="{StaticResource Card}" Padding="22,18" Margin="9,0,9,0">
              <StackPanel>
                <StackPanel Orientation="Horizontal">
                  <TextBlock Text="&#xEC4A;" FontFamily="{StaticResource Icons}" Foreground="#0EA5A5" Margin="0,0,8,0"/>
                  <TextBlock Text="CPU LOAD" Style="{StaticResource StatLabel}"/>
                </StackPanel>
                <TextBlock x:Name="CpuText" FontSize="29" FontWeight="SemiBold" Foreground="#152235" Margin="0,10,0,10" Text="-"/>
                <ProgressBar x:Name="CpuBar" Style="{StaticResource Meter}" Foreground="#0EA5A5"/>
                <TextBlock x:Name="PlanText" Foreground="#7686A0" FontSize="12" Margin="0,10,0,0"/>
              </StackPanel>
            </Border>
            <Border Style="{StaticResource Card}" Padding="22,18" Margin="9,0,0,0">
              <StackPanel>
                <StackPanel Orientation="Horizontal">
                  <TextBlock Text="&#xE81C;" FontFamily="{StaticResource Icons}" Foreground="#16A34A" Margin="0,0,8,0"/>
                  <TextBlock Text="SINCE LAST APPLY" Style="{StaticResource StatLabel}"/>
                </StackPanel>
                <TextBlock x:Name="DeltaText" FontSize="29" FontWeight="SemiBold" Foreground="#16A34A" Margin="0,10,0,6" Text="-"/>
                <TextBlock x:Name="DeltaSub" Foreground="#7686A0" FontSize="12" TextWrapping="Wrap" LineHeight="17"
                           Text="Apply changes, then restart, to see the real difference."/>
              </StackPanel>
            </Border>
          </UniformGrid>

          <Border Grid.Row="2" Style="{StaticResource Card}" Padding="22,18">
            <DockPanel>
              <DockPanel DockPanel.Dock="Top" Margin="0,0,0,14">
                <Button x:Name="BtnRefreshProc" DockPanel.Dock="Right" Style="{StaticResource Btn}" Margin="0" VerticalAlignment="Center">
                  <StackPanel Orientation="Horizontal"><TextBlock Text="&#xE72C;" FontFamily="{StaticResource Icons}" Margin="0,1,8,0"/><TextBlock Text="Refresh"/></StackPanel>
                </Button>
                <StackPanel VerticalAlignment="Center">
                  <TextBlock Text="Top processes by memory" FontSize="16" FontWeight="SemiBold" Foreground="#152235"/>
                  <TextBlock x:Name="ProcNote" Foreground="#8094AC" FontSize="11" Margin="0,3,0,0"
                             Text="Memory = private working set (Task Manager's Memory column).  Double-click an app to end it or pause it."/>
                </StackPanel>
              </DockPanel>
              <ListView x:Name="ProcList" Background="Transparent" BorderThickness="0" Foreground="#243244"
                        ScrollViewer.HorizontalScrollBarVisibility="Disabled"
                        VirtualizingPanel.IsVirtualizing="True" VirtualizingPanel.VirtualizationMode="Recycling">
                <ListView.View>
                  <GridView>
                    <GridViewColumn Header="PROCESS" Width="320" DisplayMemberBinding="{Binding Name}"/>
                    <GridViewColumn Header="INSTANCES" Width="100" DisplayMemberBinding="{Binding Count}"/>
                    <GridViewColumn Header="MEMORY (MB)" Width="130" DisplayMemberBinding="{Binding MB}"/>
                    <GridViewColumn Header="CPU" Width="90" DisplayMemberBinding="{Binding CpuText}"/>
                  </GridView>
                </ListView.View>
              </ListView>
            </DockPanel>
          </Border>
        </Grid>
      </TabItem>

      <!-- MEMORY -->
      <TabItem>
        <TabItem.Header><StackPanel Orientation="Horizontal">
          <TextBlock Text="&#xE964;" FontFamily="{StaticResource Icons}" FontSize="16" Width="30" VerticalAlignment="Center"/>
          <TextBlock Text="Memory &amp; RAM" FontSize="14" VerticalAlignment="Center"/></StackPanel></TabItem.Header>
        <DockPanel>
          <StackPanel DockPanel.Dock="Top">
            <TextBlock Text="Memory &amp; RAM" Style="{StaticResource PageTitle}"/>
            <TextBlock Style="{StaticResource PageSub}"
                       Text="Background services and features Windows runs by default. Green = safe for almost everyone. Yellow = read the trade-off first. Settings are only changed, never deleted, so all of them can be undone."/>
            <DockPanel Margin="0,0,0,2">
              <TextBox x:Name="MemSearch" DockPanel.Dock="Right" Style="{StaticResource Search}" Width="240" Height="34" Margin="8,0,0,8" Tag="Search memory settings..."/>
              <WrapPanel>
                <Button x:Name="BtnMemRec" Content="Select recommended" Style="{StaticResource Btn}"/>
                <Button x:Name="BtnMemNone" Content="Select none" Style="{StaticResource Btn}"/>
                <Button x:Name="BtnTrim" Content="Trim RAM now (temporary)" Style="{StaticResource Btn}"
                        ToolTip="Asks every process to release unused pages. Windows pages memory back in as apps need it, so the effect is short-lived."/>
              </WrapPanel>
            </DockPanel>
          </StackPanel>
          <ScrollViewer VerticalScrollBarVisibility="Auto" Margin="0,8,0,0"><ItemsControl x:Name="MemList" ItemTemplate="{StaticResource TweakTemplate}"/></ScrollViewer>
        </DockPanel>
      </TabItem>

      <!-- BLOATWARE -->
      <TabItem>
        <TabItem.Header><StackPanel Orientation="Horizontal">
          <TextBlock Text="&#xE74D;" FontFamily="{StaticResource Icons}" FontSize="16" Width="30" VerticalAlignment="Center"/>
          <TextBlock Text="Remove bloatware" FontSize="14" VerticalAlignment="Center"/></StackPanel></TabItem.Header>
        <DockPanel>
          <StackPanel DockPanel.Dock="Top">
            <TextBlock Text="Remove bloatware" Style="{StaticResource PageTitle}"/>
            <TextBlock Style="{StaticResource PageSub}"
                       Text="Preinstalled apps found on this PC. Only apps on a curated list are shown - the Store, app installer, security, drivers and system components can never be removed here. Nothing is selected until you choose."/>
            <Border Background="#FFF8E7" BorderBrush="#F4E0A8" BorderThickness="1" CornerRadius="10" Padding="14,10" Margin="0,0,0,14" MaxWidth="880" HorizontalAlignment="Left">
              <Grid>
                <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                <TextBlock Text="&#xE7BA;" FontFamily="{StaticResource Icons}" Foreground="#C77F0A" FontSize="15" Margin="0,1,10,0"/>
                <TextBlock Grid.Column="1" TextWrapping="Wrap" Foreground="#8A6514" FontSize="12" LineHeight="18"
                           Text="Uninstalling removes the app for every user on this PC and stops Windows reinstalling it for new accounts. Unlike settings, an uninstall cannot be undone with one click - but every Store app can be reinstalled for free, and Backup &amp; Restore gives you a direct link to each one."/>
              </Grid>
            </Border>
            <DockPanel Margin="0,0,0,2">
              <TextBox x:Name="BloatSearch" DockPanel.Dock="Right" Style="{StaticResource Search}" Width="240" Height="34" Margin="8,0,0,8" Tag="Search apps..."/>
              <WrapPanel>
                <Button x:Name="BtnBloatRec" Content="Select recommended" Style="{StaticResource Btn}"/>
                <Button x:Name="BtnBloatNone" Content="Select none" Style="{StaticResource Btn}"/>
                <Button x:Name="BtnBloatRescan" Style="{StaticResource Btn}">
                  <StackPanel Orientation="Horizontal"><TextBlock Text="&#xE72C;" FontFamily="{StaticResource Icons}" Margin="0,1,8,0"/><TextBlock Text="Rescan"/></StackPanel>
                </Button>
                <TextBlock x:Name="BloatStatus" Foreground="#64748B" VerticalAlignment="Center" Margin="6,0,0,8" Text="Scanning installed apps..."/>
              </WrapPanel>
            </DockPanel>
          </StackPanel>
          <ScrollViewer VerticalScrollBarVisibility="Auto" Margin="0,8,0,0">
            <ItemsControl x:Name="BloatList" ItemTemplate="{StaticResource TweakTemplate}">
              <ItemsControl.GroupStyle>
                <GroupStyle>
                  <GroupStyle.HeaderTemplate><DataTemplate>
                    <TextBlock Text="{Binding Name}" FontSize="12" FontWeight="Bold" Foreground="#8094AC" Margin="2,10,0,10"/>
                  </DataTemplate></GroupStyle.HeaderTemplate>
                </GroupStyle>
              </ItemsControl.GroupStyle>
            </ItemsControl>
          </ScrollViewer>
        </DockPanel>
      </TabItem>

      <!-- STARTUP -->
      <TabItem>
        <TabItem.Header><StackPanel Orientation="Horizontal">
          <TextBlock Text="&#xE7E8;" FontFamily="{StaticResource Icons}" FontSize="16" Width="30" VerticalAlignment="Center"/>
          <TextBlock Text="Startup apps" FontSize="14" VerticalAlignment="Center"/></StackPanel></TabItem.Header>
        <DockPanel>
          <StackPanel DockPanel.Dock="Top">
            <TextBlock Text="Startup apps" Style="{StaticResource PageTitle}"/>
            <TextBlock Style="{StaticResource PageSub}"
                       Text="Programs that launch when you sign in - usually the biggest source of avoidable RAM use. Switching one on disables it at startup exactly like Task Manager does (nothing is deleted). Windows Security is hidden and never touched."/>
            <DockPanel Margin="0,0,0,2">
              <TextBox x:Name="StartSearch" DockPanel.Dock="Right" Style="{StaticResource Search}" Width="240" Height="34" Margin="8,0,0,8" Tag="Search startup apps..."/>
              <WrapPanel>
                <Button x:Name="BtnStartNone" Content="Select none" Style="{StaticResource Btn}"/>
                <Button x:Name="BtnStartReload" Content="Reload list" Style="{StaticResource Btn}"/>
              </WrapPanel>
            </DockPanel>
          </StackPanel>
          <ScrollViewer VerticalScrollBarVisibility="Auto" Margin="0,8,0,0"><ItemsControl x:Name="StartList" ItemTemplate="{StaticResource TweakTemplate}"/></ScrollViewer>
        </DockPanel>
      </TabItem>

      <TabItem>
        <TabItem.Header><StackPanel Orientation="Horizontal">
          <TextBlock Text="&#xE8B7;" FontFamily="{StaticResource Icons}" FontSize="16" Width="30" VerticalAlignment="Center"/>
          <TextBlock Text="Explorer &amp; UI" FontSize="14" VerticalAlignment="Center"/></StackPanel></TabItem.Header>
        <DockPanel>
          <StackPanel DockPanel.Dock="Top">
            <TextBlock Text="Explorer &amp; UI" Style="{StaticResource PageTitle}"/>
            <TextBlock Style="{StaticResource PageSub}" Text="Explorer, taskbar and theme tweaks - classic right-click menu, show file extensions, dark mode, taskbar cleanup. All reversible."/>
            <DockPanel Margin="0,0,0,2">
              <TextBox x:Name="UiSearch" DockPanel.Dock="Right" Style="{StaticResource Search}" Width="240" Height="34" Margin="8,0,0,8" Tag="Search UI tweaks..."/>
              <WrapPanel>
                <Button x:Name="BtnUiRec" Content="Select recommended" Style="{StaticResource Btn}"/>
                <Button x:Name="BtnUiNone" Content="Select none" Style="{StaticResource Btn}"/>
              </WrapPanel>
            </DockPanel>
          </StackPanel>
          <ScrollViewer VerticalScrollBarVisibility="Auto" Margin="0,8,0,0"><ItemsControl x:Name="UiList" ItemTemplate="{StaticResource TweakTemplate}"/></ScrollViewer>
        </DockPanel>
      </TabItem>

      <TabItem>
        <TabItem.Header><StackPanel Orientation="Horizontal">
          <TextBlock Text="&#xE72E;" FontFamily="{StaticResource Icons}" FontSize="16" Width="30" VerticalAlignment="Center"/>
          <TextBlock Text="Privacy &amp; AI" FontSize="14" VerticalAlignment="Center"/></StackPanel></TabItem.Header>
        <DockPanel>
          <StackPanel DockPanel.Dock="Top">
            <TextBlock Text="Privacy &amp; AI" Style="{StaticResource PageTitle}"/>
            <TextBlock Style="{StaticResource PageSub}" Text="Turn off Recall, Copilot and app AI (Paint/Notepad/Edge), advertising ID, activity history and telemetry. Block telemetry servers or change DNS. All reversible."/>
            <DockPanel Margin="0,0,0,2">
              <TextBox x:Name="PrivSearch" DockPanel.Dock="Right" Style="{StaticResource Search}" Width="240" Height="34" Margin="8,0,0,8" Tag="Search privacy tweaks..."/>
              <WrapPanel>
                <Button x:Name="BtnPrivRec" Content="Select recommended" Style="{StaticResource Btn}"/>
                <Button x:Name="BtnPrivNone" Content="Select none" Style="{StaticResource Btn}"/>
              </WrapPanel>
            </DockPanel>
          </StackPanel>
          <ScrollViewer VerticalScrollBarVisibility="Auto" Margin="0,8,0,0"><ItemsControl x:Name="PrivList" ItemTemplate="{StaticResource TweakTemplate}"/></ScrollViewer>
        </DockPanel>
      </TabItem>

      <!-- CPU -->
      <TabItem>
        <TabItem.Header><StackPanel Orientation="Horizontal">
          <TextBlock Text="&#xEC4A;" FontFamily="{StaticResource Icons}" FontSize="16" Width="30" VerticalAlignment="Center"/>
          <TextBlock Text="CPU" FontSize="14" VerticalAlignment="Center"/></StackPanel></TabItem.Header>
        <DockPanel>
          <StackPanel DockPanel.Dock="Top">
            <TextBlock Text="CPU" Style="{StaticResource PageTitle}"/>
            <TextBlock Style="{StaticResource PageSub}"
                       Text="Scheduling and power settings that favour responsiveness and games. Expect smoother frame times and snappier input rather than much higher average FPS."/>
            <DockPanel Margin="0,0,0,2">
              <TextBox x:Name="CpuSearch" DockPanel.Dock="Right" Style="{StaticResource Search}" Width="240" Height="34" Margin="8,0,0,8" Tag="Search CPU settings..."/>
              <WrapPanel>
                <Button x:Name="BtnCpuRec" Content="Select recommended" Style="{StaticResource Btn}"/>
                <Button x:Name="BtnCpuNone" Content="Select none" Style="{StaticResource Btn}"/>
              </WrapPanel>
            </DockPanel>
          </StackPanel>
          <ScrollViewer VerticalScrollBarVisibility="Auto" Margin="0,8,0,0"><ItemsControl x:Name="CpuList" ItemTemplate="{StaticResource TweakTemplate}"/></ScrollViewer>
        </DockPanel>
      </TabItem>

      <!-- GPU -->
      <TabItem>
        <TabItem.Header><StackPanel Orientation="Horizontal">
          <TextBlock Text="&#xE7F4;" FontFamily="{StaticResource Icons}" FontSize="16" Width="30" VerticalAlignment="Center"/>
          <TextBlock Text="GPU" FontSize="14" VerticalAlignment="Center"/></StackPanel></TabItem.Header>
        <DockPanel>
          <StackPanel DockPanel.Dock="Top">
            <TextBlock Text="GPU" Style="{StaticResource PageTitle}"/>
            <TextBlock x:Name="GpuInfo" Style="{StaticResource PageSub}"/>
            <DockPanel Margin="0,0,0,2">
              <TextBox x:Name="GpuSearch" DockPanel.Dock="Right" Style="{StaticResource Search}" Width="240" Height="34" Margin="8,0,0,8" Tag="Search GPU settings..."/>
              <WrapPanel>
                <Button x:Name="BtnGpuRec" Content="Select recommended" Style="{StaticResource Btn}"/>
                <Button x:Name="BtnGpuNone" Content="Select none" Style="{StaticResource Btn}"/>
              </WrapPanel>
            </DockPanel>
          </StackPanel>
          <ScrollViewer VerticalScrollBarVisibility="Auto" Margin="0,8,0,0"><ItemsControl x:Name="GpuList" ItemTemplate="{StaticResource TweakTemplate}"/></ScrollViewer>
        </DockPanel>
      </TabItem>

      <TabItem>
        <TabItem.Header><StackPanel Orientation="Horizontal">
          <TextBlock Text="&#xE895;" FontFamily="{StaticResource Icons}" FontSize="16" Width="30" VerticalAlignment="Center"/>
          <TextBlock Text="Windows Update" FontSize="14" VerticalAlignment="Center"/></StackPanel></TabItem.Header>
        <DockPanel>
          <StackPanel DockPanel.Dock="Top">
            <TextBlock Text="Windows Update" Style="{StaticResource PageTitle}"/>
            <TextBlock Style="{StaticResource PageSub}" Text="Control how and when Windows updates: stop forced restarts, defer feature updates, exclude drivers, or disable auto-updates entirely (advanced). All reversible."/>
            <DockPanel Margin="0,0,0,2">
              <TextBox x:Name="UpdSearch" DockPanel.Dock="Right" Style="{StaticResource Search}" Width="240" Height="34" Margin="8,0,0,8" Tag="Search update options..."/>
              <WrapPanel>
                <Button x:Name="BtnUpdRec" Content="Select recommended" Style="{StaticResource Btn}"/>
                <Button x:Name="BtnUpdNone" Content="Select none" Style="{StaticResource Btn}"/>
              </WrapPanel>
            </DockPanel>
          </StackPanel>
          <ScrollViewer VerticalScrollBarVisibility="Auto" Margin="0,8,0,0"><ItemsControl x:Name="UpdList" ItemTemplate="{StaticResource TweakTemplate}"/></ScrollViewer>
        </DockPanel>
      </TabItem>

      <TabItem>
        <TabItem.Header><StackPanel Orientation="Horizontal">
          <TextBlock Text="&#xE769;" FontFamily="{StaticResource Icons}" FontSize="16" Width="30" VerticalAlignment="Center"/>
          <TextBlock Text="Paused Tasks" FontSize="14" VerticalAlignment="Center"/></StackPanel></TabItem.Header>
        <DockPanel Margin="0,0,14,0">
          <StackPanel DockPanel.Dock="Top">
            <TextBlock Text="Paused Tasks" Style="{StaticResource PageTitle}"/>
            <TextBlock Style="{StaticResource PageSub}"
                       Text="Apps you paused from the Dashboard. A paused app cannot launch until its timer runs out, or until you lift it here. Pausing uses Image File Execution Options and auto-expires with a scheduled task."/>
            <WrapPanel>
              <Button x:Name="BtnPausedRefresh" Style="{StaticResource Btn}">
                <StackPanel Orientation="Horizontal"><TextBlock Text="&#xE72C;" FontFamily="{StaticResource Icons}" Margin="0,1,8,0"/><TextBlock Text="Refresh"/></StackPanel>
              </Button>
              <Button x:Name="BtnResumeAll" Content="Resume all" Style="{StaticResource Btn}"/>
            </WrapPanel>
          </StackPanel>
          <ScrollViewer VerticalScrollBarVisibility="Auto" Margin="0,8,0,0"><StackPanel x:Name="PausedList"/></ScrollViewer>
        </DockPanel>
      </TabItem>

      <!-- RESTORE -->
      <TabItem>
        <TabItem.Header><StackPanel Orientation="Horizontal">
          <TextBlock Text="&#xE81C;" FontFamily="{StaticResource Icons}" FontSize="16" Width="30" VerticalAlignment="Center"/>
          <TextBlock Text="Backup &amp; Restore" FontSize="14" VerticalAlignment="Center"/></StackPanel></TabItem.Header>
        <DockPanel Margin="0,0,14,0">
          <StackPanel DockPanel.Dock="Top">
            <TextBlock Text="Backup &amp; Restore" Style="{StaticResource PageTitle}"/>
            <TextBlock Style="{StaticResource PageSub}"
                       Text="Every apply saves the previous value of everything it changed. Restoring puts those exact values back, and lists any removed apps with a direct link to reinstall them. For a full rollback you can also use the System Restore point created before applying."/>
            <WrapPanel>
              <Button x:Name="BtnRestore" Style="{StaticResource PrimaryBtn}">
                <StackPanel Orientation="Horizontal"><TextBlock Text="&#xE777;" FontFamily="{StaticResource Icons}" Margin="0,1,8,0"/><TextBlock Text="Restore selected backup"/></StackPanel>
              </Button>
              <Button x:Name="BtnRestorePoint" Content="Create restore point now" Style="{StaticResource Btn}"/>
              <Button x:Name="BtnOpenSysRestore" Content="Open System Restore" Style="{StaticResource Btn}"/>
              <Button x:Name="BtnOpenFolder" Content="Open backup folder" Style="{StaticResource Btn}"/>
              <Button x:Name="BtnExport" Content="Export preset" Style="{StaticResource Btn}"
                      ToolTip="Save the currently ticked changes to a .json file you can reapply on another PC."/>
              <Button x:Name="BtnImport" Content="Import preset" Style="{StaticResource Btn}"
                      ToolTip="Load a .json preset and tick its changes."/>
            </WrapPanel>
          </StackPanel>
          <ListBox x:Name="BackupList" Background="Transparent" BorderThickness="0" Margin="0,8,0,0" ScrollViewer.HorizontalScrollBarVisibility="Disabled"/>
        </DockPanel>
      </TabItem>
    </TabControl>

    <!-- Bottom bar -->
    <Border Grid.Row="1" Background="#F6F9FD" BorderBrush="#E4EBF4" BorderThickness="0,1,0,0" Padding="24,12">
      <Grid>
        <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
        <DockPanel>
          <StackPanel x:Name="BusyPanel" DockPanel.Dock="Top" Orientation="Horizontal" Margin="0,0,0,6" Visibility="Collapsed">
            <Ellipse Width="8" Height="8" Fill="{StaticResource Accent}" VerticalAlignment="Center" Margin="0,0,8,0"/>
            <TextBlock x:Name="BusyText" Foreground="{StaticResource AccentDark}" FontWeight="SemiBold"/>
          </StackPanel>
          <TextBox x:Name="LogBox" Height="74" IsReadOnly="True" Background="#FFFFFF" Foreground="#5A6A7E" BorderBrush="#E4EBF4"
                   FontFamily="Cascadia Mono, Consolas" FontSize="11" VerticalScrollBarVisibility="Auto"
                   HorizontalScrollBarVisibility="Auto" TextWrapping="NoWrap" Padding="8,6"/>
        </DockPanel>
        <StackPanel Grid.Column="1" Margin="22,0,0,0" VerticalAlignment="Center">
          <TextBlock x:Name="SelCount" Foreground="#64748B" HorizontalAlignment="Right" Margin="0,0,0,8" Text="0 changes selected"/>
          <Button x:Name="BtnApply" Style="{StaticResource PrimaryBtn}" Margin="0" Padding="26,12" FontSize="14">
            <StackPanel Orientation="Horizontal"><TextBlock Text="&#xE73E;" FontFamily="{StaticResource Icons}" Margin="0,2,9,0"/><TextBlock Text="Review &amp; apply"/></StackPanel>
          </Button>
        </StackPanel>
      </Grid>
    </Border>
  </Grid>
</Window>
'@

function Get-SystemAccent {
    # The Windows accent colour (DWM AccentColor is stored as 0xAABBGGRR). Fall back to a clean blue.
    $fallback = '#0A84FF'
    try {
        $v = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\DWM' -Name AccentColor -ErrorAction Stop).AccentColor
        $r = $v -band 0xFF; $g = ($v -shr 8) -band 0xFF; $b = ($v -shr 16) -band 0xFF
        # Guard against a near-white accent that would vanish on a light background.
        if (($r + $g + $b) -gt 660) { return $fallback }
        return ('#{0:X2}{1:X2}{2:X2}' -f $r, $g, $b)
    } catch { return $fallback }
}
function Convert-Shade([string]$hex, [double]$factor) {
    $r = [Convert]::ToInt32($hex.Substring(1,2),16); $g = [Convert]::ToInt32($hex.Substring(3,2),16); $b = [Convert]::ToInt32($hex.Substring(5,2),16)
    if ($factor -lt 1) { $r=[int]($r*$factor); $g=[int]($g*$factor); $b=[int]($b*$factor) }
    else { $r=[int]($r+(255-$r)*($factor-1)); $g=[int]($g+(255-$g)*($factor-1)); $b=[int]($b+(255-$b)*($factor-1)) }
    '#{0:X2}{1:X2}{2:X2}' -f [math]::Min(255,[math]::Max(0,$r)), [math]::Min(255,[math]::Max(0,$g)), [math]::Min(255,[math]::Max(0,$b))
}
$script:Accent = Get-SystemAccent
[xml]$xaml = $xamlRaw.Replace('__ACCENT__', $script:Accent).Replace('__ACCENTDARK__', (Convert-Shade $script:Accent 0.80)).Replace('__ACCENTLIGHT__', (Convert-Shade $script:Accent 1.88))

$window = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xaml))
$icoPath = if ($env:WINOPT_ICO) { $env:WINOPT_ICO } elseif ($PSCommandPath) { Join-Path (Split-Path -Parent $PSCommandPath) 'WinOptimizer.ico' } else { $null }
if ($icoPath -and (Test-Path $icoPath)) { try { $window.Icon = [System.Windows.Media.Imaging.BitmapFrame]::Create([Uri]$icoPath) } catch {} }
$ui = @{}
foreach ($n in @(
    'Tabs','SysInfo','GpuLine','BtnQuick','RamText','RamBar','RamSub','CpuText','CpuBar','PlanText','DeltaText','DeltaSub',
    'ProcList','ProcNote','BtnRefreshProc','MemList','MemSearch','BloatSearch','StartSearch','CpuSearch','GpuSearch',
    'BtnMemRec','BtnMemNone','BtnTrim',
    'BloatList','BloatStatus','BtnBloatRec','BtnBloatNone','BtnBloatRescan',
    'StartList','BtnStartNone','BtnStartReload','CpuList','BtnCpuRec','BtnCpuNone','GpuList','GpuInfo','BtnGpuRec','BtnGpuNone',
    'BackupList','BtnRestore','BtnRestorePoint','BtnOpenSysRestore','BtnOpenFolder',
    'UiList','UiSearch','BtnUiRec','BtnUiNone','PrivList','PrivSearch','BtnPrivRec','BtnPrivNone',
    'UpdList','UpdSearch','BtnUpdRec','BtnUpdNone','PausedList','BtnPausedRefresh','BtnResumeAll','BtnExport','BtnImport',
    'LogBox','BusyPanel','BusyText','SelCount','BtnApply')) {
    $ui[$n] = $window.FindName($n)
    if (-not $ui[$n]) { throw "UI element '$n' not found" }
}
$script:LogBox = $ui.LogBox

# Live search: filter the visible list by name / description / group as you type.
function Set-ListFilter($list, $text) {
    if (-not $list) { return }
    $view = $list.Items
    if ([string]::IsNullOrWhiteSpace($text)) { $view.Filter = $null; return }
    $needle = $text.Trim()
    $view.Filter = [Predicate[object]]({ param($o)
        try { ("$($o.Name) $($o.Description) $($o.Group)") -match [regex]::Escape($needle) } catch { $true }
    }.GetNewClosure())
}
$script:SearchMap = @{}
foreach ($pair in @(@($ui.MemSearch, $ui.MemList), @($ui.BloatSearch, $ui.BloatList),
                    @($ui.StartSearch, $ui.StartList), @($ui.CpuSearch, $ui.CpuList), @($ui.GpuSearch, $ui.GpuList),
                    @($ui.UiSearch, $ui.UiList), @($ui.PrivSearch, $ui.PrivList), @($ui.UpdSearch, $ui.UpdList))) {
    $script:SearchMap[$pair[0]] = $pair[1]
    $pair[0].add_TextChanged({ param($s, $e) Set-ListFilter $script:SearchMap[$s] $s.Text })
}

# ---------------------------------------------------------------------------
# 9. State + UI wiring
# ---------------------------------------------------------------------------
$script:Catalog    = @()
$script:Startup    = @()
$script:Bloat      = @()
$script:BaselineMB = $null
$script:Busy       = $false
$script:BusySince  = Get-Date
$script:BusyLabel  = ''
$script:Jobs       = New-Object System.Collections.ArrayList
$script:ApplyCtx   = $null

function Get-AllTweaks { @($script:Catalog) + @($script:Startup) + @($script:Bloat) }

function Update-SelCount {
    $n = @(Get-AllTweaks | Where-Object { $_.IsSelected }).Count
    $ui.SelCount.Text = if ($n -eq 1) { '1 change selected' } else { "$n changes selected" }
    $ui.BtnApply.IsEnabled = ($n -gt 0) -and (-not $script:Busy)
}

function Register-SelectionWatch($tweaks) {
    foreach ($t in $tweaks) {
        $t.add_PropertyChanged({ param($s, $e) if ($e.PropertyName -eq 'IsSelected') { Update-SelCount } })
    }
}

function Set-Busy([bool]$On, [string]$Label = '') {
    $script:Busy = $On
    if ($On) {
        $script:BusySince = Get-Date
        $script:BusyLabel = $Label
        $ui.BusyText.Text = $Label
        $ui.BusyPanel.Visibility = 'Visible'
        $window.Cursor = [System.Windows.Input.Cursors]::AppStarting
        if (-not $script:JobTimer.IsEnabled) { $script:JobTimer.Start() }
    } else {
        $ui.BusyPanel.Visibility = 'Collapsed'
        $window.Cursor = $null
    }
    foreach ($b in 'BtnQuick','BtnRestore','BtnRestorePoint','BtnBloatRescan') { $ui[$b].IsEnabled = -not $On }
    Update-SelCount
}

# ---------- background job plumbing ----------
function Start-BgJob([scriptblock]$Script, $Argument, [scriptblock]$OnDone) {
    $sync = [hashtable]::Synchronized(@{
        Log     = New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'
        Results = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList))
        Done    = $false
        Ok      = $false
        Error   = $null
    })
    $rs = [runspacefactory]::CreateRunspace()
    $rs.Open()
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    # Pass the script as text so it is bound to the new runspace, not this one.
    [void]$ps.AddScript($Script.ToString()).AddArgument($sync).AddArgument($Argument)
    $handle = $ps.BeginInvoke()
    [void]$script:Jobs.Add(@{ Sync = $sync; PS = $ps; RS = $rs; Handle = $handle; OnDone = $OnDone })
    if (-not $script:JobTimer.IsEnabled) { $script:JobTimer.Start() }
}

function Receive-BgJobs {
    foreach ($j in @($script:Jobs)) {
        $msg = $null
        while ($j.Sync.Log.TryDequeue([ref]$msg)) { Write-Log $msg }
        if (-not ($j.Sync.Done -or $j.Handle.IsCompleted)) { continue }
        try { [void]$j.PS.EndInvoke($j.Handle) } catch { if (-not $j.Sync.Error) { $j.Sync.Error = $_.Exception.Message } }
        while ($j.Sync.Log.TryDequeue([ref]$msg)) { Write-Log $msg }
        foreach ($err in @($j.PS.Streams.Error | Select-Object -First 5)) { Write-Log "  $err" 'WARN' }
        $j.PS.Dispose()
        $j.RS.Dispose()
        $script:Jobs.Remove($j)
        if ($j.OnDone) {
            try { & $j.OnDone $j.Sync }
            catch {
                Write-Log "Error after background task: $($_.Exception.Message)" 'ERR'
                Set-Busy $false
            }
        }
    }
}

$script:JobTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:JobTimer.Interval = [TimeSpan]::FromMilliseconds(250)
$script:JobTimer.add_Tick({
    try { Receive-BgJobs } catch { Write-Log "Background task error: $($_.Exception.Message)" 'ERR' }
    if ($script:Busy) {
        $ui.BusyText.Text = '{0}...  {1:N0}s' -f $script:BusyLabel, ((Get-Date) - $script:BusySince).TotalSeconds
    }
    if ($script:Jobs.Count -eq 0 -and -not $script:Busy) { $script:JobTimer.Stop() }
})

# ---------- loading lists ----------
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
    $ui.UiList.ItemsSource   = @($script:Catalog | Where-Object Category -eq 'UI')
    $ui.PrivList.ItemsSource = @($script:Catalog | Where-Object Category -eq 'Privacy')
    $ui.UpdList.ItemsSource  = @($script:Catalog | Where-Object Category -eq 'Update')
}

function Load-Startup {
    $script:Startup = @(Get-StartupTweaks)
    Register-SelectionWatch $script:Startup
    $ui.StartList.ItemsSource = $script:Startup
}

function Load-Backups {
    $ui.BackupList.Items.Clear()
    Get-ChildItem -Path $BackupDir -Filter 'backup-*.json' -ErrorAction SilentlyContinue | Sort-Object Name -Descending | ForEach-Object {
        $entries = @()
        try { $entries = @((Get-Content $_.FullName -Raw | ConvertFrom-Json).Entries) } catch {}
        $apps = @($entries | Where-Object { $_.Type -in @('Appx','Edge','OneDrive') }).Count
        $settings = $entries.Count - $apps
        $item = New-Object System.Windows.Controls.ListBoxItem
        $item.Content = '{0}      {1} setting change(s)  -  {2} app removal(s)' -f $_.LastWriteTime.ToString('dddd d MMM yyyy, HH:mm'), $settings, $apps
        $item.Tag = $_.FullName
        [void]$ui.BackupList.Items.Add($item)
    }
    if ($ui.BackupList.Items.Count -eq 0) {
        $item = New-Object System.Windows.Controls.ListBoxItem
        $item.Content = 'No backups yet - one is created automatically every time you apply changes.'
        $item.IsEnabled = $false
        [void]$ui.BackupList.Items.Add($item)
    }
}

function Start-BloatScan {
    $ui.BloatStatus.Text = 'Scanning installed apps...'
    $script:Bloat = @()
    $ui.BloatList.ItemsSource = $null
    Update-SelCount
    Start-BgJob $ScanJob $null {
        param($sync)
        if ($sync.Error) { $ui.BloatStatus.Text = "Could not list apps: $($sync.Error)"; return }
        $script:Bloat = @(Get-BloatTweaks $sync.Installed $sync.Provisioned)
        Register-SelectionWatch $script:Bloat
        $ui.BloatList.ItemsSource = $script:Bloat
        $ui.BloatList.Items.GroupDescriptions.Clear()
        [void]$ui.BloatList.Items.GroupDescriptions.Add((New-Object System.Windows.Data.PropertyGroupDescription 'Group'))
        $ui.BloatStatus.Text = if ($script:Bloat.Count) { "$($script:Bloat.Count) removable item(s) found on this PC." } else { 'No known bloatware found on this PC.' }
        Update-SelCount
    }
}

function Set-Selection($category, [bool]$recommendedOnly, [bool]$none) {
    $list = if ($category -eq 'Bloat') { $script:Bloat } else { @($script:Catalog | Where-Object Category -eq $category) }
    foreach ($t in $list) {
        if ($none) { $t.IsSelected = $false }
        else { $t.IsSelected = $t.IsAvailable -and $t.Recommended -and $t.Status -ne 'Applied' }
    }
}

# ---------- live stats (the UI thread only reads the collector's latest snapshot) ----------
$script:LastProcVersion = -1
function Update-Stats {
    $snap = [WinOpt.Collector]::Current
    if (-not $snap) { return }
    $m = $snap.Mem
    if ($m) {
        $ui.RamText.Text = '{0:N1} / {1:N1} GB' -f ($m.UsedMB / 1024), ($m.TotalMB / 1024)
        $ui.RamBar.Value = $m.Pct
        $ui.RamSub.Text  = '{0}% in use  -  {1:N1} GB available' -f $m.Pct, ($m.AvailMB / 1024)
        if ($null -ne $script:BaselineMB) {
            $d = $script:BaselineMB - $m.UsedMB
            $ui.DeltaText.Text = if ($d -ge 0) { "-$d MB" } else { "+$([math]::Abs($d)) MB" }
        }
    }
    if ($snap.Cpu -ge 0) {
        $ui.CpuText.Text = '{0:N0} %' -f $snap.Cpu
        $ui.CpuBar.Value = $snap.Cpu
    }
    if ($snap.PowerPlan) { $ui.PlanText.Text = 'Power plan: ' + ($snap.PowerPlan -split '\|', 2)[1] }

    $onDashboard = $ui.Tabs.SelectedIndex -eq 0
    [WinOpt.Collector]::WantProcs = $onDashboard
    if ($onDashboard -and $snap.ProcVersion -ne $script:LastProcVersion) {
        $script:LastProcVersion = $snap.ProcVersion
        $ui.ProcList.ItemsSource = $snap.Procs
        if ($snap.ProcApproximate) {
            $ui.ProcNote.Text = 'Performance counters unavailable - showing total working set (includes shared memory, so it over-counts).'
        }
    }
}

function Update-Processes { [WinOpt.Collector]::RequestProcs() }

# ---------- Presets ----------
function Export-Preset {
    $ids = @(Get-AllTweaks | Where-Object { $_.IsSelected } | ForEach-Object { $_.Id })
    if (-not $ids.Count) { [System.Windows.MessageBox]::Show('Tick some changes first, then export.', 'WinOptimizer') | Out-Null; return }
    $dlg = New-Object Microsoft.Win32.SaveFileDialog
    $dlg.Filter = 'WinOptimizer preset (*.json)|*.json'; $dlg.FileName = 'winoptimizer-preset.json'
    if (-not $dlg.ShowDialog()) { return }
    @{ Preset = 'WinOptimizer'; Created = (Get-Date).ToString('o'); Ids = $ids } | ConvertTo-Json -Depth 4 | Set-Content -Path $dlg.FileName -Encoding UTF8
    Write-Log "Preset saved: $($dlg.FileName) ($($ids.Count) items)" 'OK'
}
function Import-Preset {
    $dlg = New-Object Microsoft.Win32.OpenFileDialog
    $dlg.Filter = 'WinOptimizer preset (*.json)|*.json'
    if (-not $dlg.ShowDialog()) { return }
    try { $data = Get-Content $dlg.FileName -Raw | ConvertFrom-Json } catch { Write-Log "Could not read preset: $($_.Exception.Message)" 'ERR'; return }
    $ids = @($data.Ids); $n = 0
    foreach ($t in Get-AllTweaks) { if (($ids -contains $t.Id) -and $t.IsAvailable) { $t.IsSelected = $true; $n++ } }
    Update-SelCount
    Write-Log "Preset loaded: selected $n of $($ids.Count) items. Review, then Review & apply." 'OK'
    [System.Windows.MessageBox]::Show("Selected $n of $($ids.Count) items from the preset. Review them, then click Review & apply.", 'WinOptimizer') | Out-Null
}

# ---------- Process end-task / pause dialog ----------
function Show-ProcessDialog($row) {
    if (-not $row) { return }
    $dx = [xml]@'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Manage process" SizeToContent="Height" Width="460" WindowStartupLocation="CenterOwner"
        Background="#FFFFFF" Foreground="#1C2A3A" FontFamily="Segoe UI Variable Text, Segoe UI" FontSize="13" ResizeMode="NoResize">
  <StackPanel Margin="24,20">
    <TextBlock x:Name="Ttl" FontSize="20" FontFamily="Segoe UI Semilight, Segoe UI" Foreground="#152235"/>
    <TextBlock x:Name="Sub" Foreground="#64748B" Margin="0,4,0,16" TextWrapping="Wrap"/>
    <Button x:Name="End" Style="{DynamicResource PrimaryBtn}" Margin="0,0,0,14" Padding="14,10" HorizontalAlignment="Left">
      <TextBlock Text="End task now"/></Button>
    <TextBlock Text="Pause it (block from relaunching) for:" FontWeight="SemiBold" Margin="0,0,0,8"/>
    <WrapPanel x:Name="Durations"/>
    <Button x:Name="Cancel" Content="Cancel" Style="{DynamicResource Btn}" HorizontalAlignment="Right" Margin="0,8,0,0" IsCancel="True"/>
  </StackPanel>
</Window>
'@
    $dlg = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $dx))
    $dlg.Owner = $window
    $dlg.Resources.MergedDictionaries.Add($window.Resources)
    $dlg.FindName('Ttl').Text = $row.Name
    $dlg.FindName('Sub').Text = "$($row.Count) running instance(s), $($row.MB) MB. Ending stops it now; pausing also stops it and prevents it reopening."
    $dlg.FindName('End').Add_Click({
        $k = Stop-AppNow $row.Name
        Write-Log "Ended $($row.Name): stopped $k instance(s)." 'OK'
        Update-Processes; $dlg.Close()
    })
    $wrap = $dlg.FindName('Durations')
    $mk = {
        param($label, $span)
        $b = New-Object System.Windows.Controls.Button
        $b.Content = $label; $b.Style = $window.FindResource('Btn')
        $b.Add_Click({
            try {
                $until = $null
                if ($span) { $until = (Get-Date).Add($span) }
                Pause-App $row.Name $until
                Load-PausedTasks
                Update-Processes
                $dlg.Close()
            } catch {
                [System.Windows.MessageBox]::Show($_.Exception.Message, 'WinOptimizer') | Out-Null
            }
        }.GetNewClosure())
        [void]$wrap.Children.Add($b)
    }
    foreach ($key in $PauseDurations.Keys) { & $mk $key $PauseDurations[$key] }
    & $mk 'Permanently' $null
    [void]$dlg.ShowDialog()
}

# ---------- Paused Tasks page ----------
function Load-PausedTasks {
    $ui.PausedList.Children.Clear()
    $items = @(Get-ActivePauses)
    if (-not $items.Count) {
        $tb = New-Object System.Windows.Controls.TextBlock
        $tb.Text = 'No paused apps. Pause one by double-clicking it on the Dashboard.'
        $tb.Foreground = '#8094AC'; $tb.Margin = New-Object System.Windows.Thickness(2,6,0,0)
        [void]$ui.PausedList.Children.Add($tb); return
    }
    foreach ($it in $items) {
        $when = 'Permanent'
        if ($it.Until) { try { $when = 'until ' + ([datetime]$it.Until).ToString('ddd d MMM, HH:mm') } catch {} }
        $card = New-Object System.Windows.Controls.Border
        $card.Background = '#FFFFFF'; $card.BorderBrush = '#E4EBF4'
        $card.BorderThickness = New-Object System.Windows.Thickness(1); $card.CornerRadius = New-Object System.Windows.CornerRadius(10)
        $card.Padding = New-Object System.Windows.Thickness(16,12,16,12); $card.Margin = New-Object System.Windows.Thickness(0,0,14,8)
        $g = New-Object System.Windows.Controls.Grid
        $c0 = New-Object System.Windows.Controls.ColumnDefinition; $c0.Width = 'Auto'
        $c1 = New-Object System.Windows.Controls.ColumnDefinition
        $g.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition))
        $g.ColumnDefinitions.Add($c0)
        $sp = New-Object System.Windows.Controls.StackPanel
        $t1 = New-Object System.Windows.Controls.TextBlock; $t1.Text = $it.Exe; $t1.FontWeight = 'SemiBold'; $t1.FontSize = 14; $t1.Foreground = '#152235'
        $t2 = New-Object System.Windows.Controls.TextBlock; $t2.Text = "Paused $when"; $t2.Foreground = '#64748B'; $t2.FontSize = 12; $t2.Margin = New-Object System.Windows.Thickness(0,3,0,0)
        [void]$sp.Children.Add($t1); [void]$sp.Children.Add($t2)
        [System.Windows.Controls.Grid]::SetColumn($sp,0); [void]$g.Children.Add($sp)
        $btn = New-Object System.Windows.Controls.Button; $btn.Content = 'Resume now'; $btn.Style = $window.FindResource('Btn'); $btn.Margin = New-Object System.Windows.Thickness(0)
        $exe = $it.Exe
        $btn.Add_Click({ Resume-App $exe; Load-PausedTasks }.GetNewClosure())
        [System.Windows.Controls.Grid]::SetColumn($btn,1); [void]$g.Children.Add($btn)
        $card.Child = $g
        [void]$ui.PausedList.Children.Add($card)
    }
}

# ---------- Preview / confirm dialog ----------
$CategoryTitles = [ordered]@{ Memory = 'Memory & RAM settings'; UI = 'Explorer & UI'; Privacy = 'Privacy & AI'; Update = 'Windows Update'; Startup = 'Startup apps to disable'; CPU = 'CPU settings'; GPU = 'GPU settings'; Bloat = 'Apps to UNINSTALL' }

function Show-Preview($selected) {
    $sb = New-Object System.Text.StringBuilder
    foreach ($cat in $CategoryTitles.Keys) {
        $group = @($selected | Where-Object Category -eq $cat)
        if (-not $group.Count) { continue }
        [void]$sb.AppendLine("==== $($CategoryTitles[$cat]) ($($group.Count)) ====")
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
        Title="Review changes" Width="940" Height="680" WindowStartupLocation="CenterOwner"
        Background="#FFFFFF" Foreground="#1C2A3A" FontFamily="Segoe UI Variable Text, Segoe UI" FontSize="13">
  <DockPanel Margin="26,22">
    <StackPanel DockPanel.Dock="Top" Margin="0,0,0,14">
      <TextBlock Text="Review exactly what will change" FontSize="23" FontFamily="Segoe UI Semilight, Segoe UI Light, Segoe UI" Foreground="#152235"/>
      <TextBlock x:Name="Summary" Foreground="#64748B" TextWrapping="Wrap" Margin="0,6,0,0" LineHeight="19"/>
    </StackPanel>
    <StackPanel DockPanel.Dock="Bottom" Margin="0,16,0,0">
      <CheckBox x:Name="ChkRp" IsChecked="True" Foreground="#1C2A3A" Margin="0,0,0,14"
                Content="Create a System Restore point first (recommended - runs in the background, usually under a minute)"/>
      <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
        <Button x:Name="Cancel" Content="Cancel" Style="{DynamicResource Btn}" IsCancel="True" Margin="0,0,10,0"/>
        <Button x:Name="Ok" Content="Apply changes" Style="{DynamicResource PrimaryBtn}" Margin="0" Padding="22,9"/>
      </StackPanel>
    </StackPanel>
    <TextBox x:Name="Details" IsReadOnly="True" FontFamily="Cascadia Mono, Consolas" FontSize="12" Background="#F6F9FD" Foreground="#243244"
             BorderBrush="#E4EBF4" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto" Padding="12,10"/>
  </DockPanel>
</Window>
'@
    $dlg = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $dlgXaml))
    $dlg.Owner = $window
    $dlg.Resources.MergedDictionaries.Add($window.Resources)
    $script:PreviewDlg = $dlg
    $removals = @($selected | Where-Object Category -eq 'Bloat').Count
    $risky    = @($selected | Where-Object Risk -ne 'Safe').Count
    $summary  = "$($selected.Count) item(s) selected ($risky marked Moderate/Advanced). Current value -> new value is listed for every setting, and setting changes are saved to a backup you can restore."
    if ($removals) { $summary += "  $removals app item(s) will be UNINSTALLED - these can be reinstalled from the Store but not undone with one click." }
    $dlg.FindName('Summary').Text = $summary
    $dlg.FindName('Details').Text = $sb.ToString()
    $script:PreviewResult = $null
    $dlg.FindName('Ok').add_Click({
        $script:PreviewResult = @{ RestorePoint = [bool]$script:PreviewDlg.FindName('ChkRp').IsChecked }
        $script:PreviewDlg.DialogResult = $true
    })
    [void]$dlg.ShowDialog()
    return $script:PreviewResult
}

# ---------- Apply pipeline: restore point (bg) -> settings (UI) -> app removal (bg) -> summary ----------
function Save-ApplyBackup {
    $ctx = $script:ApplyCtx
    if (-not $ctx -or -not $ctx.Entries.Count) { return }
    @{ Created = (Get-Date).ToString('o'); Computer = $env:COMPUTERNAME; Entries = @($ctx.Entries) } |
        ConvertTo-Json -Depth 6 | Set-Content -Path $ctx.BackupPath -Encoding UTF8
}

function Invoke-Apply {
    if ($script:Busy) { return }
    $selected = @(Get-AllTweaks | Where-Object { $_.IsSelected -and $_.IsAvailable })
    if (-not $selected.Count) { return }
    $choice = Show-Preview $selected
    if (-not $choice) { Write-Log 'Cancelled - nothing was changed.'; return }

    $script:ApplyCtx = @{
        Selected   = $selected
        Entries    = New-Object System.Collections.ArrayList
        Failures   = New-Object System.Collections.ArrayList
        BackupPath = Join-Path $BackupDir ('backup-{0}.json' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    }
    $script:BaselineMB = (Get-MemStats).UsedMB

    if ($choice.RestorePoint) {
        Set-Busy $true 'Creating System Restore point'
        Write-Log 'Creating System Restore point...'
        Start-BgJob $RestorePointJob "WinOptimizer - before changes $(Get-Date -Format 'yyyy-MM-dd HH:mm')" {
            param($sync)
            if ($sync.Ok) { Write-Log 'Restore point created.' 'OK'; Invoke-ApplyChanges; return }
            Write-Log "Restore point failed: $($sync.Error)" 'ERR'
            $r = [System.Windows.MessageBox]::Show(
                "A System Restore point could not be created (System Protection may be off or blocked by policy).`n`nSetting changes are still backed up by this app and can be restored.`n`nContinue anyway?",
                'WinOptimizer', 'YesNo', 'Warning')
            if ($r -eq 'Yes') { Invoke-ApplyChanges } else { Write-Log 'Aborted - nothing was changed.'; Set-Busy $false }
        }
    } else {
        Invoke-ApplyChanges
    }
}

function Invoke-ApplyChanges {
    $ctx = $script:ApplyCtx
    Set-Busy $true 'Applying settings'
    foreach ($t in @($ctx.Selected | Where-Object Category -ne 'Bloat')) {
        Write-Log "> $($t.Name)"
        foreach ($a in $t.Actions) {
            try {
                $e = Invoke-Action $a
                if ($e) { [void]$ctx.Entries.Add($e) }
            } catch {
                [void]$ctx.Failures.Add("$($t.Name): $($_.Exception.Message)")
                Write-Log "  FAILED: $($_.Exception.Message)" 'ERR'
            }
        }
        $t.IsSelected = $false
    }
    Save-ApplyBackup

    $removals = @($ctx.Selected | Where-Object Category -eq 'Bloat')
    if ($removals.Count) {
        $items = @($removals | ForEach-Object {
            $a = @($_.Actions)[0]
            @{ Id = $_.Id; Kind = $a.Type; Patterns = @($a.Patterns); Display = $_.Name }
        })
        foreach ($t in $removals) { $t.IsSelected = $false }
        Set-Busy $true "Uninstalling $($items.Count) app item(s) - this can take a few minutes"
        Start-BgJob $RemovalJob @{ Items = $items; Protected = $ProtectedAppx } { param($sync) Complete-Apply $sync }
    } else {
        Complete-Apply $null
    }
}

function Complete-Apply($sync) {
    $ctx = $script:ApplyCtx
    $settingsChanged = $ctx.Entries.Count
    $removedOk = 0; $removalTotal = 0
    if ($sync) {
        if ($sync.Error) { [void]$ctx.Failures.Add("App removal: $($sync.Error)") }
        foreach ($r in @($sync.Results)) {
            $removalTotal++
            foreach ($fam in @($r.Families | Where-Object { $_ })) {
                [void]$ctx.Entries.Add([ordered]@{ Type = 'Appx'; FamilyName = $fam; Display = $r.Display })
            }
            if ($r.Changed -and $r.Kind -in @('Edge','OneDrive')) {
                [void]$ctx.Entries.Add([ordered]@{ Type = $r.Kind; Display = $r.Display })
            }
            if ($r.Ok) { $removedOk++; Write-Log "  $($r.Display): $($r.Message)" 'OK' }
            else { [void]$ctx.Failures.Add("$($r.Display): $($r.Message)"); Write-Log "  $($r.Display): $($r.Message)" 'ERR' }
        }
        Save-ApplyBackup
    }
    if ($ctx.Entries.Count) { Write-Log "Backup saved: $($ctx.BackupPath)" 'OK' }

    foreach ($t in $script:Catalog) { Update-TweakStatus $t }
    Load-Startup
    Load-Backups
    if ($sync) { Start-BloatScan }
    [WinOpt.Collector]::RequestPlan()
    [WinOpt.Collector]::RequestProcs()
    Set-Busy $false
    $ui.DeltaSub.Text = 'Measured since you clicked Apply. Most savings (services, startup apps, removed apps) only fully show after a restart.'

    $msg = "Finished.`n`n- Settings changed: $settingsChanged"
    if ($sync) { $msg += "`n- App items removed: $removedOk of $removalTotal (each one verified)" }
    if ($ctx.Failures.Count) {
        $msg += "`n`nProblems ($($ctx.Failures.Count)):`n" + ((@($ctx.Failures) | Select-Object -First 8 | ForEach-Object { "- $_" }) -join "`n")
        if ($ctx.Failures.Count -gt 8) { $msg += "`n- ...see the log at the bottom of the window" }
    }
    $msg += "`n`nRestart Windows when it suits you so that service, startup and app changes take full effect. This app will not restart your PC for you."
    $icon = if ($ctx.Failures.Count) { 'Warning' } else { 'Information' }
    [System.Windows.MessageBox]::Show($msg, 'WinOptimizer', 'OK', $icon) | Out-Null
}

# ---------- Restore ----------
function Show-ReinstallDialog($entries) {
    $dx = [xml]@'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Reinstall removed apps" Width="600" Height="560" WindowStartupLocation="CenterOwner"
        Background="#FFFFFF" Foreground="#1C2A3A" FontFamily="Segoe UI Variable Text, Segoe UI" FontSize="13">
  <DockPanel Margin="26,22">
    <StackPanel DockPanel.Dock="Top" Margin="0,0,0,16">
      <TextBlock Text="Reinstall removed apps" FontSize="23" FontFamily="Segoe UI Semilight, Segoe UI Light, Segoe UI" Foreground="#152235"/>
      <TextBlock TextWrapping="Wrap" Foreground="#64748B" Margin="0,6,0,0" LineHeight="19"
                 Text="Uninstalled apps cannot be put back automatically. Click an app to open its Microsoft Store (or download) page, then press Get / Install."/>
    </StackPanel>
    <Button x:Name="Close" DockPanel.Dock="Bottom" Content="Close" HorizontalAlignment="Right" Style="{DynamicResource Btn}" Margin="0,16,0,0" IsCancel="True"/>
    <ScrollViewer VerticalScrollBarVisibility="Auto"><StackPanel x:Name="Rows"/></ScrollViewer>
  </DockPanel>
</Window>
'@
    $dlg = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $dx))
    $dlg.Owner = $window
    $dlg.Resources.MergedDictionaries.Add($window.Resources)
    $rows = $dlg.FindName('Rows')
    foreach ($e in $entries) {
        $uri = switch ($e.Type) {
            'Appx'     { "ms-windows-store://pdp/?PFN=$($e.FamilyName)" }
            'Edge'     { 'https://www.microsoft.com/edge/download' }
            'OneDrive' { 'https://www.microsoft.com/microsoft-365/onedrive/download' }
        }
        $label = if ($e.Type -eq 'Appx') { "$($e.Display)   -   $($e.FamilyName -replace '_.*$', '')" } else { "$($e.Display)   -   download page" }
        $b = New-Object System.Windows.Controls.Button
        $b.Content = $label
        $b.Tag = $uri
        $b.Style = $window.FindResource('Btn')
        $b.Margin = New-Object System.Windows.Thickness(0, 0, 0, 8)
        $b.add_Click({ Start-Process $this.Tag })
        [void]$rows.Children.Add($b)
    }
    [void]$dlg.ShowDialog()
}

function Invoke-Restore {
    if ($script:Busy) { return }
    $item = $ui.BackupList.SelectedItem
    if (-not $item -or -not $item.Tag) { [System.Windows.MessageBox]::Show('Select a backup first.', 'WinOptimizer') | Out-Null; return }
    $path = $item.Tag
    $r = [System.Windows.MessageBox]::Show("Restore everything saved in this backup?`n`n$path`n`nSettings go back to their exact previous values. Removed apps are listed with links to reinstall them.", 'WinOptimizer', 'OKCancel', 'Question')
    if ($r -ne 'OK') { return }

    $data = Get-Content $path -Raw | ConvertFrom-Json
    $list = @($data.Entries)
    [array]::Reverse($list)
    $reinstall = New-Object System.Collections.ArrayList
    $errors = 0
    Write-Log "Restoring from $path"
    foreach ($e in $list) {
        if ($e.Type -in @('Appx','Edge','OneDrive')) {
            [void]$reinstall.Add($e)
            if ($e.Type -eq 'Edge') {
                # Lift the Edge Update block so the Edge installer is allowed to run again.
                Remove-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\EdgeUpdate' -Name 'Install{56EB18F8-B008-4CBD-B6D2-8C97FE7E9062}' -ErrorAction SilentlyContinue
            }
            continue
        }
        try { Restore-Entry $e } catch { $errors++; Write-Log "  FAILED: $($_.Exception.Message)" 'ERR' }
    }
    Rename-Item -Path $path -NewName ([IO.Path]::GetFileName($path) -replace '^backup-', 'restored-') -ErrorAction SilentlyContinue
    foreach ($t in $script:Catalog) { Update-TweakStatus $t }
    Load-Startup
    Load-Backups
    [WinOpt.Collector]::RequestPlan()
    [System.Windows.MessageBox]::Show("Settings restored with $errors error(s). Restart Windows to complete it.", 'WinOptimizer') | Out-Null
    if ($reinstall.Count) { Show-ReinstallDialog $reinstall }
}

# ---------- Events ----------
$ui.BtnApply.add_Click({ Invoke-Apply })
$ui.BtnQuick.add_Click({
    foreach ($c in 'Memory','CPU','GPU') { Set-Selection $c $true $false }
    if (-not @(Get-AllTweaks | Where-Object { $_.IsSelected -and $_.IsAvailable }).Count) {
        [System.Windows.MessageBox]::Show('All recommended settings are already applied on this PC.', 'WinOptimizer') | Out-Null
        return
    }
    Invoke-Apply
})
$ui.BtnMemRec.add_Click({ Set-Selection 'Memory' $true $false })
$ui.BtnMemNone.add_Click({ Set-Selection 'Memory' $false $true })
$ui.BtnCpuRec.add_Click({ Set-Selection 'CPU' $true $false })
$ui.BtnCpuNone.add_Click({ Set-Selection 'CPU' $false $true })
$ui.BtnGpuRec.add_Click({ Set-Selection 'GPU' $true $false })
$ui.BtnGpuNone.add_Click({ Set-Selection 'GPU' $false $true })
$ui.BtnUiRec.add_Click({ Set-Selection 'UI' $true $false })
$ui.BtnUiNone.add_Click({ Set-Selection 'UI' $false $true })
$ui.BtnPrivRec.add_Click({ Set-Selection 'Privacy' $true $false })
$ui.BtnPrivNone.add_Click({ Set-Selection 'Privacy' $false $true })
$ui.BtnUpdRec.add_Click({ Set-Selection 'Update' $true $false })
$ui.BtnUpdNone.add_Click({ Set-Selection 'Update' $false $true })
$ui.BtnExport.add_Click({ Export-Preset })
$ui.BtnImport.add_Click({ Import-Preset })
$ui.ProcList.add_MouseDoubleClick({ Show-ProcessDialog $ui.ProcList.SelectedItem })
$ui.BtnPausedRefresh.add_Click({ Load-PausedTasks })
$ui.BtnResumeAll.add_Click({
    foreach ($it in @(Get-ActivePauses)) { Resume-App $it.Exe }
    Load-PausedTasks
})
$ui.BtnBloatRec.add_Click({ Set-Selection 'Bloat' $true $false })
$ui.BtnBloatNone.add_Click({ Set-Selection 'Bloat' $false $true })
$ui.BtnBloatRescan.add_Click({ if (-not $script:Busy) { Start-BloatScan } })
$ui.BtnStartNone.add_Click({ foreach ($t in $script:Startup) { $t.IsSelected = $false } })
$ui.BtnStartReload.add_Click({ Load-Startup; Update-SelCount })
$ui.BtnRefreshProc.add_Click({ Update-Processes })
$ui.BtnTrim.add_Click({
    $before = (Get-MemStats).UsedMB
    $n = Invoke-TrimWorkingSets
    Start-Sleep -Milliseconds 500
    $after = (Get-MemStats).UsedMB
    Write-Log "Trimmed $n processes: in-use RAM $before MB -> $after MB. This is temporary; Windows pages memory back in as apps need it." 'OK'
    Update-Processes
})
$ui.BtnRestore.add_Click({ Invoke-Restore })
$ui.BtnRestorePoint.add_Click({
    if ($script:Busy) { return }
    Set-Busy $true 'Creating System Restore point'
    Start-BgJob $RestorePointJob "WinOptimizer - manual $(Get-Date -Format 'yyyy-MM-dd HH:mm')" {
        param($sync)
        if ($sync.Ok) { Write-Log 'Restore point created.' 'OK' } else { Write-Log "Restore point failed: $($sync.Error)" 'ERR' }
        Set-Busy $false
    }
})
$ui.BtnOpenSysRestore.add_Click({ Start-Process "$env:SystemRoot\System32\rstrui.exe" })
$ui.BtnOpenFolder.add_Click({ Start-Process explorer.exe $BackupDir })

# UI refresh: 1 s; each tick only copies already-collected numbers into labels.
$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromSeconds(1)
$timer.add_Tick({ try { Update-Stats } catch {} })

$window.add_Loaded({
    [WinOpt.Collector]::Start()
    $timer.Start()
    # Let the window paint first, then do the one-off scans.
    [void]$window.Dispatcher.BeginInvoke([System.Windows.Threading.DispatcherPriority]::ContextIdle, [Action]{
        Write-Log "WinOptimizer started. Log: $LogFile"
        try {
            $info = Get-SystemSummary
            $ui.SysInfo.Text = "$($info.Os)  -  $($info.Cpu)"
            $ui.GpuLine.Text = "Graphics: $($info.Gpus)"
            $ui.GpuInfo.Text = "Detected: $($info.Gpus). These settings reduce background GPU work and latency. They do not overclock or change driver settings - use your GPU vendor's app for that."
        } catch {}
        try {
            Load-Catalog
            Load-Startup
            Load-Backups
            Update-SelCount
            Load-PausedTasks
            Start-BloatScan
        } catch {
            Write-Log "Startup scan failed: $($_.Exception.Message)" 'ERR'
        }
    })
})
$window.add_Closing({
    param($s, $e)
    if ($script:Busy) {
        $r = [System.Windows.MessageBox]::Show("Changes are still being applied. Closing now could leave an app half-removed.`n`nClose anyway?", 'WinOptimizer', 'YesNo', 'Warning')
        if ($r -ne 'Yes') { $e.Cancel = $true }
    }
})
$window.add_Closed({ $timer.Stop(); $script:JobTimer.Stop(); [WinOpt.Collector]::Stop() })

[void]$window.ShowDialog()
