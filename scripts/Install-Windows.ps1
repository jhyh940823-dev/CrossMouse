[CmdletBinding()]
param(
    [switch]$InstallService,
    [switch]$UninstallService,
    [switch]$BuildOnly,
    [switch]$CiTest,
    [switch]$CiFailAfterReady,
    [switch]$ElevatedStage,
    [string]$StagingPath,
    [string]$PairingKeyPath,
    [string]$OwnerSid,
    [string]$ExpectedHash,
    [int]$Port = 49431
)
$ErrorActionPreference = 'Stop'
$serviceName = 'CrossMouseInput'
$root = Join-Path $env:ProgramFiles 'CrossMouse'
$dataRoot = Join-Path $env:ProgramData 'CrossMouse'
$credentials = Join-Path $dataRoot 'credentials'
$exe = Join-Path $root 'CrossMouse.exe'
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)

function Check-NativeResult([string]$operation) {
    if ($LASTEXITCODE -ne 0) { throw "$operation failed (exit $LASTEXITCODE)." }
}
function Protect-Directory([string]$path, [switch]$Private) {
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
    if (!$Private) {
        $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule(
            [Security.Principal.SecurityIdentifier]'S-1-5-32-545', 'ReadAndExecute', 'ContainerInherit,ObjectInherit', 'None', 'Allow')))
    }
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
function Protect-Tree([string]$path, [bool]$Private = $false) {
    if ($path -ieq $credentials) { $Private = $true }
    Protect-Directory $path -Private:$Private
    # Enumerate one level at a time. Never follow a junction while recursively
    # looking for junctions, and never retain an old writable child ACL.
    foreach ($child in @(Get-ChildItem -LiteralPath $path -Force)) {
        if ($child.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Refusing reparse point: $($child.FullName)" }
        if ($child.PSIsContainer) { Protect-Tree $child.FullName $Private }
        elseif ($Private -or $child.FullName -ieq (Join-Path $dataRoot 'key')) { Protect-Key $child.FullName }
        else { Protect-ReadOnlyFile $child.FullName }
    }
}
function Assert-TrustedRoot([string]$path) {
    if (!(Test-Path -LiteralPath $path)) { return }
    $item = Get-Item -LiteralPath $path -Force
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Refusing reparse-point root: $path" }
    $acl = Get-Acl -LiteralPath $path
    $owner = $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value
    if ($owner -notin @('S-1-5-18','S-1-5-32-544')) { throw "Refusing a service directory owned by an untrusted principal: $path" }
    $write = [Security.AccessControl.FileSystemRights]'Write,Modify,Delete,ChangePermissions,TakeOwnership'
    foreach ($entry in $acl.Access) {
        $sid = $entry.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value
        if ($entry.AccessControlType -eq 'Allow' -and $sid -notin @('S-1-5-18','S-1-5-32-544') -and
            ($entry.FileSystemRights -band $write)) { throw "Refusing a writable pre-existing service directory: $path" }
    }
}
function Open-InstalledControls {
    $desktop = [Environment]::GetFolderPath('DesktopDirectory')
    if ($desktop) {
        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut((Join-Path $desktop 'CrossMouse.lnk'))
        $shortcut.TargetPath = $exe; $shortcut.WorkingDirectory = $root
        $shortcut.Save()
    }
    Start-Process $exe
}

if ($Port -lt 1024 -or $Port -gt 65535) { throw 'Invalid TCP port.' }
if ($CiTest -and $env:GITHUB_ACTIONS -ne 'true') { throw '-CiTest is reserved for the isolated CI runner.' }
if ($CiFailAfterReady -and (!$CiTest -or $env:GITHUB_ACTIONS -ne 'true')) { throw 'Failure injection is CI-only.' }
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
    $ExpectedHash = (Get-FileHash -LiteralPath (Join-Path $StagingPath 'CrossMouse.exe') -Algorithm SHA256).Hash
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
        $existingTestKey = Join-Path $credentials 'key'
        if (Test-Path -LiteralPath $existingTestKey) { $PairingKeyPath = $existingTestKey }
        else {
            $PairingKeyPath = Join-Path $StagingPath 'ci-pairing.txt'
            $key = New-Object byte[] 32
            $random = [Security.Cryptography.RandomNumberGenerator]::Create()
            try { $random.GetBytes($key) } finally { $random.Dispose() }
            [IO.File]::WriteAllText($PairingKeyPath, ([BitConverter]::ToString($key) -replace '-', ''))
            [Array]::Clear($key, 0, $key.Length)
        }
    }
    if (!(Test-Path -LiteralPath $PairingKeyPath)) { throw 'Existing pairing key was not found; no key was reset or invented.' }
    if (!$isAdmin) {
        Write-Host 'Administrator approval will install the paired input service in Program Files.'
        Write-Host 'The paired Mac can then type into sign-in and UAC. Passwords, UAC and antivirus stay enabled.'
        $arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $PSCommandPath + '" -InstallService -ElevatedStage' +
            ' -StagingPath "' + $StagingPath + '" -PairingKeyPath "' + $PairingKeyPath + '" -OwnerSid "' + $OwnerSid + '" -Port ' + $Port
        $arguments += ' -ExpectedHash ' + $ExpectedHash
        $child = Start-Process powershell.exe -ArgumentList $arguments -Verb RunAs -Wait -PassThru
        if ($child.ExitCode -ne 0) { throw 'Service installation did not complete. Existing build and settings were preserved.' }
        Open-InstalledControls
        return
    }
}

