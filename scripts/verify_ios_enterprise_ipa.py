"""Check the *final, externally signed* enterprise IPA before release.

This catches identity and entitlement handoff mistakes. Parsing the embedded
profile and CodeSignature does not replace codesign verification or an iPhone
installation test. No certificate or private key is read from the repository.
"""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
from io import BytesIO
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import struct
import subprocess
import sys
import zipfile
from xml.parsers.expat import ExpatError


_MACHO_64_LITTLE = b"\xcf\xfa\xed\xfe"
_LC_CODE_SIGNATURE = 0x1D
_SUPERBLOB_MAGIC = 0xFADE0CC0
_XML_ENTITLEMENTS_MAGIC = 0xFADE7171
_XML_ENTITLEMENTS_SLOT = 5
_MAX_INFO_BYTES = 1024 * 1024
_MAX_PROFILE_BYTES = 4 * 1024 * 1024
_MAX_EXECUTABLE_BYTES = 256 * 1024 * 1024
_MAX_IPA_BYTES = 512 * 1024 * 1024
# The archived, device-used 0.3.102/2144 enterprise app has this anomalous
# signed App ID. Recognizing it only identifies the package; a no-uninstall
# iPhone cover test is still required to establish upgrade/data compatibility.
_LEGACY_BUNDLE_ID = "com.liuhetong.liuhetongMobile"
_LEGACY_TEAM_ID = "ZXB3TS7QD4"
_LEGACY_APPLICATION_IDENTIFIER = "ZXB3TS7QD4.cn.edu.buaa.wxwork.notifyext"


def _zip_entry(archive: zipfile.ZipFile, name: str, limit: int) -> bytes:
    try:
        entry = archive.getinfo(name)
    except KeyError as exc:
        raise ValueError(f"IPA is missing {name}") from exc
    if entry.file_size > limit:
        raise ValueError(f"IPA entry exceeds size limit: {name}")
    with archive.open(entry) as source:
        data = source.read(limit + 1)
    if len(data) > limit:
        raise ValueError(f"IPA entry exceeds size limit: {name}")
    return data


def _runner_root(archive: zipfile.ZipFile) -> str:
    roots = {
        name.removesuffix("/Info.plist")
        for name in archive.namelist()
        if re.fullmatch(r"Payload/[^/]+\.app/Info\.plist", name)
    }
    if len(roots) != 1:
        raise ValueError("IPA must contain exactly one top-level iOS app")
    return roots.pop()


def _openssl_binary() -> str:
    configured = os.environ.get("OPENSSL_BIN")
    if configured:
        return configured
    found = shutil.which("openssl")
    if found:
        return found
    if os.name == "nt":
        git_openssl = Path(r"C:\Program Files\Git\usr\bin\openssl.exe")
        if git_openssl.is_file():
            return str(git_openssl)
    raise ValueError("OpenSSL is required to verify the embedded provisioning profile")


