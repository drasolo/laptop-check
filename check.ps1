# laptop-check: what can I build on this machine?
#
# Tests behaviour (can I run X, can I reach Y) and writes a report to
# .\results. It installs nothing and changes no settings. Everything it
# creates goes in a temp folder (or a uniquely named test file) and is
# deleted at the end. Written for Windows PowerShell 5.1; run it with run.bat.
[CmdletBinding()]
param(
    [int]$TimeoutSec = 20,
    [int]$Port = 8799
)

$ErrorActionPreference = 'Stop'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

$root    = Split-Path -Parent $MyInvocation.MyCommand.Path
$outDir  = Join-Path $root 'results'
$work    = Join-Path ([IO.Path]::GetTempPath()) ('laptop-check-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $outDir, $work | Out-Null
$results = New-Object System.Collections.Generic.List[object]

# ------------------------------------------------------------------ helpers
function Add-Result($area, $check, $status, $detail, $ms) {
    $text = ("$detail").Trim()
    $results.Add([pscustomobject]@{ Area = $area; Check = $check; Status = $status; Detail = $text; Ms = $ms })
    $color = @{ PASS = 'Green'; WARN = 'Yellow'; FAIL = 'Red'; INFO = 'Gray' }[$status]
    Write-Host ("[{0}] {1} / {2}: {3}" -f $status, $area, $check, ($text -split "`n")[0]) -ForegroundColor $color
}

# Runs one check. The block ends with @{ s = status; d = detail }.
# An exception anywhere in it is a FAIL carrying the exception's message.
function Check($area, $name, [scriptblock]$block) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try {
        $r = @(& $block)[-1]
        Add-Result $area $name $r.s $r.d $sw.ElapsedMilliseconds
    } catch {
        Add-Result $area $name 'FAIL' $_.Exception.Message $sw.ElapsedMilliseconds
    }
}

