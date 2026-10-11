"""Install only this task's empty synthetic package, with bounded non-streaming ADB."""
from pathlib import Path
import subprocess
import sys

ADB = 'C:/Users/Administrator/AppData/Local/Android/Sdk/platform-tools/adb.exe'
DEVICE = 'emulator-5558'
PACKAGE = 'com.liuhetong.mobile.debug'


def main():
    if len(sys.argv) != 2:
        raise ValueError('Exactly one verified fixture APK is required')
    apk = Path(sys.argv[1]).resolve(strict=True)
    if apk.name != 'final.apk' or not apk.is_file():
        raise ValueError('Expected verified final.apk')
    state = subprocess.run([ADB, '-s', DEVICE, 'get-state'], capture_output=True,
                           text=True, check=True, timeout=15)
    if state.stdout.strip() != 'device':
        raise RuntimeError('Fixture device unavailable')
    packages = subprocess.run([ADB, '-s', DEVICE, 'shell', 'pm', 'list', 'packages', '-u', PACKAGE],
                              capture_output=True, text=True, check=True, timeout=15)
    if 'package:' + PACKAGE in packages.stdout.splitlines():
        raise RuntimeError('Existing or retained package; refuse replacement')
    # subprocess kills and waits for only the owned adb client on timeout.
    # Device-side completion may remain uncertain; the caller must not assume failure is rollback.
    completed = subprocess.run([ADB, '-s', DEVICE, 'install', '--no-streaming', str(apk)],
                               capture_output=True, text=True, encoding='utf-8',
                               errors='replace', timeout=180)
    print(completed.stdout, end='')
    print(completed.stderr, end='', file=sys.stderr)
    return completed.returncode


if __name__ == '__main__':
    raise SystemExit(main())
