@echo off
rem laptop-check: what does this Windows machine let me build and run?
rem
rem Batch on purpose. On a locked laptop .ps1 files are the first thing
rem blocked, and a check that cannot start reports nothing. Python-specific
rem checks are in probe.py, started with the first Python that works.
rem It installs nothing, changes no settings, and deletes what it creates.
rem
rem Rule for editing this file: inside ( ) blocks use !var!, never %var%.
rem A path like "C:\Program Files (x86)" expanded with %...% ends the block.
setlocal EnableExtensions EnableDelayedExpansion
chcp 65001 >nul
cd /d "%~dp0"
set "ROOT=%~dp0"
set "T=20"

rem --- guard: started from inside a ZIP, before it was extracted
echo "%ROOT%" | findstr /i /c:".zip\\" >nul
if not errorlevel 1 (
  echo.
  echo  This is running from inside the ZIP file. Extract it first:
  echo  right-click the ZIP, Extract All, then run run.bat from the new folder.
  echo.
  pause
  exit /b 1
)

set "W=%TEMP%\laptop-check-%RANDOM%%RANDOM%"
mkdir "%W%" 2>nul
set "RES=%W%\results.txt"
type nul >"%RES%"
for /f %%e in ('echo prompt $E ^| cmd') do set "ESC=%%e"

rem --- where the report goes: results\, or %TEMP% when that is not writable
set "OUT=%ROOT%results"
set "OUTMOVED="
mkdir "%OUT%" 2>nul
((echo x)>"%OUT%\.probe") 2>nul
if exist "%OUT%\.probe" (del "%OUT%\.probe") else (
  set "OUT=%TEMP%\laptop-check-results"
  set "OUTMOVED=1"
  mkdir "!OUT!" 2>nul
)

rem --- runwait: a command with a time limit. job.bat runs %JOBCMD% and
rem writes JOBOUT, then JOBOUT.done; the caller polls for the .done file.
>"%W%\job.bat" echo @%%JOBCMD%% ^>"%%JOBOUT%%" 2^>^&1
>>"%W%\job.bat" echo @^>"%%JOBOUT%%.done" echo %%errorlevel%%

rem --- targets: defaults, then apps.txt (kept local, see apps.example.txt)
set "HOSTS=github.com pypi.org files.pythonhosted.org www.python.org"
set "PORTS="
set "WHEELS="
set "MINPY=3.10"
if exist "%ROOT%apps.txt" (
  for /f "usebackq eol=# tokens=1,2,3" %%a in ("%ROOT%apps.txt") do (
    if /i "%%a"=="host" set "HOSTS=!HOSTS! %%b"
    if /i "%%a"=="port" set "PORTS=!PORTS! %%b"
    if /i "%%a"=="wheel" set "WHEELS=!WHEELS! %%b:%%c"
    if /i "%%a"=="python" set "MINPY=%%b"
  )
  set "TARGETS=apps.txt"
) else (
  set "TARGETS=defaults (no apps.txt)"
)
if not defined PORTS set "PORTS=8000"

echo.
echo  laptop-check: testing what this machine lets you do. Takes a few minutes.
echo  Targets: !TARGETS!
echo.

