"""Exercise the candidate verifier with synthetic binary/app/ZIP boundaries."""

import hashlib
import json
import os
import plistlib
import stat
import struct
import subprocess
import sys
import zipfile
from pathlib import Path

import pytest


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts/prepare_ios_unsigned_ipa.py"
EXPORTS = ["sqlite3_key", "sqlite3_blob_open", "sqlite3_blob_read",
           "sqlite3_blob_write", "sqlite3_blob_close", "sqlite3_blob_bytes"]
ASSET = "assets/html/statistics_tools_combined_v2.html"


def macho(*, platform=2, cpu=0x100000C, filetype=2, libraries=(), exports=(),
          undefined=(), truncate=False):
    commands = [struct.pack("<6I", 0x32, 24, platform, 0x100000, 0x1A0300, 0)]
    for name in libraries:
        encoded = name.encode() + b"\0"
        size = (24 + len(encoded) + 7) // 8 * 8
        commands.append(struct.pack("<6I", 0xC, size, 24, 0, 0, 0)
                        + encoded.ljust(size - 24, b"\0"))
    strings = b"\0"
    symbols = b""
    for name in exports:
        symbols += struct.pack("<IBBHQ", len(strings), 1 if name in undefined else 0xF,
                               0 if name in undefined else 1, 0, 0 if name in undefined else 4096)
        strings += ("_" + name).encode() + b"\0"
    if exports:
        symoff = 32 + sum(map(len, commands)) + 24
        commands.append(struct.pack("<6I", 2, 24, symoff, len(exports),
                                    symoff + len(symbols), len(strings)))
    header = struct.pack("<IiiIIIII", 0xFEEDFACF, cpu, 0, filetype,
                         len(commands), sum(map(len, commands)), 0, 0)
    value = header + b"".join(commands) + symbols + strings
    return value[:40] if truncate else value


def write_zip(app, ipa, *, omit=None, replace=None, executable=True, duplicate=False):
    with zipfile.ZipFile(ipa, "w", zipfile.ZIP_DEFLATED) as archive:
        for path in sorted(app.rglob("*")):
            if path.is_dir() and not path.is_symlink():
                continue
            relative = path.relative_to(app).as_posix()
            if relative == omit:
                continue
            entry = zipfile.ZipInfo("Payload/Runner.app/" + relative)
            entry.create_system = 3
            mode = path.lstat().st_mode
            if path.name == "Runner":
                # Windows chmod cannot represent POSIX executable bits. The IPA
                # boundary still must carry them, like a real ditto device ZIP.
                mode = stat.S_IFREG | (0o755 if executable else 0o644)
            entry.external_attr = mode << 16
            payload = os.readlink(path).encode() if path.is_symlink() else path.read_bytes()
            if replace and relative == replace[0]:
                payload = replace[1]
            archive.writestr(entry, payload)
        if duplicate:
            with pytest.warns(UserWarning, match="Duplicate name"):
                archive.writestr("Payload/Runner.app/Info.plist", b"duplicate")


@pytest.fixture
def candidate(tmp_path):
    source = tmp_path / "source"
    app = tmp_path / "Runner.app"
    out = tmp_path / "delivery"
    out.mkdir()
    (source / "ios/Runner").mkdir(parents=True)
    (source / "pubspec.yaml").write_text("version: 0.4.36+2205\n  mobile_scanner: 6.0.11\n", encoding="utf-8")
    (source / "pubspec.lock").write_text("locked dependencies\n", encoding="utf-8")
    plugins = ["mobile_scanner", "sqlcipher_flutter_libs", "permission_handler_apple"]
    (source / ".flutter-plugins-dependencies").write_text(json.dumps({"plugins": {
        "ios": [{"name": name, "native_build": True, "dev_dependency": False}
                for name in plugins]}}), encoding="utf-8")
    (source / "ios/Podfile.lock").write_text("PODS:\n" + "".join(f"  - {name} (1.0)\n" for name in plugins), encoding="utf-8")
    (source / "ios/Runner/GeneratedPluginRegistrant.m").write_text("source registry", encoding="utf-8")
    (source / "ios/Runner/Runner.entitlements").write_bytes(plistlib.dumps({"aps-environment": "production"}))
    asset = source / ASSET
    asset.parent.mkdir(parents=True)
    asset.write_bytes(b"source statistics html exact bytes")
    app.mkdir()
    info = {"CFBundleIdentifier": "com.liuhetong.liuhetongMobile",
            "CFBundleShortVersionString": "0.4.36", "CFBundleVersion": "2205",
            "CFBundleExecutable": "Runner", "MinimumOSVersion": "16.0",
            "CFBundleSupportedPlatforms": ["iPhoneOS"], "UIDeviceFamily": [1, 2],
            "UIBackgroundModes": ["audio", "voip", "remote-notification"]}
    (app / "Info.plist").write_bytes(plistlib.dumps(info))
    (app / "Runner").write_bytes(macho(libraries=["@rpath/SQLCipher.framework/SQLCipher", "/usr/lib/libsqlite3.dylib"]))
    (app / "Runner").chmod(0o755)
    for name in ["App", "Flutter", "SQLCipher"]:
        folder = app / f"Frameworks/{name}.framework"
        folder.mkdir(parents=True)
        (folder / name).write_bytes(macho(filetype=6, exports=EXPORTS if name == "SQLCipher" else ()))
    packaged_asset = app / "Frameworks/App.framework/flutter_assets" / ASSET
    packaged_asset.parent.mkdir(parents=True)
    packaged_asset.write_bytes(asset.read_bytes())
    tools = tmp_path / "toolchain.txt"
    tools.write_text("Flutter 3.44.9\nXcode 26.3\n", encoding="utf-8")
    return source, app, out / "ChatFlow-0.4.36-build2205-unsigned.ipa", tools


