"""Compare a CI iOS IPA with the final enterprise re-sign, excluding signing data.

This is a deliberately conservative payload check. It does not validate a
certificate chain, entitlements, provisioning, or installation compatibility;
run verify_ios_enterprise_ipa.py and the no-uninstall device test separately.
"""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import stat
import struct
import sys
import zipfile
from xml.parsers.expat import ExpatError


MAX_IPA_BYTES = 1024 * 1024 * 1024
MAX_ENTRIES = 30000
MAX_ENTRY_BYTES = 256 * 1024 * 1024
MAX_TOTAL_BYTES = 2 * 1024 * 1024 * 1024
MAX_PLIST_BYTES = 16 * 1024 * 1024
MAX_COMMANDS = 4096
MAX_DIFFERENCES = 200
ARM64 = 0x0100000C
LC_SEGMENT_64 = 0x19
LC_CODE_SIGNATURE = 0x1D
THIN_64_LE = b"\xcf\xfa\xed\xfe"
FAT_32_BE = b"\xca\xfe\xba\xbe"
FAT_64_BE = b"\xca\xfe\xba\xbf"
MACHO_MAGICS = {THIN_64_LE, FAT_32_BE, FAT_64_BE}


def _sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _valid_zip_name(name: str) -> bool:
    return (
        name.startswith("Payload/")
        and "\\" not in name
        and "\x00" not in name
        and all(part not in ("", ".", "..") for part in name.rstrip("/").split("/"))
    )


def _inventory(archive: zipfile.ZipFile) -> tuple[str, dict[str, zipfile.ZipInfo]]:
    entries = archive.infolist()
    if len(entries) > MAX_ENTRIES:
        raise ValueError("IPA has too many ZIP entries")
    files: dict[str, zipfile.ZipInfo] = {}
    casefold_names: set[str] = set()
    total = 0
    for entry in entries:
        if not entry.filename.startswith("Payload/"):
            continue
        name = entry.filename
        if not _valid_zip_name(name):
            raise ValueError(f"invalid Payload ZIP path: {name}")
        if entry.is_dir():
            continue
        if name in files or name.casefold() in casefold_names:
            raise ValueError(f"duplicate Payload ZIP path: {name}")
        mode = (entry.external_attr >> 16) & 0o170000
        if mode == stat.S_IFLNK:
            raise ValueError(f"symlink is not supported in Payload: {name}")
        if entry.flag_bits & 1:
            raise ValueError(f"encrypted ZIP entry is not supported: {name}")
        if entry.file_size > MAX_ENTRY_BYTES or entry.compress_size > MAX_IPA_BYTES:
            raise ValueError(f"Payload ZIP entry exceeds size limit: {name}")
        total += entry.file_size
        if total > MAX_TOTAL_BYTES:
            raise ValueError("Payload ZIP exceeds total size limit")
        files[name] = entry
        casefold_names.add(name.casefold())
    roots = {
        name.rsplit("/Info.plist", 1)[0]
        for name in files
        if name.count("/") == 2 and name.startswith("Payload/") and name.endswith(".app/Info.plist")
    }
    if len(roots) != 1:
        raise ValueError("IPA must contain exactly one top-level Payload app")
    root = roots.pop()
    if any(not name.startswith(root + "/") for name in files):
        raise ValueError("IPA contains files outside its top-level Payload app")
    return root, files


def _signing_only(path: str) -> bool:
    parts = path.split("/")
    if parts[-1] == "embedded.mobileprovision" and len(parts) >= 2:
        return parts[-2].endswith((".app", ".appex"))
    return (
        len(parts) >= 3
        and parts[-2] == "_CodeSignature"
        and parts[-1] == "CodeResources"
        and parts[-3].endswith((".app", ".appex", ".framework", ".bundle", ".xpc"))
    )


def _read_entry(archive: zipfile.ZipFile, entry: zipfile.ZipInfo, *, limit: int = MAX_ENTRY_BYTES) -> bytes:
    if entry.file_size > limit:
        raise ValueError(f"Payload entry exceeds read limit: {entry.filename}")
    with archive.open(entry) as source:
        data = source.read(limit + 1)
        if len(data) > limit or source.read(1):
            raise ValueError(f"Payload entry exceeds read limit: {entry.filename}")
    if len(data) != entry.file_size:
        raise ValueError(f"Payload entry has unexpected length: {entry.filename}")
    return data


