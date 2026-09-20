"""Runtime metadata survives stripping; unrelated selectors must not satisfy gates."""
import importlib.util
import struct
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("permission_metadata", ROOT / "scripts/check_ios_permission_binary.py")
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)
REQUEST = "requestPermission:completionHandler:errorHandler:"
REQUIRED = {
    "AudioVideoPermissionStrategy": [REQUEST, "checkPermissionStatus:"],
    "PhotoPermissionStrategy": [REQUEST],
    "NotificationPermissionStrategy": [REQUEST],
}


def macho(classes=None, *, relative=False, direct=False, chained=False, zero_imp=False, data_imp=False, metaclass=False):
    classes = REQUIRED if classes is None else classes
    blob = bytearray(0x2000)
    base = 0x100000000
    cursor = 0x440
    pointers = []

    def alloc(size):
        nonlocal cursor
        cursor = (cursor + 7) & ~7
        result = cursor
        cursor += size
        return result

    def string(value):
        encoded = value.encode() + b"\0"
        result = alloc(len(encoded))
        blob[result:result + len(encoded)] = encoded
        return result

    def pointer(offset, target):
        struct.pack_into("<Q", blob, offset, base + target if target else 0)
        if target:
            pointers.append(offset)

    for index, (name, methods) in enumerate(classes.items()):
        cls, ro = alloc(40), alloc(72)
        pointer(0x400 + index * 8, cls)
        pointer(cls + 32, ro)
        struct.pack_into("<I", blob, ro, int(metaclass))
        pointer(ro + 24, string(name))
        if not methods:
            continue
        size = 12 if relative else 24
        table = alloc(8 + size * len(methods))
        pointer(ro + 32, table)
        flags = (0x80000000 | (0x40000000 if direct else 0)) if relative else 0
        struct.pack_into("<II", blob, table, flags | size, len(methods))
        for number, selector in enumerate(methods):
            entry = table + 8 + number * size
            name_offset = string(selector)
            imp = 0 if zero_imp else (0x410 if data_imp else 0x300)
            if relative:
                if not direct:
                    ref = alloc(8)
                    pointer(ref, name_offset)
                    name_offset = ref
                struct.pack_into("<iii", blob, entry, name_offset - entry, 0, (imp - entry - 8) if imp else 0)
            else:
                pointer(entry, name_offset)
                pointer(entry + 16, imp)

    text = struct.pack("<II16sQQQQiiII", 0x19, 72, b"__TEXT", base, 0x400, 0, 0x400, 5, 5, 0, 0)
    data = struct.pack("<II16sQQQQiiII", 0x19, 152, b"__DATA", base + 0x400, 0x1400, 0x400, 0x1400, 3, 3, 1, 0)
    data += struct.pack("<16s16sQQIIIIIIII", b"__objc_classlist", b"__DATA", base + 0x400, len(classes) * 8, 0x400, 3, 0, 0, 0, 0, 0, 0)
    commands = text + data
    if chained:
        pointers.sort()
        for index, offset in enumerate(pointers):
            target = struct.unpack_from("<Q", blob, offset)[0] - base
            next_delta = (pointers[index + 1] - offset) // 4 if index + 1 < len(pointers) else 0
            struct.pack_into("<Q", blob, offset, target | (next_delta << 51))
        fixups = struct.pack("<7I", 0, 28, 64, 64, 0, 1, 0)
        fixups += struct.pack("<3I", 2, 0, 12)
        fixups += struct.pack("<IHHQIHH", 24, 4096, 6, 0x400, 0, 1, 0)
        blob[0x1800:0x1800 + len(fixups)] = fixups
        commands += struct.pack("<4I", 0x80000034, 16, 0x1800, len(fixups))
    struct.pack_into("<IiiIIIII", blob, 0, 0xFEEDFACF, 0x100000C, 0, 2, 3 if chained else 2, len(commands), 0, 0)
    blob[32:32 + len(commands)] = commands
    return bytes(blob)


@pytest.mark.parametrize("relative,direct,chained", [(False, False, False), (False, False, True), (True, False, True), (True, True, True)])
def test_stripped_runtime_metadata_passes(relative, direct, chained):
    binary = macho(relative=relative, direct=direct, chained=chained)
    assert b"-[AudioVideoPermissionStrategy" not in binary
    MODULE.verify_permission_binary(binary)


def test_placeholder_classes_cannot_borrow_other_class_methods():
    classes = {name: [] for name in REQUIRED}
    classes["UnrelatedStrategy"] = [REQUEST, "checkPermissionStatus:"]
    with pytest.raises(ValueError, match="AudioVideoPermissionStrategy"):
        MODULE.verify_permission_binary(macho(classes))


@pytest.mark.parametrize("relative", [False, True])
@pytest.mark.parametrize("option", ["zero_imp", "data_imp", "metaclass"])
def test_missing_executable_instance_implementation_fails(option, relative):
    with pytest.raises(ValueError):
        MODULE.verify_permission_binary(macho(relative=relative, direct=relative, chained=True, **{option: True}))


@pytest.mark.parametrize("binary", [b"", b"-[AudioVideoPermissionStrategy checkPermissionStatus:]\0", macho()[:100]])
def test_invalid_or_string_only_input_fails_closed(binary):
    with pytest.raises(ValueError):
        MODULE.verify_permission_binary(binary)


def test_unknown_chained_pointer_format_fails_closed():
    binary = bytearray(macho(chained=True))
    struct.pack_into("<H", binary, 0x1800 + 28 + 12 + 6, 99)
    with pytest.raises(ValueError, match="pointer format"):
        MODULE.verify_permission_binary(bytes(binary))


def test_each_required_selector_is_bound_to_its_class():
    for name, selectors in REQUIRED.items():
        for selector in selectors:
            classes = {key: list(value) for key, value in REQUIRED.items()}
            classes[name].remove(selector)
            with pytest.raises(ValueError):
                MODULE.verify_permission_binary(macho(classes, relative=True, direct=True, chained=True))


def test_old_symbol_strings_cannot_rescue_empty_method_tables():
    binary = macho({name: [] for name in REQUIRED})
    binary += b"\0".join(method.encode() for method in MODULE.REQUIRED_METHODS) + b"\0"
    with pytest.raises(ValueError, match="AudioVideoPermissionStrategy"):
        MODULE.verify_permission_binary(binary)


def test_bound_external_pointer_cannot_be_used_as_a_class():
    binary = bytearray(macho(chained=True))
    pointer = struct.unpack_from("<Q", binary, 0x400)[0]
    struct.pack_into("<Q", binary, 0x400, pointer | (1 << 63))
    with pytest.raises(ValueError, match="external binding"):
        MODULE.verify_permission_binary(bytes(binary))


def test_malformed_chain_cannot_escape_page():
    binary = bytearray(macho(chained=True))
    pointer = struct.unpack_from("<Q", binary, 0x400)[0]
    struct.pack_into("<Q", binary, 0x400, (pointer & ((1 << 51) - 1)) | (0xFFF << 51))
    with pytest.raises(ValueError, match="outside its page"):
        MODULE.verify_permission_binary(bytes(binary))
