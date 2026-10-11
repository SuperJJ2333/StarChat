import struct
import tempfile
import unittest
import zipfile
from pathlib import Path

import inspect_native as subject


def elf(*, align=16384, relro_end=16384, exports=("EVP_Digest",),
        undefined=(), debug=b"debug"):
    # Small ELF64 ET_DYN fixture with real program/section/dynamic/symbol tables.
    strings = b"\0libcrypto.so\0libc.so\0" + b"".join(
        name.encode() + b"\0" for name in exports + undefined)
    symbols = bytes(24)
    for name in exports + undefined:
        symbols += struct.pack("<IBBHQQ", strings.index(name.encode() + b"\0"),
                               0x12, 0, 1 if name in exports else 0, 0x800, 4)
    dynamic = struct.pack("<qQqQqQ", 14, 1, 1, 14, 0, 0)
    names = b"\0.dynstr\0.dynsym\0.dynamic\0.shstrtab\0.debug\0"
    data = bytearray(0x1000)
    section_offset = 0xC00
    data[:64] = struct.pack("<16sHHIQQQIHHHHHH",
        b"\x7fELF\x02\x01\x01" + bytes(9), 3, 183, 1, 0, 64,
        section_offset, 0, 64, 56, 2, 64, 6, 4)
    data[64:120] = struct.pack("<IIQQQQQQ", 1, 6, 0, 0, 0,
                               len(data), 0x8000, align)
    data[120:176] = struct.pack("<IIQQQQQQ", 0x6474E552, 4, 0, 0x2000, 0,
                               0, relro_end - 0x2000, 1)
    sections = [(0, 0, 0, 0, 0, 0, 0, 0, 0, 0)]
    for name, typ, flags, offset, payload, link, entsize in [
        (".dynstr", 3, 2, 0x200, strings, 0, 0),
        (".dynsym", 11, 2, 0x300, symbols, 1, 24),
        (".dynamic", 6, 2, 0x600, dynamic, 1, 16),
        (".shstrtab", 3, 0, 0x700, names, 0, 0),
        (".debug", 1, 0, 0x900, debug, 0, 0),
    ]:
        data[offset:offset + len(payload)] = payload
        sections.append((names.index(name.encode() + b"\0"), typ, flags,
                         offset, offset, len(payload), link, 0, 8, entsize))
    for i, section in enumerate(sections):
        struct.pack_into("<IIQQQQIIQQ", data, section_offset + i * 64, *section)
    return bytes(data)


def apk(path, data, *, aligned=True, duplicate=False, compressed=False):
    name = "lib/arm64-v8a/libcrypto.so"
    with zipfile.ZipFile(path, "w") as archive:
        info = zipfile.ZipInfo(name)
        if aligned:
            padding = (-(30 + len(name) + 4)) % 16384
            info.extra = struct.pack("<HH", 0xCAFE, padding) + bytes(padding)
        info.compress_type = zipfile.ZIP_DEFLATED if compressed else zipfile.ZIP_STORED
        archive.writestr(info, data)
        if duplicate:
            archive.writestr(name, data)


class NativeInspectionTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(dir=Path(__file__).parent)
        self.addCleanup(self.tmp.cleanup)
        self.path = Path(self.tmp.name) / "fixture.apk"

    def test_zip_16k_never_hides_elf_4k_and_relro_failure(self):
        apk(self.path, elf(align=4096, relro_end=12288))
        result = subject.inspect_apk(self.path)
        library = result["libraries"]["lib/arm64-v8a/libcrypto.so"]
        self.assertTrue(library["zip"]["aligned_16k"])
        self.assertFalse(library["elf"]["loads_16k"])
        self.assertFalse(library["elf"]["relro_16k"])
        self.assertEqual(library["elf"]["relro"][0]["end_mod_16k"], 12288)

    def test_relro_failure_is_independent_of_load_alignment(self):
        result = subject.inspect_elf(elf(relro_end=12288))
        self.assertTrue(result["loads_16k"])
        self.assertFalse(result["relro_16k"])

    def test_relro_rounding_reports_actual_writable_load_intersection(self):
        result = subject.inspect_elf(elf(relro_end=12288))
        relro = result["relro"][0]
        self.assertEqual(relro["page_end_16k"], 16384)
        self.assertEqual(relro["writable_load_intersections_after_end"],
                         [{"start": 12288, "end": 16384, "load_index": 0}])

    def test_compressed_native_zip_is_not_direct_mmap_alignment_pass(self):
        apk(self.path, elf(), compressed=True)
        native = subject.inspect_apk(self.path)["libraries"]
        self.assertIsNone(native["lib/arm64-v8a/libcrypto.so"]["zip"]["aligned_16k"])

    def test_duplicate_native_zip_is_rejected(self):
        with self.assertWarns(UserWarning):
            apk(self.path, elf(), duplicate=True)
        with self.assertRaisesRegex(ValueError, "duplicate"):
            subject.inspect_apk(self.path)

    def test_truncated_and_wrong_machine_elf_are_rejected(self):
        for data in [elf()[:90], elf()[:18] + b"\x3e\x00" + elf()[20:]]:
            with self.assertRaises(ValueError):
                subject.inspect_elf(data)

    def test_byte_comparison_does_not_ignore_changed_or_missing_library(self):
        left = {"a.so": {"sha256": "one"}, "b.so": {"sha256": "two"}}
        right = {"a.so": {"sha256": "changed"}, "c.so": {"sha256": "two"}}
        comparison = subject.compare_libraries(left, right)
        self.assertFalse(comparison["identical"])
        self.assertEqual(comparison["changed"], ["a.so"])
        self.assertEqual(comparison["missing"], ["b.so"])
        self.assertEqual(comparison["added"], ["c.so"])

    def test_nonallocated_strip_difference_is_not_runtime_section_difference(self):
        first = subject.inspect_elf(elf(debug=b"symbols"))
        second = subject.inspect_elf(elf(debug=b"removed"))
        self.assertEqual(first["allocated_sections"], second["allocated_sections"])
        self.assertEqual(first["soname"], "libcrypto.so")
        self.assertEqual(first["needed"], ["libc.so"])

    def test_undefined_symbol_is_not_an_export(self):
        result = subject.inspect_elf(elf(exports=("EVP_Digest",),
                                        undefined=("EVP_sha512",)))
        self.assertIn("EVP_Digest", result["exports"])
        self.assertNotIn("EVP_sha512", result["exports"])

    def test_matrix_fallback_accepts_one_size_symbol_but_not_missing_required(self):
        required = ["EVP_Digest"]
        self.assertTrue(subject.symbol_contract(
            ["EVP_Digest", "EVP_MD_size"], required)["satisfied"])
        self.assertTrue(subject.symbol_contract(
            ["EVP_Digest", "EVP_MD_get_size"], required)["satisfied"])
        self.assertFalse(subject.symbol_contract(
            ["EVP_MD_size"], required)["satisfied"])
        self.assertFalse(subject.symbol_contract(
            ["EVP_Digest"], required)["satisfied"])

    def test_missing_input_never_creates_success_report(self):
        output = Path(self.tmp.name) / "report.json"
        result = subject.main(["--source", str(self.path), "--final",
            str(self.path), "--baseline", str(self.path), "--aar", str(self.path),
            "--ffi", str(self.path), "--output", str(output)])
        self.assertEqual(result, 2)
        self.assertFalse(output.exists())


if __name__ == "__main__":
    unittest.main(verbosity=2)
