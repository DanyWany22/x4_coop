@echo off
rem X4 Co-op: host a session. Your partner joins this PC's address (e.g. its Tailscale IP) on UDP 47810.
rem The first time, allow Python through Windows Firewall when asked, or your partner can't reach you.
setlocal
where py >nul 2>nul && (set "PY=py -3") || (set "PY=python")
echo Your Tailscale address (give it to your partner):
tailscale ip -4 2>nul || echo   (Tailscale not found - use your public or LAN address)
echo.
:ask
set /p "PASSWORD=Shared password (letters and digits; your partner types the same): "
if "%PASSWORD%"=="" goto ask
%PY% "%~dp0x4_coop_bridge.py" --host --password "%PASSWORD%"
pause
