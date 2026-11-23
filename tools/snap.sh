#!/bin/sh
# 用法：tools/snap.sh dist/flock.lua 帧数 时间偏移 "按键" 输出名  → 把最后一帧放大 3 倍存 PNG
out="${5:-snap}"; d="${TMPDIR:-/tmp}"
SNAP="$d/$out" SNAPAT="$2" lua test/run.lua "$1" "$2" "$3" "$4" >/dev/null || exit 1
python3 -I "$(dirname "$0")/ppm2png.py" "$d/${out}_$2.ppm" "$d/$out.png" && echo "$d/$out.png"
