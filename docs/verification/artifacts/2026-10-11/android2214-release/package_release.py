"""Build a local, reviewable Android 2214 package. Never contacts a server."""
import argparse
import ast
import csv
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import tarfile
import tempfile
from types import ModuleType, SimpleNamespace

HERE = Path(__file__).resolve().parent
SIGNER = '75b31c66476cd8e2c9319551b49405a1de1e5c23e9a0dbdcc9eb76b52ba61fff'
NAME = 'ChatFlow-0.4.45-build2214-arm64.apk'
CHECKS = ('shared_flutter', 'native_android', 'final_apk')
MODULES = ('release_2214.py', 'delivery_2214.py', 'settings_2214.py', 'verify_production_2214.py')
BASELINES = ('hk-live-snapshot.json', 'sg-live-snapshot.json', 'settings-before.json',
             'static-baseline.json', 'cloudfront-before.json', 'bucket-policy-before.json')


def fail(condition, message):
    if not condition:
        raise ValueError(message)


def hex_identity(value, length, label):
    fail(isinstance(value, str) and re.fullmatch('[0-9a-f]{%d}' % length, value)
         and value != '0' * length, 'missing/invalid ' + label)
    return value


def regular(path):
    path = Path(path).absolute()
    fail(path.is_file() and not any(p.is_symlink() for p in (path, *path.parents)),
         'regular non-symlink file required: ' + str(path))
    return path


def member(root, name):
    fail(isinstance(name, str) and name and '\\' not in name and ':' not in name,
         'invalid relative member')
    part = PurePosixPath(name)
    fail(not part.is_absolute() and all(p not in ('..', '.') for p in name.split('/')),
         'unsafe relative member')
    path = Path(root).absolute().joinpath(*part.parts)
    fail(path.is_relative_to(Path(root).absolute()), 'member escaped root')
    return regular(path)


def digest(path):
    with regular(path).open('rb') as source:
        return hashlib.file_digest(source, 'sha256').hexdigest()


def read_json(path):
    return json.loads(regular(path).read_text(encoding='utf-8'))


def write_json(path, value):
    Path(path).write_text(json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + '\n', encoding='utf-8')


def load_release(path):
    # Execute the verified source; never trust timestamp-based cached bytecode.
    module = ModuleType('release_2214_package')
    module.__file__ = str(path)
    exec(compile(regular(path).read_bytes(), str(path), 'exec'), module.__dict__)
    return module


def validate_steps(path):
    with regular(path).open(encoding='utf-8', newline='') as source:
        reader = csv.DictReader(source, delimiter='\t')
        fail(reader.fieldnames and reader.fieldnames[:2] == ['step', 'exit_code'], 'steps schema')
        rows = list(reader)
    names = [row['step'] for row in rows]
    fail(rows and len(names) == len(set(names)) and all(names), 'empty/duplicate build steps')
    fail(all(row.get('exit_code') == '0' and None not in row for row in rows), 'failed/malformed build step')
    # Current builder names and the explicit canonical receipts are supported.
    for aliases in ({'source-build', 'flutter-build-release'}, {'apk-rebuild', 'apktool-rebuild'},
                    {'signature-gate', 'apksigner-verify'}):
        fail(bool(set(names) & aliases), 'missing required build phase')
    return len(rows)


