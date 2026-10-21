@echo off
rem Windows launcher for please.ps1: please <command> [args]
rem
rem The arguments are handed over through the environment instead of on the
rem command line, because "powershell -File" re-parses them and splits CMake
rem arguments such as -DFOO:BOOL=ON at the colon. please.ps1 tokenizes
rem PLEASE_ARGS itself.
setlocal
set PLEASE_BAT=1
set PLEASE_ARGS=%*
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0please.ps1"
exit /b %ERRORLEVEL%
