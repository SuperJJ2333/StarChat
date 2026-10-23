"""Regression coverage for the developer interpreter and platform lock boundary."""
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / 'scripts/python_environment.py'


def run_helper(*args):
    return subprocess.run([sys.executable, str(SCRIPT), *map(str, args)],
                          capture_output=True, text=True, encoding='utf-8', timeout=60)


def test_windows_lock_preserves_every_production_pin_except_uvloop(tmp_path):
    output = tmp_path / 'requirements.windows.lock'
    result = run_helper('lock', '--platform', 'win32', '--output', output)
    assert result.returncode == 0, result.stderr
    pins = output.read_text(encoding='utf-8').splitlines()
    original = (ROOT / 'services/business-api/requirements.lock').read_text().splitlines()
    assert 'uvloop==0.22.1' not in pins
    assert set(original) - set(pins) == {'uvloop==0.22.1'}
    assert 'pytest==8.4.2' in pins
    assert 'matrix-nio==0.26.0' in pins
    assert len(pins) == len(set(pins))


def test_linux_lock_keeps_uvloop(tmp_path):
    output = tmp_path / 'requirements.linux.lock'
    result = run_helper('lock', '--platform', 'linux', '--output', output)
    assert result.returncode == 0, result.stderr
    assert 'uvloop==0.22.1' in output.read_text().splitlines()


def test_environment_check_rejects_global_interpreter():
    result = subprocess.run([sys._base_executable, str(SCRIPT), 'check'],
                            capture_output=True, text=True, timeout=60)
    assert result.returncode != 0
    assert 'isolated Python 3.12' in result.stderr


def test_optimized_interpreter_is_rejected_before_verification():
    result = subprocess.run([sys.executable, '-O', str(SCRIPT), 'check'],
                            capture_output=True, text=True, timeout=60)
    assert result.returncode != 0
    assert 'Python optimization must be disabled' in result.stderr
