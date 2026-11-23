#!/bin/sh
# 把 src/common.lua 拼到每个游戏前面，生成可以直接拷进 iPod 的单文件脚本
cd "$(dirname "$0")/.." || exit 1
mkdir -p dist
for f in src/*.lua; do
  name=$(basename "$f")
  [ "$name" = "common.lua" ] && continue
  data=""
  [ -f "src/data/$name" ] && data="src/data/$name"   # 生成的数据（比如穹顶的照片场景）
  { echo "-- 由 tools/build.sh 生成，改源码请改 src/ 下的文件"; cat src/common.lua; echo; [ -n "$data" ] && { cat "$data"; echo; }; cat "$f"; } > "dist/$name"
  luac -p "dist/$name" || exit 1
  # Rockbox 是 Lua 5.1 的整数版：不允许 5.3+ 的写法
  if cat src/common.lua "$f" | grep -nE '//|[^~]~[^=]|<<|>>|\bgoto\b|::[a-z]' | grep -v -- '--' ; then
    echo "!! $name 里有 Lua 5.1 不支持的写法"; exit 1
  fi
  echo "ok  dist/$name"
done
# Rockbox 的 Lua 每个函数最多 100 个 local、30 个 upvalue
lua tools/check_limits.lua dist/*.lua || { echo "!! 超出 Rockbox Lua 的限制"; exit 1; }
