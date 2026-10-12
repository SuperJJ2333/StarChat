"""Run one existing synthetic-DPAPI test; never execute the signing wrapper."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timezone

HERE = Path(__file__).resolve().parent
TEST_COMMIT = 'bf6fa639fa3a02fab067b2708d27832c8299992f'
TEST_PATH = 'docs/verification/artifacts/2026-10-12/media-debug-packaging-tools/test_sign_wrapper.py'
TEST_SHA = '7cb68309598f3e92c215600e0c5efbe161d001b095485ab3f84c7506267d3f3d'
TEST_NAME = 'test_sign_wrapper.WrapperTests.test_dpapi_line_terminator_preserves_password_and_decrypts'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--phase', choices=('red', 'green'), required=True)
    args = parser.parse_args()
    receipt_path = HERE / f'signer-dpapi-{args.phase}-receipt.json'
    log_path = HERE / f'signer-dpapi-{args.phase}.log'
    if receipt_path.exists() or log_path.exists():
        parser.error('Evidence already exists; do not overwrite it')
    test_bytes = subprocess.check_output(
        ['git', 'show', f'{TEST_COMMIT}:{TEST_PATH}'], cwd=HERE, timeout=15)
    if hashlib.sha256(test_bytes).hexdigest() != TEST_SHA:
        raise RuntimeError('Exact regression test input drift')
    wrapper = HERE / 'tools' / 'sign-existing-identity.ps1'
    wrapper_sha = hashlib.sha256(wrapper.read_bytes()).hexdigest()
    scratch = HERE / 'test-scratch'
    scratch.mkdir(exist_ok=True)
    started = datetime.now(timezone.utc).isoformat()
    monotonic = time.monotonic()
    # The pinned test gives itself a synthetic USERPROFILE and extracts only the
    # DPAPI assignment with the PowerShell AST. No main-script invocation occurs.
    with tempfile.TemporaryDirectory(prefix='dpapi-expression-', dir=scratch) as tmp:
        Path(tmp, 'test_sign_wrapper.py').write_bytes(test_bytes)
        env = os.environ.copy()
        env.update(CHATFLOW_SIGN_WRAPPER_UNDER_TEST=str(wrapper),
                   PYTHONUTF8='1', PYTHONIOENCODING='utf-8',
                   PYTHONDONTWRITEBYTECODE='1')
        result = subprocess.run(
            [sys.executable, '-m', 'unittest', '-v', TEST_NAME],
            cwd=tmp, env=env, capture_output=True, text=True,
            encoding='utf-8', timeout=40)
    elapsed = round(time.monotonic() - monotonic, 3)
    output = result.stdout + result.stderr
    if 'synthetic-dpapi-line-ending-value' in output:
        raise RuntimeError('Unexpected synthetic plaintext in output; evidence withheld')
    log_path.write_text(output, encoding='utf-8', newline='\n')
    receipt = {
        'started_utc': started, 'elapsed_seconds': elapsed,
        'phase': args.phase, 'exit_code': result.returncode,
        'wrapper_sha256': wrapper_sha,
        'test_commit': TEST_COMMIT, 'test_path': TEST_PATH,
        'test_git_sha256': TEST_SHA, 'test_name': TEST_NAME,
        'log_sha256': hashlib.sha256(log_path.read_bytes()).hexdigest(),
        'synthetic_windows_dpapi_only': True,
        'real_identity_read': False, 'actual_signing_or_build': False,
        'red_expected_failure': 'System.FormatException while parsing CRLF serialized DPAPI envelope',
        'green_assertion': 'CRLF envelope decrypts and preserves both plaintext boundary spaces; no signer/output APK',
    }
    receipt_path.write_text(json.dumps(receipt, indent=2) + '\n', encoding='utf-8', newline='\n')
    print(json.dumps({'phase': args.phase, 'test_exit_code': result.returncode,
                      'wrapper_sha256': wrapper_sha, 'elapsed_seconds': elapsed}))
    return result.returncode


if __name__ == '__main__':
    raise SystemExit(main())
