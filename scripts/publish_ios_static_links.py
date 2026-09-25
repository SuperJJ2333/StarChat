"""Publish one enterprise IPA through the static iOS website only.

This command deliberately does not call SettingService apply. The app's automatic
and manual update checks therefore retain their existing iOS version. A payload
exception is allowed only for a specific candidate/final SHA pair and an exact,
fully enumerated list of changes acknowledged in the release record.

Run on the production host with a private source IPA and CI candidate. Example:
  python3 publish_ios_static_links.py release.json --root /opt/starchat/frontend \
    --ipa /opt/starchat/releases/ios2173/signed.ipa \
    --ios-candidate /opt/starchat/releases/ios2173/ci.ipa \
    --backup /opt/starchat/docs/verification/artifacts/2026-09-25/ios2173-static
"""

import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import re
import tempfile
from urllib.parse import urlsplit


STATIC_NAMES = ('download.html', 'src/admin-home.js', 'downloads/ios/manifest.plist')
SHA256_PATTERN = re.compile(r'[0-9a-f]{64}\Z')
KNOWN_SIGNER_DIFFERENCES = (
    'added Payload path: Payload/Runner.app/Frameworks/AppRuntime/ATHelper.dylib',
    'added Payload path: Payload/Runner.app/Frameworks/Partner/libutils.dylib',
    'added Payload path: Payload/Runner.app/flag',
    'Payload/Runner.app/Runner: Mach-O load commands changed for CPU 100000c',
)
PRIVATE_BACKUP_ROOT = Path('/opt/starchat/docs/verification/artifacts')
APP_SETTING_KEYS = frozenset((
    'app_latest_version', 'app_latest_build', 'app_min_supported_build',
    'app_update_notes', 'app_apk_url',
    'app_ios_latest_version', 'app_ios_latest_build',
    'app_ios_min_supported_build', 'app_ios_update_notes',
    'app_ios_download_url',
))


def _neighbor(name):
    path = Path(__file__).with_name(name + '.py')
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f'{name} is unavailable')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _sha256_file(path):
    digest = hashlib.sha256()
    with path.open('rb') as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()


def _sha256_bytes(data):
    return hashlib.sha256(data).hexdigest()


def _validate_exception(record, comparison):
    waiver = record.get('payload_exception')
    evidence = record.get('ios_ipa_evidence')
    if not isinstance(waiver, dict) or not isinstance(evidence, dict):
        raise ValueError('payload exception and final IPA evidence are required')
    expected_differences = waiver.get('expected_differences')
    if (waiver.get('candidate_sha256') != record['ios_ci_candidate_sha256']
            or waiver.get('final_sha256') != evidence.get('sha256')
            or not isinstance(expected_differences, list)
            or expected_differences != list(KNOWN_SIGNER_DIFFERENCES)
            or any(not isinstance(item, str) or not item.strip() for item in expected_differences)
            or not str(waiver.get('reason', '')).strip()
            or not str(waiver.get('authorized_by', '')).strip()):
        raise ValueError('payload exception is incomplete or does not identify this IPA')
    if (comparison.get('candidate_sha256') != waiver['candidate_sha256']
            or comparison.get('final_sha256') != waiver['final_sha256']
            or comparison.get('status') != 'fail'
            or comparison.get('differences') != expected_differences
            or 'additional differences omitted' in expected_differences):
        raise ValueError('payload exception differs from actual CI-to-enterprise changes')


def _reject_symlinks(path, root):
    """Reject aliases for every path segment owned by the static publisher."""
    path, root = path.absolute(), root.absolute()
    current = path
    while True:
        if current.is_symlink():
            raise ValueError(f'symlink is not allowed in static release path: {current}')
        if current == root:
            return
        if current == current.parent:
            raise ValueError('static release path escapes the public root')
        current = current.parent


def validate_backup_location(backup, *, allowed_root=PRIVATE_BACKUP_ROOT):
    """Keep CLI backups inside the server's private verification tree."""
    target, allowed = Path(backup).resolve(), Path(allowed_root).resolve()
    if target == allowed or not target.is_relative_to(allowed):
        raise ValueError('backup must be a fresh child of the private verification artifacts root')


