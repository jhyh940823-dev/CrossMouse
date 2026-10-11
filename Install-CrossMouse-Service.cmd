@echo off
setlocal
echo CrossMouse: install the paired Windows input service.
echo Keep your keyboard and mouse connected directly to this PC during installation.
echo Administrator approval is required. Windows sign-in and UAC will stay enabled.
echo This grants the paired Mac permission to send input to Windows sign-in and UAC.
echo.
choice /C YN /N /M "Install service? [Y/N] "
if errorlevel 2 exit /b 0
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\Install-Windows.ps1" -InstallService
set "result=%errorlevel%"
echo.
if not "%result%"=="0" echo Installation did not complete. Keep this window's error output.
pause
exit /b %result%