def _decode_profile(profile_bytes: bytes) -> dict:
    result = subprocess.run(
        [_openssl_binary(), "cms", "-verify", "-noverify", "-inform", "DER", "-binary"],
        input=profile_bytes,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if result.returncode != 0:
        raise ValueError("embedded provisioning profile CMS verification failed")
    try:
        profile = plistlib.loads(result.stdout)
    except (ValueError, TypeError, plistlib.InvalidFileException, ExpatError) as exc:
        raise ValueError("embedded provisioning profile is not a plist") from exc
    if not isinstance(profile, dict):
        raise ValueError("embedded provisioning profile is not a dictionary")
    return profile


def _signed_entitlements(executable: bytes) -> dict:
    """Read the XML entitlement slot from a thin little-endian arm64 Mach-O."""
    if len(executable) < 32 or executable[:4] != _MACHO_64_LITTLE:
        raise ValueError("unsupported Runner Mach-O format")
    cpu_type = struct.unpack_from("<I", executable, 4)[0]
    if cpu_type != 0x0100000C:
        raise ValueError("Runner Mach-O must contain arm64")
    ncmds, sizeofcmds = struct.unpack_from("<II", executable, 16)
    commands_end = 32 + sizeofcmds
    if ncmds > 4096 or commands_end > len(executable):
        raise ValueError("invalid Runner Mach-O load commands")
    command_offset = 32
    signature_range = None
    for _ in range(ncmds):
        if command_offset + 8 > commands_end:
            raise ValueError("truncated Runner Mach-O load command")
        command, command_size = struct.unpack_from("<II", executable, command_offset)
        if command_size < 8 or command_offset + command_size > commands_end:
            raise ValueError("invalid Runner Mach-O load command size")
        if command == _LC_CODE_SIGNATURE:
            if command_size < 16 or signature_range is not None:
                raise ValueError("invalid Runner CodeSignature command")
            signature_range = struct.unpack_from("<II", executable, command_offset + 8)
        command_offset += command_size
    if signature_range is None:
        raise ValueError("Runner CodeSignature is missing")
    data_offset, data_size = signature_range
    if data_size < 20 or data_offset + data_size > len(executable):
        raise ValueError("Runner CodeSignature is truncated")
    signature = executable[data_offset:data_offset + data_size]
    magic, blob_length, count = struct.unpack_from(">III", signature)
    if (magic != _SUPERBLOB_MAGIC or blob_length > len(signature)
            or blob_length < 12 + 8 * count or count > 4096):
        raise ValueError("invalid Runner CodeSignature SuperBlob")
    entitlement_payload = None
    for index in range(count):
        slot, offset = struct.unpack_from(">II", signature, 12 + 8 * index)
        if offset + 8 > blob_length:
            raise ValueError("truncated Runner CodeSignature blob")
        item_magic, item_length = struct.unpack_from(">II", signature, offset)
        if item_length < 8 or offset + item_length > blob_length:
            raise ValueError("invalid Runner CodeSignature blob size")
        if slot == _XML_ENTITLEMENTS_SLOT:
            if item_magic != _XML_ENTITLEMENTS_MAGIC or entitlement_payload is not None:
                raise ValueError("invalid Runner XML entitlements")
            entitlement_payload = signature[offset + 8:offset + item_length]
    if entitlement_payload is None:
        raise ValueError("Runner XML entitlements are missing (DER-only unsupported)")
    try:
        entitlements = plistlib.loads(entitlement_payload)
    except (ValueError, TypeError, plistlib.InvalidFileException, ExpatError) as exc:
        raise ValueError("Runner signed entitlements are not a plist") from exc
    if not isinstance(entitlements, dict):
        raise ValueError("Runner signed entitlements are not a dictionary")
    return entitlements


def _keychain_groups(entitlements: dict, label: str, team_id: str) -> list[str]:
    groups = entitlements.get("keychain-access-groups")
    if (not isinstance(groups, list) or not groups
            or any(not isinstance(group, str) or not group for group in groups)
            or len(groups) != len(set(groups))):
        raise ValueError(f"{label} Keychain access groups are missing or invalid")
    if not any(group.startswith(team_id + ".") for group in groups):
        raise ValueError(f"{label} has no Team-prefixed Keychain access group")
    return groups


def _profile_allows_group(group: str, allowed: str) -> bool:
    return group == allowed or (
        allowed.endswith("*") and allowed.count("*") == 1
        and group.startswith(allowed[:-1])
    )


def inspect_ipa(
    path: str | Path,
    *,
    expected_bundle_id: str,
    expected_version: str,
    expected_build: str | int,
    expected_team_id: str,
    require_apns: bool = True,
    expected_legacy_application_identifier: str | None = None,
    decode_profile=None,
) -> dict:
    """Return release evidence only when the final IPA's identities agree."""
    path = Path(path)
    decode_profile = decode_profile or _decode_profile
    # Parse and hash the same bytes. A path reopened after parsing could refer
    # to a different IPA when a handoff process replaces the file in place.
    with path.open("rb") as source:
        ipa_bytes = source.read(_MAX_IPA_BYTES + 1)
    if len(ipa_bytes) > _MAX_IPA_BYTES:
        raise ValueError("IPA exceeds inspection size limit")
    with zipfile.ZipFile(BytesIO(ipa_bytes)) as archive:
        root = _runner_root(archive)
        try:
            info = plistlib.loads(_zip_entry(archive, root + "/Info.plist", _MAX_INFO_BYTES))
        except (ValueError, TypeError, plistlib.InvalidFileException, ExpatError) as exc:
            raise ValueError("Runner Info.plist is invalid") from exc
        if not isinstance(info, dict):
            raise ValueError("Runner Info.plist is not a dictionary")
        executable_name = info.get("CFBundleExecutable")
        if not isinstance(executable_name, str) or not re.fullmatch(r"[A-Za-z0-9_.-]+", executable_name):
            raise ValueError("invalid Runner executable name")
        profile_bytes = _zip_entry(archive, root + "/embedded.mobileprovision", _MAX_PROFILE_BYTES)
        try:
            profile = decode_profile(profile_bytes)
        except (ValueError, TypeError, plistlib.InvalidFileException, ExpatError) as exc:
            raise ValueError("embedded provisioning profile is not a plist") from exc
        signed = _signed_entitlements(
            _zip_entry(archive, root + "/" + executable_name, _MAX_EXECUTABLE_BYTES)
        )

    bundle_id = info.get("CFBundleIdentifier")
    version = info.get("CFBundleShortVersionString")
    build = info.get("CFBundleVersion")
    if (bundle_id != expected_bundle_id or version != expected_version
            or str(build) != str(expected_build)):
        raise ValueError("IPA bundle identity, version, or build does not match release")
    if not isinstance(profile, dict):
        raise ValueError("embedded provisioning profile is not a dictionary")
    if (profile.get("TeamIdentifier") != [expected_team_id]
            or profile.get("ApplicationIdentifierPrefix") != [expected_team_id]):
        raise ValueError("enterprise provisioning profile team identity does not match")
    if profile.get("ProvisionsAllDevices") is not True:
        raise ValueError("provisioning profile is not enterprise distribution")
    expiration = profile.get("ExpirationDate")
    if not isinstance(expiration, datetime):
        raise ValueError("provisioning profile expiration is missing")
    if expiration.tzinfo is None:
        expiration = expiration.replace(tzinfo=timezone.utc)
    if expiration <= datetime.now(timezone.utc):
        raise ValueError("provisioning profile has expired")
    profile_entitlements = profile.get("Entitlements")
    if not isinstance(profile_entitlements, dict):
        raise ValueError("provisioning profile entitlements are missing")
    expected_app_id = expected_team_id + "." + expected_bundle_id
    if expected_legacy_application_identifier is not None:
        if (expected_bundle_id != _LEGACY_BUNDLE_ID
                or expected_team_id != _LEGACY_TEAM_ID
                or expected_legacy_application_identifier != _LEGACY_APPLICATION_IDENTIFIER):
            raise ValueError("unsupported legacy application-identifier override")
        expected_app_id = _LEGACY_APPLICATION_IDENTIFIER
    profile_app_id = profile_entitlements.get("application-identifier")
    signed_app_id = signed.get("application-identifier")
    if profile_app_id != expected_app_id or signed_app_id != expected_app_id:
        raise ValueError("profile or signed application-identifier does not match bundle identity")
    if signed.get("com.apple.developer.team-identifier") != expected_team_id:
        raise ValueError("signed Team ID does not match enterprise profile")
    profile_debug = profile_entitlements.get("get-task-allow")
    signed_debug = signed.get("get-task-allow")
    if profile_debug is not False or signed_debug is not False:
        raise ValueError("enterprise IPA must disable get-task-allow")
    profile_apns = profile_entitlements.get("aps-environment")
    signed_apns = signed.get("aps-environment")
    if profile_apns != signed_apns or signed_apns not in (None, "production"):
        raise ValueError("profile and signed APNs entitlements differ or are not production")
    if require_apns and signed_apns != "production":
        raise ValueError("production APNs entitlement is required")
    profile_groups = _keychain_groups(profile_entitlements, "profile", expected_team_id)
    signed_groups = _keychain_groups(signed, "signed IPA", expected_team_id)
    if any(
        not any(_profile_allows_group(group, allowed) for allowed in profile_groups)
        for group in signed_groups
    ):
        raise ValueError("Runner signed Keychain group is not allowed by enterprise profile")

    return {
        "sha256": hashlib.sha256(ipa_bytes).hexdigest(),
        "artifact_bytes": len(ipa_bytes),
        "bundle_id": bundle_id,
        "version": version,
        "build": int(build),
        "team_id": expected_team_id,
        "profile_application_identifier": profile_app_id,
        "signed_application_identifier": signed_app_id,
        "aps_environment": signed_apns,
        "get_task_allow": False,
        "provisions_all_devices": True,
        "profile_keychain_access_groups": profile_groups,
        "signed_keychain_access_groups": signed_groups,
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("ipa", type=Path)
    parser.add_argument("--bundle-id", required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--build", required=True)
    parser.add_argument("--team-id", required=True)
    parser.add_argument("--allow-no-apns", action="store_true")
    parser.add_argument(
        "--expected-legacy-application-identifier",
        help="opt in only to the exact signed App ID of the archived 2144 enterprise app; "
             "device cover-install evidence is still required",
    )
    parser.add_argument("--output", type=Path, help="write passing evidence to a new JSON file")
    args = parser.parse_args(argv)
    try:
        evidence = inspect_ipa(
            args.ipa,
            expected_bundle_id=args.bundle_id,
            expected_version=args.version,
            expected_build=args.build,
            expected_team_id=args.team_id,
            require_apns=not args.allow_no_apns,
            expected_legacy_application_identifier=args.expected_legacy_application_identifier,
        )
        encoded = json.dumps(evidence, ensure_ascii=False, indent=2) + "\n"
        if args.output:
            with args.output.open("x", encoding="utf-8") as target:
                target.write(encoded)
        else:
            print(encoded, end="")
    except (OSError, ValueError, zipfile.BadZipFile) as exc:
        print(f"IPA_VALIDATION_FAILED: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