def _validate_static_baseline(record, root):
    expected = record.get('static_before_sha256')
    if not isinstance(expected, dict) or set(expected) != set(STATIC_NAMES):
        raise ValueError('static drift baseline is missing or incomplete')
    before = {}
    for name in STATIC_NAMES:
        _reject_symlinks(root / name, root)
        digest = expected[name]
        if not isinstance(digest, str) or not SHA256_PATTERN.fullmatch(digest):
            raise ValueError(f'invalid static drift baseline: {name}')
        before[name] = (root / name).read_bytes()
        if _sha256_bytes(before[name]) != digest:
            raise ValueError(f'static drift: {name}')
    previous = plistlib.loads(before['downloads/ios/manifest.plist'])
    metadata = previous['items'][0]['metadata']
    if metadata['bundle-identifier'] != record['bundle_id']:
        raise ValueError('current manifest bundle ID differs from release record')
    if int(metadata['bundle-version']) >= record['build']:
        raise ValueError('static iOS build rollback or duplicate refused')
    return before


def _write_immutable_ipa(source, destination, expected_sha256, expected_size):
    destination.parent.mkdir(parents=True, exist_ok=True)
    if destination.is_symlink():
        raise ValueError('immutable IPA destination may not be a symlink')
    if destination.exists():
        if (destination.stat().st_size != expected_size
                or _sha256_file(destination) != expected_sha256):
            raise ValueError('immutable IPA path already contains different bytes')
        return False
    fd, temp = tempfile.mkstemp(dir=destination.parent, prefix='.ios-ipa-')
    try:
        copied = hashlib.sha256()
        size = 0
        with source.open('rb') as origin, os.fdopen(fd, 'wb') as target:
            for chunk in iter(lambda: origin.read(1024 * 1024), b''):
                target.write(chunk)
                copied.update(chunk)
                size += len(chunk)
            target.flush()
            os.fsync(target.fileno())
        if size != expected_size or copied.hexdigest() != expected_sha256:
            raise ValueError('source IPA changed while copying')
        os.chmod(temp, 0o644)
        os.link(temp, destination)  # Atomic and refuses another publisher's file.
        return True
    finally:
        if os.path.exists(temp):
            os.unlink(temp)