def _entry_digest(archive: zipfile.ZipFile, entry: zipfile.ZipInfo) -> str:
    digest = hashlib.sha256()
    total = 0
    with archive.open(entry) as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            total += len(chunk)
            if total > MAX_ENTRY_BYTES:
                raise ValueError(f"Payload entry exceeds read limit: {entry.filename}")
            digest.update(chunk)
    if total != entry.file_size:
        raise ValueError(f"Payload entry has unexpected length: {entry.filename}")
    return digest.hexdigest()


def _read_info(archive: zipfile.ZipFile, entry: zipfile.ZipInfo) -> dict:
    try:
        info = plistlib.loads(_read_entry(archive, entry, limit=MAX_PLIST_BYTES))
    except (ValueError, TypeError, plistlib.InvalidFileException, ExpatError) as exc:
        raise ValueError(f"invalid Info.plist: {entry.filename}") from exc
    if not isinstance(info, dict):
        raise ValueError(f"Info.plist is not a dictionary: {entry.filename}")
    return info


def _fat_slices(data: bytes) -> dict[tuple[int, int], bytes]:
    if data[:4] == THIN_64_LE:
        if len(data) < 32:
            raise ValueError("truncated thin Mach-O header")
        cpu, subtype = struct.unpack_from("<II", data, 4)
        return {(cpu, subtype): data}
    if data[:4] not in (FAT_32_BE, FAT_64_BE):
        raise ValueError("unsupported Mach-O format")
    is_64 = data[:4] == FAT_64_BE
    if len(data) < 8:
        raise ValueError("truncated fat Mach-O header")
    nfat = struct.unpack_from(">I", data, 4)[0]
    stride = 32 if is_64 else 20
    table_end = 8 + nfat * stride
    if not 1 <= nfat <= 32 or table_end > len(data):
        raise ValueError("invalid fat Mach-O architecture table")
    result: dict[tuple[int, int], bytes] = {}
    spans = []
    for i in range(nfat):
        offset = 8 + i * stride
        if is_64:
            cpu, subtype, start, size, align, reserved = struct.unpack_from(">IIQQII", data, offset)
            if reserved != 0:
                raise ValueError("invalid fat Mach-O reserved field")
        else:
            cpu, subtype, start, size, align = struct.unpack_from(">IIIII", data, offset)
        if align > 30 or start < table_end or size < 32 or start + size > len(data):
            raise ValueError("invalid fat Mach-O architecture range")
        if start % (1 << align):
            raise ValueError("misaligned fat Mach-O architecture")
        key = (cpu, subtype)
        if key in result:
            raise ValueError("duplicate fat Mach-O architecture")
        result[key] = data[start : start + size]
        spans.append((start, start + size))
    spans.sort()
    if any(left[1] > right[0] for left, right in zip(spans, spans[1:])):
        raise ValueError("overlapping fat Mach-O architectures")
    return result


def _thin_parts(data: bytes, expected_cpu: int, expected_subtype: int) -> tuple[tuple, list[tuple[int, bytes]], int, bytes, tuple[int, int] | None]:
    if len(data) < 32 or data[:4] != THIN_64_LE:
        raise ValueError("unsupported thin Mach-O architecture")
    magic, cpu, subtype, filetype, ncmds, sizeofcmds, flags, reserved = struct.unpack_from("<IiiIIIII", data)
    if cpu != expected_cpu or (subtype & 0xFFFFFFFF) != expected_subtype:
        raise ValueError("fat Mach-O CPU metadata disagrees with inner slice")
    end = 32 + sizeofcmds
    if ncmds > MAX_COMMANDS or sizeofcmds > 1024 * 1024 or end > len(data):
        raise ValueError("invalid Mach-O load-command table")
    commands = []
    signature = None
    position = 32
    for _ in range(ncmds):
        if position + 8 > end:
            raise ValueError("truncated Mach-O load command")
        command, size = struct.unpack_from("<II", data, position)
        if size < 8 or size % 8 or position + size > end:
            raise ValueError("invalid Mach-O load-command size")
        raw = data[position : position + size]
        if command == LC_CODE_SIGNATURE:
            if size != 16 or signature is not None:
                raise ValueError("invalid or duplicate LC_CODE_SIGNATURE")
            sig_offset, sig_size = struct.unpack_from("<II", raw, 8)
            if sig_size == 0 or sig_offset < end or sig_offset + sig_size != len(data):
                raise ValueError("invalid Mach-O CodeSignature range")
            signature = (sig_offset, sig_size)
        else:
            commands.append((command, raw))
        position += size
    if position != end:
        raise ValueError("Mach-O load-command count/size mismatch")
    header = (magic, cpu, subtype, filetype, flags, reserved)
    return header, commands, end, data, signature