if (!$isAdmin -or !$InstallService) { throw 'Protected service installation requires administrator approval.' }
if ([string]::IsNullOrWhiteSpace($OwnerSid)) { throw 'Missing installing user identity.' }
$owner = New-Object Security.Principal.SecurityIdentifier($OwnerSid)
if (!$owner.IsAccountSid()) { throw 'The pipe owner must be a user account SID.' }
$sourceExe = Join-Path $StagingPath 'CrossMouse.exe'
if (!(Test-Path -LiteralPath $sourceExe)) { throw 'Built CrossMouse executable is missing.' }
if ($ExpectedHash -notmatch '^[0-9a-fA-F]{64}$' -or
    (Get-FileHash -LiteralPath $sourceExe -Algorithm SHA256).Hash -ine $ExpectedHash) {
    throw 'The built executable changed before administrator installation.'
}
$version = [Diagnostics.FileVersionInfo]::GetVersionInfo($sourceExe)
if ($version.ProductName -ne 'CrossMouse' -or $version.FileMajorPart -ne 0 -or $version.FileMinorPart -ne 5) {
    throw 'This installer accepts only the CrossMouse 0.5 build it created.'
}
$pairing = [IO.File]::ReadAllText($PairingKeyPath).Trim()
if ($pairing -notmatch '^[0-9a-fA-F]{64}$') { throw 'Pairing key must be exactly 32 bytes.' }

$oldServiceInfo = Get-CimInstance Win32_Service -Filter "Name='$serviceName'"
if ($oldServiceInfo -and ($oldServiceInfo.PathName -ine ('"' + $exe + '" --service') -or
    $oldServiceInfo.StartName -notin @('LocalSystem', 'NT AUTHORITY\SYSTEM'))) {
    throw 'A different service owns the CrossMouseInput name. Refusing to stop or replace it.'
}
$serviceRegistry = "HKLM:\SYSTEM\CurrentControlSet\Services\$serviceName"
$oldEnvironment = $null; $oldRecovery = $null
if ($oldServiceInfo) {
    $oldEnvironment = (Get-ItemProperty -LiteralPath $serviceRegistry -Name Environment -ErrorAction SilentlyContinue).Environment
    $oldRecovery = (Get-ItemProperty -LiteralPath $serviceRegistry -Name FailureActions -ErrorAction SilentlyContinue).FailureActions
}
$oldFirewall = $null
if (!$CiTest) {
    $oldFirewall = Get-NetFirewallRule -Name 'CrossMouse-Input-LAN' -ErrorAction SilentlyContinue
    if ($oldFirewall) {
        $application = $oldFirewall | Get-NetFirewallApplicationFilter
        $ports = $oldFirewall | Get-NetFirewallPortFilter
        $addresses = $oldFirewall | Get-NetFirewallAddressFilter
        if (!$oldServiceInfo -or @($oldFirewall).Count -ne 1 -or
            $application.Program -ine $exe -or $ports.Protocol -notin @('TCP', '6') -or
            [string]$ports.LocalPort -ne [string]$Port -or [string]$addresses.RemoteAddress -ne 'LocalSubnet' -or
            $oldFirewall.Action -ne 'Allow' -or $oldFirewall.Direction -ne 'Inbound') {
            throw 'A different firewall rule owns the CrossMouse name. No rule was changed.'
        }
    }
}
$firewallCreated = $false
$runChanged = $false; $oldRunCommand = $null
$runPath = "$OwnerSid\Software\Microsoft\Windows\CurrentVersion\Run"

