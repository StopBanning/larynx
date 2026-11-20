#!/bin/zsh
# Makes packaging/larynx.ico (the Windows icon, embedded in larynx.exe by windows/build.rs) from the Mac's
# packaging/Larynx.icns, so both platforms carry the same mark. macOS only (iconutil, sips). Run it after changing
# the icon; the result is committed.
set -euo pipefail
cd "$(dirname "$0")/.."
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
iconutil -c iconset packaging/Larynx.icns -o "$tmp/Larynx.iconset"
set="$tmp/Larynx.iconset"
# The icon's own small sizes where it has them; the 256 scaled down for the rest.
cp "$set/icon_16x16.png" "$tmp/p16.png"
cp "$set/icon_32x32.png" "$tmp/p32.png"
cp "$set/icon_32x32@2x.png" "$tmp/p64.png"
cp "$set/icon_256x256.png" "$tmp/p256.png"
for s in 20 24 40 48 96; do sips -z $s $s "$set/icon_256x256.png" --out "$tmp/p$s.png" >/dev/null; done
python3 - "$tmp" packaging/larynx.ico <<'PY'
import struct, sys
tmp, out_path = sys.argv[1], sys.argv[2]
sizes = [16, 20, 24, 32, 40, 48, 64, 96, 256]
data = [open(f"{tmp}/p{s}.png", "rb").read() for s in sizes]
head = struct.pack("<HHH", 0, 1, len(sizes))
offset, body = 6 + 16 * len(sizes), b""
for s, d in zip(sizes, data):
    dim = 0 if s >= 256 else s
    head += struct.pack("<BBBBHHII", dim, dim, 0, 0, 1, 32, len(d), offset)
    offset += len(d)
    body += d
open(out_path, "wb").write(head + body)
print(f"{out_path}: {len(sizes)} sizes, {len(head + body)} bytes")
PY