def _normalize_commands(
    commands: list[tuple[int, bytes]],
    signature: tuple[int, int] | None,
    file_length: int,
    *,
    normalize_linkedit_size: bool,
) -> list[tuple[int, bytes]]:
    normalized = []
    linkedit_found = False
    for command, raw in commands:
        if command == LC_SEGMENT_64 and len(raw) >= 72 and raw[8:24].rstrip(b"\0") == b"__LINKEDIT":
            linkedit_found = True
            if len(raw) != 72:
                raise ValueError("unexpected __LINKEDIT section table")
            fileoff, filesize = struct.unpack_from("<QQ", raw, 40)
            vmsize = struct.unpack_from("<Q", raw, 32)[0]
            allowed_vm_sizes = {
                (filesize + page_size - 1) // page_size * page_size
                for page_size in (4096, 16384)
            }
            if fileoff + filesize > file_length or vmsize not in allowed_vm_sizes:
                raise ValueError("invalid __LINKEDIT segment range")
            if signature:
                sig_offset, sig_size = signature
                if not (fileoff <= sig_offset and sig_offset + sig_size <= fileoff + filesize):
                    raise ValueError("CodeSignature is outside __LINKEDIT")
            if normalize_linkedit_size:
                copy = bytearray(raw)
                copy[32:40] = b"\0" * 8  # vmsize may grow with the signature.
                copy[48:56] = b"\0" * 8  # filesize includes the signature.
                raw = bytes(copy)
        normalized.append((command, raw))
    if signature and not linkedit_found:
        raise ValueError("CodeSignature has no __LINKEDIT segment")
    return normalized


def _compare_macho(candidate: bytes, final: bytes) -> str | None:
    first = _fat_slices(candidate)
    second = _fat_slices(final)
    if ARM64 not in {cpu for cpu, _ in first} or ARM64 not in {cpu for cpu, _ in second}:
        return "arm64 architecture missing"
    if first.keys() != second.keys():
        return "Mach-O architecture inventory changed"
    for key in sorted(first):
        old = _thin_parts(first[key], *key)
        new = _thin_parts(second[key], *key)
        old_header, old_commands, old_end, old_data, old_sig = old
        new_header, new_commands, new_end, new_data, new_sig = new
        if old_header != new_header:
            return f"Mach-O header changed for CPU {key[0]:x}"
        normalize_linkedit_size = bool(old_sig or new_sig)
        if _normalize_commands(
            old_commands, old_sig, len(old_data), normalize_linkedit_size=normalize_linkedit_size
        ) != _normalize_commands(
            new_commands, new_sig, len(new_data), normalize_linkedit_size=normalize_linkedit_size
        ):
            return f"Mach-O load commands changed for CPU {key[0]:x}"
        common_end = max(old_end, new_end)
        if old_end < common_end and any(old_data[old_end:common_end]):
            return f"Mach-O non-signature header padding changed for CPU {key[0]:x}"
        if new_end < common_end and any(new_data[new_end:common_end]):
            return f"Mach-O non-signature header padding changed for CPU {key[0]:x}"
        old_body_end = old_sig[0] if old_sig else len(old_data)
        new_body_end = new_sig[0] if new_sig else len(new_data)
        if old_body_end < common_end or new_body_end < common_end:
            return f"Mach-O CodeSignature overlaps code for CPU {key[0]:x}"
        if old_data[common_end:old_body_end] != new_data[common_end:new_body_end]:
            return f"Mach-O non-signature bytes changed for CPU {key[0]:x}"
    return None


def _append(differences: list[str], message: str) -> None:
    if len(differences) < MAX_DIFFERENCES:
        differences.append(message)
    elif len(differences) == MAX_DIFFERENCES:
        differences.append("additional differences omitted")


