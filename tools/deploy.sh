#!/bin/sh
# 打包、拷到 iPod，然后自动推出。
# 用法：tools/deploy.sh [--no-eject] [iPod 上的文件夹名，默认 Slow]
# 会自动找挂载着、带 .rockbox 目录的那个盘。
cd "$(dirname "$0")/.." || exit 1

EJECT=1
if [ "$1" = "--no-eject" ]; then EJECT=0; shift; fi
DEST_DIR="${1:-Slow}"

./tools/build.sh || exit 1

IPOD=""
for v in /Volumes/*; do
  if [ -d "$v/.rockbox" ]; then IPOD="$v"; break; fi
done
if [ -z "$IPOD" ]; then
  echo "没找到装了 Rockbox 的 iPod。插上 iPod，确认它在访达里出现了再试。"
  exit 1
fi

mkdir -p "$IPOD/$DEST_DIR" || exit 1
cp dist/*.lua "$IPOD/$DEST_DIR/" || exit 1
sync
echo "已拷到 ${IPOD}/${DEST_DIR}："
ls -l "$IPOD/$DEST_DIR"

if [ "$EJECT" = 1 ]; then
  if diskutil eject "$IPOD"; then
    echo "iPod 已推出，可以拔了。"
  else
    echo "!! 推出失败（可能有程序正在用 iPod 上的文件）。请在访达里手动推出。"
    exit 1
  fi
else
  echo "没有推出。拔之前先在访达里推出 iPod。"
fi
