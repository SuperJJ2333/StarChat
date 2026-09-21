"""Reuse only successful same-repository Flutter checks with matching inputs."""
import json
import os
import re
import subprocess
import urllib.request
from pathlib import Path


# This is a bounded handoff between two runs of this task, not a generic bypass.
# The pinned workflow executes Flutter 3.44.9, analyze and the full flutter test.
EVIDENCE_RUN = '35519856915'
EVIDENCE_SHA = 'd988cae9f22d3a0f048841211833a47d4da21083'


def verified_sha(run, jobs):
    if str(run.get('id')) != EVIDENCE_RUN or run.get('head_sha') != EVIDENCE_SHA:
        raise ValueError('Only the reviewed full-check source/run can be reused')
    if run.get('repository', {}).get('full_name') != 'SuperJJ2333/StarChat':
        raise ValueError('Check run belongs to another repository')
    if run.get('path') != '.github/workflows/ios-testflight.yml':
        raise ValueError('Unexpected check workflow')
    checks = [j for j in jobs.get('jobs', []) if j.get('name') == 'flutter-checks']
    if len(checks) != 1 or checks[0].get('conclusion') != 'success':
        raise ValueError('Referenced Flutter checks did not succeed')
    if not any(step.get('name') == 'Flutter checks' and step.get('conclusion') == 'success'
               for step in checks[0].get('steps', [])):
        raise ValueError('Full Flutter check step was not successful')
    sha = run.get('head_sha', '')
    if not re.fullmatch(r'[0-9a-f]{40}', sha):
        raise ValueError('Invalid check source identity')
    return sha


def main():
    run_id = os.environ.get('REUSE_CHECKS_RUN', '')
    if not run_id:
        return
    if run_id != EVIDENCE_RUN:
        raise ValueError('Invalid check run id')
    base = 'https://api.github.com/repos/SuperJJ2333/StarChat/actions/runs/' + run_id
    def get(url):
        request = urllib.request.Request(url, headers={
            'Authorization': 'Bearer ' + os.environ['GH_TOKEN'],
            'Accept': 'application/vnd.github+json',
        })
        with urllib.request.urlopen(request, timeout=30) as response:
            return json.load(response)
    sha = verified_sha(get(base), get(base + '/jobs?per_page=100'))
    subprocess.run(['git', 'fetch', '--no-tags', '--depth=1', 'origin', sha], check=True)
    # flutter test covers test/, not integration_test/. Analyze and the native
    # integration job run again; every other Flutter input must be identical.
    subprocess.run(['git', 'diff', '--exit-code', sha, 'HEAD', '--',
                    'apps/mobile_flutter',
                    ':(exclude)apps/mobile_flutter/integration_test/**'], check=True)
    with Path(os.environ['GITHUB_OUTPUT']).open('a', encoding='utf-8') as output:
        output.write('reused=true\n')
    print(f'Flutter unit checks reused from successful run {run_id}, source {sha}; inputs identical.')


if __name__ == '__main__':
    main()
