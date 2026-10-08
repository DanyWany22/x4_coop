@echo off
rem X4 Co-op: compare two machines' traces. Drag both .jsonl files (this PC's and your partner's, from
rem bridge\traces) onto this file. Writes an HTML report next to the traces and opens it.
setlocal
where py >nul 2>nul && (set "PY=py -3") || (set "PY=python")
if "%~2"=="" (
  echo Drag two trace files onto report.bat: one from each PC, from bridge\traces\x4coop-*.jsonl
  pause
  exit /b 1
)
set "OUT=%~dp1report-%~n1.html"
%PY% "%~dp0x4_coop_trace_report.py" "%~1" "%~2" --html "%OUT%"
if exist "%OUT%" start "" "%OUT%"
pause
