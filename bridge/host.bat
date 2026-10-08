@echo off
rem X4 Co-op: host a session. Your partner joins this PC's address on port 47810.
rem The first time, allow Python through Windows Firewall when asked, or your partner can't reach you.
setlocal
where py >nul 2>nul && (set "PY=py -3") || (set "PY=python")
echo Give your partner ONE of these addresses:
echo.
echo  - Tailscale:
tailscale ip -4 2>nul || echo      (Tailscale not installed)
echo  - Same home network (the 192.168... or 10... one):
ipconfig | findstr /c:"IPv4"
echo  - Over the internet: your public IP (search "what is my ip"). First forward
echo    UDP and TCP port 47810 on your router to this PC's home-network address.
echo.
:ask
set /p "PASSWORD=Shared password (letters, digits, spaces; over the internet 12+ characters): "
if "%PASSWORD%"=="" goto ask
%PY% "%~dp0x4_coop_bridge.py" --host --password "%PASSWORD%"
pause
