@echo off
rem X4 Co-op: record the co-op traffic with Windows' own Packet Monitor (pktmon), independently of the bridge.
rem Every packet to or from port 47810 (the UDP game link and the TCP save transfer), with its IP and UDP/TCP
rem headers. Needs administrator rights: right-click this file, "Run as administrator".
setlocal
net session >nul 2>&1 || (echo Run this as administrator: right-click capture.bat, Run as administrator. & pause & exit /b 1)
for /f %%t in ('powershell -NoProfile -Command "Get-Date -Format yyyyMMdd-HHmmss"') do set "STAMP=%%t"
if not exist "%~dp0traces" mkdir "%~dp0traces"
set "OUT=%~dp0traces\capture-%COMPUTERNAME%-%STAMP%"
pktmon filter remove >nul
pktmon filter add X4Coop -p 47810 >nul
pktmon start --capture --comp nics --pkt-size 0 --file-name "%OUT%.etl" >nul || (echo pktmon could not start. & pktmon filter remove >nul & pause & exit /b 1)
echo Capturing every packet to or from port 47810. Play, then press a key here to stop.
pause >nul
pktmon stop >nul
pktmon filter remove >nul
pktmon etl2pcap "%OUT%.etl" --out "%OUT%.pcapng" >nul
pktmon etl2txt "%OUT%.etl" --out "%OUT%.txt" --hex >nul
echo.
echo Saved in %~dp0traces:
echo   capture-%COMPUTERNAME%-%STAMP%.pcapng  open in Wireshark, filter: udp.port == 47810
echo   capture-%COMPUTERNAME%-%STAMP%.txt     the same packets as text, headers and bytes
echo Each datagram's payload starts with 58 34 43 32 20 ("X4C2 "), then the HMAC tag that the
echo bridge's trace (x4coop-*.jsonl) lists for the same packet.
pause
