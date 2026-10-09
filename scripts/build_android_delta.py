#!/usr/bin/env python3
"""CFDELTA1: bounded ZIP-payload copy/add, zlib transport, exact signed APK bytes.

No APK parsing/decompression during application. This does not sign or publish
releases. The JSON descriptor must separately be signed by the APK signing key
(SHA256withRSA over exact UTF-8 JSON) before the Android client accepts it.
"""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import struct
import tracemalloc
import zipfile
import zlib

BUFFER_SIZE = 65536
MAX_APK_SIZE = 512 * 1024 * 1024
MAX_OPERATIONS = 100000
HEADER = struct.Struct('>8sQQ32s32sI')
MAGIC = b'CFDELTA1'


def digest(path):
    h = hashlib.sha256()
    with open(path, 'rb') as stream:
        for block in iter(lambda: stream.read(BUFFER_SIZE), b''):
            h.update(block)
    return h.hexdigest()


def ranges(path):
    """Only compressed ZIP payload bytes are reusable; headers/signing stay new."""
    size = Path(path).stat().st_size
    result = []
    with zipfile.ZipFile(path) as archive, open(path, 'rb') as stream:
        if len(archive.infolist()) > 20000:
            raise ValueError('too many ZIP entries')
        for entry in archive.infolist():
            stream.seek(entry.header_offset)
            header = stream.read(30)
            if len(header) != 30 or header[:4] != b'PK\x03\x04':
                raise ValueError('invalid ZIP local header')
            name, extra = struct.unpack_from('<HH', header, 26)
            offset = entry.header_offset + 30 + name + extra
            length = entry.compress_size
            if length < 0 or offset < 0 or length > size - offset:
                raise ValueError('ZIP range outside file')
            stream.seek(offset)
            h = hashlib.sha256()
            remaining = length
            while remaining:
                block = stream.read(min(BUFFER_SIZE, remaining))
                if not block:
                    raise ValueError('truncated ZIP')
                h.update(block)
                remaining -= len(block)
            result.append((offset, length, h.digest()))
    return sorted(result)


def build_delta(base, target, patch):
    base, target, patch = map(Path, (base, target, patch))
    if patch.resolve() in (base.resolve(), target.resolve()):
        raise ValueError('patch must not overwrite inputs')
    base_size, target_size = base.stat().st_size, target.stat().st_size
    if not 0 < base_size <= MAX_APK_SIZE or not 0 < target_size <= MAX_APK_SIZE:
        raise ValueError('APK size limit')
    old = {(length, sha): offset for offset, length, sha in ranges(base) if length >= 64}
    operations, position, copied = [], 0, 0
    for offset, length, sha in ranges(target):
        source = old.get((length, sha))
        if source is None or offset < position:
            continue
        if offset > position:
            operations.append((1, position, offset - position))
        operations.append((0, source, length))
        copied += length
        position = offset + length
    if position < target_size:
        operations.append((1, position, target_size - position))
    if not 0 < len(operations) <= MAX_OPERATIONS:
        raise ValueError('operation limit')
    base_sha, target_sha = digest(base), digest(target)
    part = patch.with_name(patch.name + '.part')
    try:
        with open(part, 'wb') as out, open(target, 'rb') as source:
            out.write(HEADER.pack(MAGIC, base_size, target_size, bytes.fromhex(base_sha), bytes.fromhex(target_sha), len(operations)))
            compressor = zlib.compressobj(9)
            for kind, offset, length in operations:
                out.write(compressor.compress(bytes([kind]) + (struct.pack('>QQ', offset, length) if kind == 0 else struct.pack('>Q', length))))
                if kind == 1:
                    source.seek(offset)
                    remaining = length
                    while remaining:
                        block = source.read(min(BUFFER_SIZE, remaining))
                        if not block:
                            raise ValueError('target changed during generation')
                        out.write(compressor.compress(block))
                        remaining -= len(block)
            out.write(compressor.flush())
            out.flush()
            os.fsync(out.fileno())
        if digest(base) != base_sha or digest(target) != target_sha:
            raise ValueError('inputs changed during generation')
        os.replace(part, patch)
    finally:
        part.unlink(missing_ok=True)
    size = patch.stat().st_size
    return dict(format='CFDELTA1', base_size=base_size, target_size=target_size,
                base_sha256=base_sha, target_sha256=target_sha, patch_size=size,
                patch_sha256=digest(patch), copied_bytes=copied,
                operations=len(operations), eligible=size * 5 < target_size * 4)