def _bundle_executables(archive: zipfile.ZipFile, files: dict[str, zipfile.ZipInfo]) -> set[str]:
    executables = set()
    for name, entry in files.items():
        if not name.endswith("/Info.plist"):
            continue
        info = _read_info(archive, entry)
        executable = info.get("CFBundleExecutable")
        if executable is None:
            continue
        if not isinstance(executable, str) or not executable or "/" in executable or "\\" in executable:
            raise ValueError(f"invalid CFBundleExecutable in {name}")
        executable_path = name[: -len("Info.plist")] + executable
        if executable_path not in files:
            raise ValueError(f"bundle executable is missing: {executable_path}")
        executables.add(executable_path)
    return executables


def compare_ipa_payload(candidate: Path | str, final: Path | str) -> dict:
    """Return a JSON-safe report; `pass` means only recognized signing bytes differ."""
    candidate = Path(candidate)
    final = Path(final)
    result: dict = {
        "candidate_sha256": None,
        "final_sha256": None,
        "status": "fail",
        "differences": [],
        "payload_path_count": None,
        "final_payload_path_count": None,
    }
    differences = result["differences"]
    try:
        for path in (candidate, final):
            if not path.is_file() or path.stat().st_size > MAX_IPA_BYTES:
                raise ValueError(f"IPA missing or exceeds size limit: {path}")
        result["candidate_sha256"] = _sha256_file(candidate)
        result["final_sha256"] = _sha256_file(final)
        with zipfile.ZipFile(candidate) as old_zip, zipfile.ZipFile(final) as new_zip:
            old_root, old_files = _inventory(old_zip)
            new_root, new_files = _inventory(new_zip)
            if old_root != new_root:
                _append(differences, f"top-level Payload app changed: {old_root} -> {new_root}")
            old_names = {name for name in old_files if not _signing_only(name)}
            new_names = {name for name in new_files if not _signing_only(name)}
            result["payload_path_count"] = len(old_files)
            result["final_payload_path_count"] = len(new_files)
            for name in sorted(old_names - new_names):
                _append(differences, f"missing Payload path: {name}")
            for name in sorted(new_names - old_names):
                _append(differences, f"added Payload path: {name}")
            old_executables = _bundle_executables(old_zip, old_files)
            new_executables = _bundle_executables(new_zip, new_files)
            if old_executables != new_executables:
                _append(differences, "bundle executable inventory changed")
            for name in sorted(old_names & new_names):
                old_entry, new_entry = old_files[name], new_files[name]
                if name.endswith("/Info.plist"):
                    if _read_info(old_zip, old_entry) != _read_info(new_zip, new_entry):
                        _append(differences, f"Info.plist values changed: {name}")
                    continue
                with old_zip.open(old_entry) as stream:
                    old_magic = stream.read(4)
                with new_zip.open(new_entry) as stream:
                    new_magic = stream.read(4)
                must_be_macho = name in old_executables or name in new_executables or name.endswith((".dylib", ".so"))
                if must_be_macho or old_magic in MACHO_MAGICS or new_magic in MACHO_MAGICS:
                    if old_magic not in MACHO_MAGICS or new_magic not in MACHO_MAGICS:
                        _append(differences, f"Mach-O executable missing or unparseable: {name}")
                        continue
                    try:
                        detail = _compare_macho(_read_entry(old_zip, old_entry), _read_entry(new_zip, new_entry))
                    except ValueError as exc:
                        detail = f"Mach-O unparseable: {exc}"
                    if detail:
                        _append(differences, f"{name}: {detail}")
                elif old_entry.file_size != new_entry.file_size or _entry_digest(old_zip, old_entry) != _entry_digest(new_zip, new_entry):
                    _append(differences, f"resource bytes changed: {name}")
    except (OSError, ValueError, zipfile.BadZipFile, RuntimeError) as exc:
        _append(differences, str(exc))
    if not differences:
        result["status"] = "pass"
    return result


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--candidate", required=True, type=Path, help="CI-generated source IPA")
    parser.add_argument("--final", required=True, type=Path, help="enterprise re-signed IPA")
    parser.add_argument("--json-out", type=Path, help="optional report path; also prints JSON to stdout")
    args = parser.parse_args(argv)
    result = compare_ipa_payload(args.candidate, args.final)
    encoded = json.dumps(result, ensure_ascii=False, indent=2, sort_keys=True)
    if args.json_out:
        args.json_out.write_text(encoded + "\n", encoding="utf-8")
    print(encoded)
    return 0 if result["status"] == "pass" else 1


if __name__ == "__main__":
    sys.exit(main())
