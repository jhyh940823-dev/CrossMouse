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
    Stop-Service $serviceName
    (Get-Service $serviceName).WaitForStatus('Stopped', [TimeSpan]::FromSeconds(15))
    Start-Sleep -Seconds 2
    if (Get-Process -Id $state.AgentPid -ErrorAction SilentlyContinue) { throw 'Owned SYSTEM input agent survived service stop.' }
    Write-Host 'PASS graceful service stop and bounded agent lifetime'
} finally {
    & (Join-Path $PSScriptRoot 'Install-Windows.ps1') -UninstallService
}
