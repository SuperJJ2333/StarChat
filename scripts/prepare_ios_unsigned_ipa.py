"""Validate a full device app and ditto IPA, then emit enterprise handoff evidence.

This never signs, changes the payload, or claims source entitlements are signed
rights. Native load commands/symbol tables are read without loading any code.
"""

import argparse
import hashlib
import json
import os
import plistlib
import re
import shutil
import stat
import struct
import sys
import zipfile
from pathlib import Path, PurePosixPath


STATISTICS_ASSET = "assets/html/statistics_tools_combined_v2.html"
SQLCIPHER_EXPORTS = (
    "sqlite3_key", "sqlite3_blob_open", "sqlite3_blob_read",
    "sqlite3_blob_write", "sqlite3_blob_close", "sqlite3_blob_bytes",
)
BUNDLE_ID = "com.liuhetong.liuhetongMobile"


def require(condition, message):
    if not condition:
        raise ValueError(message)


def digest(value):
    return hashlib.sha256(value).hexdigest()


def read_macho(value, *, exports=False):
    """Read the actual arm64 device slice, including defined external symbols."""
    def unpack(fmt, offset):
        require(0 <= offset and offset + struct.calcsize(fmt) <= len(value),
                "Truncated Mach-O metadata")
        return struct.unpack_from(fmt, value, offset)

    magic = unpack("<I", 0)[0]
    if magic in (0xBEBAFECA, 0xBFBAFECA):
        count = unpack(">I", 4)[0]
        require(0 < count <= 32, "Invalid universal Mach-O slice count")
        stride, fmt = (32, ">iiQQII") if magic == 0xBFBAFECA else (20, ">iiIII")
        slices = []
        for index in range(count):
            cpu, _, offset, size, *_ = unpack(fmt, 8 + index * stride)
            require(offset + size <= len(value) and size > 0, "Truncated Mach-O slice")
            require(cpu == 0x100000C, "Universal candidate contains non-arm64 slice")
            slices.append(read_macho(value[offset:offset + size], exports=exports))
        return slices[0]

    magic, cpu, _, filetype, count, command_bytes, _, _ = unpack("<IiiIIIII", 0)
    require(magic == 0xFEEDFACF, "Expected 64-bit Mach-O binary")
    require(cpu == 0x100000C, "Expected arm64 Mach-O binary")
    require(filetype in (2, 6), "Expected Mach-O executable or framework")
    require(32 + command_bytes <= len(value), "Truncated Mach-O commands")
    offset = 32
    libraries, platforms, symbols = [], [], set()
    symbol_table = None
    for _ in range(count):
        command, size = unpack("<II", offset)
        require(size >= 8 and offset + size <= 32 + command_bytes,
                "Invalid Mach-O load command")
        if command == 0x32:  # LC_BUILD_VERSION
            require(size >= 24, "Truncated Mach-O build version")
            platform, minimum, *_ = unpack("<4I", offset + 8)
            platforms.append((platform, minimum))
        elif command == 0x25:  # LC_VERSION_MIN_IPHONEOS, older device SDKs
            require(size == 16, "Invalid iPhoneOS minimum version command")
            platforms.append((2, unpack("<I", offset + 8)[0]))
        elif command in (0xC, 0x80000018, 0x8000001F, 0x20, 0x80000023):
            require(size >= 24, "Truncated dylib load command")
            start = unpack("<I", offset + 8)[0]
            require(24 <= start < size, "Invalid dylib name offset")
            end = value.find(b"\0", offset + start, offset + size)
            require(end >= 0, "Unterminated dylib name")
            libraries.append(value[offset + start:end].decode("utf-8"))
        elif command == 2 and exports:  # LC_SYMTAB
            require(size == 24 and symbol_table is None, "Invalid Mach-O symbol table")
            symbol_table = unpack("<4I", offset + 8)
        offset += size
    require(offset == 32 + command_bytes, "Invalid Mach-O command byte count")
    require(platforms and all(platform == 2 for platform, _ in platforms),
            "Expected iOS device Mach-O, simulator/other platform forbidden")
    if exports:
        require(symbol_table is not None, "SQLCipher defined export table missing")
        symoff, count, stroff, strsize = symbol_table
        require(symoff + count * 16 <= len(value) and stroff + strsize <= len(value),
                "Truncated SQLCipher symbol table")
        for index in range(count):
            name_offset, kind, section, _, address = unpack("<IBBHQ", symoff + index * 16)
            # N_EXT | N_SECT only; undefined references and string decoys do not count.
            if kind & 0xE0 or not kind & 1 or kind & 0x0E != 0x0E or not section or not address:
                continue
            require(name_offset < strsize, "Invalid SQLCipher symbol string offset")
            end = value.find(b"\0", stroff + name_offset, stroff + strsize)
            require(end >= 0, "Unterminated SQLCipher symbol name")
            symbols.add(value[stroff + name_offset:end].decode("utf-8").removeprefix("_"))
    minimum = max(version for _, version in platforms)
    return {"architecture": "arm64", "platform": "iOS-device", "filetype": filetype,
            "minimum_os": f"{minimum >> 16}.{minimum >> 8 & 255}.{minimum & 255}",
            "loaded_libraries": libraries, "defined_exports": sorted(symbols)}


