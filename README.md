# laptop-check

Finds out what a Windows machine lets you do as a developer: run scripts and
programs, use git, Python and Node, download packages, reach GitHub, run a
local web server, use a browser for automation. Each check records PASS,
WARN, FAIL or INFO with the exact error, so you can plan around what's
blocked.

It tests behaviour only. It doesn't read security policies or antivirus
settings, installs nothing, and changes no settings. Test files go in a temp
folder or get a unique name, and they're deleted at the end.

## Run it

1. Copy this folder to the laptop. Clone it, or download the ZIP.
2. Double-click `run.bat`. It takes a minute or two.
3. The report lands in `results\report-<date>.md`, with a JSON copy next to
   it.

Requirements: Windows 10 or 11 with Windows PowerShell 5.1, which every
Windows has.

### If it doesn't start

If `run.bat` says *"running scripts is disabled on this system"*, PowerShell
scripts are blocked by policy. That's your first finding. Don't work around
it with `-ExecutionPolicy Bypass` without asking IT: ask them to allow your
scripts, or to sign this one.

## What it checks

| Area | Checks |
|---|---|
| Rights | administrator; writing to the profile, LOCALAPPDATA, Documents, `C:\`, Program Files |
| Running code | PowerShell language mode and execution policy; running a `.ps1`, a `.bat` and an unsigned `.exe` (from temp, LOCALAPPDATA, and Downloads marked as downloaded); the built-in C# compiler |
| Tools | git, python, py, node, npm, dotnet, VS Code, winget, WSL, Docker |
| Installing | `pip download` from PyPI, `npm view` from the npm registry, `git ls-remote` to GitHub (nothing gets installed) |
| Network | github.com, raw.githubusercontent.com, pypi.org, registry.npmjs.org; SSH port 22; proxy; who signed GitHub's certificate (TLS inspection) |
| Local server | listening on `127.0.0.1:8799` and connecting to it |
| Browsers | Edge and Chrome present; headless Edge; Edge F12 tools allowed |
| Files | Documents on OneDrive; long paths; how fast 500 small files get written |

Options: `check.ps1 -TimeoutSec 30 -Port 8800`.

## Privacy

- `results\` is in `.gitignore`. Reports never get committed by accident.
- The report replaces your user name, computer name and domain with
  `<user>`, `<pc>` and `<domain>`.
- It still describes what the company laptop allows. Read it before you
  share it, and share only what you need.
