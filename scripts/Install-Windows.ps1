[CmdletBinding()]
param(
    [switch]$InstallService,
    [switch]$UninstallService,
    [switch]$BuildOnly,
    [switch]$CiTest,
    [switch]$ElevatedStage,
    [string]$StagingPath,
    [string]$PairingKeyPath,
    [string]$OwnerSid,
    [int]$Port = 49431
)
$ErrorActionPreference = 'Stop'
$serviceName = 'CrossMouseInput'
$root = Join-Path $env:ProgramFiles 'CrossMouse'
$dataRoot = Join-Path $env:ProgramData 'CrossMouse'
$exe = Join-Path $root 'CrossMouse.exe'
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)

function Check-NativeResult([string]$operation) {
    if ($LASTEXITCODE -ne 0) { throw "$operation failed (exit $LASTEXITCODE)." }
}
function Protect-Directory([string]$path) {
    if (Test-Path -LiteralPath $path) {
        if ((Get-Item -LiteralPath $path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw "Refusing reparse-point installation directory: $path"
        }
    } else { [IO.Directory]::CreateDirectory($path) | Out-Null }
    $acl = New-Object Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true, $false)
    $acl.SetOwner([Security.Principal.SecurityIdentifier]'S-1-5-32-544')
    foreach ($sid in @('S-1-5-18', 'S-1-5-32-544')) {
        $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule(
            [Security.Principal.SecurityIdentifier]$sid, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')))
    }
    $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule(
        [Security.Principal.SecurityIdentifier]'S-1-5-32-545', 'ReadAndExecute', 'ContainerInherit,ObjectInherit', 'None', 'Allow')))
    Set-Acl -LiteralPath $path -AclObject $acl
}
function Protect-Key([string]$path) {
    $acl = New-Object Security.AccessControl.FileSecurity
    $acl.SetAccessRuleProtection($true, $false)
    $acl.SetOwner([Security.Principal.SecurityIdentifier]'S-1-5-32-544')
    foreach ($sid in @('S-1-5-18', 'S-1-5-32-544')) {
        $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule(
            [Security.Principal.SecurityIdentifier]$sid, 'FullControl', 'Allow')))
    }
    Set-Acl -LiteralPath $path -AclObject $acl
}
function Protect-ReadOnlyFile([string]$path) {
    $acl = New-Object Security.AccessControl.FileSecurity
    $acl.SetAccessRuleProtection($true, $false)
    $acl.SetOwner([Security.Principal.SecurityIdentifier]'S-1-5-32-544')
    foreach ($sid in @('S-1-5-18', 'S-1-5-32-544')) {
        $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule(
            [Security.Principal.SecurityIdentifier]$sid, 'FullControl', 'Allow')))
    }
    $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule(
        [Security.Principal.SecurityIdentifier]'S-1-5-32-545', 'ReadAndExecute', 'Allow')))
    Set-Acl -LiteralPath $path -AclObject $acl
}
function Stop-OwnedApps {
    foreach ($process in @(Get-Process CrossMouse, CrossMouse.Windows -ErrorAction SilentlyContinue)) {
        $path = $null
        try { $path = $process.Path } catch { continue }
        if (!$path) { continue }
        $parent = Split-Path -Path $path -Parent
        $leaf = Split-Path -Path $parent -Leaf
        if ($parent -ieq $root -or $leaf -match '^CrossMouse-built(?:-v[0-9]+)?$') {
            Stop-Process -Id $process.Id -Force
            $process.WaitForExit(3000) | Out-Null
        }
    }
}

if ($Port -lt 1024 -or $Port -gt 65535) { throw 'Invalid TCP port.' }
if ($CiTest -and $env:GITHUB_ACTIONS -ne 'true') { throw '-CiTest is reserved for the isolated CI runner.' }
if ($UninstallService) {
    if (!$isAdmin) { throw 'Run this uninstall command as administrator.' }
    $service = Get-Service $serviceName -ErrorAction SilentlyContinue
    if ($service) {
        if ($service.Status -ne 'Stopped') { Stop-Service $serviceName; $service.WaitForStatus('Stopped', [TimeSpan]::FromSeconds(15)) }
        & sc.exe delete $serviceName | Out-Host; Check-NativeResult 'Service removal'
    }
    Remove-NetFirewallRule -Name 'CrossMouse-Input-LAN' -ErrorAction SilentlyContinue
    Write-Host 'CrossMouse service removed. Pairing data, binaries and rollback copies were preserved.'
    return
}