def invoke(candidate, **overrides):
    source, app, ipa, tools = candidate
    arguments = {"app": str(app), "ipa": str(ipa), "source-root": str(source),
                 "output-dir": str(ipa.parent), "source-sha": "a" * 40,
                 "repository": "fixture/StarChat", "run-id": "123456",
                 "run-attempt": "1", "version": "0.4.36", "build": "2205",
                 "toolchain-report": str(tools)}
    arguments.update(overrides)
    command = [sys.executable, str(SCRIPT)]
    for key, value in arguments.items():
        command.extend(["--" + key, value])
    return subprocess.run(command, capture_output=True, text=True, encoding="utf-8")


def test_complete_device_payload_produces_bound_unsigned_handoff(candidate):
    source, app, ipa, _ = candidate
    write_zip(app, ipa)
    result = invoke(candidate)
    assert result.returncode == 0, result.stderr
    report = json.loads((ipa.parent / "build-manifest.json").read_text(encoding="utf-8"))
    assert report["ipa"]["sha256"] == hashlib.sha256(ipa.read_bytes()).hexdigest()
    assert report["ipa"]["bytes"] == ipa.stat().st_size
    assert report["source_commit"] == "a" * 40
    assert report["ci"] == {"repository": "fixture/StarChat", "run_id": 123456, "run_attempt": 1}
    assert report["signing"]["state"] == "unsigned-candidate-awaiting-enterprise-resigning"
    assert report["signing"]["source_entitlements_are_signed_rights"] is False
    assert report["app"]["runner"]["platform"] == "iOS-device"
    assert set(report["app"]["sqlcipher_exports"]) == set(EXPORTS)
    assert report["statistics_asset_sha256"] == hashlib.sha256((source / ASSET).read_bytes()).hexdigest()
    assert (ipa.parent / "Runner.entitlements").read_bytes() == (source / "ios/Runner/Runner.entitlements").read_bytes()


@pytest.mark.parametrize("field,value,error", [
    ("CFBundleIdentifier", "other.app", "Bundle ID"),
    ("CFBundleVersion", "2204", "build"),
    ("CFBundleShortVersionString", "0.4.35", "version"),
    ("MinimumOSVersion", "15.0", "16.0"),
    ("CFBundleSupportedPlatforms", ["iPhoneSimulator"], "iPhoneOS"),
    ("UIBackgroundModes", ["audio"], "background"),
])
def test_rejects_wrong_or_incomplete_candidate_identity(candidate, field, value, error):
    _, app, ipa, _ = candidate
    info = plistlib.loads((app / "Info.plist").read_bytes())
    info[field] = value
    (app / "Info.plist").write_bytes(plistlib.dumps(info))
    write_zip(app, ipa)
    result = invoke(candidate)
    assert result.returncode != 0
    assert error.lower() in result.stderr.lower()
    assert not (ipa.parent / "build-manifest.json").exists()


