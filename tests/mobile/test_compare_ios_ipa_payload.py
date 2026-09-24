"""A re-sign may change signatures, but must not change the app payload."""

import hashlib
import importlib.util
import plistlib
import struct
import zipfile
from pathlib import Path

import pytest


SCRIPT = Path(__file__).resolve().parents[2] / "scripts" / "compare_ios_ipa_payload.py"


def _comparator():
    spec = importlib.util.spec_from_file_location("compare_ios_ipa_payload", SCRIPT)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _macho(*, signature=b"signature", payload=b"AOT-CODE", dylib=None, rpath=None, cpu=0x0100000C):
    """A thin Mach-O with realistic linkedit bookkeeping and fixed code offset."""
    segment = bytearray(struct.pack("<II16sQQQQiiII", 0x19, 72, b"__LINKEDIT", 256, 0, 256, 0, 1, 1, 0, 0))
    commands = [segment]
    if dylib is not None:
        name = dylib.encode() + b"\0"
        size = (24 + len(name) + 7) & ~7
        commands.append(bytearray(struct.pack("<IIIIII", 0xC, size, 24, 0, 0, 0) + name.ljust(size - 24, b"\0")))
    if rpath is not None:
        name = rpath.encode() + b"\0"
        size = (12 + len(name) + 7) & ~7
        commands.append(bytearray(struct.pack("<III", 0x8000001C, size, 12) + name.ljust(size - 12, b"\0")))
    signature_offset = 256 + len(payload)
    if signature is not None:
        commands.append(bytearray(struct.pack("<IIII", 0x1D, 16, signature_offset, len(signature))))
    segment[32:40] = struct.pack("<Q", (len(payload) + (len(signature) if signature else 0) + 4095) & ~4095)
    segment[48:56] = struct.pack("<Q", len(payload) + (len(signature) if signature else 0))
    command_blob = b"".join(commands)
    assert 32 + len(command_blob) <= 256
    header = struct.pack("<IiiIIIII", 0xFEEDFACF, cpu, 0, 2, len(commands), len(command_blob), 0, 0)
    return header + command_blob + bytes(256 - 32 - len(command_blob)) + payload + (signature or b"")


def _fat(arm64: bytes, x86: bytes | None = None) -> bytes:
    slices = [(0x0100000C, arm64)]
    if x86 is not None:
        slices.append((0x01000007, x86))
    table_end = 8 + 20 * len(slices)
    offset = (table_end + 7) & ~7
    table = bytearray()
    body = bytearray(b"\0" * (offset - table_end))
    for cpu, data in slices:
        table += struct.pack(">IIIII", cpu, 0, offset, len(data), 3)
        body += data
        offset += len(data)
        padding = (-offset) & 7
        body += b"\0" * padding
        offset += padding
    return struct.pack(">II", 0xCAFEBABE, len(slices)) + table + body


def _files(*, runner=None, aot=None, info=None, extra=None, signature=b"sig-one"):
    root = "Payload/Runner.app/"
    info = info or {"CFBundleIdentifier": "com.liuhetong.liuhetongMobile", "CFBundleExecutable": "Runner", "CFBundleVersion": "2173"}
    files = {
        root + "Info.plist": plistlib.dumps(info, fmt=plistlib.FMT_BINARY),
        root + "Runner": runner if runner is not None else _macho(signature=signature),
        root + "Frameworks/App.framework/Info.plist": plistlib.dumps({"CFBundleExecutable": "App"}),
        root + "Frameworks/App.framework/App": aot if aot is not None else _macho(signature=signature, payload=b"FLUTTER-AOT"),
        root + "Frameworks/Flutter.framework/Info.plist": plistlib.dumps({"CFBundleExecutable": "Flutter"}),
        root + "Frameworks/Flutter.framework/Flutter": _macho(signature=signature, payload=b"FLUTTER-ENGINE"),
        root + "Frameworks/SQLCipher.framework/Info.plist": plistlib.dumps({"CFBundleExecutable": "SQLCipher"}),
        root + "Frameworks/SQLCipher.framework/SQLCipher": _macho(signature=signature, payload=b"SQLCIPHER"),
        root + "Assets.car": b"ASSETS",
        root + "Frameworks/App.framework/flutter_assets/AssetManifest.bin": b"asset-manifest",
        root + "Frameworks/App.framework/flutter_assets/assets/image.png": b"\x89PNG-SAME",
        root + "embedded.mobileprovision": b"profile-one",
        root + "_CodeSignature/CodeResources": b"codesign-one",
    }
    files.update(extra or {})
    return files


