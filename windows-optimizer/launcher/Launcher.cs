// WinOptimizer.exe - hosts the WinOptimizer UI *inside this process* so the taskbar
// button, icon and pinning all belong to WinOptimizer.exe (not a child powershell).
// The PowerShell engine is loaded by reflection, so no compile-time dependency on it.
// The exe's manifest requests administrator, so it runs elevated as a single process.
using System;
using System.IO;
using System.Reflection;
using System.Diagnostics;
using System.Windows.Forms;
using System.ComponentModel;
using System.Security.Principal;

[assembly: AssemblyTitle("WinOptimizer")]
[assembly: AssemblyDescription("Safe, reversible Windows RAM/CPU/GPU optimizer")]
[assembly: AssemblyProduct("WinOptimizer")]
[assembly: AssemblyCompany("deeluss")]
[assembly: AssemblyCopyright("Copyright deeluss")]
[assembly: AssemblyVersion("1.3.0.0")]
[assembly: AssemblyFileVersion("1.3.0.0")]

static class Program
{
    [STAThread]
    static int Main()
    {
        if (!IsAdmin())
        {
            try
            {
                Process.Start(new ProcessStartInfo(Assembly.GetExecutingAssembly().Location) { UseShellExecute = true, Verb = "runas" });
                return 0;
            }
            catch (Win32Exception)
            {
                MessageBox.Show("WinOptimizer needs administrator rights to change services and system settings.",
                    "WinOptimizer", MessageBoxButtons.OK, MessageBoxIcon.Information);
                return 1;
            }
        }
        string dir = Path.Combine(Path.GetTempPath(), "WinOptimizer-" + Guid.NewGuid().ToString("N"));
        string script;
        using (var r = new StreamReader(Assembly.GetExecutingAssembly().GetManifestResourceStream("WinOptimizer.ps1")))
            script = r.ReadToEnd();
        try
        {
            Directory.CreateDirectory(dir);
            string ico = Path.Combine(dir, "WinOptimizer.ico");
            Extract("WinOptimizer.ico", ico);
            Environment.SetEnvironmentVariable("WINOPT_ICO", ico);
            try { HostInProcess(script); }       // preferred: window belongs to this exe
            catch { ShellOut(script, dir); }      // fallback: never worse than launching powershell
            return 0;
        }
        catch (Exception ex)
        {
            MessageBox.Show("WinOptimizer could not start:\n\n" + ex.Message, "WinOptimizer",
                MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 2;
        }
        finally { try { Directory.Delete(dir, true); } catch { } }
    }

    static void Extract(string res, string dest)
    {
        using (Stream s = Assembly.GetExecutingAssembly().GetManifestResourceStream(res))
        using (FileStream fs = File.Create(dest)) { s.CopyTo(fs); }
    }

    // Runs the script on THIS STA thread via a Windows PowerShell runspace, loaded reflectively.
    static void HostInProcess(string script)
    {
        Assembly a = null;
        try { a = Assembly.Load("System.Management.Automation, Version=3.0.0.0, Culture=neutral, PublicKeyToken=31bf3856ad364e35"); }
        catch { }
        if (a == null)
        {
#pragma warning disable 0618
            a = Assembly.LoadWithPartialName("System.Management.Automation");
#pragma warning restore 0618
        }
        if (a == null) throw new Exception("Windows PowerShell engine not found.");

        Type rf = a.GetType("System.Management.Automation.Runspaces.RunspaceFactory", true);
        object rs = rf.GetMethod("CreateRunspace", Type.EmptyTypes).Invoke(null, null);
        Type rsType = rs.GetType();
        rsType.GetProperty("ApartmentState").SetValue(rs, System.Threading.ApartmentState.STA, null);
        Type pto = a.GetType("System.Management.Automation.Runspaces.PSThreadOptions", true);
        rsType.GetProperty("ThreadOptions").SetValue(rs, Enum.Parse(pto, "UseCurrentThread"), null);
        rsType.GetMethod("Open", Type.EmptyTypes).Invoke(rs, null);

        Type psT = a.GetType("System.Management.Automation.PowerShell", true);
        object ps = psT.GetMethod("Create", Type.EmptyTypes).Invoke(null, null);
        psT.GetProperty("Runspace").SetValue(ps, rs, null);
        psT.GetMethod("AddScript", new[] { typeof(string) }).Invoke(ps, new object[] { script });

        MethodInfo invoke = null;
        foreach (MethodInfo mi in psT.GetMethods())
            if (mi.Name == "Invoke" && !mi.IsGenericMethod && mi.GetParameters().Length == 0) { invoke = mi; break; }
        if (invoke == null) throw new Exception("PowerShell.Invoke not found.");
        invoke.Invoke(ps, null);   // blocks on this STA thread until the window closes
    }

    static void ShellOut(string script, string dir)
    {
        string file = Path.Combine(dir, "WinOptimizer.ps1");
        File.WriteAllText(file, script);
        string ps = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), @"WindowsPowerShell\v1.0\powershell.exe");
        var psi = new ProcessStartInfo(ps, "-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File \"" + file + "\"")
            { UseShellExecute = false, CreateNoWindow = true };
        using (Process p = Process.Start(psi)) p.WaitForExit();
    }

    static bool IsAdmin()
    {
        using (WindowsIdentity id = WindowsIdentity.GetCurrent())
            return new WindowsPrincipal(id).IsInRole(WindowsBuiltInRole.Administrator);
    }
}
