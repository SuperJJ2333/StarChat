"""Read-only, bounded ARM64 ELF/ZIP inspection. Never signs or changes inputs."""
import argparse
import hashlib
import json
import re
import struct
import sys
import zipfile
from datetime import datetime, timezone
from pathlib import Path

PAGE = 16384
MAX_LIBRARY = 128 * 1024 * 1024
BASELINE_SHA = "08a7448114ad5d768b534b81b61668e03a71a2c26f95e894297e098838f15271"
AAR_SHA = "a5b05c4b362d35c022238ef9b2e4e2196248adea3bac9dd683845ee75a3a8d66"
CRYPTO = "lib/arm64-v8a/libcrypto.so"
SIZE_FALLBACK = {"EVP_MD_get_size", "EVP_MD_size"}


def digest(data):
    return hashlib.sha256(data).hexdigest()


def file_identity(path):
    path = Path(path)
    hasher = hashlib.sha256()
    with path.open("rb") as stream:
        while chunk := stream.read(1024 * 1024):
            hasher.update(chunk)
    return {"path": str(path.resolve()), "bytes": path.stat().st_size,
            "sha256": hasher.hexdigest()}


def inspect_elf(data):
    def take(offset, size):
        if offset < 0 or size < 0 or offset + size > len(data):
            raise ValueError("ELF range exceeds actual file bytes")
        return data[offset:offset + size]

    header = struct.unpack("<16sHHIQQQIHHHHHH", take(0, 64))
    ident, typ, machine = header[:3]
    if ident[:7] != b"\x7fELF\x02\x01\x01" or machine != 183 or typ != 3:
        raise ValueError("expected little-endian ELF64 ARM64 shared object")
    phoff, shoff = header[5:7]
    phsize, phnum, shsize, shnum, strindex = header[9:14]
    if phsize != 56 or not 0 < phnum <= 1024 or shsize != 64:
        raise ValueError("unsupported ELF table layout")
    if not 0 < shnum <= 65535 or not 0 <= strindex < shnum:
        raise ValueError("missing or unsupported ELF section table")
    take(phoff, phsize * phnum)
    take(shoff, shsize * shnum)
    programs = []
    for index in range(phnum):
        p = struct.unpack("<IIQQQQQQ", take(phoff + index * phsize, phsize))
        record = dict(zip(
            ("type", "flags", "offset", "vaddr", "paddr", "filesz", "memsz", "align"), p))
        take(record["offset"], record["filesz"])
        # GNU_RELRO can describe a rounded protection extent. PT_LOAD cannot
        # map more file bytes than its memory extent.
        if record["type"] == 1 and record["filesz"] > record["memsz"]:
            raise ValueError("PT_LOAD file extent exceeds memory extent")
        programs.append(record)
    loads = []
    relro = []
    for p in programs:
        if p["type"] == 1:
            aligned = (p["align"] >= PAGE and
                       p["align"] & (p["align"] - 1) == 0 and
                       (p["vaddr"] - p["offset"]) % PAGE == 0)
            loads.append({**p, "aligned_16k": aligned})
        if p["type"] == 0x6474E552:
            end = p["vaddr"] + p["memsz"]
            page_end = (end + PAGE - 1) // PAGE * PAGE
            intersections = []
            for index, load in enumerate(q for q in programs if q["type"] == 1):
                start = max(end, load["vaddr"])
                stop = min(page_end, load["vaddr"] + load["memsz"])
                if load["flags"] & 2 and start < stop:
                    intersections.append({"start": start, "end": stop,
                                          "load_index": index})
            relro.append({**p, "end": end, "end_mod_16k": end % PAGE,
                          "end_aligned_16k": end % PAGE == 0,
                          "page_end_16k": page_end,
                          "writable_load_intersections_after_end": intersections})
    if not loads:
        raise ValueError("ELF has no PT_LOAD")
    sections = [struct.unpack("<IIQQQQIIQQ", take(shoff + n * shsize, shsize))
                for n in range(shnum)]

    def section_data(index):
        if not 0 <= index < len(sections):
            raise ValueError("ELF section link outside table")
        sec = sections[index]
        return b"" if sec[1] == 8 else take(sec[4], sec[5])

    def string(table, offset):
        if not 0 <= offset < len(table):
            raise ValueError("ELF string offset outside table")
        end = table.find(b"\0", offset)
        if end == -1:
            raise ValueError("unterminated ELF string")
        return table[offset:end].decode("utf-8", errors="strict")

    section_names = section_data(strindex)
    allocated = []
    exports = set()
    needed, sonames = [], []
    for index, sec in enumerate(sections):
        name = string(section_names, sec[0])
        payload = section_data(index)
        if sec[2] & 2:
            allocated.append({"name": name, "type": sec[1], "flags": sec[2],
                              "address": sec[3], "size": sec[5],
                              "sha256": None if sec[1] == 8 else digest(payload)})
        if sec[1] == 11:
            if sec[9] != 24 or len(payload) % 24 or len(payload) > 24 * 500000:
                raise ValueError("invalid or excessive dynamic symbol table")
            names = section_data(sec[6])
            for off in range(0, len(payload), 24):
                symbol = struct.unpack_from("<IBBHQQ", payload, off)
                label, info, visibility, defined = symbol[:4]
                if defined and info >> 4 in (1, 2) and visibility & 3 in (0, 3):
                    exports.add(string(names, label))
        if sec[1] == 6:
            if sec[9] != 16 or len(payload) % 16:
                raise ValueError("invalid dynamic table")
            names = section_data(sec[6])
            for off in range(0, len(payload), 16):
                tag, value = struct.unpack_from("<qQ", payload, off)
                if tag == 0:
                    break
                if tag == 1:
                    needed.append(string(names, value))
                elif tag == 14:
                    sonames.append(string(names, value))
    if len(sonames) > 1:
        raise ValueError("duplicate SONAME")
    return {"machine": machine, "loads": loads, "relro": relro,
            "loads_16k": all(p["aligned_16k"] for p in loads),
            # Absence is reported, not invented as enabled RELRO hardening.
            "relro_present": bool(relro),
            "relro_16k": all(p["end_aligned_16k"] for p in relro),
            "soname": sonames[0] if sonames else None, "needed": sorted(needed),
            "exports": sorted(exports), "allocated_sections": allocated}


