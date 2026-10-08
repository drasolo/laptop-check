"""laptop-check probe: the checks batch cannot do. Standard library only.

run.bat starts this with the first Python that works (an installed one, or a
portable one it just downloaded) and reads its output. One result per line:

    STATUS|AREA|CHECK|DETAIL|KIND|FIX

KIND is S (do it yourself), W (work around) or I (ask IT); '-' is empty.
Settings arrive as LC_* environment variables. It installs nothing: wheels
are downloaded and unpacked into run.bat's temp folder, which gets deleted.
"""
import glob
import json
import os
import shutil
import socket
import ssl
import subprocess
import sys
import tempfile
import time
import urllib.request
import zipfile

T = int(os.environ.get('LC_TIMEOUT', '20'))
WORK = os.environ.get('LC_WORK') or tempfile.mkdtemp()
PUBLIC_CAS = ('DigiCert', 'Sectigo', 'USERTrust', "Let's Encrypt", 'ISRG', 'GlobalSign',
              'GoDaddy', 'Starfield', 'Amazon', 'Google Trust', 'Microsoft', 'Entrust',
              'Baltimore', 'Certum', 'Comodo', 'Cloudflare')


def out(status, area, check, detail='-', kind='-', fix='-'):
    def clean(x):
        x = str(x).replace('|', '/').replace('!', '').replace('\r', ' ').replace('\n', ' ')
        return ' '.join(x.split()) or '-'
    print('|'.join(clean(x) for x in (status, area, check, detail, kind, fix)), flush=True)


def run(args, timeout=60):
    try:
        return subprocess.run(args, capture_output=True, text=True, timeout=timeout,
                              encoding='utf-8', errors='replace')
    except subprocess.TimeoutExpired:
        return subprocess.CompletedProcess(args, -1, '', f'no answer after {timeout} s')


def last_line(text):
    lines = [l.strip() for l in (text or '').splitlines() if l.strip()]
    return lines[-1] if lines else ''


def guarded(area, check):
    def wrap(fn):
        def inner(*a):
            try:
                fn(*a)
            except Exception as e:  # a crash in one check must not hide the rest
                out('FAIL', area, check, f'{type(e).__name__}: {e}')
        return inner
    return wrap


HAS_PIP = run([sys.executable, '-m', 'pip', '--version']).returncode == 0


@guarded('Python', 'version')
def version():
    want = tuple(int(x) for x in os.environ.get('LC_MINPY', '3.10').split('.'))
    have = sys.version.split()[0]
    if sys.version_info[:len(want)] >= want:
        out('PASS', 'Python', 'version', f'{have} ({sys.executable})')
    else:
        out('FAIL', 'Python', 'version', f'{have}, the apps need {".".join(map(str, want))} or newer', 'S',
            'Install a newer Python from python.org with "Install for me only" (no admin needed).')


def pip_failure(stderr):
    """(kind, fix) for a failed pip network call."""
    if 'CERTIFICATE_VERIFY_FAILED' in stderr:
        return 'S', ('pip does not trust the company certificate. Upgrade pip using Windows certificates: '
                     'python -m pip install --user --upgrade pip --use-feature=truststore')
    if '407' in stderr or 'ProxyError' in stderr:
        return 'S', 'The proxy needs a login. Set HTTPS_PROXY=http://user:password@proxy:port before pip, or ask IT.'
    return 'I', 'pip cannot reach PyPI. Ask IT to allow pypi.org and files.pythonhosted.org, or for the company package index.'


