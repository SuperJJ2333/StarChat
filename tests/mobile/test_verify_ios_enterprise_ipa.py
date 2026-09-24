"""Regression tests for the final, externally re-signed enterprise IPA."""

import datetime
import hashlib
import importlib.util
import plistlib
import struct
import zipfile
from pathlib import Path

import pytest


BUNDLE_ID = 'com.liuhetong.liuhetongMobile'
TEAM_ID = 'ZXB3TS7QD4'
VERSION = '0.4.7'
BUILD = '2172'
APP_ID = f'{TEAM_ID}.{BUNDLE_ID}'
KEYCHAIN_GROUPS = [f'{TEAM_ID}.*', 'com.apple.token']
OTHER_TEAM_ID = 'ABCD123456'


def _macho_with_entitlements(entitlements, *, truncate_signature=False):
    """A thin arm64 Mach-O with LC_CODE_SIGNATURE and XML slot 5."""
    xml = plistlib.dumps(entitlements)
    entitlement_blob = struct.pack('>II', 0xFADE7171, 8 + len(xml)) + xml
    signature = (
        struct.pack('>III', 0xFADE0CC0, 20 + len(entitlement_blob), 1)
        + struct.pack('>II', 5, 20)
        + entitlement_blob
    )
    if truncate_signature:
        signature = signature[:20]
    header = struct.pack('<IiiIIIII', 0xFEEDFACF, 0x0100000C, 0, 2, 1, 16, 0, 0)
    load_command = struct.pack('<IIII', 0x1D, 16, len(header) + 16, len(signature))
    return header + load_command + signature


def _ipa(
    tmp_path,
    *,
    team_id=TEAM_ID,
    signed_app_id=None,
    profile_app_id=None,
    signed_apns='production',
    profile_apns='production',
    signed_debug=False,
    profile_debug=False,
    profile_team=None,
    signed_keychain_groups=None,
    profile_keychain_groups=None,
    truncate_signature=False,
    include_signed_team=True,
):
    profile_team = team_id if profile_team is None else profile_team
    signed_app_id = f'{team_id}.{BUNDLE_ID}' if signed_app_id is None else signed_app_id
    profile_app_id = f'{team_id}.{BUNDLE_ID}' if profile_app_id is None else profile_app_id
    default_groups = [f'{team_id}.*', 'com.apple.token']
    info = {
        'CFBundleIdentifier': BUNDLE_ID,
        'CFBundleShortVersionString': VERSION,
        'CFBundleVersion': BUILD,
        'CFBundleExecutable': 'Runner',
        'CFBundlePackageType': 'APPL',
        'MinimumOSVersion': '16.0',
        'UIDeviceFamily': [1, 2],
        'UIBackgroundModes': ['audio', 'voip', 'remote-notification'],
    }
    signed_entitlements = {
        'application-identifier': signed_app_id,
        'get-task-allow': signed_debug,
        'keychain-access-groups': (
            default_groups if signed_keychain_groups is None else signed_keychain_groups
        ),
    }
    if include_signed_team:
        signed_entitlements['com.apple.developer.team-identifier'] = team_id
    profile_entitlements = {
        'application-identifier': profile_app_id,
        'get-task-allow': profile_debug,
        'keychain-access-groups': (
            default_groups if profile_keychain_groups is None else profile_keychain_groups
        ),
    }
    if signed_apns is not None:
        signed_entitlements['aps-environment'] = signed_apns
    if profile_apns is not None:
        profile_entitlements['aps-environment'] = profile_apns
    profile = {
        'Name': 'ChatFlow Enterprise',
        'TeamIdentifier': [profile_team],
        'ApplicationIdentifierPrefix': [profile_team],
        'ProvisionsAllDevices': True,
        'Entitlements': profile_entitlements,
        'ExpirationDate': datetime.datetime(2030, 1, 1),
    }
    target = tmp_path / 'ChatFlow-0.4.7-build2172.ipa'
    with zipfile.ZipFile(target, 'w', compression=zipfile.ZIP_DEFLATED) as archive:
        archive.writestr('Payload/Runner.app/Info.plist', plistlib.dumps(info))
        archive.writestr('Payload/Runner.app/embedded.mobileprovision', plistlib.dumps(profile))
        archive.writestr(
            'Payload/Runner.app/Runner',
            _macho_with_entitlements(
                signed_entitlements, truncate_signature=truncate_signature
            ),
        )
    return target


def _inspect(path, *, expected_team_id=TEAM_ID, require_apns=True):
    script = Path(__file__).parents[2] / 'scripts/verify_ios_enterprise_ipa.py'
    spec = importlib.util.spec_from_file_location('verify_ios_enterprise_ipa', script)
    verifier = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(verifier)
    return verifier.inspect_ipa(
        path,
        expected_bundle_id=BUNDLE_ID,
        expected_version=VERSION,
        expected_build=BUILD,
        expected_team_id=expected_team_id,
        require_apns=require_apns,
        decode_profile=plistlib.loads,
    )


def _replace_ipa_entry(path, entry_name, replacement):
    with zipfile.ZipFile(path) as archive:
        contents = [(item.filename, archive.read(item)) for item in archive.infolist()]
    with zipfile.ZipFile(path, 'w', compression=zipfile.ZIP_DEFLATED) as archive:
        for name, payload in contents:
            archive.writestr(name, replacement if name.endswith(entry_name) else payload)


