$ErrorActionPreference = 'Stop'
if ($env:GITHUB_ACTIONS -ne 'true') { throw 'This test installs a temporary service only on the isolated CI runner.' }
$serviceName = 'CrossMouseInput'
if (Get-Service $serviceName -ErrorAction SilentlyContinue) { throw 'Refusing to alter a pre-existing service.' }
try {
    & (Join-Path $PSScriptRoot 'Install-Windows.ps1') -InstallService -CiTest -Port 49439
    $status = Join-Path $env:ProgramData 'CrossMouse\status.json'
    $deadline = (Get-Date).AddSeconds(15)
    while (!(Test-Path $status) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 250 }
    if (!(Test-Path $status)) {
        $lastError = Join-Path $env:ProgramData 'CrossMouse\last-error.txt'
        if (Test-Path $lastError) { Get-Content $lastError | Write-Host }
        throw 'SYSTEM console agent did not produce status.'
    }
    $state = Get-Content $status -Raw | ConvertFrom-Json
    if ($state.SessionId -eq 0) { throw 'Service input agent incorrectly ran in session zero.' }
    $protectedKey = Join-Path $env:ProgramData 'CrossMouse\credentials\key'
    $access = (Get-Acl $protectedKey).Access
    foreach ($entry in $access) {
        $sid = $entry.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value
        if ($entry.AccessControlType -eq 'Allow' -and $sid -notin @('S-1-5-18','S-1-5-32-544')) {
            throw 'Service pairing key granted access outside SYSTEM/Administrators.'
        }
    }
    Write-Host 'PASS boot service, protected key ACL, interactive agent status'
    $exe = Join-Path $env:ProgramFiles 'CrossMouse\CrossMouse.exe'
    $process = Start-Process $exe -ArgumentList '--service-boundary-test' -NoNewWindow -PassThru -Wait
    if ($process.ExitCode -ne 0) { throw "Service desktop test failed: $($process.ExitCode)" }
    # A failed upgrade must restore the last working binary/configuration and
    # restart the previously running agent; not merely leave files on disk.
    $beforeHash = (Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash
    $config = Join-Path $env:ProgramData 'CrossMouse\service.json'
    $beforeConfig = [IO.File]::ReadAllText($config)
    $injected = $false
    try {
        & (Join-Path $PSScriptRoot 'Install-Windows.ps1') -InstallService -CiTest -CiFailAfterReady -Port 49439
    } catch {
        if ($_.Exception.Message -notmatch 'CI injected install failure') { throw }
        $injected = $true
    }
    if (!$injected -or (Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash -ne $beforeHash -or
        [IO.File]::ReadAllText($config) -ne $beforeConfig -or (Get-Service $serviceName).Status -ne 'Running') {
        throw 'Failed upgrade did not restore the previous executable, configuration and running service.'
    }
    $deadline = (Get-Date).AddSeconds(15)
    do {
        $state = Get-Content $status -Raw | ConvertFrom-Json
        if ($state.State -in @('Waiting', 'Connected') -and
            (Get-Process -Id $state.AgentPid -ErrorAction SilentlyContinue)) { break }
        Start-Sleep -Milliseconds 250
    } while ((Get-Date) -lt $deadline)
    if (!(Get-Process -Id $state.AgentPid -ErrorAction SilentlyContinue)) { throw 'Rollback agent did not restart.' }
    $process = Start-Process $exe -ArgumentList '--service-boundary-test' -NoNewWindow -PassThru -Wait
    if ($process.ExitCode -ne 0) { throw 'Restored service failed its encrypted desktop/input check.' }
    Write-Host 'PASS failed upgrade restores binary/configuration and authenticated input service'
    Stop-Service $serviceName
    (Get-Service $serviceName).WaitForStatus('Stopped', [TimeSpan]::FromSeconds(15))
    Start-Sleep -Seconds 2
    if (Get-Process -Id $state.AgentPid -ErrorAction SilentlyContinue) { throw 'Owned SYSTEM input agent survived service stop.' }
    Write-Host 'PASS graceful service stop and bounded agent lifetime'
} finally {
    $probe = Join-Path $env:ProgramData 'CrossMouse\desktop-permissions.json'
    if (Test-Path $probe) { Get-Content $probe -Raw | Write-Host }
    & (Join-Path $PSScriptRoot 'Install-Windows.ps1') -UninstallService
}