def inspect_apk(path):
    identity = file_identity(path)
    libraries = {}
    with zipfile.ZipFile(path) as archive, Path(path).open("rb") as raw:
        entries = archive.infolist()
        names = [item.filename for item in entries]
        if len(names) != len(set(names)):
            raise ValueError("duplicate ZIP entry")
        native = [item for item in entries
                  if item.filename.startswith("lib/") and item.filename.endswith(".so")]
        if not native or len(native) > 128:
            raise ValueError("missing or excessive native libraries")
        if sum(item.file_size for item in native) > 512 * 1024 * 1024:
            raise ValueError("native libraries exceed inspection byte budget")
        for item in native:
            if not re.fullmatch(r"lib/arm64-v8a/[^/]+\.so", item.filename):
                raise ValueError("non-ARM64 or malformed native ZIP path")
            if item.file_size > MAX_LIBRARY or item.flag_bits & 1:
                raise ValueError("oversized or encrypted native entry")
            raw.seek(item.header_offset)
            header = raw.read(30)
            if len(header) != 30 or header[:4] != b"PK\x03\x04":
                raise ValueError("invalid local ZIP header")
            local = struct.unpack("<IHHHHHIIIHH", header)
            if local[3] != item.compress_type:
                raise ValueError("local and central ZIP compression differ")
            filename = raw.read(local[-2])
            encoding = "utf-8" if local[2] & 0x800 else "cp437"
            if filename.decode(encoding) != item.filename:
                raise ValueError("local and central ZIP names differ")
            offset = item.header_offset + 30 + local[-2] + local[-1]
            if offset + item.compress_size > identity["bytes"]:
                raise ValueError("native ZIP data outside file")
            payload = archive.read(item)  # CRC checked; size bounded above.
            parsed = inspect_elf(payload)
            if item.filename != CRYPTO:
                exported = parsed.pop("exports")
                parsed["export_count"] = len(exported)
                parsed["export_names_sha256"] = digest("\n".join(exported).encode())
            libraries[item.filename] = {
                "sha256": digest(payload), "bytes": len(payload), "elf": parsed,
                "zip": {"compression": item.compress_type, "data_offset": offset,
                        "aligned_16k": offset % PAGE == 0
                        if item.compress_type == zipfile.ZIP_STORED else None,
                        "direct_mmap_stored": item.compress_type == zipfile.ZIP_STORED}}
    if file_identity(path) != identity:
        raise ValueError("APK input changed during inspection")
    return {**identity, "libraries": libraries}


def compare_libraries(left, right):
    before, after = set(left), set(right)
    changed = sorted(name for name in before & after
                     if left[name]["sha256"] != right[name]["sha256"])
    missing, added = sorted(before - after), sorted(after - before)
    return {"identical": not (changed or missing or added),
            "changed": changed, "missing": missing, "added": added}


def symbol_contract(exports, required):
    exported = set(exports)
    missing = sorted(set(required) - exported)
    fallback = sorted(SIZE_FALLBACK & exported)
    return {"required": sorted(required), "missing": missing,
            "size_fallback_exported": fallback,
            "satisfied": not missing and bool(fallback)}


def ffi_symbols(path):
    source = Path(path).read_text(encoding="utf-8")
    symbols = re.findall(
        r"libcrypto\.lookupFunction<[\s\S]*?>\(\s*['\"]([A-Za-z0-9_]+)['\"]\s*\)",
        source)
    if len(symbols) != source.count("libcrypto.lookupFunction<"):
        raise ValueError("unparsed Matrix FFI lookup")
    if not symbols or not SIZE_FALLBACK <= set(symbols):
        raise ValueError("Matrix size fallback contract not recognized")
    return sorted(set(symbols) - SIZE_FALLBACK)