def test_valid_enterprise_ipa_reports_actual_signed_identity_and_sha(tmp_path):
    path = _ipa(tmp_path)

    evidence = _inspect(path)

    assert evidence['sha256'] == hashlib.sha256(path.read_bytes()).hexdigest()
    assert evidence['bundle_id'] == BUNDLE_ID
    assert evidence['version'] == VERSION
    assert str(evidence['build']) == BUILD
    assert evidence['team_id'] == TEAM_ID
    assert evidence['profile_application_identifier'] == APP_ID
    assert evidence['signed_application_identifier'] == APP_ID
    assert evidence['aps_environment'] == 'production'
    assert evidence['get_task_allow'] is False
    assert evidence['provisions_all_devices'] is True
    assert evidence['profile_keychain_access_groups'] == KEYCHAIN_GROUPS
    assert evidence['signed_keychain_access_groups'] == KEYCHAIN_GROUPS


def test_accepts_a_different_consistent_enterprise_team(tmp_path):
    path = _ipa(tmp_path, team_id=OTHER_TEAM_ID)

    evidence = _inspect(path, expected_team_id=OTHER_TEAM_ID)

    assert evidence['team_id'] == OTHER_TEAM_ID
    assert evidence['profile_application_identifier'] == f'{OTHER_TEAM_ID}.{BUNDLE_ID}'
    assert evidence['signed_application_identifier'] == f'{OTHER_TEAM_ID}.{BUNDLE_ID}'
    assert evidence['profile_keychain_access_groups'] == [f'{OTHER_TEAM_ID}.*', 'com.apple.token']
    assert evidence['signed_keychain_access_groups'] == [f'{OTHER_TEAM_ID}.*', 'com.apple.token']


def test_rejects_signed_keychain_group_not_allowed_by_profile(tmp_path):
    path = _ipa(tmp_path, profile_keychain_groups=[f'{TEAM_ID}.*'])

    with pytest.raises(ValueError):
        _inspect(path)


def test_rejects_missing_team_prefixed_keychain_group(tmp_path):
    path = _ipa(
        tmp_path,
        profile_keychain_groups=['com.apple.token'],
        signed_keychain_groups=['com.apple.token'],
    )

    with pytest.raises(ValueError):
        _inspect(path)


@pytest.mark.parametrize('field', ['signed_app_id', 'profile_app_id'])
def test_rejects_app_id_for_another_app(tmp_path, field):
    path = _ipa(tmp_path, **{field: f'{TEAM_ID}.cn.edu.buaa.bhpan.fileProvider'})

    with pytest.raises(ValueError):
        _inspect(path)


def test_rejects_profile_from_another_team(tmp_path):
    path = _ipa(tmp_path, profile_team='DIFFERENT1')

    with pytest.raises(ValueError):
        _inspect(path)


def test_rejects_missing_signed_team_identifier(tmp_path):
    path = _ipa(tmp_path, include_signed_team=False)

    with pytest.raises(ValueError, match='Team ID'):
        _inspect(path)


def test_evidence_uses_parsed_ipa_bytes_not_a_later_path_read(tmp_path):
    path = _ipa(tmp_path)
    original = path.read_bytes()
    script = Path(__file__).parents[2] / 'scripts/verify_ios_enterprise_ipa.py'
    spec = importlib.util.spec_from_file_location('verify_ios_enterprise_ipa_snapshot', script)
    verifier = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(verifier)

    original_parser = verifier._signed_entitlements
    replaced = []

    def replace_after_entitlements_are_parsed(executable):
        result = original_parser(executable)
        path.write_bytes(b'another-uninspected-ipa')
        replaced.append(True)
        return result

    verifier._signed_entitlements = replace_after_entitlements_are_parsed
    evidence = verifier.inspect_ipa(
        path,
        expected_bundle_id=BUNDLE_ID,
        expected_version=VERSION,
        expected_build=BUILD,
        expected_team_id=TEAM_ID,
        decode_profile=plistlib.loads,
    )

    assert replaced == [True]
    assert evidence['sha256'] == hashlib.sha256(original).hexdigest()
    assert evidence['artifact_bytes'] == len(original)


def test_missing_apns_is_rejected_by_default(tmp_path):
    path = _ipa(tmp_path, signed_apns=None, profile_apns=None)

    with pytest.raises(ValueError):
        _inspect(path)


def test_missing_apns_can_be_explicitly_allowed_for_foreground_only(tmp_path):
    path = _ipa(tmp_path, signed_apns=None, profile_apns=None)

    evidence = _inspect(path, require_apns=False)

    assert evidence['aps_environment'] is None


@pytest.mark.parametrize('field', ['signed_debug', 'profile_debug'])
def test_rejects_debug_entitlement_in_enterprise_ipa(tmp_path, field):
    path = _ipa(tmp_path, **{field: True})

    with pytest.raises(ValueError):
        _inspect(path)


def test_rejects_truncated_codesign_entitlements_blob(tmp_path):
    path = _ipa(tmp_path, truncate_signature=True)

    with pytest.raises(ValueError):
        _inspect(path)


@pytest.mark.parametrize('entry_name', [
    '/Info.plist', '/embedded.mobileprovision', '/Runner',
])
def test_malformed_xml_plist_returns_named_validation_error(tmp_path, entry_name):
    path = _ipa(tmp_path)
    if entry_name == '/Runner':
        with zipfile.ZipFile(path) as archive:
            executable = archive.read('Payload/Runner.app/Runner')
        assert b'</plist>' in executable
        replacement = executable.replace(b'</plist>', b'x/plist>', 1)
    else:
        replacement = b'<plist><dict>'
    _replace_ipa_entry(path, entry_name, replacement)

    with pytest.raises(ValueError, match='plist|entitlements'):
        _inspect(path)
