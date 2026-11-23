#!/bin/sh
# 从 no_upload/Yosemite/ 里的照片重新生成穹顶的场景数据 src/data/dome.lua。
# 照片本身不进仓库；脚本只取轮廓和明暗档位。
cd "$(dirname "$0")/.." || exit 1
TMP="${TMPDIR:-/tmp}/yosemite_bmp"
mkdir -p "$TMP"
for f in no_upload/Yosemite/*.jpg; do
  n=$(basename "$f" .jpg)
  [ -f "$TMP/$n.bmp" ] || sips -s format bmp -z 528 940 "$f" --out "$TMP/$n.bmp" >/dev/null || exit 1
done
python3 -I tools/yosemite.py "$TMP" || exit 1
echo "已生成 src/data/dome.lua，运行 ./tools/build.sh 打包"