def _ipa(tmp_path, name, files):
    path = tmp_path / name
    with zipfile.ZipFile(path, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        for file_name, contents in files.items():
            archive.writestr(file_name, contents)
    return path


def _compare(tmp_path, candidate_files, final_files):
    candidate = _ipa(tmp_path, "candidate.ipa", candidate_files)
    final = _ipa(tmp_path, "signed.ipa", final_files)
    return _comparator().compare_ipa_payload(candidate, final), candidate, final


def test_signature_and_provisioning_changes_only_pass(tmp_path):
    candidate_files = _files(signature=b"short-signature")
    final_files = _files(signature=b"longer-enterprise-signature")
    root = "Payload/Runner.app/"
    final_files[root + "embedded.mobileprovision"] = b"enterprise-profile"
    final_files[root + "_CodeSignature/CodeResources"] = b"enterprise-coderesources"
    final_files[root + "Info.plist"] = plistlib.dumps(plistlib.loads(candidate_files[root + "Info.plist"]), fmt=plistlib.FMT_XML)
    result, candidate, final = _compare(tmp_path, candidate_files, final_files)
    assert result["status"] == "pass"
    assert result["differences"] == []
    assert result["candidate_sha256"] == hashlib.sha256(candidate.read_bytes()).hexdigest()
    assert result["final_sha256"] == hashlib.sha256(final.read_bytes()).hexdigest()
    assert result["payload_path_count"] >= 10


def test_injected_dylib_is_rejected_even_with_only_signature_changes_elsewhere(tmp_path):
    original = _files()
    modified = _files(extra={"Payload/Runner.app/Frameworks/SignerHook.dylib": _macho()})
    result, _, _ = _compare(tmp_path, original, modified)
    assert result["status"] == "fail"
    assert any("SignerHook.dylib" in difference for difference in result["differences"])


def test_added_load_dylib_command_is_rejected(tmp_path):
    result, _, _ = _compare(
        tmp_path,
        _files(runner=_macho()),
        _files(runner=_macho(signature=b"enterprise", dylib="@rpath/SignerHook.dylib")),
    )
    assert result["status"] == "fail"
    assert any("load commands" in difference for difference in result["differences"])


def test_added_rpath_command_is_rejected(tmp_path):
    result, _, _ = _compare(
        tmp_path,
        _files(runner=_macho()),
        _files(runner=_macho(signature=b"enterprise", rpath="@executable_path/Frameworks/Partner")),
    )
    assert result["status"] == "fail"
    assert any("load commands" in difference for difference in result["differences"])


def test_unsigned_candidate_to_signed_final_passes_when_code_is_identical(tmp_path):
    result, _, _ = _compare(
        tmp_path,
        _files(runner=_macho(signature=None)),
        _files(runner=_macho(signature=b"enterprise")),
    )
    assert result["status"] == "pass"


def test_linkedit_memory_size_cannot_be_arbitrarily_expanded(tmp_path):
    enlarged = bytearray(_macho(signature=b"enterprise"))
    enlarged[64:72] = struct.pack("<Q", 1 << 28)
    result, _, _ = _compare(
        tmp_path,
        _files(runner=_macho()),
        _files(runner=bytes(enlarged)),
    )
    assert result["status"] == "fail"
    assert any("__LINKEDIT" in difference for difference in result["differences"])


def test_aot_and_resource_changes_are_rejected(tmp_path):
    root = "Payload/Runner.app/"
    original = _files()
    modified = _files(aot=_macho(payload=b"TAMPERED-AOT"), extra={root + "Assets.car": b"TAMPERED"})
    result, _, _ = _compare(tmp_path, original, modified)
    assert result["status"] == "fail"
    assert any("App.framework/App" in difference for difference in result["differences"])
    assert any("Assets.car" in difference for difference in result["differences"])


def test_info_plist_value_change_is_rejected(tmp_path):
    result, _, _ = _compare(tmp_path, _files(), _files(info={"CFBundleIdentifier": "other", "CFBundleExecutable": "Runner", "CFBundleVersion": "2173"}))
    assert result["status"] == "fail"
    assert any("Info.plist" in difference for difference in result["differences"])


def test_malformed_info_plist_returns_failure_report(tmp_path):
    result, _, _ = _compare(
        tmp_path,
        _files(),
        _files(extra={"Payload/Runner.app/Info.plist": b"<plist><dict>"}),
    )
    assert result["status"] == "fail"
    assert any("Info.plist" in difference for difference in result["differences"])


def test_corrupt_macho_and_missing_arm64_fail_closed(tmp_path):
    corrupt, _, _ = _compare(tmp_path, _files(), _files(runner=_macho()[:-3]))
    assert corrupt["status"] == "fail"
    assert any("Runner" in difference for difference in corrupt["differences"])
    other_cpu, _, _ = _compare(tmp_path, _files(), _files(runner=_macho(cpu=0x01000007)))
    assert other_cpu["status"] == "fail"


def test_fat_binary_signature_change_passes_with_same_architectures(tmp_path):
    original = _files(runner=_fat(_macho(signature=b"one"), _macho(signature=b"one", cpu=0x01000007)))
    modified = _files(runner=_fat(_macho(signature=b"different"), _macho(signature=b"different", cpu=0x01000007)))
    result, _, _ = _compare(tmp_path, original, modified)
    assert result["status"] == "pass"


def test_path_traversal_and_duplicate_entries_fail_closed(tmp_path):
    original = _files()
    traversal = _files(extra={"Payload/Runner.app/../Other.app/evil": b"x"})
    result, _, _ = _compare(tmp_path, original, traversal)
    assert result["status"] == "fail"
    final = _ipa(tmp_path, "duplicate.ipa", original)
    with pytest.warns(UserWarning):
        with zipfile.ZipFile(final, "a") as archive:
            archive.writestr("Payload/Runner.app/Runner", b"evil")
    assert _comparator().compare_ipa_payload(_ipa(tmp_path, "candidate.ipa", original), final)["status"] == "fail"


def test_added_extension_or_missing_resource_is_rejected(tmp_path):
    root = "Payload/Runner.app/"
    original = _files()
    modified = _files(extra={root + "PlugIns/Injected.appex/Info.plist": plistlib.dumps({"CFBundleExecutable": "Injected"}), root + "PlugIns/Injected.appex/Injected": _macho()})
    modified.pop(root + "Frameworks/App.framework/flutter_assets/assets/image.png")
    result, _, _ = _compare(tmp_path, original, modified)
    assert result["status"] == "fail"
    assert any("Injected.appex" in difference for difference in result["differences"])
    assert any("image.png" in difference for difference in result["differences"])


def test_size_limit_fails_closed(tmp_path, monkeypatch):
    module = _comparator()
    monkeypatch.setattr(module, "MAX_ENTRY_BYTES", 5)
    candidate = _ipa(tmp_path, "candidate.ipa", _files())
    final = _ipa(tmp_path, "signed.ipa", _files())
    result = module.compare_ipa_payload(candidate, final)
    assert result["status"] == "fail"
    assert any("size limit" in difference for difference in result["differences"])