@guarded('Python', 'pip')
def pip():
    if not HAS_PIP:
        embedded = os.environ.get('LC_EMBEDDED') == '1'
        out('INFO' if embedded else 'FAIL', 'Python', 'pip',
            'portable Python, which ships without pip' if embedded else 'python -m pip does not run',
            '-' if embedded else 'S', '-' if embedded else 'Run: python -m ensurepip --user')
        return
    cfg = run([sys.executable, '-m', 'pip', 'config', 'list']).stdout
    index = [l for l in cfg.splitlines() if 'index-url' in l]
    if index:
        out('INFO', 'Python', 'pip package index', '; '.join(index))
    dest = tempfile.mkdtemp(dir=WORK)
    r = run([sys.executable, '-m', 'pip', 'download', '--no-deps', '--dest', dest, 'six'], timeout=120)
    if r.returncode == 0:
        out('PASS', 'Python', 'pip download from PyPI', 'packages download')
    else:
        kind, fix = pip_failure(r.stderr)
        out('FAIL', 'Python', 'pip download from PyPI', last_line(r.stderr), kind, fix)


@guarded('Python', 'native modules')
def wheels():
    specs = os.environ.get('LC_WHEELS', '').split()
    if specs and not HAS_PIP:
        out('INFO', 'Python', 'native modules', 'needs pip to download them; skipped')
        return
    for spec in specs:
        dist, _, module = spec.partition(':')
        module = module or dist
        check = f'load {dist} (compiled code)'
        dest = tempfile.mkdtemp(dir=WORK)
        # With its dependencies: curl_cffi, for one, needs cffi's compiled
        # _cffi_backend, and without it the import fails for the wrong reason.
        r = run([sys.executable, '-m', 'pip', 'download', '--only-binary', ':all:',
                 '--dest', dest, dist], timeout=300)
        found = glob.glob(os.path.join(dest, '*.whl'))
        main = [w for w in found if os.path.basename(w).lower().startswith(dist.lower().replace('-', '_'))]
        if r.returncode or not main:
            kind, fix = pip_failure(r.stderr)
            out('FAIL', 'Python', check, 'download failed: ' + last_line(r.stderr), kind, fix)
            continue
        unpacked = os.path.join(dest, 'x')
        for whl in found:
            with zipfile.ZipFile(whl) as z:
                z.extractall(unpacked)
        # A fresh process, so the .pyd and .dll files load the way an app loads them.
        code = f'import sys; sys.path.insert(0, {unpacked!r}); import {module}; print("ok")'
        r = run([sys.executable, '-c', code])
        if 'ok' in r.stdout:
            out('PASS', 'Python', check, f'{os.path.basename(main[0])} imports')
            continue
        err = last_line(r.stderr)
        policy = any(s in err for s in ('blocked', 'Device Guard', 'Application Control', '1260', '4551', 'policy'))
        if policy:
            out('FAIL', 'Python', check, err, 'I',
                'Application control blocks compiled Python modules. Ask IT to allow .pyd/.dll files '
                'loaded by python.exe from your Python and project folders.')
        elif 'DLL load failed' in err:
            out('FAIL', 'Python', check, err, 'S',
                'A system library is missing. The Microsoft Visual C++ Redistributable usually fixes it '
                '(it needs admin, so ask IT if you cannot install it).')
        else:
            out('WARN', 'Python', check, err, '-', '-')


def certifi_bundle():
    try:
        import certifi
        return certifi.where()
    except ImportError:
        pass
    try:
        from pip._vendor import certifi
        return certifi.where()
    except ImportError:
        return None


