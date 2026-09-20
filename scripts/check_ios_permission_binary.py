"""Check actual ObjC instance method tables, independent of stripped symbols.

The shipped candidate is a thin arm64 Mach-O. Read its class list, class_ro_t
and method_list_t using file-backed VM mappings, resolving dyld's 64/64_OFFSET
chained rebases. Unsupported layouts fail closed rather than guessing pointers.
No dylibs are loaded and neither the binary nor its signature is modified.
"""
from pathlib import Path
import struct
import sys

REQUIRED_METHODS = (
    "-[AudioVideoPermissionStrategy requestPermission:completionHandler:errorHandler:]",
    "-[AudioVideoPermissionStrategy checkPermissionStatus:]",
    "-[PhotoPermissionStrategy requestPermission:completionHandler:errorHandler:]",
    "-[NotificationPermissionStrategy requestPermission:completionHandler:errorHandler:]",
)


class ObjCMetadata:
    def __init__(self, binary: bytes):
        self.binary = binary
        self.segments = []
        self.sections = []
        self.rebases = {}
        magic, cpu, _, filetype, count, command_bytes, _, _ = self.unpack("<IiiIIIII", 0)
        if magic != 0xFEEDFACF or cpu != 0x100000C or filetype != 2:
            raise ValueError("Expected thin arm64 Mach-O executable")
        self.checked(32, command_bytes)
        offset = 32
        fixups = None
        for _ in range(count):
            command, size = self.unpack("<II", offset)
            if size < 8 or offset + size > 32 + command_bytes:
                raise ValueError("Invalid Mach-O load command")
            if command == 0x19:  # LC_SEGMENT_64
                if size < 72:
                    raise ValueError("Truncated segment")
                (_, _, name, vmaddr, vmsize, fileoff, filesize,
                 _, protection, section_count, _) = self.unpack("<II16sQQQQiiII", offset)
                if size != 72 + section_count * 80 or filesize > vmsize:
                    raise ValueError("Invalid segment layout")
                self.checked(fileoff, filesize)
                self.segments.append((vmaddr, vmsize, fileoff, filesize, protection))
                for index in range(section_count):
                    fields = self.unpack("<16s16sQQIIIIIIII", offset + 72 + index * 80)
                    section, _, address, length, section_fileoff = fields[:5]
                    if section.rstrip(b"\0") == b"__objc_classlist":
                        if not (vmaddr <= address and address + length <= vmaddr + filesize):
                            raise ValueError("ObjC class list outside file-backed segment")
                        if section_fileoff != fileoff + address - vmaddr or length % 8:
                            raise ValueError("Invalid ObjC class list")
                        self.sections.append((address, length))
            elif command == 0x80000034:  # LC_DYLD_CHAINED_FIXUPS
                if size != 16 or fixups is not None:
                    raise ValueError("Invalid chained fixup command")
                fixups = self.unpack("<II", offset + 8)
            offset += size
        if offset != 32 + command_bytes:
            raise ValueError("Invalid Mach-O command size")
        bases = [vm for vm, _, fileoff, filesize, _ in self.segments if fileoff == 0 and filesize]
        if len(bases) != 1 or not self.sections:
            raise ValueError("Missing image base or ObjC class list")
        self.base = bases[0]
        if fixups:
            self.read_fixups(*fixups)

    def checked(self, offset, size):
        if offset < 0 or size < 0 or offset + size > len(self.binary):
            raise ValueError("Truncated Mach-O metadata")
        return offset

    def unpack(self, fmt, offset):
        self.checked(offset, struct.calcsize(fmt))
        return struct.unpack_from(fmt, self.binary, offset)

    def file_offset(self, address, size=1):
        for vm, _, fileoff, filesize, _ in self.segments:
            if vm <= address and address + size <= vm + filesize:
                return fileoff + address - vm
        raise ValueError("ObjC pointer outside file-backed segments")

    def pointer(self, address):
        if address in self.rebases:
            target = self.rebases[address]
            if target is None:
                raise ValueError("Unexpected external binding in ObjC metadata")
            return target
        return self.unpack("<Q", self.file_offset(address, 8))[0]

    def string(self, address):
        offset = self.file_offset(address)
        # Names/selectors are small; a missing terminator is malformed input.
        end = self.binary.find(b"\0", offset, min(offset + 4096, len(self.binary)))
        if end < 0:
            raise ValueError("Unterminated ObjC string")
        self.file_offset(address, end - offset + 1)
        try:
            return self.binary[offset:end].decode("utf-8")
        except UnicodeDecodeError as error:
            raise ValueError("Invalid ObjC string") from error

    def read_fixups(self, start, length):
        self.checked(start, length)
        if length < 28:
            raise ValueError("Truncated chained fixups")

        def read(fmt, relative):
            if relative < 0 or relative + struct.calcsize(fmt) > length:
                raise ValueError("Chained fixups exceed payload")
            return self.unpack(fmt, start + relative)

        version, starts, _, _, _, _, _ = read("<7I", 0)
        if version != 0:
            raise ValueError("Unsupported chained fixup version")
        count = read("<I", starts)[0]
        if count > len(self.segments):
            raise ValueError("Invalid chained segment count")
        for index in range(count):
            relative = read("<I", starts + 4 + index * 4)[0]
            if not relative:
                continue
            info = starts + relative
            size, page_size, pointer_format, segment_offset, _, page_count = read("<IHHQIH", info)
            if pointer_format not in (2, 6):
                raise ValueError(f"Unsupported chained pointer format: {pointer_format}")
            if size < 22 + page_count * 2 or info + size > length or page_size not in (4096, 16384):
                raise ValueError("Invalid chained page table")
            vm, vmsize, _, _, _ = self.segments[index]
            if self.base + segment_offset != vm or page_count * page_size > vmsize + page_size - 1:
                raise ValueError("Chained segment address mismatch")
            for page in range(page_count):
                first = read("<H", info + 22 + page * 2)[0]
                if first == 0xFFFF:
                    continue
                starts_in_page = [first]
                if first & 0x8000:  # DYLD_CHAINED_PTR_START_MULTI
                    starts_in_page = []
                    overflow = first & 0x7FFF
                    while True:
                        if 22 + overflow * 2 + 2 > size:
                            raise ValueError("Invalid chained multi-start table")
                        item = read("<H", info + 22 + overflow * 2)[0]
                        starts_in_page.append(item & 0x7FFF)
                        overflow += 1
                        if item & 0x8000:
                            break
                page_base = vm + page * page_size
                for first in starts_in_page:
                    address = page_base + first
                    while True:
                        if not (page_base <= address and address + 8 <= page_base + page_size):
                            raise ValueError("Chained pointer outside its page")
                        if address in self.rebases:
                            raise ValueError("Overlapping chained pointer entries")
                        raw = self.unpack("<Q", self.file_offset(address, 8))[0]
                        delta = ((raw >> 51) & 0xFFF) * 4
                        if raw >> 63:  # bind to external image; never valid for checked methods
                            target = None
                        else:
                            low = raw & ((1 << 36) - 1)
                            high = ((raw >> 36) & 0xFF) << 56
                            target = (low + (self.base if pointer_format == 6 else 0)) | high
                        self.rebases[address] = target
                        if not delta:
                            break
                        address += delta

    def executable(self, address):
        return address != 0 and any(
            protection & 4 and vm <= address < vm + filesize
            for vm, _, _, filesize, protection in self.segments
        )

    def instance_methods(self, wanted_classes):
        result = {}
        for section, length in self.sections:
            for entry in range(section, section + length, 8):
                cls = self.pointer(entry)
                # class_t.data has runtime flags in its low bits.
                ro = self.pointer(cls + 32) & ~7
                flags = self.unpack("<I", self.file_offset(ro, 40))[0]
                name = self.string(self.pointer(ro + 24))
                if name not in wanted_classes:
                    continue
                if flags & 1 or name in result:  # RO_META / duplicate runtime classes
                    raise ValueError("Invalid or duplicate instance class: " + name)
                result[name] = {}
                table = self.pointer(ro + 32)
                if not table:
                    continue
                method_flags, count = self.unpack("<II", self.file_offset(table, 8))
                relative = bool(method_flags & 0x80000000)
                direct_selectors = bool(method_flags & 0x40000000)
                stride = method_flags & 0xFFFF
                if stride != (12 if relative else 24) or count > 100000:
                    raise ValueError("Unsupported ObjC method list layout")
                self.file_offset(table, 8 + count * stride)
                for number in range(count):
                    method = table + 8 + number * stride
                    if relative:
                        name_delta, _, imp_delta = self.unpack("<iii", self.file_offset(method, 12))
                        name_pointer = method + name_delta
                        if not direct_selectors:
                            name_pointer = self.pointer(name_pointer)
                        imp = method + 8 + imp_delta if imp_delta else 0
                    else:
                        name_pointer = self.pointer(method)
                        imp = self.pointer(method + 16)
                    selector = self.string(name_pointer)
                    if selector in result[name]:
                        raise ValueError("Duplicate ObjC method: " + name + " " + selector)
                    result[name][selector] = imp
        return result


def verify_permission_binary(binary: bytes) -> None:
    required = [method[2:-1].split(" ", 1) for method in REQUIRED_METHODS]
    metadata = ObjCMetadata(binary)
    classes = metadata.instance_methods({name for name, _ in required})
    for method, (name, selector) in zip(REQUIRED_METHODS, required):
        if not metadata.executable(classes.get(name, {}).get(selector, 0)):
            raise ValueError("Native permission implementation missing: " + method)


if __name__ == "__main__":
    verify_permission_binary(Path(sys.argv[1]).read_bytes())
    print("Native permission runtime method tables: PASS (camera/microphone/photos/notifications)")