class ZlibReader:
    def __init__(self, stream):
        self.stream, self.z = stream, zlib.decompressobj()
        self.pending = b''
        self.buffer = b''

    def read(self, length):
        if length > BUFFER_SIZE:
            raise ValueError('read limit')
        while len(self.buffer) < length and not self.z.eof:
            block = self.pending or self.stream.read(BUFFER_SIZE)
            if not block:
                raise EOFError('truncated zlib')
            try:
                data = self.z.decompress(block, BUFFER_SIZE - len(self.buffer))
            except zlib.error as error:
                raise ValueError('corrupt zlib') from error
            self.pending = self.z.unconsumed_tail
            self.buffer += data
        if len(self.buffer) < length:
            raise EOFError('truncated command')
        result, self.buffer = self.buffer[:length], self.buffer[length:]
        return result

    def finish(self):
        if self.buffer:
            raise ValueError('extra operations')
        while not self.z.eof:
            block = self.pending or self.stream.read(BUFFER_SIZE)
            if not block:
                raise EOFError('truncated zlib')
            try:
                if self.z.decompress(block, 1):
                    raise ValueError('extra operations')
            except zlib.error as error:
                raise ValueError('corrupt zlib') from error
            self.pending = self.z.unconsumed_tail
        if self.z.unused_data or self.stream.read(1):
            raise ValueError('trailing compressed data')


def apply_delta(base, patch, output):
    base, patch, output = map(Path, (base, patch, output))
    if output.resolve() in (base.resolve(), patch.resolve()):
        raise ValueError('output must not overwrite inputs')
    part = output.with_name(output.name + '.part')
    try:
        with open(patch, 'rb') as encoded, open(base, 'rb') as old:
            header = encoded.read(HEADER.size)
            if len(header) != HEADER.size:
                raise EOFError('truncated header')
            magic, old_size, size, old_sha, new_sha, count = HEADER.unpack(header)
            if magic != MAGIC or not 0 < old_size <= MAX_APK_SIZE or not 0 < size <= MAX_APK_SIZE or not 0 < count <= MAX_OPERATIONS:
                raise ValueError('invalid header bounds')
            if base.stat().st_size != old_size or bytes.fromhex(digest(base)) != old_sha:
                raise ValueError('wrong installed base')
            reader = ZlibReader(encoded)
            written, h = 0, hashlib.sha256()
            with open(part, 'wb') as out:
                for _ in range(count):
                    kind = reader.read(1)[0]
                    if kind == 0:
                        offset, length = struct.unpack('>QQ', reader.read(16))
                        if offset > old_size or length > old_size - offset:
                            raise ValueError('copy outside base')
                        old.seek(offset)
                    elif kind == 1:
                        length, = struct.unpack('>Q', reader.read(8))
                    else:
                        raise ValueError('unsupported operation')
                    if length == 0 or length > size - written:
                        raise ValueError('output limit')
                    remaining = length
                    while remaining:
                        chunk = min(BUFFER_SIZE, remaining)
                        block = old.read(chunk) if kind == 0 else reader.read(chunk)
                        if len(block) != chunk:
                            raise EOFError('truncated base')
                        out.write(block)
                        h.update(block)
                        remaining -= chunk
                    written += length
                reader.finish()
                if written != size or h.digest() != new_sha:
                    raise ValueError('target size/hash mismatch')
                out.flush()
                os.fsync(out.fileno())
        os.replace(part, output)
    finally:
        part.unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--base', required=True, type=Path)
    parser.add_argument('--target', required=True, type=Path)
    parser.add_argument('--patch', required=True, type=Path)
    parser.add_argument('--verify-output', type=Path)
    parser.add_argument('--descriptor', type=Path)
    parser.add_argument('--package-name')
    parser.add_argument('--target-build', type=int)
    parser.add_argument('--certificate-sha256')
    parser.add_argument('--patch-url')
    parser.add_argument('--signature-file', type=Path, help='Detached SHA256withRSA signature from the approved APK signer; no private key is read')
    parser.add_argument('--envelope-output', type=Path)
    parser.add_argument('--measure-memory', action='store_true')
    args = parser.parse_args()
    if args.measure_memory:
        tracemalloc.start()
    info = build_delta(args.base, args.target, args.patch)
    if args.verify_output:
        apply_delta(args.base, args.patch, args.verify_output)
    if args.descriptor:
        if not all((args.package_name, args.target_build, args.certificate_sha256, args.patch_url)):
            parser.error('descriptor requires package/build/certificate/URL')
        descriptor = {k: info[k] for k in ('format', 'base_size', 'target_size', 'base_sha256', 'target_sha256', 'patch_size', 'patch_sha256')}
        descriptor.update(package_name=args.package_name, target_build=args.target_build, certificate_sha256=args.certificate_sha256, patch_url=args.patch_url)
        args.descriptor.write_text(json.dumps(descriptor, sort_keys=True, separators=(',', ':')), encoding='utf-8')
    if args.envelope_output:
        if not args.descriptor or not args.signature_file:
            parser.error('envelope requires descriptor and externally produced signature file')
        signature = args.signature_file.read_bytes()
        if not 64 <= len(signature) <= 1024:
            parser.error('invalid detached RSA signature size')
        args.envelope_output.write_text(json.dumps({'signed_payload': args.descriptor.read_text(encoding='utf-8'),
            'signature': base64.b64encode(signature).decode('ascii')}, separators=(',', ':')), encoding='utf-8')
    if args.measure_memory:
        info['python_peak_working_bytes'] = tracemalloc.get_traced_memory()[1]
        tracemalloc.stop()
    print(json.dumps(info, indent=2))


if __name__ == '__main__':
    main()
