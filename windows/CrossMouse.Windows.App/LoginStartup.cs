using Microsoft.Win32;

namespace CrossMouse.Windows.App;

/// <summary>
/// Optional, current-user-only login startup. Never changes Windows sign-in,
/// UAC, firewall, passwords, or startup entries belonging to other programs.
/// Register only from the user's explicit checkbox action.
/// </summary>
internal sealed class LoginStartup
{
    internal const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    internal const string ValueName = "CrossMouse";
    private readonly string _registryPath;

    // Tests use an isolated non-Run registry path, so they cannot enable an
    // actual login item or replace a real user's existing startup entry.
    internal LoginStartup(string registryPath = RunKey) => _registryPath = registryPath;

    internal string? RegisteredCommand
    {
        get
        {
            using var key = Registry.CurrentUser.OpenSubKey(_registryPath, writable: false);
            return key?.GetValue(ValueName, null, RegistryValueOptions.DoNotExpandEnvironmentNames) as string;
        }
    }

    internal bool IsEnabledFor(string exePath) =>
        string.Equals(RegisteredCommand, BuildCommand(exePath), StringComparison.OrdinalIgnoreCase);

    internal void SetEnabled(bool enabled, string exePath)
    {
        if (enabled)
        {
            string command = BuildCommand(exePath);
            if (!File.Exists(exePath)) throw new FileNotFoundException("실행 파일이 없습니다.", exePath);
            using var key = Registry.CurrentUser.CreateSubKey(_registryPath, writable: true);
            key.SetValue(ValueName, command, RegistryValueKind.String);
        }
        else
        {
            using var key = Registry.CurrentUser.OpenSubKey(_registryPath, writable: true);
            key?.DeleteValue(ValueName, throwOnMissingValue: false);
        }
    }

    internal static string BuildCommand(string exePath)
    {
        if (string.IsNullOrWhiteSpace(exePath) || !Path.IsPathFullyQualified(exePath) ||
            exePath.IndexOfAny(['"', '\r', '\n', '\0']) >= 0 ||
            !string.Equals(Path.GetFileName(exePath), "CrossMouse.exe", StringComparison.OrdinalIgnoreCase))
            throw new ArgumentException("고정된 폴더의 CrossMouse.exe에서 등록해 주세요.");
        string command = $"\"{exePath}\" --background";
        if (command.Length > 260)
            throw new ArgumentException("자동 실행 경로가 너무 깁니다. 더 짧은 폴더로 옮긴 뒤 등록하세요.");
        return command;
    }
}