def validate_build(apk, artifact, steps, gate_path):
    regular(apk)
    fail((artifact.get('version'), artifact.get('build'), artifact.get('mode')) ==
         ('0.4.45', 2214, 'standard-arm64-release') and type(artifact.get('build')) is int,
         'wrong target/version/mode')
    fail(artifact.get('signer_sha256') == SIGNER, 'fixed signer required')
    for key, length in (('source_commit', 40), ('mobile_manifest_sha256', 64),
                        ('pubspec_lock_sha256', 64), ('final_apk_sha256', 64)):
        hex_identity(artifact.get(key), length, key)
    size = artifact.get('final_apk_bytes')
    fail(type(size) is int and size > 0 and Path(apk).stat().st_size == size, 'APK byte identity')
    fail(digest(apk) == artifact['final_apk_sha256'], 'APK SHA identity')
    validate_steps(steps)
    gates = read_json(gate_path)
    for gate_key, artifact_key in (('source_commit', 'source_commit'),
            ('source_manifest_sha256', 'mobile_manifest_sha256'),
            ('pubspec_lock_sha256', 'pubspec_lock_sha256'), ('artifact_sha256', 'final_apk_sha256')):
        fail(gates.get(gate_key) == artifact[artifact_key], 'gate binding drift: ' + gate_key)
    identity = dict(package='com.liuhetong.mobile', abi='arm64-v8a', version='0.4.45',
                    build=2214, signer_sha256=SIGNER, artifact_bytes=size)
    fail(gates.get('final_identity') == identity and
         type(gates['final_identity']['artifact_bytes']) is int and
         type(gates['final_identity']['build']) is int, 'final package/ABI/signer identity')
    fail(isinstance(gates.get('checks'), dict) and set(gates['checks']) == set(CHECKS), 'three final gates required')
    for key in CHECKS:
        evidence = gates['checks'][key]
        fail(evidence.get('status') == 'pass', 'gate not passed: ' + key)
        hex_identity(evidence.get('sha256'), 64, 'gate evidence SHA')
        fail(digest(member(Path(gate_path).parent, evidence.get('path'))) == evidence['sha256'],
             'gate evidence drift: ' + key)
    return dict(version='0.4.45', build=2214, artifact_sha256=artifact['final_apk_sha256'],
                artifact_bytes=size, source_commit=artifact['source_commit'],
                source_manifest_sha256=artifact['mobile_manifest_sha256'],
                pubspec_lock_sha256=artifact['pubspec_lock_sha256'], signer_sha256=SIGNER)


def validate_source(root, manifest_path, artifact):
    fail(digest(manifest_path) == artifact['mobile_manifest_sha256'], 'source manifest identity')
    manifest = read_json(manifest_path)
    files = manifest.get('files')
    fail(isinstance(files, list) and files, 'nonempty source manifest required')
    seen = set()
    for item in files:
        name = item.get('path')
        fail(name not in seen, 'duplicate source member')
        seen.add(name)
        hex_identity(item.get('sha256'), 64, 'source member SHA')
        fail(digest(member(root, name)) == item['sha256'], 'source file drift: ' + name)
    fail({'apps/mobile_flutter/pubspec.yaml', 'apps/mobile_flutter/pubspec.lock'} <= seen,
         'source manifest omits version or dependency lock')
    fail(digest(member(root, 'apps/mobile_flutter/pubspec.lock')) == artifact['pubspec_lock_sha256'],
         'dependency lock drift')
    # The passed build gate attests the commit; this does not require HEAD to stay
    # unchanged after evidence-only commits. Every manifest input is rehashed.


