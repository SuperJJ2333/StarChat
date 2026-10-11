"""Bind unchanged platform gates to the final source; never rebuild or publish."""
import argparse
import hashlib
import json
import subprocess
from datetime import datetime, timezone
from pathlib import Path


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def git(repo, *args):
    return subprocess.run(['git', '-C', str(repo), *args], check=True,
                          capture_output=True).stdout.decode('utf-8').strip()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--repo', type=Path, required=True)
    parser.add_argument('--manifest', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    repo = args.repo.resolve(strict=True)
    dest = args.output
    if dest.exists():
        raise ValueError('Never overwrite platform evidence')
    manifest = json.loads(args.manifest.read_text(encoding='utf-8'))
    candidate = git(repo, 'rev-parse', 'HEAD')
    assert candidate == manifest['source_commit']
    for entry in manifest['files'] + manifest['generated_inputs']:
        assert digest(repo / entry['path']) == entry['sha256'], entry['path']
    root = Path(__file__).resolve().parent
    native_path = root / 'final-gates/native-android.json'
    native = json.loads(native_path.read_text(encoding='utf-8'))
    assert native['status'] == 'pass' and native['real_tests'] == 3
    assert not git(repo, 'diff', '--name-only', native['executed_source_commit'],
                   candidate, '--', *native['unchanged_source_paths'])
    for entry in native['evidence'].values():
        assert digest(Path(entry['path'])) == entry['sha256']
    native['candidate_source_commit'] = candidate
    native['candidate_manifest_sha256'] = digest(args.manifest)
    native['reused_report_sha256'] = digest(native_path)
    ios_path = root / 'ios-final-r2-verified-summary.json'
    ios = json.loads(ios_path.read_text(encoding='utf-8'))
    assert ios['status'] == 'pass' and len(ios['native_targets']) == 3
    assert sum(t['passed'] for t in ios['native_targets']) == 20
    assert sum(t['skipped'] + t['failed'] for t in ios['native_targets']) == 0
    changed = git(repo, 'diff', '--name-only', ios['source_commit'], candidate,
                  '--', 'apps/mobile_flutter', '.github/workflows').splitlines()
    assert changed == ['apps/mobile_flutter/test/features/matrix/room_search_media_grid_test.dart'], changed
    ipa = root / 'ios-unsigned-38125303494/extracted/ChatFlow-0.4.45-build2214-unsigned.ipa'
    assert digest(ipa) == '0fad8d42bcab9439ff35951e44b7f0df6b284660200b23b576f6d12ce72a4d3b'
    assert ipa.stat().st_size == 34964622
    ios_binding = {
        'schema': 1, 'status': 'pass', 'scope': 'unchanged iOS runtime/native/dependencies/workflow build and native evidence',
        'candidate_source_commit': candidate,
        'candidate_manifest_sha256': digest(args.manifest),
        'executed_source_commit': ios['source_commit'], 'run_id': ios['run_id'],
        'changed_mobile_or_workflow_paths': changed,
        'reused_summary_sha256': digest(ios_path), 'ipa_sha256': digest(ipa),
        'ipa_bytes': ipa.stat().st_size, 'native_passed': 20,
        'limitations': ['Unsigned IPA; enterprise identity and old-iPhone upgrade not validated',
                        'No actual APNs/Focus/locked-device arrival or power/performance acceptance'],
    }
    dest.mkdir(parents=True, exist_ok=False)
    for name, data in [('native-android.json', native), ('ios-reuse.json', ios_binding)]:
        data['bound_at_utc'] = datetime.now(timezone.utc).isoformat()
        (dest / name).write_text(json.dumps(data, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    print(json.dumps({'status': 'pass', 'candidate': candidate, 'native_tests': 3,
                      'ios_native_tests': 20, 'output': str(dest)}))


if __name__ == '__main__':
    main()
