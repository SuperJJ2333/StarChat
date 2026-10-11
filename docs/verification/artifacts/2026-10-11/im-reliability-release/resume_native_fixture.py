"""Resume verified synthetic APK using bounded non-streaming ADB installation."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
from datetime import datetime, timezone

repo = Path('C:/Users/Administrator/.codex/worktrees/im-reliability/StarChat')
dest = repo/'docs/verification/artifacts/2026-10-11/im-reliability-release/native-storage2214-r2'
apk = dest/'final.apk'
expected = '7ec5863b389e0c1902d6b20933491924276c99daad27c25a66d79ff9ae58f4ee'
assert hashlib.sha256(apk.read_bytes()).hexdigest() == expected
adb = 'C:/Users/Administrator/AppData/Local/Android/Sdk/platform-tools/adb.exe'
device, package = 'emulator-5558', 'com.liuhetong.mobile.debug'
receipt = {'started_utc': datetime.now(timezone.utc).isoformat(), 'source_commit': '2a0fc392',
           'apk_sha256': expected, 'device': device, 'package': package, 'steps': []}

def run(name, argv, *, timeout=15, cwd=None, required=True):
    try:
        result = subprocess.run(argv, cwd=cwd, capture_output=True, text=True, encoding='utf-8', errors='replace', timeout=timeout)
    except subprocess.TimeoutExpired:
        receipt['steps'].append({'name': name, 'timeout_seconds': timeout})
        raise
    (dest/(name+'.log')).write_text(result.stdout+result.stderr, encoding='utf-8')
    receipt['steps'].append({'name': name, 'exit_code': result.returncode})
    if required:
        assert result.returncode == 0, name
    return result.stdout.strip()

def device_cmd(name, args, **kwargs):
    return run(name, [adb, '-s', device, *args], **kwargs)

assert device_cmd('resume-state', ['get-state']) == 'device'
existing = device_cmd('resume-preflight', ['shell','pm','list','packages','-u',package])
assert 'package:'+package not in existing.splitlines(), 'existing or retained package; refuse'
assert not Path('W:/').exists(), 'W mapping already owned'
run('resume-map', ['subst.exe','W:',str(repo)])
attempted = False
try:
    attempted = True
    device_cmd('install-no-streaming', ['install','--no-streaming',str(apk)], timeout=180)
    run('native-drive', ['C:/src/flutter/bin/flutter.bat','drive','--no-pub','--debug','--flavor','standard',
                        '--use-application-binary',str(apk),'--driver','integration_test/permission_driver.dart',
                        '-t','integration_test/reliability_media_native_test.dart','-d',device,'--timeout','180'],
        cwd='W:/apps/mobile_flutter', timeout=240)
    receipt['result'] = 'PASS'
finally:
    try:
        if attempted:
            path = device_cmd('resume-installed-path', ['shell','pm','path',package], required=False)
            if path:
                assert path.startswith('package:/data/app/') and '\n' not in path
                path = path.removeprefix('package:')
                actual = device_cmd('resume-installed-sha', ['shell','sha256sum',path]).split()[0]
                assert actual == expected, 'installed identity differs; refuse removal'
                device_cmd('resume-owned-remove', ['uninstall',package], timeout=30)
    finally:
        mapping = run('resume-mapping-check', ['subst.exe'])
        assert 'W:\\: => '+str(repo) in mapping, 'mapping owner changed; refuse removal'
        run('resume-unmap', ['subst.exe','W:','/D'])
        receipt['ended_utc'] = datetime.now(timezone.utc).isoformat()
        (dest/'resume-receipt.json').write_text(json.dumps(receipt, indent=2), encoding='utf-8')
print(json.dumps(receipt, indent=2))
