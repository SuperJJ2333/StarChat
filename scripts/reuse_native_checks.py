"""Bounded reuse of this task's successful, unchanged native permission gate."""
import json
import os
from pathlib import Path
import subprocess
import urllib.request

EVIDENCE_RUN = '35526915961'
EVIDENCE_SHA = 'f25ffee9dce5a51149f0156425ad755c4ff9472f'
WORKFLOW = '.github/workflows/ios-testflight.yml'


def verify_native_evidence(run, jobs):
    if (str(run.get('id')) != EVIDENCE_RUN
            or run.get('head_sha') != EVIDENCE_SHA
            or run.get('repository', {}).get('full_name') != 'SuperJJ2333/StarChat'
            or run.get('path') != WORKFLOW):
        raise ValueError('Unexpected native evidence identity')
    native = [job for job in jobs.get('jobs', []) if job.get('name') == 'simulator-build']
    if len(native) != 1 or native[0].get('conclusion') != 'success':
        raise ValueError('Native evidence job did not succeed')
    if not any(step.get('name') == 'Exercise real native permission strategies'
               and step.get('conclusion') == 'success' for step in native[0].get('steps', [])):
        raise ValueError('Native assertions did not succeed')


def native_job(workflow):
    return workflow.split('  simulator-build:', 1)[1].split('  build-upload:', 1)[0].replace(
        '    if: ${{ !inputs.reuse-native-run }}\n', '')


def main():
    if os.environ.get('REUSE_NATIVE_RUN') != EVIDENCE_RUN:
        raise ValueError('Only the reviewed native run may be reused')
    base = 'https://api.github.com/repos/SuperJJ2333/StarChat/actions/runs/' + EVIDENCE_RUN
    def get(url):
        request = urllib.request.Request(url, headers={
            'Authorization': 'Bearer ' + os.environ['GH_TOKEN'],
            'Accept': 'application/vnd.github+json',
        })
        with urllib.request.urlopen(request, timeout=30) as response:
            return json.load(response)
    verify_native_evidence(get(base), get(base + '/jobs?per_page=100'))
    subprocess.run(['git', 'fetch', '--no-tags', '--depth=1', 'origin', EVIDENCE_SHA], check=True)
    subprocess.run(['git', 'diff', '--exit-code', EVIDENCE_SHA, 'HEAD', '--', 'apps/mobile_flutter'], check=True)
    source = subprocess.check_output(['git', 'show', EVIDENCE_SHA + ':' + WORKFLOW], text=True)
    if native_job(source) != native_job(Path(WORKFLOW).read_text(encoding='utf-8')):
        raise ValueError('Native toolchain or commands changed')
    print('Native job reused from ' + EVIDENCE_RUN + '; full app and native workflow inputs identical.')


if __name__ == '__main__':
    main()
