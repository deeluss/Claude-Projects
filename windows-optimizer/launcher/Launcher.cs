// WinOptimizer.exe - self-contained launcher.
// Embeds WinOptimizer.ps1, requests administrator rights, extracts the script to the
// elevated user's temp folder and runs it in Windows PowerShell 5.1 (WPF needs STA).
using System;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Security.Principal;
using System.Windows.Forms;

[assembly: AssemblyTitle("WinOptimizer")]
[assembly: AssemblyProduct("WinOptimizer")]
[assembly: AssemblyDescription("Safe, reversible Windows RAM/CPU/GPU optimizer")]
[assembly: AssemblyVersion("1.0.0.0")]
[assembly: AssemblyFileVersion("1.0.0.0")]

static class Program
{
    [STAThread]
    static int Main(string[] args)
    {
        if (!IsAdmin())
        {
            try
            {
                var psi = new ProcessStartInfo(Assembly.GetExecutingAssembly().Location)
                {
                    UseShellExecute = true,
                    Verb = "runas"
                };
                Process.Start(psi);
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
        string script = Path.Combine(dir, "WinOptimizer.ps1");
        try
        {
            Directory.CreateDirectory(dir);
            using (Stream res = Assembly.GetExecutingAssembly().GetManifestResourceStream("WinOptimizer.ps1"))
            using (FileStream fs = File.Create(script))
            {
                res.CopyTo(fs);
            }

            string ps = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System),
                                     @"WindowsPowerShell\v1.0\powershell.exe");
            var run = new ProcessStartInfo(ps,
                "-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File \"" + script + "\"")
            {
                UseShellExecute = false,
                CreateNoWindow = true
            };
            using (Process p = Process.Start(run))
            {
                p.WaitForExit();
                return p.ExitCode;
            }
        }
        catch (Exception ex)
        {
            MessageBox.Show("WinOptimizer could not start:\n\n" + ex.Message, "WinOptimizer",
                MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 2;
        }
        finally
        {
            try { Directory.Delete(dir, true); } catch { }
        }
    }

    static bool IsAdmin()
    {
        using (WindowsIdentity id = WindowsIdentity.GetCurrent())
            return new WindowsPrincipal(id).IsInRole(WindowsBuiltInRole.Administrator);
    }
}
