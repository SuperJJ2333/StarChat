"""Pinned, isolated clock discipline deployment. Execute on the authorized host."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import time

ROOT = Path('/opt/starchat/releases/clock-20260910')
VERSION = '4.5-1ubuntu4.2'
CONFIG = '''manual
maxdrift 500
maxslewrate 100000
port 0
cmdport 0
bindcmdaddress /run/starchat-clock/chronyd.sock
pidfile /run/starchat-clock/chronyd.pid
driftfile /var/lib/starchat-clock/drift
'''
UNIT = f'''[Unit]
Description=StarChat independently checked gradual clock discipline
After=network-online.target
Wants=network-online.target
Conflicts=systemd-timesyncd.service
[Service]
Type=simple
ExecStart={ROOT}/usr/sbin/chronyd -n -u root -f {ROOT}/chrony.conf
RuntimeDirectory=starchat-clock
RuntimeDirectoryMode=0700
StateDirectory=starchat-clock
StateDirectoryMode=0700
UMask=0077
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
ReadWritePaths=/run/starchat-clock /var/lib/starchat-clock
CapabilityBoundingSet=CAP_SYS_TIME CAP_SYS_NICE CAP_NET_BIND_SERVICE CAP_SETUID CAP_SETGID
Restart=on-failure
RestartSec=5
[Install]
WantedBy=multi-user.target
'''
FEED = f'''[Unit]
Description=StarChat fresh independent HTTPS UTC samples
After=starchat-clock.service network-online.target
Requires=starchat-clock.service
[Service]
Type=oneshot
ExecStart=/usr/bin/python3 {ROOT}/starchat_clock_feed.py --directory {ROOT} --apply
TimeoutStartSec=20
UMask=0077
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
ReadWritePaths=/run/starchat-clock /var/lib/starchat-clock
'''
TIMER = '''[Unit]
Description=Check independent UTC every five minutes
[Timer]
OnActiveSec=300s
OnUnitInactiveSec=300s
AccuracySec=1s
Persistent=true
[Install]
WantedBy=timers.target
'''


def run(args, **kwargs):
    kwargs.setdefault('timeout', 120)
    return subprocess.check_output(args, text=True, stderr=subprocess.PIPE, **kwargs).strip()


def state(unit, command):
    return subprocess.run(['systemctl', command, unit], capture_output=True, text=True).stdout.strip()


def prepare():
    if ROOT.exists() and (ROOT / 'prepared.json').exists():
        raise SystemExit('release already prepared; inspect existing evidence before retry')
    ROOT.mkdir(parents=True, exist_ok=True, mode=0o700)
    ROOT.chmod(0o700)
    baseline = dict(active=state('systemd-timesyncd', 'is-active'), enabled=state('systemd-timesyncd', 'is-enabled'))
    (ROOT / 'baseline.json').write_text(json.dumps(baseline))
    if state('chrony', 'is-active') == 'active' or state('chronyd', 'is-active') == 'active':
        raise SystemExit('another chrony instance requires coordination')
    metadata = run(['apt-cache', 'show', 'chrony=' + VERSION])
    expected = next(line.split(': ', 1)[1] for line in metadata.splitlines() if line.startswith('SHA256: '))
    run(['apt-get', 'download', 'chrony=' + VERSION], cwd=ROOT)
    package, = ROOT.glob('chrony_*.deb')
    assert hashlib.sha256(package.read_bytes()).hexdigest() == expected
    assert run(['dpkg-deb', '-f', str(package), 'Version']) == VERSION
    run(['dpkg-deb', '-x', str(package), str(ROOT)])
    for binary in ('usr/sbin/chronyd', 'usr/bin/chronyc'):
        assert 'not found' not in run(['ldd', str(ROOT / binary)])
    (ROOT / 'chrony.conf').write_text(CONFIG)
    for name, value in [('starchat-clock.service', UNIT), ('starchat-clock-feed.service', FEED), ('starchat-clock-feed.timer', TIMER)]:
        (ROOT / name).write_text(value)
    # Parse-only: -p prints configuration and exits; it cannot discipline the clock.
    parsed = run([str(ROOT / 'usr/sbin/chronyd'), '-p', '-f', str(ROOT / 'chrony.conf')])
    assert 'makestep' not in parsed and 'initstepslew' not in parsed
    run(['/usr/bin/python3', str(ROOT / 'starchat_clock_feed.py'), '--directory', str(ROOT)])
    (ROOT / 'prepared.json').write_text(json.dumps(dict(package_sha256=expected, version=VERSION,
        configuration_sha256=hashlib.sha256(CONFIG.encode()).hexdigest())))
    print('prepared: pinned binaries, dependencies, parse-only config and references verified; runtime unchanged')


def start():
    assert (ROOT / 'prepared.json').is_file()
    assert (ROOT / 'chrony.conf').read_text() == CONFIG
    baseline = json.loads((ROOT / 'baseline.json').read_text())
    assert state('systemd-timesyncd', 'is-active') == baseline['active']
    assert state('systemd-timesyncd', 'is-enabled') == baseline['enabled']
    assert state('chrony', 'is-active') != 'active' and state('chronyd', 'is-active') != 'active'
    for name, value in [('starchat-clock.service', UNIT), ('starchat-clock-feed.service', FEED), ('starchat-clock-feed.timer', TIMER)]:
        assert (ROOT / name).read_text() == value
        Path('/etc/systemd/system', name).write_text(value)
    run(['systemctl', 'daemon-reload'])
    run(['systemctl', 'disable', '--now', 'systemd-timesyncd.service'])
    try:
        run(['systemctl', 'enable', '--now', 'starchat-clock.service'])
        deadline = time.monotonic() + 15
        while True:
            try:
                run([str(ROOT / 'usr/bin/chronyc'), '-h', '/run/starchat-clock/chronyd.sock', 'tracking'], timeout=3)
                break
            except (subprocess.CalledProcessError, subprocess.TimeoutExpired):
                if time.monotonic() >= deadline:
                    raise
                time.sleep(.25)
        run(['systemctl', 'start', 'starchat-clock-feed.service'])
        run(['systemctl', 'enable', '--now', 'starchat-clock-feed.timer'])
    except Exception:
        rollback()
        raise
    print('started: gradual correction and reference timer; observe convergence before healthy claim')


def rollback():
    for unit in ('starchat-clock-feed.timer', 'starchat-clock-feed.service', 'starchat-clock.service'):
        subprocess.run(['systemctl', 'disable', '--now', unit], capture_output=True)
    baseline = json.loads((ROOT / 'baseline.json').read_text())
    if baseline['enabled'] == 'enabled':
        run(['systemctl', 'enable', 'systemd-timesyncd.service'])
    # timesyncd may step on newly restored network connectivity. Restore its
    # boot preference, but do not restart it without a reviewed correction policy.
    print('prior enabled state restored; timesyncd remains stopped pending safe discipline review; no wall-time reset issued')


def recover_frequency():
    """Discard an overfit manual frequency estimate, retaining offset slew only."""
    assert not (ROOT / 'frequency-recovery.json').exists()
    run(['systemctl', 'stop', 'starchat-clock-feed.timer', 'starchat-clock-feed.service'])
    run(['systemctl', 'stop', 'starchat-clock.service'])
    drift = Path('/var/lib/starchat-clock/drift')
    if drift.exists():
        (ROOT / 'pre-recovery-drift').write_bytes(drift.read_bytes())
    # Chrony reads this as ABSOLUTE frequency; removing the file would inherit
    # the previous kernel frequency. Large uncertainty avoids claiming precision.
    drift.write_text('0.0 100000.0\n')
    drift.chmod(0o600)
    (ROOT / 'chrony.conf').write_text(CONFIG)
    for name, value in [('starchat-clock.service', UNIT), ('starchat-clock-feed.service', FEED), ('starchat-clock-feed.timer', TIMER)]:
        (ROOT / name).write_text(value)
        Path('/etc/systemd/system', name).write_text(value)
    run([str(ROOT / 'usr/sbin/chronyd'), '-p', '-f', str(ROOT / 'chrony.conf')])
    run(['systemctl', 'daemon-reload'])
    run(['systemctl', 'start', 'starchat-clock.service'])
    deadline = time.monotonic() + 15
    while True:
        try:
            run([str(ROOT / 'usr/bin/chronyc'), '-h', '/run/starchat-clock/chronyd.sock', 'tracking'], timeout=3)
            break
        except (subprocess.CalledProcessError, subprocess.TimeoutExpired):
            if time.monotonic() >= deadline:
                raise
            time.sleep(.25)
    run(['systemctl', 'start', 'starchat-clock-feed.service'])
    run(['systemctl', 'start', 'starchat-clock-feed.timer'])
    (ROOT / 'frequency-recovery.json').write_text(json.dumps(dict(neutral_frequency_ppm=0,
        maxdrift_ppm=500, min_feed_spacing_seconds=300, wall_time_step=False)))
    print('bounded frequency seed and feed spacing applied; observe independent convergence')


if __name__ == '__main__':
    {'prepare': prepare, 'start': start, 'rollback': rollback, 'recover-frequency': recover_frequency}[sys.argv[1]]()