def create_package(args):
    artifact = read_json(args.artifact)
    record = validate_build(args.apk, artifact, args.steps, args.gates)
    validate_source(args.source_root, args.source_manifest, artifact)
    fail(isinstance(args.signing_confirmed_by, str) and args.signing_confirmed_by.strip(), 'signing evidence description required')
    output = Path(args.output).absolute()
    fail(not output.exists() and not output.is_symlink(), 'output must be new')
    fail(output.parent.is_dir() and not any(p.is_symlink() for p in (output.parent, *output.parents)), 'safe existing output parent required')
    # Validation precedes even the temporary output. No partially valid package
    # appears at the final path if an input or offline preparation fails.
    temporary = Path(tempfile.mkdtemp(prefix='.2214-package-', dir=output.parent))
    try:
        os.chmod(temporary, 0o700)
        runtime = temporary / 'runtime'; runtime.mkdir(mode=0o700)
        payload = HERE / 'payload'
        for name in (*MODULES, *BASELINES):
            shutil.copyfile(regular(payload / name), runtime / name)
        release = load_release(runtime / 'release_2214.py')
        for name in (*release.PRESERVED, 'download.html', 'downloads/android-release.json'):
            destination = runtime / 'hk-snapshot' / name
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(member(payload / 'hk-snapshot', name), destination)
        release.prepare(SimpleNamespace(sha256=record['artifact_sha256'], bytes=record['artifact_bytes'],
            signing_confirmed_by=args.signing_confirmed_by, source_commit=record['source_commit'],
            source_manifest_sha256=record['source_manifest_sha256'], snapshot=runtime/'hk-snapshot',
            settings=runtime/'settings-before.json', cloudfront=runtime/'cloudfront-before.json',
            policy=runtime/'bucket-policy-before.json', output=runtime/'prepared-2214'))
        r = read_json(runtime / 'prepared-2214/release.json'); release.validate_release(r)
        # No policy write exists in the cloud operation. Preserve its local
        # before/target bytes too, instead of merely equivalent JSON.
        shutil.copyfile(runtime/'bucket-policy-before.json',runtime/'prepared-2214/bucket-policy-target.json')
        delivery = temporary / 'delivery'; delivery.mkdir()
        shutil.copyfile(args.apk, delivery / NAME)
        evidence = temporary / 'evidence'; evidence.mkdir()
        orchestrator = temporary / 'orchestrator'; orchestrator.mkdir()
        for name in ('package_release.py', 'execute_release.py'):
            shutil.copyfile(regular(HERE/name), orchestrator/name)
        for name, source in (('artifact.json', args.artifact), ('steps.tsv', args.steps),
                ('gates.json', args.gates), ('mobile-inputs.json', args.source_manifest)):
            shutil.copyfile(source, evidence / name)
        gates = read_json(args.gates)
        for check in gates['checks'].values():
            destination = evidence / check['path']
            fail(destination not in (evidence/n for n in ('artifact.json', 'steps.tsv', 'gates.json', 'mobile-inputs.json')), 'gate evidence reserved filename')
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(member(Path(args.gates).parent, check['path']), destination)
        validate_build(delivery/NAME, read_json(evidence/'artifact.json'), evidence/'steps.tsv', evidence/'gates.json')
        backfill = temporary/'source-backfill'; backfill.mkdir()
        edits = {}
        for name, hashes in r['deployment']['static'].items():
            target = backfill / 'frontend' / name; target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(runtime/'prepared-2214/staged'/name, target)
            edits['frontend/'+name] = {**hashes, 'staged': 'source-backfill/frontend/'+name}
        write_json(backfill/'plan.json', {'mode':'review-only-no-repository-write', 'files':edits,
            'preserved':{'frontend/'+n:h for n,h in r['deployment']['preserved'].items()},
            'rule':'Parent compares exact before hashes, applies only these two files after publication review; any drift stops.'})
        # Read-only projections are frozen alongside the runtime, not re-frozen
        # from future live state. They are executed before the first remote write.
        for host in ('hk', 'sg'):
            shutil.copyfile(HERE/'baseline'/f'{host}-projection-source.py', runtime/f'{host}-projection-source.py')
        runtime_files = {p.relative_to(runtime).as_posix():digest(p) for p in sorted(runtime.rglob('*'))
                         if p.is_file() and '__pycache__' not in p.parts}
        for name in runtime_files:
            if name.endswith('.py'): ast.parse((runtime/name).read_text(encoding='utf-8'), feature_version=(3,9))
        archive = temporary/'runtime-2214.tar.gz'
        with tarfile.open(archive, 'w:gz') as tar:
            for name in runtime_files: tar.add(runtime/name, arcname=name, recursive=False)
        # Omit import bytecode entirely from the final package.
        for path in runtime.rglob('__pycache__'): shutil.rmtree(path)
        files = {p.relative_to(temporary).as_posix():digest(p) for p in sorted(temporary.rglob('*')) if p.is_file()}
        freeze = {'schema':1, **record, 'files':files, 'runtime_files':runtime_files,
            'runtime_sha256':digest(archive), 'runtime_bytes':archive.stat().st_size,
            'release_sha256':digest(runtime/'prepared-2214/release.json'),
            'build_steps':validate_steps(evidence/'steps.tsv')}
        write_json(temporary/'freeze-manifest.json', freeze)
        os.rename(temporary, output)
        return {'status':'PREPARED_OFFLINE_REQUIRES_REVIEW', 'package':str(output),
                'freeze_sha256':digest(output/'freeze-manifest.json'), **record}
    except BaseException:
        # Only this function's checked, newly-created temporary directory.
        fail(temporary.parent == output.parent and temporary.name.startswith('.2214-package-'), 'temporary ownership')
        shutil.rmtree(temporary)
        raise


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('apk', 'artifact', 'steps', 'gates', 'source-root', 'source-manifest', 'output'):
        parser.add_argument('--'+name, type=Path, required=True)
    parser.add_argument('--signing-confirmed-by', required=True)
    print(json.dumps(create_package(parser.parse_args()), ensure_ascii=False, sort_keys=True))


if __name__ == '__main__': main()