@guarded('TLS', 'certificates')
def tls():
    hosts = os.environ.get('LC_HOSTS', 'pypi.org github.com').split()
    bundle = certifi_bundle()
    bundle_fails = []
    for host in hosts:
        try:
            sock = socket.create_connection((host, 443), timeout=T)
        except OSError as e:
            out('INFO', 'TLS', f'{host}, direct', f'no direct connection: {e}')
            continue
        # On Windows the default context also trusts the Windows certificate store.
        with sock, ssl.create_default_context().wrap_socket(sock, server_hostname=host) as t:
            issuer = dict(x[0] for x in t.getpeercert()['issuer'])
        org = issuer.get('organizationName') or issuer.get('commonName') or '?'
        if any(ca.lower() in org.lower() for ca in PUBLIC_CAS):
            out('PASS', 'TLS', f'{host}, issuer', org)
        else:
            out('WARN', 'TLS', f'{host}, issuer', f'{org}: the company inspects HTTPS traffic', '-', '-')
        if bundle:
            try:
                with socket.create_connection((host, 443), timeout=T) as s2, \
                        ssl.create_default_context(cafile=bundle).wrap_socket(s2, server_hostname=host):
                    pass
            except ssl.SSLError:
                bundle_fails.append(host)
    if bundle_fails:
        fixed, why = write_bundle(bundle, bundle_fails)
        if fixed:
            fix = (f'Libraries that ship their own certificate list (requests, httpx, curl_cffi) fail on inspected '
                   f'sites. {fixed} holds that list plus the Windows root certificates, and works on these hosts. '
                   f'Copy it next to your projects and set SSL_CERT_FILE, REQUESTS_CA_BUNDLE and CURL_CA_BUNDLE '
                   f'to its path (setx SSL_CERT_FILE "path" keeps it for your user); for curl_cffi also pass verify="path".')
        else:
            bundle_fails.append(f'(a combined bundle did not help: {why})')
            fix = ('Libraries that ship their own certificate list (requests, httpx, curl_cffi) fail on inspected sites. '
                   'Install truststore or pip-system-certs, or set SSL_CERT_FILE and REQUESTS_CA_BUNDLE to a .pem '
                   'that also holds the company root certificate.')
        out('FAIL', 'TLS', 'apps with their own certificate list', 'certifi rejects ' + ', '.join(bundle_fails), 'S', fix)
    elif bundle:
        out('PASS', 'TLS', 'apps with their own certificate list', 'certifi accepts every host it reached')


def write_bundle(certifi_pem, hosts):
    """certifi plus the Windows certificate stores as one .pem.

    Returns (path, None) when the file works for every host in `hosts`, else
    (None, why). Each Windows certificate is test-loaded on its own first:
    one that OpenSSL cannot read would make the whole file fail to load.
    """
    if not hasattr(ssl, 'enum_certificates'):
        return None, 'not on Windows'
    if not os.environ.get('LC_OUT'):
        return None, 'no output folder'
    with open(certifi_pem, encoding='utf-8') as f:
        pems = [f.read()]
    seen, skipped = set(), 0
    for store in ('ROOT', 'CA'):
        for der, enc, trust in ssl.enum_certificates(store):
            if enc != 'x509_asn' or der in seen:
                continue
            seen.add(der)
            try:
                ssl.create_default_context(cadata=der)
            except (ssl.SSLError, ValueError):
                skipped += 1
                continue
            pems.append(ssl.DER_cert_to_PEM_cert(der))
    path = os.path.join(os.environ['LC_OUT'], 'ca-bundle.pem')
    with open(path, 'w', encoding='utf-8') as f:
        f.write('\n'.join(pems))
    for host in hosts:
        try:
            with socket.create_connection((host, 443), timeout=T) as s, \
                    ssl.create_default_context(cafile=path).wrap_socket(s, server_hostname=host):
                pass
        except (OSError, ssl.SSLError) as e:
            return None, f'{host}: {e} ({len(seen)} Windows certificates, {skipped} unreadable)'
    return path, None


def port_owner(port):
    for line in run(['netstat', '-ano']).stdout.splitlines():
        parts = line.split()
        if len(parts) >= 5 and parts[1].endswith(f':{port}') and parts[3] == 'LISTENING':
            pid = parts[4]
            row = run(['tasklist', '/fi', f'PID eq {pid}', '/fo', 'csv', '/nh']).stdout.strip()
            return f'{row.split(",")[0].strip(chr(34)) if row else "?"} (PID {pid})'
    return 'another program'