def inspect_aar(path):
    identity = file_identity(path)
    if identity["sha256"] != AAR_SHA:
        raise ValueError("locked OpenSSL AAR hash mismatch")
    with zipfile.ZipFile(path) as archive:
        names = archive.namelist()
        matches = [name for name in names if
                   name.endswith("/arm64-v8a/libcrypto.so") or
                   name.endswith("/android.arm64-v8a/libcrypto.so")]
        if len(matches) != 1 or len(names) != len(set(names)):
            raise ValueError("ambiguous AAR ARM64 libcrypto")
        entry = archive.getinfo(matches[0])
        if entry.file_size > MAX_LIBRARY:
            raise ValueError("oversized AAR libcrypto")
        payload = archive.read(entry)
    if file_identity(path) != identity:
        raise ValueError("AAR changed during inspection")
    return {**identity, "entry": matches[0], "library_sha256": digest(payload),
            "elf": inspect_elf(payload)}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    for flag in ("source", "final", "baseline", "aar", "ffi", "output"):
        parser.add_argument("--" + flag, required=True, type=Path)
    args = parser.parse_args(argv)
    try:
        for path in (args.source, args.final, args.baseline, args.aar, args.ffi):
            if not path.is_file():
                raise ValueError("required input missing: " + str(path))
        if args.output.exists():
            raise ValueError("output already exists; preserve historical evidence")
        if args.source.resolve() == args.final.resolve():
            raise ValueError("source and final must be distinct artifacts")
        if file_identity(args.baseline)["sha256"] != BASELINE_SHA:
            raise ValueError("official 2213 baseline hash mismatch")
        source, final, baseline = (inspect_apk(path) for path in
                                   (args.source, args.final, args.baseline))
        if any(CRYPTO not in item["libraries"] for item in (source, final, baseline)):
            raise ValueError("required libcrypto missing")
        aar = inspect_aar(args.aar)
        ffi_identity = file_identity(args.ffi)
        required = ffi_symbols(args.ffi)
        if file_identity(args.ffi) != ffi_identity:
            raise ValueError("Matrix FFI input changed")
        crypto = final["libraries"][CRYPTO]
        old_crypto = baseline["libraries"][CRYPTO]
        contract = symbol_contract(crypto["elf"]["exports"], required)
        correspondence = compare_libraries(source["libraries"], final["libraries"])
        load_failures = [name for name, item in final["libraries"].items()
                         if not item["elf"]["loads_16k"]]
        relro_failures = [name for name, item in final["libraries"].items()
                          if not item["elf"]["relro_16k"]]
        zip_failures = [name for name, item in final["libraries"].items()
                        if item["zip"]["aligned_16k"] is False]
        compressed = [name for name, item in final["libraries"].items()
                      if item["zip"]["aligned_16k"] is None]
        projection = ("allocated_sections", "exports", "soname", "needed")
        aar_comparison = {field: crypto["elf"][field] == aar["elf"][field]
                          for field in projection}
        report = {
            "created_utc": datetime.now(timezone.utc).isoformat(),
            "scope": "Static ELF/ZIP/byte correspondence only; no runtime, signature or device acceptance",
            "official_reference": "https://developer.android.com/guide/practices/page-sizes",
            "source": source, "final": final, "baseline_2213": baseline,
            "locked_aar": aar, "matrix_ffi": ffi_identity,
            "source_final_native_bytes": correspondence,
            "final_libcrypto_matches_2213": crypto["sha256"] == old_crypto["sha256"],
            "aar_raw_bytes_equal": crypto["sha256"] == aar["library_sha256"],
            "aar_strip_aware_projection_equal": aar_comparison,
            "matrix_symbols": contract,
            "final_elf_load_failures": load_failures,
            "final_elf_relro_end_nonzero_observations": relro_failures,
            "relro_observation_limits": (
                "Official end-modulo formula and writable PT_LOAD geometry only; "
                "not a reproduced loader or device failure. Actual Bionic page "
                "protection, compatibility mode and execution are not tested."),
            "final_zip_stored_alignment_failures": zip_failures,
            "final_zip_compressed_not_direct_mmap": compressed,
            "static_16k_checks_pass": not (load_failures or relro_failures or
                                           zip_failures or compressed),
            "runtime_16k_verified": False,
            "known_libcrypto_load_alignment_p1_retained": CRYPTO in load_failures}
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
        # Report creation is not compatibility PASS. Known ELF failures remain
        # nonzero even if ZIP alignment, symbols and byte correspondence pass.
        return 0 if (report["static_16k_checks_pass"] and correspondence["identical"]
                     and contract["satisfied"] and all(aar_comparison.values())
                     and report["final_libcrypto_matches_2213"]) else 1
    except (OSError, ValueError, zipfile.BadZipFile, struct.error) as error:
        print("INSPECTION_INCOMPLETE: " + str(error), file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