if (!$ElevatedStage) {
    $project = Join-Path (Split-Path $PSScriptRoot -Parent) 'windows\CrossMouse.Windows.App\CrossMouse.Windows.App.csproj'
    $StagingPath = Join-Path $env:LOCALAPPDATA ('CrossMouse\build-' + [guid]::NewGuid().ToString('N'))
    & dotnet publish $project -c Release -r win-x64 --self-contained true `
        -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true -o $StagingPath
    Check-NativeResult 'CrossMouse build'
    if ($BuildOnly) { Write-Host "Built, not installed: $StagingPath"; return }
    if (!$InstallService) {
        Start-Process (Join-Path $StagingPath 'CrossMouse.exe')
        Write-Host "Ordinary login-session build: $StagingPath"
        Write-Host 'Login/UAC control requires the explicitly requested -InstallService option.'
        return
    }
    $OwnerSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $PairingKeyPath = Join-Path $env:LOCALAPPDATA 'CrossMouse\key'
    if ($CiTest) {
        $PairingKeyPath = Join-Path $StagingPath 'ci-pairing.txt'
        $key = New-Object byte[] 32
        $random = [Security.Cryptography.RandomNumberGenerator]::Create()
        try { $random.GetBytes($key) } finally { $random.Dispose() }
        [IO.File]::WriteAllText($PairingKeyPath, ([BitConverter]::ToString($key) -replace '-', ''))
        [Array]::Clear($key, 0, $key.Length)
    }
    if (!(Test-Path -LiteralPath $PairingKeyPath)) { throw 'Existing pairing key was not found; no key was reset or invented.' }
    if (!$isAdmin) {
        Write-Host 'Administrator approval will install the paired input service in Program Files.'
        Write-Host 'The paired Mac can then type into sign-in and UAC. Passwords, UAC and antivirus stay enabled.'
        $arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $PSCommandPath + '" -InstallService -ElevatedStage' +
            ' -StagingPath "' + $StagingPath + '" -PairingKeyPath "' + $PairingKeyPath + '" -OwnerSid "' + $OwnerSid + '" -Port ' + $Port
        $child = Start-Process powershell.exe -ArgumentList $arguments -Verb RunAs -Wait -PassThru
        if ($child.ExitCode -ne 0) { throw 'Service installation did not complete. Existing build and settings were preserved.' }
        Start-Process $exe
        return
    }
}

if (!$isAdmin -or !$InstallService) { throw 'Protected service installation requires administrator approval.' }
if ([string]::IsNullOrWhiteSpace($OwnerSid)) { throw 'Missing installing user identity.' }
$owner = New-Object Security.Principal.SecurityIdentifier($OwnerSid)
if (!$owner.IsAccountSid()) { throw 'The pipe owner must be a user account SID.' }
$sourceExe = Join-Path $StagingPath 'CrossMouse.exe'
if (!(Test-Path -LiteralPath $sourceExe)) { throw 'Built CrossMouse executable is missing.' }
$version = [Diagnostics.FileVersionInfo]::GetVersionInfo($sourceExe)
if ($version.ProductName -ne 'CrossMouse' -or $version.FileMajorPart -ne 0 -or $version.FileMinorPart -ne 5) {
    throw 'This installer accepts only the CrossMouse 0.5 build it created.'
}
$pairing = [IO.File]::ReadAllText($PairingKeyPath).Trim()
if ($pairing -notmatch '^[0-9a-fA-F]{64}$') { throw 'Pairing key must be exactly 32 bytes.' }

Protect-Directory $root
Protect-Directory $dataRoot
Protect-Directory (Join-Path $dataRoot 'bundles')
if (Get-ChildItem -LiteralPath $root -Force -Recurse | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }) {
    throw 'Refusing to update an installation containing a reparse point.'
}
$oldService = Get-Service $serviceName -ErrorAction SilentlyContinue
if ($oldService -and $oldService.Status -ne 'Stopped') {
    Stop-Service $serviceName; $oldService.WaitForStatus('Stopped', [TimeSpan]::FromSeconds(15))
}
Stop-OwnedApps
$backup = $null
if (Test-Path -LiteralPath $exe) {
    $backup = Join-Path $root ('backup-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
    Protect-Directory $backup
    Copy-Item -LiteralPath $exe -Destination (Join-Path $backup 'CrossMouse.exe')
}
try {
    Copy-Item -LiteralPath $sourceExe -Destination $exe -Force
    Protect-ReadOnlyFile $exe
    $keyPath = Join-Path $dataRoot 'key'
    if (Test-Path -LiteralPath $keyPath) {
        if ([IO.File]::ReadAllText($keyPath).Trim() -ine $pairing) { throw 'Existing protected pairing differs. Refusing an implicit re-pair.' }
    } else { [IO.File]::WriteAllText($keyPath, $pairing) }
    Protect-Key $keyPath
    $pairing = $null
    $configuration = @{ Port = $Port; OwnerSid = $OwnerSid; AllowLocalTestPeer = [bool]$CiTest } | ConvertTo-Json -Compress
    [IO.File]::WriteAllText((Join-Path $dataRoot 'service.json'), $configuration)
    Protect-ReadOnlyFile (Join-Path $dataRoot 'service.json')
    if (!$oldService) {
        New-Service -Name $serviceName -BinaryPathName ('"' + $exe + '" --service') -StartupType Automatic `
            -DisplayName 'CrossMouse paired input (login and secure desktop)' | Out-Null
    } else {
        & sc.exe config $serviceName binPath= ('"' + $exe + '" --service') start= auto | Out-Host
        Check-NativeResult 'Service configuration'
    }
    # Single-file native extraction is protected too; no SYSTEM DLLs in a user's Temp.
    $serviceRegistry = "HKLM:\SYSTEM\CurrentControlSet\Services\$serviceName"
    New-ItemProperty -Path $serviceRegistry -Name Environment -PropertyType MultiString -Force `
        -Value @('DOTNET_BUNDLE_EXTRACT_BASE_DIR=' + (Join-Path $dataRoot 'bundles')) | Out-Null
    & sc.exe failure $serviceName reset= 86400 actions= restart/3000/restart/10000/restart/30000 | Out-Host
    Check-NativeResult 'Service recovery'
    if (!$CiTest) {
        Remove-NetFirewallRule -Name 'CrossMouse-Input-LAN' -ErrorAction SilentlyContinue
        New-NetFirewallRule -Name 'CrossMouse-Input-LAN' -DisplayName 'CrossMouse paired input - local subnet only' `
            -Direction Inbound -Action Allow -Protocol TCP -LocalPort $Port -Program $exe -RemoteAddress LocalSubnet -Profile Any | Out-Null
        # Preserve opt-in: replace an existing CrossMouse login entry, never create one silently.
        $run = [Microsoft.Win32.Registry]::Users.OpenSubKey("$OwnerSid\Software\Microsoft\Windows\CurrentVersion\Run", $true)
        if ($run) {
            try {
                if ($null -ne $run.GetValue('CrossMouse')) { $run.SetValue('CrossMouse', ('"' + $exe + '" --background')) }
            } finally { $run.Dispose() }
        }
    }
    Start-Service $serviceName
    (Get-Service $serviceName).WaitForStatus('Running', [TimeSpan]::FromSeconds(15))
    Write-Host "Installed: $exe"
    Write-Host 'Boot service is running. The paired Mac must still be signed in and connected to the local network.'
    Write-Host 'This does not automate Windows PIN/password entry or disable UAC.'
    if ($backup) { Write-Host "Rollback executable: $backup" }
} catch {
    if ($backup) {
        Stop-Service $serviceName -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 800
        Copy-Item -LiteralPath (Join-Path $backup 'CrossMouse.exe') -Destination $exe -Force
        if ($oldService) { Start-Service $serviceName -ErrorAction SilentlyContinue }
    }
    throw
}
