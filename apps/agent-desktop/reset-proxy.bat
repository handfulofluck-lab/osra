@echo off
REM OSRA emergency proxy reset (BUG-007): restores Windows' direct connection
REM when the agent was force-killed and its system-proxy setting survived on a dead
REM 127.0.0.1:8877 endpoint. Run as the same user the agent ran as, then reboot the browser.
reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings" /v ProxyEnable /t REG_DWORD /d 0 /f >nul
reg delete "HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings" /v ProxyServer /f >nul 2>&1
reg delete "HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings\Connections" /v DefaultConnectionSettings /f >nul 2>&1
reg delete "HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings\Connections" /v SavedLegacySettings /f >nul 2>&1
powershell -NoProfile -ExecutionPolicy Bypass -Command "$sig = @'
[System.Runtime.InteropServices.DllImport(\"wininet.dll\")]
public static extern bool InternetSetOption(System.IntPtr hInternet, int dwOption, System.IntPtr lpBuffer, int dwBufferLength);
'@; $type = Add-Type -MemberDefinition $sig -Name WinInet -Namespace FamilyShield -PassThru; [void]$type::InternetSetOption([System.IntPtr]::Zero, 39, [System.IntPtr]::Zero, 0); [void]$type::InternetSetOption([System.IntPtr]::Zero, 37, [System.IntPtr]::Zero, 0)" >nul 2>&1
echo OSRA proxy cleared - direct connection restored.
pause

