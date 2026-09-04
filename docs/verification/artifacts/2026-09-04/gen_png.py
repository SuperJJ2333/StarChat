import base64
import struct
import zlib


def png(r, g, b):
    def chunk(t, d):
        c = t + d
        return struct.pack('>I', len(d)) + c + struct.pack('>I', zlib.crc32(c) & 0xffffffff)

    ihdr = struct.pack('>IIBBBBB', 2, 2, 8, 2, 0, 0, 0)
    raw = b''.join(b'\x00' + bytes([r, g, b]) * 2 for _ in range(2))
    body = chunk(b'IHDR', ihdr) + chunk(b'IDAT', zlib.compress(raw)) + chunk(b'IEND', b'')
    return b'\x89PNG\r\n\x1a\n' + body


for name, rgb in [('BLACK', (0, 0, 0)), ('WHITE', (255, 255, 255)), ('GREY', (8, 8, 8))]:
    print(f'{name}: {base64.b64encode(png(*rgb)).decode()}')
