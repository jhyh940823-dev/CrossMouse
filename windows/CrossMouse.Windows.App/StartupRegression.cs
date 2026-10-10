using Microsoft.Win32;
using System.Security.Cryptography;

namespace CrossMouse.Windows.App;

/// <summary>Tests registration in an isolated NON-Run key and the real hidden GUI.</summary>
internal static class StartupRegression
{
    internal static int Run()
    {
        string testKey = @"Software\CrossMouse\StartupTest-" + Guid.NewGuid().ToString("N");
        string temp = Path.Combine(Path.GetTempPath(), "CrossMouse Startup 한글 " + Guid.NewGuid().ToString("N"));
        int result = 1;
        try
        {
            Directory.CreateDirectory(temp);
            string exe = Path.Combine(temp, "CrossMouse.exe");
            File.WriteAllText(exe, "test placeholder; never executed");
            var startup = new LoginStartup(testKey);
            if (startup.RegisteredCommand is not null) throw new Exception("Test key was not empty.");
            startup.SetEnabled(true, exe);
            string expected = $"\"{exe}\" --background";
            if (startup.RegisteredCommand != expected || !startup.IsEnabledFor(exe))
                throw new Exception("Quoted/unicode login command did not round-trip.");
            var reopened = new LoginStartup(testKey);
            if (!reopened.IsEnabledFor(exe)) throw new Exception("Registration did not persist.");
            startup.SetEnabled(true, exe); // idempotent enable
            using (var otherValue = Registry.CurrentUser.OpenSubKey(testKey, writable: true))
                otherValue!.SetValue("Unrelated", "preserve");
            startup.SetEnabled(false, exe);
            startup.SetEnabled(false, exe); // idempotent disable
            using (var check = Registry.CurrentUser.OpenSubKey(testKey))
                if (check?.GetValue("Unrelated") as string != "preserve")
                    throw new Exception("Disabling modified an unrelated value.");
            if (startup.RegisteredCommand is not null) throw new Exception("Disable left startup enabled.");
            foreach (string invalid in new[] { "CrossMouse.exe", "C:\\bad\"\\CrossMouse.exe", "C:\\dotnet.exe" })
            {
                try { LoginStartup.BuildCommand(invalid); throw new Exception("Invalid startup path accepted."); }
                catch (ArgumentException) { }
            }
            try
            {
                LoginStartup.BuildCommand("C:\\" + new string('x', 260) + "\\CrossMouse.exe");
                throw new Exception("Overlong startup command accepted.");
            }
            catch (ArgumentException) { }
            Console.WriteLine("PASS login registration, disable, quoted path, persistence; no real Run key changed");

            byte[] secret = RandomNumberGenerator.GetBytes(32);
            using var window = new CrossMouseWindow(secret, port: 0,
                startInBackground: true, loginStartup: startup);
            string instanceSuffix = Guid.NewGuid().ToString("N");
            using var instance = new SingleInstance(instanceSuffix);
            if (!instance.IsOwner) throw new Exception("Isolated test instance was already running.");
            instance.Listen(window);
            int shownCount = 0;
            window.Shown += (_, _) => shownCount++;
            using var watchdog = new System.Threading.Timer(_ =>
            {
                Console.Error.WriteLine("FAIL hidden startup watchdog");
                Environment.Exit(1);
            }, null, TimeSpan.FromSeconds(20), Timeout.InfiniteTimeSpan);
            using var checkTimer = new System.Windows.Forms.Timer { Interval = 100 };
            checkTimer.Tick += async (_, _) =>
            {
                if (!window.ReceiverRunningForTest) return;
                checkTimer.Stop();
                try
                {
                    if (window.Visible || shownCount != 0)
                        throw new Exception("Background launch flashed a visible window.");
                    await Program.CheckLoopbackHandshake(secret, window.ListeningPortForTest);
                    if (startup.RegisteredCommand is not null)
                        throw new Exception("Starting an app silently opted the user into auto-start.");
                    // Simulate a manual second launch, on another thread so
                    // a recursive mutex acquisition cannot hide a test error.
                    await Task.Run(() =>
                    {
                        using var duplicate = new SingleInstance(instanceSuffix);
                        if (duplicate.IsOwner) throw new Exception("Two receivers acquired single-instance ownership.");
                        duplicate.NotifyExisting();
                    });
                    for (int i = 0; i < 50 && !window.Visible; i++) await Task.Delay(20);
                    if (!window.Visible) throw new Exception("Tray could not reopen background-launched app.");
                    window.Close();
                    if (window.Visible || !window.ReceiverRunningForTest)
                        throw new Exception("X stopped a background-launched receiver.");
                    await Program.CheckLoopbackHandshake(secret, window.ListeningPortForTest);
                    await window.QuitForTestAsync();
                    if (window.ReceiverRunningForTest)
                        throw new Exception("Explicit Exit left the background receiver running.");
                    result = 0;
                    Console.WriteLine("PASS hidden login start, authenticated pong, single-instance reopen, X, explicit exit");
                }
                catch (Exception error)
                {
                    Console.Error.WriteLine("FAIL startup GUI: " + error);
                    await window.QuitForTestAsync();
                }
                finally { Application.ExitThread(); }
            };
            checkTimer.Start();
            Application.Run(window);
        }
        catch (Exception error) { Console.Error.WriteLine("FAIL startup: " + error); }
        finally
        {
            Registry.CurrentUser.DeleteSubKeyTree(testKey, throwOnMissingSubKey: false);
            if (Directory.Exists(temp)) Directory.Delete(temp, recursive: true);
        }
        return result;
    }
}
