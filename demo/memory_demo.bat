@echo off
rem X4 memory demo, not part of the co-op mod: finds your credits in X4's memory, reads them and writes a new
rem amount. Load a throwaway save first, and don't save afterwards.
setlocal
where py >nul 2>nul && (set "PY=py -3") || (set "PY=python")
%PY% "%~dp0x4_memory_demo.py"
pause