def publish(record, root, source_ipa, candidate_ipa, backup, *, request=None,
            db=None, inspector=None, comparator=None):
    """Apply a link-only release with exact-file CAS and reversible static writes."""
    import fcntl

    release = _neighbor('release_metadata')
    release.validate(record)
    if record['platform'] != 'ios':
        raise ValueError('this publisher only accepts iOS')
    root, source_ipa, candidate_ipa, backup = map(
        Path, (root, source_ipa, candidate_ipa, backup))
    request = request or release.fetch
    db = db or release.db_settings
    inspector = inspector or release.inspect_uploaded_ios_ipa
    comparator = comparator or release.compare_uploaded_ios_payload
    artifact_path = urlsplit(record['artifact_url']).path
    if not artifact_path.startswith('/downloads/ios/'):
        raise ValueError('iOS artifact must use the immutable downloads/ios path')
    destination = root / artifact_path.lstrip('/')
    if (not root.is_dir() or not destination.parent.resolve().is_relative_to(root.resolve())
            or backup.resolve().is_relative_to(root.resolve())):
        raise ValueError('release paths must keep private evidence outside the public root')
    _reject_symlinks(destination, root)
    expected_sha = record.get('ios_ipa_evidence', {}).get('sha256')
    if not isinstance(expected_sha, str) or not SHA256_PATTERN.fullmatch(expected_sha):
        raise ValueError('final IPA SHA256 is missing')
    if backup.exists():
        raise ValueError('backup directory already exists')

    with (root.parent / '.release-metadata.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        if source_ipa.stat().st_size != record['artifact_bytes'] or _sha256_file(source_ipa) != expected_sha:
            raise ValueError('final IPA SHA256 or byte count differs from release evidence')
        if _sha256_file(candidate_ipa) != record['ios_ci_candidate_sha256']:
            raise ValueError('CI candidate IPA SHA256 differs from release record')
        if inspector(source_ipa, record) != record['ios_ipa_evidence']:
            raise ValueError('final IPA signed identity differs from release evidence')
        comparison = comparator(candidate_ipa, source_ipa)
        _validate_exception(record, comparison)
        before = _validate_static_baseline(record, root)
        desired = release.render(record, before['download.html'], before['src/admin-home.js'])
        if set(desired) != set(STATIC_NAMES):
            raise ValueError('static renderer changed its output inventory')
        settings_before = db({'mode': 'inspect'})
        if not isinstance(settings_before, dict):
            raise ValueError('settings inspection returned no snapshot')
        expected_settings = record.get('expected_app_settings_before')
        if (not isinstance(expected_settings, dict)
                or set(expected_settings) != APP_SETTING_KEYS
                or settings_before != expected_settings):
            raise ValueError('app update settings drift or missing exact baseline')
        try:
            current_app_build = int(settings_before['app_ios_latest_build'])
        except (TypeError, ValueError) as exc:
            raise ValueError('app update settings latest build is invalid') from exc
        if current_app_build >= record['build']:
            raise ValueError('app update settings already expose this or a newer iOS build')
        if destination.exists() and (
                destination.stat().st_size != record['artifact_bytes']
                or _sha256_file(destination) != expected_sha):
            raise ValueError('immutable IPA path already contains different bytes')

        backup.mkdir(parents=True, mode=0o700)
        os.chmod(backup, 0o700)
        (backup / 'before.json').write_text(json.dumps({
            'settings': settings_before,
            'static_sha256': record['static_before_sha256'],
            'final_ipa_sha256': expected_sha,
        }, ensure_ascii=False, indent=2), encoding='utf-8')
        (backup / 'release.json').write_text(json.dumps(
            record, ensure_ascii=False, indent=2), encoding='utf-8')
        (backup / 'payload-comparison.json').write_text(json.dumps(
            comparison, ensure_ascii=False, indent=2), encoding='utf-8')
        for name, data in before.items():
            target = backup / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(data)

        written = []
        created_ipa = False
        try:
            created_ipa = _write_immutable_ipa(
                source_ipa, destination, expected_sha, record['artifact_bytes'])
            for name, data in desired.items():
                target = root / name
                if target.read_bytes() != before[name]:
                    raise ValueError(f'static drift: {name}')
                release.atomic_write(target, data)
                written.append(name)
            release.check(record, request)
            if destination.stat().st_size != record['artifact_bytes'] or _sha256_file(destination) != expected_sha:
                raise ValueError('public IPA path changed during publication')
            settings_after = db({'mode': 'inspect'})
            if settings_after != settings_before:
                raise ValueError('application update settings changed during static publication')
            result = {
                'artifact_url': record['artifact_url'],
                'artifact_sha256': expected_sha,
                'artifact_bytes': record['artifact_bytes'],
                'static_after_sha256': {name: _sha256_bytes((root / name).read_bytes())
                                        for name in STATIC_NAMES},
                'settings_before': settings_before,
                'settings_after': settings_after,
                'payload_exception': record['payload_exception'],
            }
            (backup / 'result.json').write_text(json.dumps(
                result, ensure_ascii=False, indent=2), encoding='utf-8')
        except Exception:
            for name in reversed(written):
                target = root / name
                if target.read_bytes() == desired[name]:
                    release.atomic_write(target, before[name])
            if (created_ipa and not destination.is_symlink() and destination.is_file()
                    and destination.stat().st_size == record['artifact_bytes']
                    and _sha256_file(destination) == expected_sha
                    and all((root / name).read_bytes() == before[name] for name in STATIC_NAMES)):
                destination.unlink()
            raise
        return result


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('record', type=Path)
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--ipa', type=Path, required=True)
    parser.add_argument('--ios-candidate', type=Path, required=True)
    parser.add_argument('--backup', type=Path, required=True)
    args = parser.parse_args(argv)
    validate_backup_location(args.backup)
    record = json.loads(args.record.read_text(encoding='utf-8'))
    result = publish(record, args.root, args.ipa, args.ios_candidate, args.backup)
    print('STATIC_IOS_LINKS_PUBLISH_PASS ' + json.dumps({
        'artifact_url': result['artifact_url'],
        'artifact_sha256': result['artifact_sha256'],
        'backup': str(args.backup),
        'app_settings_unchanged': result['settings_before'] == result['settings_after'],
    }, ensure_ascii=False))


if __name__ == '__main__':
    main()