@pytest.mark.parametrize("mutation,error", [
    ({"platform": 7}, "device"), ({"cpu": 0x1000007}, "arm64"),
    ({"truncate": True}, "truncated"),
    ({"libraries": ["/usr/lib/libsqlite3.dylib", "@rpath/SQLCipher.framework/SQLCipher"]}, "shadows"),
    ({"libraries": []}, "load SQLCipher"),
])
def test_rejects_simulator_or_incorrect_native_loader(candidate, mutation, error):
    _, app, ipa, _ = candidate
    (app / "Runner").write_bytes(macho(**mutation))
    write_zip(app, ipa)
    result = invoke(candidate)
    assert result.returncode != 0
    assert error.lower() in result.stderr.lower()


@pytest.mark.parametrize("symbol", EXPORTS)
def test_sqlcipher_requires_each_actual_defined_export(candidate, symbol):
    _, app, ipa, _ = candidate
    (app / "Frameworks/SQLCipher.framework/SQLCipher").write_bytes(
        macho(filetype=6, exports=EXPORTS, undefined=[symbol]))
    write_zip(app, ipa)
    result = invoke(candidate)
    assert result.returncode != 0
    assert symbol in result.stderr


@pytest.mark.parametrize("problem,error", [
    ("asset", "statistics"), ("plugin", "production plugin"),
    ("pod", "CocoaPods"), ("entitlement", "production APNs"),
    ("framework", "framework"),
])
def test_rejects_missing_source_or_native_production_inputs(candidate, problem, error):
    source, app, ipa, _ = candidate
    if problem == "asset":
        (app / "Frameworks/App.framework/flutter_assets" / ASSET).write_bytes(b"stale")
    elif problem == "plugin":
        (source / ".flutter-plugins-dependencies").write_text('{"plugins":{"ios":[]}}', encoding="utf-8")
    elif problem == "pod":
        (source / "ios/Podfile.lock").write_text("PODS:\n", encoding="utf-8")
    elif problem == "entitlement":
        (source / "ios/Runner/Runner.entitlements").write_bytes(plistlib.dumps({"aps-environment": "development"}))
    else:
        (app / "Frameworks/Flutter.framework/Flutter").unlink()
    write_zip(app, ipa)
    result = invoke(candidate)
    assert result.returncode != 0
    assert error.lower() in result.stderr.lower()


@pytest.mark.parametrize("zip_options,error", [
    ({"omit": "Runner"}, "complete Payload"),
    ({"replace": ("Info.plist", b"different")}, "Payload bytes"),
    ({"executable": False}, "executable mode"),
    ({"duplicate": True}, "duplicate"),
])
def test_zip_must_preserve_complete_app_bytes_and_executable_mode(candidate, zip_options, error):
    _, app, ipa, _ = candidate
    write_zip(app, ipa, **zip_options)
    result = invoke(candidate)
    assert result.returncode != 0
    assert error.lower() in result.stderr.lower()


@pytest.mark.parametrize("arguments,error", [
    ({"source-sha": "old-source"}, "source SHA"),
    ({"run-attempt": "0"}, "run attempt"),
    ({"run-id": "0"}, "run ID"),
])
def test_manifest_refuses_unbound_ci_identity(candidate, arguments, error):
    _, app, ipa, _ = candidate
    write_zip(app, ipa)
    result = invoke(candidate, **arguments)
    assert result.returncode != 0
    assert error.lower() in result.stderr.lower()


def test_preserves_framework_symlink_and_rejects_changed_link_target(candidate):
    _, app, ipa, _ = candidate
    link = app / "Frameworks/App.framework/asset-link"
    link.symlink_to("flutter_assets")
    write_zip(app, ipa)
    accepted = invoke(candidate)
    assert accepted.returncode == 0, accepted.stderr
    write_zip(app, ipa, replace=("Frameworks/App.framework/asset-link", b"other-target"))
    rejected = invoke(candidate)
    assert rejected.returncode != 0
    assert "symlink target changed" in rejected.stderr


def test_rejects_corrupt_zip_crc_before_emitting_manifest(candidate):
    _, app, ipa, _ = candidate
    write_zip(app, ipa)
    value = bytearray(ipa.read_bytes())
    with zipfile.ZipFile(ipa) as archive:
        entry = archive.getinfo("Payload/Runner.app/Runner")
        _, _, _, _, _, _, _, _, _, name_length, extra_length = struct.unpack_from("<IHHHHHIIIHH", value, entry.header_offset)
        offset = entry.header_offset + 30 + name_length + extra_length
        value[offset] ^= 1
    ipa.write_bytes(value)
    result = invoke(candidate)
    assert result.returncode != 0
    assert "CRC" in result.stderr
    assert not (ipa.parent / "build-manifest.json").exists()