rem ================================================================ shell
rem PowerShell matters only to apps that ship .ps1 files: this tool needs none.
rem Started from PowerShell 7, PSModulePath points Windows PowerShell at
rem modules it cannot load and Get-ExecutionPolicy fails. Empty, it uses its own.
set "PSModulePath="
set "GPO="
for %%h in (HKLM HKCU) do (
  for /f "tokens=3" %%v in ('reg query "%%h\SOFTWARE\Policies\Microsoft\Windows\PowerShell" /v ExecutionPolicy 2^>nul ^| findstr /i ExecutionPolicy') do set "GPO=!GPO!%%h=%%v "
)
set "EPL="
rem no single quotes inside: for /f uses them to delimit the command
for /f "tokens=1,2" %%a in ('powershell -NoProfile -Command "Get-ExecutionPolicy -List | Format-Table -HideTableHeaders" 2^>nul') do set "EPL=!EPL!%%a=%%b "
>"%W%\ep.txt" echo(!EPL!
set "A=PowerShell" & set "C=running .ps1 scripts"
if defined GPO (
  set "S=WARN" & set "D=set by Group Policy: !GPO!" & set "K=I"
  set "F=PowerShell scripts are blocked by Group Policy. Ask IT to allow RemoteSigned for your user, or to sign the scripts you need. Meanwhile use the .bat or .cmd version of a script, e.g. .venv\Scripts\activate.bat instead of Activate.ps1."
) else if not defined EPL (
  set "S=WARN" & set "D=powershell.exe did not start" & set "K=W"
  set "F=PowerShell itself is blocked. Use .bat or .cmd versions of any script."
) else (
  findstr /i /c:"CurrentUser=RemoteSigned" /c:"CurrentUser=Unrestricted" /c:"CurrentUser=Bypass" /c:"LocalMachine=RemoteSigned" /c:"LocalMachine=Unrestricted" /c:"LocalMachine=Bypass" "%W%\ep.txt" >nul
  if errorlevel 1 (
    set "S=WARN" & set "D=Windows default, not set by IT: !EPL!" & set "K=S"
    set "F=This is the Windows default, not an IT rule. You can allow your own scripts with: powershell -Command Set-ExecutionPolicy -Scope CurrentUser RemoteSigned. Check your IT rules first. Often you do not need it: use activate.bat, not Activate.ps1."
  ) else (
    set "S=PASS" & set "D=!EPL!"
  )
)
call :emit
set "LM="
for /f "delims=" %%l in ('powershell -NoProfile -Command "$ExecutionContext.SessionState.LanguageMode" 2^>nul') do set "LM=%%l"
if defined LM (
  set "A=PowerShell" & set "C=language mode" & set "D=!LM!"
  if /i "!LM!"=="FullLanguage" (set "S=PASS") else (set "S=WARN" & set "D=!LM!: an application-control policy is active, expect blocked programs below")
  call :emit
)

rem ================================================================ rights
whoami /groups >"%W%\groups.txt" 2>nul
set "A=Rights" & set "C=administrator" & set "S=INFO"
net session >nul 2>&1
if not errorlevel 1 (
  set "D=running elevated, as administrator"
) else (
  findstr /c:"S-1-5-32-544" "%W%\groups.txt" >nul
  if not errorlevel 1 (set "D=in the Administrators group, but not elevated now") else (set "D=not an administrator: install tools for your user only, never into Program Files")
)
call :emit

rem real Documents and Downloads, which may be redirected to OneDrive
set "DOCS="
for /f "tokens=2,*" %%a in ('reg query "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders" /v Personal 2^>nul ^| findstr /i Personal') do set "DOCS=%%b"
if defined DOCS (call set "DOCS=!DOCS!") else (set "DOCS=%USERPROFILE%\Documents")
set "DL="
for /f "tokens=2,*" %%a in ('reg query "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders" /v "{374DE290-123F-4565-9164-39C4925E467B}" 2^>nul ^| findstr /i 374DE290') do set "DL=%%b"
if defined DL (call set "DL=!DL!") else (set "DL=%USERPROFILE%\Downloads")

call :canwrite "the user profile" "%USERPROFILE%" fail
call :canwrite "LOCALAPPDATA" "%LOCALAPPDATA%" fail
call :canwrite "Documents" "%DOCS%" fail
call :canwrite "Downloads" "%DL%" fail
call :canwrite "the root of C:" "C:\" expected
call :canwrite "Program Files" "%ProgramFiles%" expected

rem ================================================================ running code
set "CSC=%WINDIR%\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
if not exist "%CSC%" set "CSC=%WINDIR%\Microsoft.NET\Framework\v4.0.30319\csc.exe"
>"%W%\hello.cs" echo public static class P { public static int Main() { System.Console.WriteLine("ok"); return 0; } }
set "A=Running code" & set "C=build a small .exe (C# compiler in Windows)"
set "HAVEEXE="
if not exist "%CSC%" (
  set "S=FAIL" & set "D=no csc.exe in .NET Framework 4" & set "K=W"
  set "F=.exe launchers cannot be built here. Start the apps from their scripts instead."
  call :emit
) else (
  "%CSC%" /nologo /out:"%W%\hello.exe" "%W%\hello.cs" >"%W%\csc.txt" 2>&1
  call :sleep 3
  if exist "%W%\hello.exe" (
    set "S=PASS" & set "D=compiled and still there 3 s later" & set "HAVEEXE=1"
  ) else (
    set "D=" & set /p D=<"%W%\csc.txt"
    if exist "%W%\csc.txt" if "!D!"=="" set "D=the .exe vanished after compiling: antivirus removed it"
    set "S=FAIL" & set "K=W" & set "F=Antivirus or policy removes freshly built programs. Start the apps from their scripts instead of their .exe launchers."
  )
  call :emit
)
if defined HAVEEXE (
  call :runexe "the temp folder" "%W%" plain
  call :runexe "LOCALAPPDATA" "%LOCALAPPDATA%" plain
  call :runexe "Documents" "%DOCS%" plain
  call :runexe "Downloads, marked as downloaded" "%DL%" motw
)
set "A=Running code" & set "C=run a .bat from Documents"
set "PB=%DOCS%\laptop-check-%RANDOM%.bat"
((echo @echo ok)>"%PB%") 2>nul
set "BOUT="
if exist "%PB%" for /f "delims=" %%l in ('call "%PB%" 2^>^&1') do set "BOUT=%%l"
del "%PB%" 2>nul
if "!BOUT!"=="ok" (set "S=PASS" & set "D=batch files run from Documents") else (
  set "S=FAIL" & set "D=!BOUT!" & set "K=I"
  set "F=Batch files are blocked outside system folders. Ask IT which folder is allowed for your tools."
)
call :emit

rem ================================================================ network
set "A=Network" & set "C=proxy" & set "S=INFO"
set "PX="
for /f "tokens=1,2,*" %%a in ('reg query "HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings" 2^>nul ^| findstr /i "ProxyEnable ProxyServer AutoConfigURL"') do set "PX=!PX!%%a=%%c "
for /f "delims=" %%l in ('netsh winhttp show proxy 2^>nul ^| findstr /i /c:"Direct access" /c:"Proxy Server"') do set "PX=!PX!winhttp: %%l "
if defined HTTPS_PROXY set "PX=!PX!HTTPS_PROXY set "
if not defined PX set "PX=none found"
set "D=!PX!"
call :emit

where curl.exe >nul 2>&1
if errorlevel 1 (
  set "A=Network" & set "C=curl.exe" & set "S=WARN" & set "D=not found: network checks skipped" & call :emit
) else (
  for %%h in (!HOSTS!) do call :host %%h
)

rem ================================================================ files
set "A=Files" & set "C=Documents and OneDrive"
rem pipes run each side in a new cmd without delayed expansion, so use a file
>"%W%\docs.txt" echo(!DOCS!
findstr /i "OneDrive" "%W%\docs.txt" >nul
if not errorlevel 1 (
  set "S=WARN" & set "D=!DOCS!" & set "K=S"
  set "F=Documents is synced to OneDrive. Keep project folders outside it, e.g. in %%USERPROFILE%%\dev: sync locks files mid-write, uploads databases and browser profiles, and slows everything down."
) else (set "S=PASS" & set "D=!DOCS!")
call :emit
set "LP="
for /f "tokens=3" %%v in ('reg query "HKLM\SYSTEM\CurrentControlSet\Control\FileSystem" /v LongPathsEnabled 2^>nul ^| findstr LongPathsEnabled') do set "LP=%%v"
set "A=Files" & set "C=long paths (over 260 characters)"
if "!LP!"=="0x1" (set "S=PASS" & set "D=enabled") else (
  set "S=WARN" & set "D=off" & set "K=W"
  set "F=Paths over 260 characters fail to copy or open. Keep projects in a short folder such as %%USERPROFILE%%\dev, and leave out deep folders such as saved web pages when copying a project."
)
call :emit
set "CFA="
for /f "tokens=3" %%v in ('reg query "HKLM\SOFTWARE\Microsoft\Windows Defender\Windows Defender Exploit Guard\Controlled Folder Access" /v EnableControlledFolderAccess 2^>nul ^| findstr EnableControlledFolderAccess') do set "CFA=%%v"
if "!CFA!"=="0x1" (
  set "A=Files" & set "C=Controlled Folder Access" & set "S=WARN" & set "D=on: unknown programs cannot write to Documents, Desktop or Pictures" & set "K=W"
  set "F=Keep projects outside the protected folders, e.g. in %%USERPROFILE%%\dev."
  call :emit
)

rem ================================================================ browsers
set "EDGE=" & set "CHROME="
for %%p in ("%ProgramFiles(x86)%\Microsoft\Edge\Application\msedge.exe" "%ProgramFiles%\Microsoft\Edge\Application\msedge.exe") do if not defined EDGE if exist %%p set "EDGE=%%~p"
for %%p in ("%ProgramFiles%\Google\Chrome\Application\chrome.exe" "%ProgramFiles(x86)%\Google\Chrome\Application\chrome.exe" "%LOCALAPPDATA%\Google\Chrome\Application\chrome.exe") do if not defined CHROME if exist %%p set "CHROME=%%~p"
set "BROWSERS="
set "A=Browsers" & set "C=Edge"
if defined EDGE (set "S=PASS" & set "D=!EDGE!" & set "BROWSERS=!EDGE!") else (set "S=FAIL" & set "D=not found")
call :emit
set "A=Browsers" & set "C=Chrome"
if defined CHROME (set "S=PASS" & set "D=!CHROME!" & set "BROWSERS=!BROWSERS!;!CHROME!") else (
  set "S=WARN" & set "D=not found" & set "K=S"
  set "F=Tools that drive Chrome (Playwright channel chrome) need Chrome. Install it for your user from google.com/chrome, or ask IT."
)
call :emit
if defined EDGE call :headless Edge "!EDGE!" "%LOCALAPPDATA%"
if defined CHROME call :headless Chrome "!CHROME!" "%LOCALAPPDATA%"
if defined CHROME (call :headless Chrome "!CHROME!" "%DOCS%") else if defined EDGE call :headless Edge "!EDGE!" "%DOCS%"
for %%k in ("Google\Chrome" "Microsoft\Edge") do call :browserpolicy %%k

rem ================================================================ python
rem An installed Python first; else a portable one downloaded from python.org,
rem which is also the answer to "can an app ship its own Python?".
set "PY="
for /f "delims=" %%p in ('py -3 -c "import sys;print(sys.executable)" 2^>nul') do set "PY=%%p"
set "STUB="
if not defined PY (
  for /f "delims=" %%p in ('where python 2^>nul') do (
    echo %%p| findstr /i "WindowsApps" >nul
    if errorlevel 1 (if not defined PY set "PY=%%p") else (set "STUB=%%p")
  )
)
set "A=Python" & set "C=installed Python"
if defined PY (
  "!PY!" -c "print('ok')" >"%W%\py.txt" 2>&1
  set "PYOK=" & set /p PYOK=<"%W%\py.txt"
  if "!PYOK!"=="ok" (set "S=PASS" & set "D=!PY!") else (
    set "S=FAIL" & set "D=!PY! does not run: !PYOK!" & set "K=I" & set "PY="
    set "F=python.exe is blocked. Ask IT to allow Python, or for the approved way to run Python tools."
  )
) else if defined STUB (
  set "S=WARN" & set "D=only the Microsoft Store shortcut: !STUB!" & set "K=S"
  set "F=Install Python from python.org with Install for me only and Add to PATH. No admin needed."
) else (
  set "S=WARN" & set "D=none on PATH" & set "K=S"
  set "F=Install Python from python.org with Install for me only and Add to PATH. No admin needed."
)
call :emit

set "EMB=%LOCALAPPDATA%\laptop-check-python-%RANDOM%"
set "EMBOK="
set "A=Python" & set "C=portable Python in your profile"
curl.exe -sS -L --max-time 120 -o "%W%\embed.zip" "https://www.python.org/ftp/python/3.12.7/python-3.12.7-embed-amd64.zip" 2>"%W%\embed.err"
if exist "%W%\embed.zip" (
  mkdir "!EMB!" 2>nul
  tar -xf "%W%\embed.zip" -C "!EMB!" 2>"%W%\embed.err"
  "!EMB!\python.exe" -c "print('ok')" >"%W%\emb.txt" 2>&1
  set "EOK=" & set /p EOK=<"%W%\emb.txt"
  if "!EOK!"=="ok" (
    set "S=PASS" & set "D=a Python bundled inside a project folder runs" & set "EMBOK=1"
  ) else (
    set "S=FAIL" & set "D=!EOK!" & set "K=I"
    set "F=A Python copied into your profile does not run, so apps that bundle their own Python will not either. Ask IT."
  )
) else (
  set "S=INFO" & set "D=could not download it from python.org, so not tested"
)
call :emit

set "PYRUN=" & set "LC_EMBEDDED=0"
if defined PY (set "PYRUN=!PY!") else if defined EMBOK (set "PYRUN=!EMB!\python.exe" & set "LC_EMBEDDED=1")
if defined PYRUN (
  set "LC_WORK=%W%" & set "LC_TIMEOUT=%T%" & set "LC_HOSTS=!HOSTS!" & set "LC_PORTS=!PORTS!"
  set "LC_WHEELS=!WHEELS!" & set "LC_MINPY=!MINPY!" & set "LC_DOCS=!DOCS!" & set "LC_BROWSERS=!BROWSERS!"
  echo  Python checks: pip, compiled modules, TLS, ports, browser automation...
  "!PYRUN!" "%ROOT%probe.py" >"%W%\probe.txt" 2>"%W%\probe.err"
  for /f "usebackq tokens=1-6 delims=|" %%a in ("%W%\probe.txt") do (
    set "S=%%a" & set "A=%%b" & set "C=%%c" & set "D=%%d" & set "K=%%e" & set "F=%%f"
    if "!D!"=="-" set "D="
    if "!K!"=="-" set "K="
    if "!F!"=="-" set "F="
    call :emit
  )
  set "PERR=" & set /p PERR=<"%W%\probe.err"
  if defined PERR (set "A=Python" & set "C=probe.py" & set "S=WARN" & set "D=stopped early: !PERR!" & call :emit)
) else (
  set "A=Python" & set "C=Python checks" & set "S=INFO" & set "D=no Python ran, so pip, compiled modules, TLS, ports and browser automation were not tested"
  call :emit
)
rd /s /q "%EMB%" 2>nul

goto :report

rem ================================================================ helpers

rem Set A, C, S, D and optionally K (S/W/I) and F, then call :emit.
:emit
if defined D (set "D=!D:|=/!") else (set "D=-")
>>"%RES%" echo(!S!^|!A!^|!C!^|!D!
set "COL=37"
if "!S!"=="PASS" set "COL=32"
if "!S!"=="WARN" set "COL=33"
if "!S!"=="FAIL" set "COL=31"
echo(!ESC![!COL!m[!S!]!ESC![0m !A! / !C!: !D!
if defined K if defined F >>"%W%\next_!K!.txt" echo(- **!A! / !C!**: !F!
set "K=" & set "F=" & set "D="
exit /b

:sleep
set /a "n=%~1+1"
ping -n %n% 127.0.0.1 >nul
exit /b

rem :runwait seconds, with JOBCMD and JOBOUT set. errorlevel 1 on timeout.
:runwait
del "%JOBOUT%" "%JOBOUT%.done" 2>nul
start "" /b cmd /c ""%W%\job.bat""
set /a "rw=0"
:rw_loop
if exist "%JOBOUT%.done" exit /b 0
if !rw! geq %~1 exit /b 1
set /a "rw+=1"
ping -n 2 127.0.0.1 >nul
goto rw_loop

rem :canwrite "label" "folder" fail|expected
:canwrite
set "A=Rights" & set "C=write a file in %~1"
set "DIR=%~2"
set "f=%~2\laptop-check-%RANDOM%.tmp"
((echo x)>"%f%") 2>nul
if exist "%f%" (
  del "%f%" & set "S=PASS" & set "D=!DIR!"
) else if "%~3"=="expected" (
  set "S=INFO" & set "D=refused, as expected without admin: !DIR!"
) else (
  set "S=FAIL" & set "D=refused: !DIR!" & set "K=I"
  set "F=You cannot write to !DIR!. Ask IT which folder you may keep tools and projects in."
)
call :emit
exit /b

rem :runexe "label" "folder" plain|motw
:runexe
set "A=Running code" & set "C=run an unsigned .exe from %~1"
set "DIR=%~2"
set "DEST=%~2\laptop-check-%RANDOM%.exe"
copy /y "%W%\hello.exe" "%DEST%" >nul 2>&1
if not exist "%DEST%" (
  set "S=FAIL" & set "D=could not copy it to !DIR!"
  call :emit
  exit /b
)
if "%~3"=="motw" (
  >"%DEST%:Zone.Identifier" echo [ZoneTransfer]
  >>"%DEST%:Zone.Identifier" echo ZoneId=3
)
"%DEST%" >"%W%\exe.txt" 2>&1
set "EO=" & set /p EO=<"%W%\exe.txt"
if "!EO!"=="ok" (set "S=PASS" & set "D=!DIR!") else (
  set "S=FAIL" & set "D=!EO! (!DIR!)" & set "K=W"
  set "F=Unsigned .exe files are blocked here. Start each app from its script (python ..., or its .bat) instead of its .exe launcher, or ask IT to approve the .exe."
)
call :emit
del "%DEST%" 2>nul
exit /b

rem :host name
:host
set "H=%~1"
set "A=Network" & set "C=https://%H%"
curl.exe -sS -o NUL -w "%%{http_code} %%{time_appconnect}" --max-time %T% "https://%H%/" >"%W%\c.txt" 2>"%W%\c.err"
set "CODE=000" & set "TLSAT=0.000000"
for /f "usebackq tokens=1,2" %%a in ("%W%\c.txt") do set "CODE=%%a" & set "TLSAT=%%b"
if "%CODE%"=="407" (
  set "S=FAIL" & set "D=HTTP 407: the proxy wants a login" & set "K=S"
  set "F=The proxy needs your login. Set HTTPS_PROXY=http://user:password@proxy:port for pip and Python apps, or ask IT to exempt these hosts."
  call :emit
  exit /b
)
if not "%CODE%"=="000" (
  set "S=PASS" & set "D=HTTP %CODE%"
  call :emit
  exit /b
)
set "ERR=" & set /p ERR=<"%W%\c.err"
rem The TLS handshake finished but no answer came: the host is reachable and
rem holds back clients that do not look like a browser (bot protection).
if not "%TLSAT%"=="0.000000" (
  set "S=WARN" & set "D=reachable, but it did not answer a plain request within %T% s: bot protection, not a network block"
  call :emit
  exit /b
)
curl.exe -sS -o NUL -w "%%{http_code}" --ssl-no-revoke --max-time %T% "https://%H%/" >"%W%\c.txt" 2>nul
set "CODE2=" & set /p CODE2=<"%W%\c.txt"
if defined CODE2 if not "%CODE2%"=="000" (
  set "S=WARN" & set "D=works only without the certificate revocation check: !ERR!" & set "K=W"
  set "F=The revocation check fails, which is common behind company proxies. curl needs --ssl-no-revoke; Python apps are not affected."
  call :emit
  exit /b
)
set "S=FAIL" & set "D=!ERR!" & set "K=I"
set "F=%H% is unreachable from this laptop. Ask IT to allow it if your apps need it."
call :emit
exit /b

rem :headless Name "exe" "profile parent": the --app launchers' case, a custom profile
:headless
set "A=Browsers" & set "C=%~1 headless, profile in %~3"
set "PROF=%~3\laptop-check-profile-%RANDOM%"
rem A screenshot, not --dump-dom: Edge's launcher can hand off to a child
rem process and exit with no output, while the child still draws the page.
set "SHOT=%W%\shot-%RANDOM%.png"
set "JOBCMD="%~2" --headless=new --disable-gpu --no-first-run --no-default-browser-check --user-data-dir="%PROF%" --screenshot="%SHOT%" about:blank"
set "JOBOUT=%W%\headless.txt"
call :runwait %T%
set /a "hw=0"
:hl_wait
if not exist "%SHOT%" if !hw! lss 10 (set /a "hw+=1" & ping -n 2 127.0.0.1 >nul & goto hl_wait)
if exist "%SHOT%" (set "S=PASS" & set "D=starts with its own profile folder") else (
  set "HE=" & set /p HE=<"%JOBOUT%"
  if not defined HE set "HE=no page drawn after %T% s"
  set "S=FAIL" & set "D=!HE!" & set "K=I"
  set "F=%~1 does not start with its own profile folder here, so apps that open their page in a browser window will not either. Ask IT."
)
call :emit
call :sleep 2
rd /s /q "%PROF%" 2>nul
exit /b

rem :browserpolicy "Vendor\Browser"
:browserpolicy
set "A=Browsers" & set "C=%~1 policies"
set "PL="
for %%h in (HKLM HKCU) do (
  for %%v in (RemoteDebuggingAllowed DeveloperToolsAvailability) do (
    for /f "tokens=3" %%x in ('reg query "%%h\SOFTWARE\Policies\%~1" /v %%v 2^>nul ^| findstr /i %%v') do set "PL=!PL!%%v=%%x "
  )
  reg query "%%h\SOFTWARE\Policies\%~1\URLBlocklist" >"%W%\ubl.txt" 2>nul
  findstr /i /c:"127.0.0.1" /c:"localhost" /c:"REG_SZ    *" "%W%\ubl.txt" >nul 2>&1
  if not errorlevel 1 set "PL=!PL!URLBlocklist may block 127.0.0.1 "
)
if not defined PL (set "S=PASS" & set "D=no policy limits automation or local pages") else (
  set "S=WARN" & set "D=!PL!"
  >"%W%\pl.txt" echo(!PL!
  findstr /c:"RemoteDebuggingAllowed=0x0" "%W%\pl.txt" >nul
  if not errorlevel 1 (
    set "K=I"
    set "F=Remote debugging is turned off by policy, so Playwright and Selenium cannot drive this browser. Ask IT to allow it, or do that step by hand."
  )
)
call :emit
exit /b

rem ================================================================ report
:report
set "STAMP=%date%_%time%"
for %%c in ("/" ":" "." "," " ") do set "STAMP=!STAMP:%%~c=-!"
set "REP=%OUT%\report-!STAMP!.md"
set "RAW=%W%\report.txt"
for /f %%n in ('findstr /b /c:"FAIL|" "%RES%" ^| find /c /v ""') do set "NF=%%n"
for /f %%n in ('findstr /b /c:"WARN|" "%RES%" ^| find /c /v ""') do set "NW=%%n"
for /f %%n in ('findstr /b /c:"PASS|" "%RES%" ^| find /c /v ""') do set "NP=%%n"
for /f "delims=" %%v in ('ver') do set "WINVER=%%v"

> "%RAW%" echo # laptop-check, !STAMP!
>>"%RAW%" echo.
>>"%RAW%" echo !WINVER!. Targets: !TARGETS!.
>>"%RAW%" echo.
>>"%RAW%" echo **!NF! blocked, !NW! worth knowing, !NP! working.**
>>"%RAW%" echo.
>>"%RAW%" echo ## Next steps
call :section S "Do it yourself"
call :section W "Work around it"
call :section I "Ask IT"
if exist "%W%\next_I.txt" (
  >>"%RAW%" echo.
  >>"%RAW%" echo Message for IT:
  >>"%RAW%" echo.
  >>"%RAW%" echo ^> Hello, I run a few small local tools on this laptop, Python scripts with a page served on 127.0.0.1. The items above are blocked. Could you allow them, or tell me the approved way to do this?
)
if not exist "%W%\next_S.txt" if not exist "%W%\next_W.txt" if not exist "%W%\next_I.txt" (
  >>"%RAW%" echo.
  >>"%RAW%" echo Nothing to do: everything the apps need works here.
)
>>"%RAW%" echo.
>>"%RAW%" echo ## Every check
>>"%RAW%" echo.
>>"%RAW%" echo ^| Status ^| Area ^| Check ^| Detail ^|
>>"%RAW%" echo ^|---^|---^|---^|---^|
for /f "usebackq tokens=1-4 delims=|" %%a in ("%RES%") do >>"%RAW%" echo ^| %%a ^| %%b ^| %%c ^| %%d ^|

rem mask the names that identify the person or the machine, keep blank lines
type nul >"%REP%"
for /f "delims=" %%l in ('findstr /n "^" "%RAW%"') do (
  set "L=%%l"
  set "L=!L:*:=!"
  if defined L (
    if defined USERNAME set "L=!L:%USERNAME%=<user>!"
    if defined COMPUTERNAME set "L=!L:%COMPUTERNAME%=<pc>!"
    if defined USERDOMAIN set "L=!L:%USERDOMAIN%=<domain>!"
  )
  >>"%REP%" echo(!L!
)

clip <"%REP%" 2>nul
rd /s /q "%W%" 2>nul
echo.
echo  !NF! blocked, !NW! worth knowing, !NP! working.
echo  Report: !REP!
if defined OUTMOVED echo  results\ was not writable here, so the report went to %%TEMP%%.
echo  It is also on the clipboard. Read it before you share it: it lists what this laptop allows.
echo.
pause
exit /b 0

rem :section KIND "Heading"
:section
if not exist "%W%\next_%~1.txt" exit /b
>>"%RAW%" echo.
>>"%RAW%" echo ### %~2
>>"%RAW%" echo.
type "%W%\next_%~1.txt" >>"%RAW%"
exit /b
