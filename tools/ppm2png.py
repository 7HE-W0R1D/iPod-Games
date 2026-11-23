# 把 176x132 的 PPM 放大 3 倍存成 PNG（只用标准库）
import sys, zlib, struct
src, dst, k = sys.argv[1], sys.argv[2], 3
data = open(src, 'rb').read()
parts = data.split(b'\n', 3)
w, h = map(int, parts[1].split()); px = parts[3]
rows = []
for y in range(h):
    line = px[y*w*3:(y+1)*w*3]
    big = b''.join(line[i:i+3]*k for i in range(0, len(line), 3))
    rows += [b'\x00' + big] * k
def chunk(t, d): return struct.pack('>I', len(d)) + t + d + struct.pack('>I', zlib.crc32(t + d) & 0xffffffff)
png = b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', w*k, h*k, 8, 2, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(b''.join(rows))) + chunk(b'IEND', b'')
open(dst, 'wb').write(png)