Assert-TrustedRoot $root
Assert-TrustedRoot $dataRoot
Protect-Tree $root
Protect-Tree $dataRoot
Protect-Directory $credentials -Private
Protect-Directory (Join-Path $dataRoot 'bundles')
$keyPath = Join-Path $credentials 'key'
if ((Test-Path -LiteralPath $keyPath) -and [IO.File]::ReadAllText($keyPath).Trim() -ine $pairing) {
    throw 'Existing protected pairing differs. Refusing an implicit re-pair.'
}
$configPath = Join-Path $dataRoot 'service.json'
$oldConfig = if (Test-Path -LiteralPath $configPath) { [IO.File]::ReadAllBytes($configPath) } else { $null }
$oldService = Get-Service $serviceName -ErrorAction SilentlyContinue
$wasRunning = $oldService -and $oldService.Status -ne 'Stopped'
$backup = $null
if (Test-Path -LiteralPath $exe) {
    $backup = Join-Path $root ('backup-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N'))
    Protect-Directory $backup
    Copy-Item -LiteralPath $exe -Destination (Join-Path $backup 'CrossMouse.exe')
}
try {
    # Backup succeeded before stopping a working installation. From this point
    # every mutation is inside the rollback boundary.
    if ($oldService -and $oldService.Status -ne 'Stopped') {
        Stop-Service $serviceName; $oldService.WaitForStatus('Stopped', [TimeSpan]::FromSeconds(15))
    }
    Stop-OwnedApps
    $newExe = Join-Path $root ('install-' + [guid]::NewGuid().ToString('N') + '.tmp')
    Copy-Item -LiteralPath $sourceExe -Destination $newExe
    Protect-ReadOnlyFile $newExe
    if ((Get-FileHash -LiteralPath $newExe -Algorithm SHA256).Hash -ine $ExpectedHash) { throw 'Staged binary changed during copy.' }
    if (Test-Path -LiteralPath $exe) { [IO.File]::Replace($newExe, $exe, $null) }
    else { [IO.File]::Move($newExe, $exe) }
    Protect-ReadOnlyFile $exe
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
    New-ItemProperty -Path $serviceRegistry -Name Environment -PropertyType MultiString -Force `
        -Value @('DOTNET_BUNDLE_EXTRACT_BASE_DIR=' + (Join-Path $dataRoot 'bundles')) | Out-Null
    & sc.exe failure $serviceName reset= 86400 actions= restart/3000/restart/10000/restart/30000 | Out-Host
    Check-NativeResult 'Service recovery'
    $startedAt = [DateTime]::UtcNow
    Start-Service $serviceName
    (Get-Service $serviceName).WaitForStatus('Running', [TimeSpan]::FromSeconds(15))
    $deadline = [DateTime]::UtcNow.AddSeconds(15)
    $healthy = $false
    while ([DateTime]::UtcNow -lt $deadline) {
        try {
            $status = Get-Content -LiteralPath (Join-Path $dataRoot 'status.json') -Raw | ConvertFrom-Json
            if ([DateTime]$status.UpdatedUtc -ge $startedAt -and $status.SessionId -gt 0 -and
                $status.Version -eq '0.5.0' -and $status.State -in @('Waiting', 'Connected')) { $healthy = $true; break }
        } catch { }
        Start-Sleep -Milliseconds 250
    }
    if (!$healthy) {
        $lastError = Join-Path $dataRoot 'last-error.txt'
        if (Test-Path $lastError) { Get-Content $lastError | Write-Host }
        throw 'The service started but its interactive input agent did not become ready. Installation will roll back.'
    }
    if ($CiFailAfterReady) { throw 'CI injected install failure after the new agent became ready.' }
    # Publish the network/login entry only after the replacement is healthy.
    # Never delete/recreate an existing rule, and roll back only our own writes.
    if (!$CiTest) {
        if (!$oldFirewall) {
            New-NetFirewallRule -Name 'CrossMouse-Input-LAN' -DisplayName 'CrossMouse paired input - local subnet only' `
                -Direction Inbound -Action Allow -Protocol TCP -LocalPort $Port -Program $exe -RemoteAddress LocalSubnet -Profile Any | Out-Null
            $firewallCreated = $true
        }
        $run = [Microsoft.Win32.Registry]::Users.OpenSubKey($runPath, $true)
        if ($run) {
            try {
                $oldRunCommand = $run.GetValue('CrossMouse')
                if ($null -ne $oldRunCommand) {
                    $runChanged = $true
                    $run.SetValue('CrossMouse', ('"' + $exe + '" --background'))
                }
            } finally { $run.Dispose() }
        }
    }
    Write-Host "Installed: $exe"
    Write-Host 'Boot service is running. The paired Mac must still be signed in and connected to the local network.'
    Write-Host 'This does not automate Windows PIN/password entry or disable UAC.'
    if ($backup) { Write-Host "Rollback executable: $backup" }
    if (!$CiTest -and !$ElevatedStage) { Open-InstalledControls }
} catch {
    $originalFailure = $_
    $failedService = Get-Service $serviceName -ErrorAction SilentlyContinue
    if ($failedService -and $failedService.Status -ne 'Stopped') {
        Stop-Service $serviceName
        $failedService.WaitForStatus('Stopped', [TimeSpan]::FromSeconds(15))
    }
    if ($firewallCreated) { Remove-NetFirewallRule -Name 'CrossMouse-Input-LAN' -ErrorAction SilentlyContinue }
    if ($runChanged) {
        $run = [Microsoft.Win32.Registry]::Users.OpenSubKey($runPath, $true)
        if ($run) { try { $run.SetValue('CrossMouse', $oldRunCommand) } finally { $run.Dispose() } }
    }
    if (!$oldService -and (Get-Service $serviceName -ErrorAction SilentlyContinue)) {
        & sc.exe delete $serviceName | Out-Host
    }
    if ($oldServiceInfo) {
        if ($null -ne $oldEnvironment) {
            New-ItemProperty -LiteralPath $serviceRegistry -Name Environment -PropertyType MultiString -Value $oldEnvironment -Force | Out-Null
        } else { Remove-ItemProperty -LiteralPath $serviceRegistry -Name Environment -ErrorAction SilentlyContinue }
        if ($null -ne $oldRecovery) {
            New-ItemProperty -LiteralPath $serviceRegistry -Name FailureActions -PropertyType Binary -Value $oldRecovery -Force | Out-Null
        } else { Remove-ItemProperty -LiteralPath $serviceRegistry -Name FailureActions -ErrorAction SilentlyContinue }
        $mode = switch ($oldServiceInfo.StartMode) { 'Auto' { 'Automatic' } 'Disabled' { 'Disabled' } default { 'Manual' } }
        Set-Service -Name $serviceName -StartupType $mode
    }
    if ($oldConfig) { [IO.File]::WriteAllBytes($configPath, $oldConfig) }
    elseif (Test-Path -LiteralPath $configPath) { Remove-Item -LiteralPath $configPath }
    if ($backup) {
        Start-Sleep -Milliseconds 800
        Copy-Item -LiteralPath (Join-Path $backup 'CrossMouse.exe') -Destination $exe -Force
        if ($wasRunning) { Start-Service $serviceName -ErrorAction SilentlyContinue }
    }
    throw $originalFailure
}