def inspect_app(app, source, version, build):
    info = plistlib.loads((app / "Info.plist").read_bytes())
    require(info.get("CFBundleIdentifier") == BUNDLE_ID, "Unexpected Bundle ID")
    require(info.get("CFBundleShortVersionString") == version, "Unexpected app version")
    require(info.get("CFBundleVersion") == build, "Unexpected app build")
    require(info.get("MinimumOSVersion") == "16.0", "Expected iOS 16.0 minimum")
    require(info.get("CFBundleSupportedPlatforms") == ["iPhoneOS"], "Expected iPhoneOS app")
    require(info.get("CFBundleExecutable") == "Runner", "Expected Runner executable")
    require({1, 2} <= set(info.get("UIDeviceFamily", [])), "Missing iPhone/iPad device family")
    require({"audio", "voip", "remote-notification"} <= set(info.get("UIBackgroundModes", [])),
            "Missing native audio/VoIP/notification background capabilities")
    runner = read_macho((app / "Runner").read_bytes())
    require(runner["filetype"] == 2, "Runner must be an executable")
    require(runner["minimum_os"] == "16.0.0", "Runner must preserve iOS 16.0 minimum")
    libraries = runner["loaded_libraries"]
    cipher = "@rpath/SQLCipher.framework/SQLCipher"
    require(cipher in libraries, "Runner does not load SQLCipher")
    sqlite = [index for index, name in enumerate(libraries) if re.search(r"/libsqlite3(?:\.[^/]*)?\.dylib$", name)]
    require(not sqlite or libraries.index(cipher) < min(sqlite), "System SQLite shadows SQLCipher")

    frameworks = {}
    for folder in sorted((app / "Frameworks").glob("*.framework")):
        binary = folder / folder.stem
        require(binary.is_file(), "Missing framework executable: " + folder.name)
        frameworks[folder.name] = {"binary_sha256": digest(binary.read_bytes())}
    for name in ("App", "Flutter", "SQLCipher"):
        require(name + ".framework" in frameworks, "Missing required framework: " + name)
        binary = app / f"Frameworks/{name}.framework/{name}"
        native = read_macho(binary.read_bytes(), exports=name == "SQLCipher")
        require(native["filetype"] == 6, "Expected dynamic framework: " + name)
        frameworks[name + ".framework"]["native"] = native
    exports = set(frameworks["SQLCipher.framework"]["native"]["defined_exports"])
    missing = set(SQLCIPHER_EXPORTS) - exports
    require(not missing, "SQLCipher actual defined exports missing: " + ", ".join(sorted(missing)))

    pubspec = (source / "pubspec.yaml").read_text(encoding="utf-8")
    require(re.search(r"^version:\s*" + re.escape(version + "+" + build) + r"\s*$", pubspec, re.M),
            "Source version/build does not match candidate")
    require(re.search(r"^  mobile_scanner: 6\.0\.11\s*$", pubspec, re.M),
            "Full production plugin mobile_scanner 6.0.11 missing")
    registry = json.loads((source / ".flutter-plugins-dependencies").read_text(encoding="utf-8"))
    plugins = [plugin for plugin in registry["plugins"]["ios"] if not plugin.get("dev_dependency")]
    plugin_names = {plugin["name"] for plugin in plugins}
    require({"mobile_scanner", "sqlcipher_flutter_libs", "permission_handler_apple"} <= plugin_names,
            "Required production plugin absent from resolved iOS registry")
    pod_lock = (source / "ios/Podfile.lock").read_text(encoding="utf-8")
    pods = set(re.findall(r"^  - ([A-Za-z0-9_]+)(?:/| \()", pod_lock, re.M))
    missing_pods = {plugin["name"] for plugin in plugins if plugin.get("native_build", True)} - pods
    require(not missing_pods, "CocoaPods production plugins missing: " + ", ".join(sorted(missing_pods)))
    asset_sha = digest((source / STATISTICS_ASSET).read_bytes())
    asset = app / "Frameworks/App.framework/flutter_assets" / STATISTICS_ASSET
    require(asset.is_file() and digest(asset.read_bytes()) == asset_sha,
            "Packaged statistics asset differs from source")
    entitlements = plistlib.loads((source / "ios/Runner/Runner.entitlements").read_bytes())
    require(entitlements.get("aps-environment") == "production", "Expected production APNs source entitlement")
    require(not (app / "embedded.mobileprovision").exists(), "Unsigned candidate contains provisioning profile")
    require(not (app / "_CodeSignature").exists(), "Unsigned candidate contains Runner signature resources")
    inputs = ["pubspec.yaml", "pubspec.lock", "ios/Podfile.lock", "ios/Runner/Runner.entitlements",
              "ios/Runner/GeneratedPluginRegistrant.m", ".flutter-plugins-dependencies"]
    hashes = {name: digest((source / name).read_bytes()) for name in inputs}
    return {"bundle_id": BUNDLE_ID, "version": version, "build": build,
            "minimum_os": "16.0", "runner": runner, "frameworks": frameworks,
            "production_ios_plugins": sorted(plugin_names),
            "sqlcipher_exports": list(SQLCIPHER_EXPORTS)}, asset_sha, hashes


