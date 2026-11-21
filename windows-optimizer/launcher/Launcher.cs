// WinOptimizer.exe - self-contained launcher.
// Embeds WinOptimizer.ps1 and the icon, asks for admin rights, extracts both to a
// temp folder and runs the script in Windows PowerShell 5.1 (WPF needs STA).
using System;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Security.Principal;
using System.Windows.Forms;

[assembly: AssemblyTitle("WinOptimizer")]
[assembly: AssemblyDescription("Safe, reversible Windows RAM/CPU/GPU optimizer")]
[assembly: AssemblyProduct("WinOptimizer")]
[assembly: AssemblyCompany("deeluss")]
[assembly: AssemblyCopyright("Copyright deeluss")]
[assembly: AssemblyVersion("1.1.0.0")]
[assembly: AssemblyFileVersion("1.1.0.0")]

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
        try
        {
            Directory.CreateDirectory(dir);
            Extract("WinOptimizer.ps1", Path.Combine(dir, "WinOptimizer.ps1"));
            Extract("WinOptimizer.ico", Path.Combine(dir, "WinOptimizer.ico"));
            string ps = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), @"WindowsPowerShell\v1.0\powershell.exe");
            var run = new ProcessStartInfo(ps, "-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File \"" + Path.Combine(dir, "WinOptimizer.ps1") + "\"")
                { UseShellExecute = false, CreateNoWindow = true };
            using (Process p = Process.Start(run)) { p.WaitForExit(); return p.ExitCode; }
        }
        catch (Exception ex)
        {
            MessageBox.Show("WinOptimizer could not start:\n\n" + ex.Message, "WinOptimizer", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 2;
        }
        finally { try { Directory.Delete(dir, true); } catch { } }
    }

    static void Extract(string res, string dest)
    {
        using (Stream s = Assembly.GetExecutingAssembly().GetManifestResourceStream(res))
        using (FileStream fs = File.Create(dest)) { s.CopyTo(fs); }
    }

    static bool IsAdmin()
    {
        using (WindowsIdentity id = WindowsIdentity.GetCurrent())
            return new WindowsPrincipal(id).IsInRole(WindowsBuiltInRole.Administrator);
    }
}
