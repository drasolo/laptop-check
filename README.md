# laptop-check

Finds out what a Windows machine lets you do as a developer, and what to do
about each thing it blocks. One run gives the whole picture, however locked
down the machine is.

It is written in batch on purpose. On a company laptop, PowerShell scripts
are often the first thing blocked, and a check that cannot start reports
nothing. The Python checks are in `probe.py`, which runs with whichever
Python works: an installed one, or a portable one the check downloads.

It tests behaviour only. It installs nothing and changes no settings.
Everything it creates goes in a temp folder, or gets a unique name, and is
deleted at the end.

## Run it

1. Download the ZIP (Code, Download ZIP) and **extract it**. Running
   `run.bat` from inside the ZIP stops with a message saying so.
2. Check `apps.txt`: it lists the hosts, ports and packages my apps need.
   For other apps, edit it (see below).
3. Double-click `run.bat`. It takes a few minutes.
4. Read **Next steps** at the top of `results\report-<date>.md`. The report
   is also copied to the clipboard.

Requirements: Windows 10 or 11. Nothing else; `curl.exe` and `tar.exe`
ship with Windows.

## What you get

Next steps comes in three groups:

- **Do it yourself**: things you can fix without admin rights, such as
  installing Python for your user only or trusting the company certificate
  in pip.
- **Work around it**: ways to keep working with the block in place, such
  as starting an app from its script instead of a blocked `.exe`.
- **Ask IT**: what only IT can change, plus a short message to send them.

Below that, a table lists every check with its result.

## What it checks

| Area | Checks |
|---|---|
| PowerShell | whether `.ps1` scripts run, and whether Group Policy or the Windows default decides it; language mode |
| Rights | administrator; writing to the profile, LOCALAPPDATA, Documents, Downloads, `C:\` and Program Files |
| Running code | building an `.exe` with the C# compiler in Windows, and whether antivirus removes it; running it from temp, LOCALAPPDATA, Documents and Downloads (marked as downloaded); a `.bat` from Documents |
| Network | every host over HTTPS, telling a blocked host from one that only rejects non-browser clients; proxy, proxy login, certificate revocation checks |
| Files | Documents on OneDrive, long paths, Controlled Folder Access, Python writing to Documents, file write speed |
| Browsers | Edge and Chrome, headless with their own profile folder (how apps open a page in an app window); remote debugging (what Playwright and Selenium need); browser policies |
| Python | an installed Python and its version; a portable Python run from your profile (how apps bundle their own); pip and the package index; packages with compiled code downloaded and imported |
| TLS | who issued each host's certificate (TLS inspection), and whether libraries with their own certificate list accept it |
| Local server | serving on 127.0.0.1 at each port, and which program holds a port that is taken |

## apps.txt

`apps.txt` names what the apps need. Change it on the machine and run
again; no new download needed. The format is in `apps.example.txt`:

```
host    example.com      a site an app calls
port    8080             a port an app serves its page on
wheel   lxml lxml.etree  a compiled package, and the module to import
python  3.10             the oldest Python the apps accept
```

## Privacy

- `results\` is in `.gitignore`, so reports never get committed by
  accident.
- The report replaces your user name, computer name and domain with
  `<user>`, `<pc>` and `<domain>`.
- It still describes what the laptop allows. Read it before you share it,
  and share only what you need.