@guarded('Local server', 'ports')
def ports():
    for port in [int(p) for p in os.environ.get('LC_PORTS', '8000').split()]:
        check = f'serve on 127.0.0.1:{port}'
        s = socket.socket()
        try:
            s.bind(('127.0.0.1', port))
        except OSError as e:
            if getattr(e, 'winerror', None) == 10013:
                out('FAIL', 'Local server', check, 'Windows reserves this port (an excluded port range)', 'W',
                    'Use a port outside the ranges in: netsh interface ipv4 show excludedportrange protocol=tcp. '
                    'Changing the ranges needs admin.')
            else:
                out('WARN', 'Local server', check, f'already in use by {port_owner(port)}', 'S',
                    'Close that program before starting the app, or start the app on another port if it allows.')
            s.close()
            continue
        s.listen(1)
        try:
            socket.create_connection(('127.0.0.1', port), timeout=5).close()
            out('PASS', 'Local server', check, 'a local web app can run here')
        except OSError as e:
            out('FAIL', 'Local server', check, f'listening works, connecting does not: {e}', 'I',
                'Something blocks loopback connections. Ask IT about the firewall or endpoint protection.')
        finally:
            s.close()


@guarded('Files', 'Python writes')
def files():
    docs = os.environ.get('LC_DOCS')
    if docs and os.path.isdir(docs):
        f = os.path.join(docs, f'laptop-check-{os.getpid()}.tmp')
        try:
            with open(f, 'w') as h:
                h.write('x')
            os.remove(f)
            out('PASS', 'Files', 'Python writes to Documents', docs)
        except PermissionError as e:
            out('FAIL', 'Files', 'Python writes to Documents', str(e), 'I',
                'Controlled Folder Access probably blocks python.exe. Ask IT to allow it, or keep '
                'projects in a folder it does not protect, such as %USERPROFILE%\\dev.')
    many = tempfile.mkdtemp(dir=WORK)
    start = time.perf_counter()
    for i in range(500):
        with open(os.path.join(many, f'{i}.txt'), 'w') as h:
            h.write('x' * 1024)
    ms = int((time.perf_counter() - start) * 1000)
    if ms < 3000:
        out('PASS', 'Files', 'writing 500 small files', f'{ms} ms')
    else:
        out('WARN', 'Files', 'writing 500 small files', f'{ms} ms: antivirus scans every file', '-', '-')


@guarded('Browsers', 'automation')
def automation():
    no_proxy = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    for exe in [b for b in os.environ.get('LC_BROWSERS', '').split(';') if b]:
        name = os.path.splitext(os.path.basename(exe))[0]
        check = f'{name}: automation (remote debugging)'
        prof = tempfile.mkdtemp(prefix='laptop-check-cdp-', dir=os.environ.get('LOCALAPPDATA') or WORK)
        p = subprocess.Popen([exe, '--headless=new', '--disable-gpu', '--no-first-run',
                              '--no-default-browser-check', '--remote-debugging-port=0',
                              f'--user-data-dir={prof}', 'about:blank'],
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            marker = os.path.join(prof, 'DevToolsActivePort')
            deadline = time.time() + T
            while time.time() < deadline and not os.path.exists(marker) and p.poll() is None:
                time.sleep(0.5)
            if not os.path.exists(marker):
                out('FAIL', 'Browsers', check, 'the debugging port never opened', 'I',
                    'Browser automation (Playwright, Selenium) needs remote debugging, which is off here. '
                    'Ask IT to allow RemoteDebuggingAllowed, or do that step by hand.')
                continue
            port = int(open(marker).read().split()[0])
            info = json.load(no_proxy.open(f'http://127.0.0.1:{port}/json/version', timeout=5))
            out('PASS', 'Browsers', check, info.get('Browser', 'answers'))
        finally:
            run(['taskkill', '/pid', str(p.pid), '/t', '/f'], timeout=15)
            time.sleep(1)
            shutil.rmtree(prof, ignore_errors=True)


if __name__ == '__main__':
    version()
    pip()
    wheels()
    tls()
    ports()
    files()
    automation()