def verify_payload(app, ipa):
    """Require exact file/symlink inventory and bytes, and retain executable mode."""
    expected = {}
    for folder, directories, files in os.walk(app, followlinks=False):
        base = Path(folder)
        for name in list(directories):
            path = base / name
            if path.is_symlink():
                files.append(name)
                directories.remove(name)
        for name in files:
            path = base / name
            relative = "Payload/Runner.app/" + path.relative_to(app).as_posix()
            mode = path.lstat().st_mode
            require(stat.S_ISREG(mode) or stat.S_ISLNK(mode), "Unsupported app filesystem entry")
            expected[relative] = (mode, os.readlink(path).encode() if stat.S_ISLNK(mode) else path.read_bytes())
    with zipfile.ZipFile(ipa) as archive:
        require(archive.testzip() is None, "IPA ZIP CRC check failed")
        names = archive.namelist()
        require(len(names) == len(set(names)), "IPA contains duplicate ZIP entries")
        actual = {}
        for entry in archive.infolist():
            parts = PurePosixPath(entry.filename).parts
            require(not entry.filename.startswith("/") and ".." not in parts and "\\" not in entry.filename,
                    "Unsafe IPA ZIP entry path")
            if entry.is_dir():
                continue
            require(entry.filename.startswith("Payload/Runner.app/"), "Unexpected file outside complete Payload")
            actual[entry.filename] = entry
        require(set(actual) == set(expected), "IPA does not preserve complete Payload inventory")
        for name, (mode, value) in expected.items():
            entry = actual[name]
            zipped_mode = entry.external_attr >> 16
            require(stat.S_IFMT(zipped_mode) == stat.S_IFMT(mode), "Payload file/symlink type changed: " + name)
            if name == "Payload/Runner.app/Runner":
                require(zipped_mode & 0o111, "Runner ZIP executable mode missing")
            # The producer runs on macOS, where exact POSIX modes are meaningful.
            # Windows artifact inspection still checks ZIP executable/type bits.
            if os.name != "nt":
                require(mode & 0o777 == zipped_mode & 0o777,
                        "Payload executable mode/permissions changed: " + name)
            require(archive.read(entry) == value, "Payload bytes/symlink target changed: " + name)
    return len(expected)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    for argument in ("app", "ipa", "source-root", "output-dir", "toolchain-report"):
        parser.add_argument("--" + argument, type=Path, required=True)
    for argument in ("source-sha", "run-id", "run-attempt", "repository", "version", "build"):
        parser.add_argument("--" + argument, required=True)
    args = parser.parse_args(argv)
    try:
        require(re.fullmatch(r"[0-9a-f]{40}", args.source_sha), "Invalid source SHA")
        require(args.run_id.isdecimal() and int(args.run_id) > 0, "Invalid CI run ID")
        require(args.run_attempt.isdecimal() and int(args.run_attempt) > 0, "Invalid CI run attempt")
        require(re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", args.repository), "Invalid repository identity")
        app, asset_sha, inputs = inspect_app(args.app, args.source_root, args.version, args.build)
        count = verify_payload(args.app, args.ipa)
        ipa_bytes = args.ipa.read_bytes()
        tools = args.toolchain_report.read_bytes()
        report = {"schema_version": 1, "source_commit": args.source_sha,
                  "ci": {"repository": args.repository, "run_id": int(args.run_id),
                         "run_attempt": int(args.run_attempt)},
                  "app": app, "source_input_sha256": inputs,
                  "statistics_asset_sha256": asset_sha,
                  "toolchain_report_sha256": digest(tools),
                  "ipa": {"filename": args.ipa.name, "bytes": len(ipa_bytes),
                          "sha256": digest(ipa_bytes), "payload_files": count, "zip_crc": "PASS"},
                  "signing": {"state": "unsigned-candidate-awaiting-enterprise-resigning",
                              "source_entitlements_are_signed_rights": False,
                              "enterprise_team_keychain_and_upgrade_verified": False}}
        args.output_dir.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(args.source_root / "ios/Runner/Runner.entitlements", args.output_dir / "Runner.entitlements")
        (args.output_dir / "toolchain.txt").write_bytes(tools)
        (args.output_dir / "build-manifest.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
        print(json.dumps(report, indent=2))
        return 0
    except (ValueError, KeyError, OSError, struct.error, zipfile.BadZipFile) as error:
        print("Unsigned IPA verification failed: " + str(error), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
