"""Integration checks run by verify.ps1 after its isolated-environment preflight.

The ordinary infra CI may use a global/unlocked interpreter; these checks require
our full locked developer environment and must not be mixed into that lane.
"""
import json
import os
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / 'scripts/python_environment.py'


def run_helper(*args):
    return subprocess.run([sys.executable, str(SCRIPT), *map(str, args)],
                          capture_output=True, text=True, encoding='utf-8', timeout=60)


def test_check_reports_real_venv_and_lock_identity():
    result = run_helper('check')
    assert result.returncode == 0, result.stderr
    report = json.loads(result.stdout)
    assert Path(report['executable']).resolve() == Path(sys.executable).resolve()
    assert report['version'].startswith('3.12.')
    assert len(report['production_lock_sha256']) == 64


def test_powershell_preflight_executes_stdin_and_restores_environment():
    # An empty-success wrapper must not make stdin validation green.
    command = r'''
$utf8=[System.Text.UTF8Encoding]::new($false)
[Console]::InputEncoding=$utf8; [Console]::OutputEncoding=$utf8; $OutputEncoding=$utf8
$env:PYTHONUTF8='1'; $env:PYTHONIOENCODING='utf-8'
$beforePath=$env:PYTHONPATH
$beforeOpts=$env:PYTEST_ADDOPTS
& $env:TEST_VERIFY_SCRIPT -Python $env:TEST_PYTHON -PreflightOnly
if($env:PYTHONPATH -cne $beforePath -or $env:PYTEST_ADDOPTS -cne $beforeOpts) {throw 'Environment leaked'}
'''
    env = os.environ.copy()
    env.update(TEST_VERIFY_SCRIPT=str(ROOT / 'scripts/verify.ps1'), TEST_PYTHON=sys.executable,
               BUSINESS_SMS_ALIYUN_CODE_VALID_MINUTES='15', PYTHONPATH='sentinel',
               PYTEST_ADDOPTS='--basetemp="C:\\do not delete\\sentinel"')
    result = subprocess.run(['pwsh', '-NoProfile', '-Command', command], env=env,
                            capture_output=True, text=True, encoding='utf-8', timeout=90)
    assert result.returncode == 0, result.stdout + result.stderr
    assert 'Python stdin: PASS (输入)' in result.stdout
    assert 'Preflight: PASS' in result.stdout
    assert 'Verification: PASS' not in result.stdout


def test_preflight_rejects_invalid_sms_configuration_without_rendering():
    env = os.environ.copy()
    env['BUSINESS_SMS_ALIYUN_CODE_VALID_MINUTES'] = '5'
    result = subprocess.run(['pwsh', '-NoProfile', '-File', str(ROOT / 'scripts/verify.ps1'),
                             '-Python', sys.executable, '-PreflightOnly'], env=env,
                            capture_output=True, text=True, encoding='utf-8', timeout=90)
    assert result.returncode != 0
    assert 'Business configuration/import preflight failed' in result.stderr
    assert 'Render-only configuration smoke test' not in result.stdout