# Runs a program with a time limit. -> @{ Code; Out; Err }
function Invoke-Tool([string]$file, [string]$arguments, [int]$timeout = $TimeoutSec) {
    $out = Join-Path $work ([guid]::NewGuid().ToString('N') + '.out')
    $err = "$out.err"
    $p = Start-Process -FilePath $file -ArgumentList $arguments -NoNewWindow -PassThru `
         -RedirectStandardOutput $out -RedirectStandardError $err
    $null = $p.Handle        # without this, ExitCode can stay empty
    if (-not $p.WaitForExit($timeout * 1000)) {
        try { $p.Kill() } catch {}
        return @{ Code = -1; Out = ''; Err = "no answer after $timeout s" }
    }
    $o = if (Test-Path $out) { Get-Content $out -Raw } else { '' }
    $e = if (Test-Path $err) { Get-Content $err -Raw } else { '' }
    # some tools (wsl) answer in UTF-16, which reads as letters with NULs between
    @{ Code = $p.ExitCode; Out = ("$o" -replace "`0", ''); Err = ("$e" -replace "`0", '') }
}

# The first runnable file for a command: .exe, .cmd or .bat. npm, for one,
# also ships a shell script and a .ps1 under the same name.
function Find-Program($cmd) {
    Get-Command $cmd -All -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandType -eq 'Application' -and $_.Extension -in '.exe', '.cmd', '.bat' } |
        Select-Object -First 1
}

# Is a command on PATH, and does it answer?
function Check-Tool($area, $name, $cmd, $arguments, [switch]$StoreStubIsFake) {
    Check $area $name {
        $c = Find-Program $cmd
        if (-not $c) { return @{ s = 'FAIL'; d = "'$cmd' is not on PATH" } }
        $path = $c.Source
        if ($StoreStubIsFake -and $path -like '*\WindowsApps\*') {
            return @{ s = 'WARN'; d = "only the Microsoft Store shortcut ($path), not a real install" }
        }
        $r = Invoke-Tool $path $arguments
        $text = (($r.Out + ' ' + $r.Err) -replace '\s+', ' ').Trim()
        if ($r.Code -eq 0) { @{ s = 'PASS'; d = "$text ($path)" } }
        else { @{ s = 'FAIL'; d = "exit $($r.Code): $text ($path)" } }
    }
}

# -> $null when a TCP connection opens, else why not
function Test-Tcp($hostName, $port, $ms = 5000) {
    $c = New-Object Net.Sockets.TcpClient
    try {
        $t = $c.ConnectAsync($hostName, $port)
        if (-not $t.Wait($ms)) { return "no answer after $($ms / 1000) s" }
        return $null
    } catch {
        $e = $_.Exception
        while ($e.InnerException) { $e = $e.InnerException }
        return $e.Message
    } finally { $c.Close() }
}

function Check-Url($name, $url) {
    Check 'Network' $name {
        $r = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec $TimeoutSec
        @{ s = 'PASS'; d = "HTTP $($r.StatusCode) from $url" }
    }
}

# Copies the test .exe to a folder and runs it from there.
function Check-RunExe($label, $dir, [switch]$MarkDownloaded) {
    Check 'Running code' "run an unsigned .exe from $label" {
        if (-not (Test-Path $exe)) { return @{ s = 'FAIL'; d = 'no test .exe (building it failed above)' } }
        $dest = Join-Path $dir ('laptop-check-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.exe')
        Copy-Item $exe $dest
        try {
            # the mark Windows puts on a file downloaded from the internet
            if ($MarkDownloaded) { Set-Content -Path $dest -Stream Zone.Identifier -Value "[ZoneTransfer]`r`nZoneId=3" }
            $r = Invoke-Tool $dest 'x' 15
            if ($r.Code -eq 0 -and $r.Out -match 'ok') { @{ s = 'PASS'; d = $dir } }
            else { @{ s = 'FAIL'; d = "exit $($r.Code): $($r.Err) ($dir)" } }
        } finally { Remove-Item $dest -Force -ErrorAction SilentlyContinue }
    }
}

# ------------------------------------------------------------------ checks
try {
    Write-Host "laptop-check: testing what this machine lets you do. Takes a minute or two.`n"

    # --- Rights
    Check 'Rights' 'administrator' {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        $elevated = (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator)
        $inGroup = @($id.Groups | Where-Object { $_.Value -eq 'S-1-5-32-544' }).Count -gt 0
        if ($elevated) { @{ s = 'INFO'; d = 'running elevated, as administrator' } }
        elseif ($inGroup) { @{ s = 'INFO'; d = 'in the Administrators group, but not elevated now' } }
        else { @{ s = 'INFO'; d = 'not an administrator: install tools per user, never into Program Files' } }
    }
    $places = @(
        @('the user profile', $env:USERPROFILE),
        @('LOCALAPPDATA', $env:LOCALAPPDATA),
        @('Documents', [Environment]::GetFolderPath('MyDocuments')),
        @('the root of C:', 'C:\'),
        @('Program Files', $env:ProgramFiles))
    foreach ($place in $places) {
        $label = $place[0]; $dir = $place[1]
        Check 'Rights' "write a file in $label" {
            $f = Join-Path $dir ('laptop-check-' + [guid]::NewGuid().ToString('N') + '.tmp')
            try {
                Set-Content -Path $f -Value 'x'
                Remove-Item $f -Force
                @{ s = 'PASS'; d = $dir }
            } catch {
                # without admin, Program Files and C:\ are expected to refuse
                $s = if ($label -in 'Program Files', 'the root of C:') { 'WARN' } else { 'FAIL' }
                @{ s = $s; d = "$($_.Exception.Message) ($dir)" }
            }
        }
    }

    # --- Running code
    Check 'Running code' 'PowerShell language mode' {
        $m = "$($ExecutionContext.SessionState.LanguageMode)"
        if ($m -eq 'FullLanguage') { @{ s = 'PASS'; d = $m } }
        else { @{ s = 'FAIL'; d = "${m}: scripts cannot use .NET freely; an application-control policy is active" } }
    }
    Check 'Running code' 'execution policy' {
        # started from PowerShell 7, the module path can point at modules 5.1
        # cannot load; the one that ships with this PowerShell always loads
        if (-not (Get-Module Microsoft.PowerShell.Security)) {
            Import-Module (Join-Path $PSHOME 'Modules\Microsoft.PowerShell.Security') -ErrorAction SilentlyContinue
        }
        $eff = "$(Get-ExecutionPolicy)"
        $list = Get-ExecutionPolicy -List | ForEach-Object { "$($_.Scope)=$($_.ExecutionPolicy)" }
        $s = if ($eff -in 'Restricted', 'AllSigned') { 'WARN' } else { 'PASS' }
        @{ s = $s; d = "effective: $eff; " + ($list -join ', ') }
    }
    Check 'Running code' 'run a .ps1 file' {
        $f = Join-Path $work 'probe.ps1'
        Set-Content -Path $f -Value "Write-Output 'ok'"
        $r = Invoke-Tool 'powershell.exe' "-NoProfile -File `"$f`""
        if ($r.Out -match 'ok') { @{ s = 'PASS'; d = 'scripts run' } }
        else { @{ s = 'FAIL'; d = ($r.Err -replace '\s+', ' ') } }
    }
    Check 'Running code' 'run a .bat file' {
        $f = Join-Path $work 'probe.bat'
        Set-Content -Path $f -Value "@echo ok" -Encoding Ascii
        $r = Invoke-Tool 'cmd.exe' "/c `"$f`""
        if ($r.Out -match 'ok') { @{ s = 'PASS'; d = 'batch files run' } }
        else { @{ s = 'FAIL'; d = "exit $($r.Code): $($r.Err)" } }
    }
    $exe = Join-Path $work 'hello.exe'
    Check 'Running code' 'build a small .exe (C#, Add-Type)' {
        Add-Type -TypeDefinition 'public static class P { public static int Main() { System.Console.WriteLine("ok"); return 0; } }' `
                 -OutputAssembly $exe -OutputType ConsoleApplication
        @{ s = 'PASS'; d = 'the C# compiler that ships with Windows works' }
    }
    Check-RunExe 'the temp folder' $work
    Check-RunExe 'LOCALAPPDATA' $env:LOCALAPPDATA
    Check-RunExe 'Downloads, marked as downloaded' (Join-Path $env:USERPROFILE 'Downloads') -MarkDownloaded
    Check 'Running code' '.NET Framework csc.exe present' {
        $csc = "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
        if (Test-Path $csc) { @{ s = 'PASS'; d = $csc } } else { @{ s = 'FAIL'; d = "not at $csc" } }
    }

    # --- Tools already here
    Check-Tool 'Tools' 'git' 'git' '--version'
    Check-Tool 'Tools' 'python' 'python' '--version' -StoreStubIsFake
    Check-Tool 'Tools' 'py launcher' 'py' '--version'
    Check-Tool 'Tools' 'node' 'node' '--version'
    Check-Tool 'Tools' 'npm' 'npm' '--version'
    Check-Tool 'Tools' 'dotnet' 'dotnet' '--version'
    Check-Tool 'Tools' 'VS Code' 'code' '--version'
    Check-Tool 'Tools' 'winget' 'winget' '--version'
    Check-Tool 'Tools' 'WSL' 'wsl' '--status'
    Check-Tool 'Tools' 'Docker' 'docker' '--version'

    # --- Installing (downloads only; nothing is installed)
    Check 'Installing' 'pip can download from PyPI' {
        $py = @((Find-Program py), (Find-Program python)) |
              Where-Object { $_ -and $_.Source -notlike '*\WindowsApps\*' } | Select-Object -First 1
        if (-not $py) { return @{ s = 'FAIL'; d = 'no Python to try with' } }
        $r = Invoke-Tool $py.Source "-m pip download --no-deps --dest `"$work\pip`" six" 60
        if ($r.Code -eq 0) { @{ s = 'PASS'; d = 'PyPI packages download' } }
        else { @{ s = 'FAIL'; d = "exit $($r.Code): " + (($r.Out + $r.Err) -replace '\s+', ' ') } }
    }
    Check 'Installing' 'npm can reach its registry' {
        $npm = Find-Program npm
        if (-not $npm) { return @{ s = 'FAIL'; d = 'no npm to try with' } }
        $r = Invoke-Tool $npm.Source 'view left-pad version' 60
        if ($r.Code -eq 0) { @{ s = 'PASS'; d = "left-pad $($r.Out.Trim())" } }
        else { @{ s = 'FAIL'; d = "exit $($r.Code): " + (($r.Out + $r.Err) -replace '\s+', ' ') } }
    }
    Check 'Installing' 'git can reach GitHub over HTTPS' {
        $git = Find-Program git
        if (-not $git) { return @{ s = 'FAIL'; d = 'no git to try with' } }
        $r = Invoke-Tool $git.Source 'ls-remote https://github.com/git/git HEAD' 30
        if ($r.Code -eq 0) { @{ s = 'PASS'; d = 'clone and push over HTTPS should work' } }
        else { @{ s = 'FAIL'; d = "exit $($r.Code): $($r.Err)" } }
    }

    # --- Network
    Check-Url 'github.com' 'https://github.com'
    Check-Url 'raw.githubusercontent.com' 'https://raw.githubusercontent.com/git/git/master/README.md'
    Check-Url 'pypi.org' 'https://pypi.org/simple/six/'
    Check-Url 'registry.npmjs.org' 'https://registry.npmjs.org/left-pad'
    Check 'Network' 'SSH to github.com (port 22)' {
        $e = Test-Tcp 'github.com' 22
        if (-not $e) { @{ s = 'PASS'; d = 'git over SSH is possible' } }
        else { @{ s = 'WARN'; d = "${e}: use HTTPS for git" } }
    }
    Check 'Network' 'proxy' {
        $target = [Uri]'https://github.com'
        $p = [Net.WebRequest]::GetSystemWebProxy().GetProxy($target)
        $sys = if ($p.Host -eq $target.Host) { 'none' } else { "$p" }
        $win = ((netsh winhttp show proxy) -join ' ') -replace '\s+', ' '
        $envp = (@($env:HTTPS_PROXY, $env:HTTP_PROXY) | Where-Object { $_ }) -join ' '
        $s = if ($sys -eq 'none') { 'INFO' } else { 'WARN' }
        @{ s = $s; d = "system proxy: $sys; env: $(if ($envp) { $envp } else { 'none' }); winhttp: $win" }
    }
    Check 'Network' 'TLS certificate seen for github.com' {
        $c = New-Object Net.Sockets.TcpClient('github.com', 443)
        try {
            $ssl = New-Object Net.Security.SslStream($c.GetStream(), $false, ({ $true }))
            $ssl.AuthenticateAsClient('github.com')
            $issuer = $ssl.RemoteCertificate.Issuer
        } finally { $c.Close() }
        $public = "DigiCert|Sectigo|USERTrust|Let's Encrypt|GlobalSign|GoDaddy|Amazon|Google Trust|Microsoft|Entrust"
        if ($issuer -match $public) { @{ s = 'PASS'; d = "issued by $issuer" } }
        else { @{ s = 'WARN'; d = "issued by ${issuer}: probably TLS inspection; pip, npm and git may need this certificate trusted" } }
    }

    # --- Local server (what a local web app or dev server needs)
    Check 'Local server' "listen on 127.0.0.1:$Port and connect to it" {
        $l = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, $Port)
        $l.Start()
        try {
            $e = Test-Tcp '127.0.0.1' $Port 3000
            if (-not $e) { @{ s = 'PASS'; d = 'a local web server would work' } }
            else { @{ s = 'FAIL'; d = $e } }
        } finally { $l.Stop() }
    }

    # --- Browsers
    $edge = @("${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
              "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe") |
            Where-Object { Test-Path $_ } | Select-Object -First 1
    $chrome = @("$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
                "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
                "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe") |
              Where-Object { Test-Path $_ } | Select-Object -First 1
    Check 'Browsers' 'Edge' { if ($edge) { @{ s = 'PASS'; d = $edge } } else { @{ s = 'FAIL'; d = 'not found' } } }
    Check 'Browsers' 'Chrome' { if ($chrome) { @{ s = 'PASS'; d = $chrome } } else { @{ s = 'WARN'; d = 'not found' } } }
    Check 'Browsers' 'Edge headless (browser automation, tests)' {
        if (-not $edge) { return @{ s = 'FAIL'; d = 'no Edge' } }
        $r = Invoke-Tool $edge "--headless=new --disable-gpu --user-data-dir=`"$work\edge`" --dump-dom about:blank" 30
        if ($r.Code -eq 0) { @{ s = 'PASS'; d = 'headless Edge runs' } }
        else { @{ s = 'FAIL'; d = "exit $($r.Code): $($r.Err)" } }
    }
    Check 'Browsers' 'Edge developer tools allowed' {
        $v = (Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' -Name DeveloperToolsAvailability -ErrorAction SilentlyContinue).DeveloperToolsAvailability
        if ($null -eq $v -or $v -eq 1) { @{ s = 'PASS'; d = 'F12 tools available' } }
        elseif ($v -eq 0) { @{ s = 'WARN'; d = 'allowed except on force-installed extensions' } }
        else { @{ s = 'FAIL'; d = 'F12 developer tools are turned off by policy' } }
    }

    # --- Files
    Check 'Files' 'Documents and OneDrive' {
        $d = [Environment]::GetFolderPath('MyDocuments')
        if ($d -match 'OneDrive') { @{ s = 'WARN'; d = "${d}: sync can lock files and slow builds; keep repos outside it, e.g. in %LOCALAPPDATA% or C:\dev" } }
        else { @{ s = 'PASS'; d = $d } }
    }
    Check 'Files' 'long paths (over 260 characters)' {
        $v = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' -Name LongPathsEnabled -ErrorAction SilentlyContinue).LongPathsEnabled
        if ($v -eq 1) { @{ s = 'PASS'; d = 'enabled' } }
        else { @{ s = 'WARN'; d = 'off: deep folders (node_modules, long repo paths) can fail; keep projects near the drive root' } }
    }
    Check 'Files' 'writing 500 small files' {
        $dir = Join-Path $work 'many'
        New-Item -ItemType Directory -Path $dir | Out-Null
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $text = 'x' * 1024
        for ($i = 0; $i -lt 500; $i++) { [IO.File]::WriteAllText((Join-Path $dir "$i.txt"), $text) }
        $ms = $sw.ElapsedMilliseconds
        if ($ms -lt 3000) { @{ s = 'PASS'; d = "$ms ms" } }
        else { @{ s = 'WARN'; d = "$ms ms: file scanning is slow; npm install and git checkout will feel it" } }
    }
}
finally {
    # ------------------------------------------------------------- report
    Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue

    # names that identify the machine or the person stay out of the report
    function Hide([string]$s) {
        foreach ($pair in @(@($env:USERNAME, '<user>'), @($env:COMPUTERNAME, '<pc>'), @($env:USERDOMAIN, '<domain>'))) {
            if ($pair[0]) { $s = $s -ireplace [regex]::Escape($pair[0]), $pair[1] }
        }
        $s
    }
    foreach ($r in $results) { $r.Detail = Hide $r.Detail }

    $stamp = Get-Date -Format 'yyyy-MM-dd-HHmm'
    $os = (Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue)
    $count = { param($st) @($results | Where-Object { $_.Status -eq $st }).Count }
    $cell = { param($t) (("$t" -replace '\|', '/' -replace '\s+', ' ').Trim()) }

    $md = New-Object System.Collections.Generic.List[string]
    $md.Add("# laptop-check, $stamp")
    $md.Add('')
    $md.Add("Windows: $($os.Caption) $($os.Version); PowerShell $($PSVersionTable.PSVersion)")
    $md.Add('')
    $md.Add("**$(& $count 'FAIL') blocked, $(& $count 'WARN') worth knowing, $(& $count 'PASS') working.**")
    foreach ($group in @(@('FAIL', 'Blocked'), @('WARN', 'Worth knowing'))) {
        $rows = @($results | Where-Object { $_.Status -eq $group[0] })
        if (-not $rows.Count) { continue }
        $md.Add('')
        $md.Add("## $($group[1])")
        foreach ($r in $rows) { $md.Add("- **$($r.Area) / $($r.Check)**: $(& $cell $r.Detail)") }
    }
    $md.Add('')
    $md.Add('## Every check')
    $md.Add('')
    $md.Add('| Status | Area | Check | Detail | ms |')
    $md.Add('|---|---|---|---|---|')
    foreach ($r in $results) {
        $d = & $cell $r.Detail
        if ($d.Length -gt 300) { $d = $d.Substring(0, 300) + '...' }
        $md.Add("| $($r.Status) | $($r.Area) | $($r.Check) | $d | $($r.Ms) |")
    }

    $mdPath = Join-Path $outDir "report-$stamp.md"
    $md | Set-Content -Path $mdPath -Encoding UTF8
    $results | ConvertTo-Json -Depth 3 | Set-Content -Path (Join-Path $outDir "report-$stamp.json") -Encoding UTF8
    Write-Host "`nReport: $mdPath"
    Write-Host "Read it before you share it: it lists what this machine allows."
}
