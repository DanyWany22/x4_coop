@echo off
rem X4 Co-op: join a hosting partner. Start this before or after X4, then type /x4coop net in game.
rem Shows the telemetry overlay over the game (X4 borderless or windowed) and records a trace in traces\.
setlocal
where py >nul 2>nul && (set "PY=py -3") || (set "PY=python")
set /p "HOST=Host address (their Tailscale, home-network or public IP): "
:ask
set /p "PASSWORD=Shared password (same as the host's): "
if "%PASSWORD%"=="" goto ask
%PY% "%~dp0x4_coop_bridge.py" --join "%HOST%" --password "%PASSWORD%" --trace --overlay
pause
