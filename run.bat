@echo off
rem Runs check.ps1 with Windows PowerShell. If scripts are blocked, that is
rem the first finding: the message below says so.
cd /d "%~dp0"
powershell.exe -NoProfile -File "%~dp0check.ps1"
if errorlevel 1 (
  echo.
  echo check.ps1 did not run, or stopped with an error.
  echo If the message above says "running scripts is disabled on this system",
  echo PowerShell scripts are blocked by policy. See README.md.
)
echo.
pause
