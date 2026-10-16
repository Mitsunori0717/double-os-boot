using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;

internal static class EdgeBoxInstaller {
    static void Extract(string name,string destination) {
        using(var source=Assembly.GetExecutingAssembly().GetManifestResourceStream(name)) {
            if(source==null) throw new InvalidOperationException("Missing embedded resource: "+name);
            using(var output=File.Create(destination)) source.CopyTo(output);
        }
    }
    static int Main() {
        string tempRoot=Path.GetFullPath(Path.GetTempPath());
        string stage=Path.Combine(tempRoot,"EdgeBoxInstall_"+Guid.NewGuid().ToString("N"));
        try {
            Directory.CreateDirectory(stage);
            Extract("Payload",Path.Combine(stage,"payload.zip"));
            Extract("Installer",Path.Combine(stage,"install.ps1"));
            var info=new ProcessStartInfo(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System),"WindowsPowerShell\\v1.0\\powershell.exe"));
            info.Arguments="-NoProfile -ExecutionPolicy Bypass -File \""+Path.Combine(stage,"install.ps1")+"\"";
            info.WorkingDirectory=stage;
            info.UseShellExecute=false;
            using(var process=Process.Start(info)) {process.WaitForExit(); return process.ExitCode;}
        } catch(Exception ex) {
            Console.Error.WriteLine("Edge Box setup failed: "+ex.Message);
            Console.Error.WriteLine("Portable ZIP: extract it, then run setup-all.cmd. Press Enter to close.");
            Console.ReadLine();
            return 1;
        } finally {
            try {
                string full=Path.GetFullPath(stage);
                if(full.StartsWith(tempRoot,StringComparison.OrdinalIgnoreCase) && Path.GetFileName(full).StartsWith("EdgeBoxInstall_",StringComparison.Ordinal)) Directory.Delete(full,true);
            } catch {}
        }
    }
}
