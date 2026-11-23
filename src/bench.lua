-- 测速：上机跑一次，量出新应用要用的几个速度。不是正式应用。
-- 结果显示在屏幕上，也存进 /.rockbox/rocks.data/slow_bench.txt
-- Select：重测   Menu：退出

local SAVE = "slow_bench.txt"
local CELL = 4
local GW, GH = div(W, CELL), div(H, CELL) -- 44 × 33
local N = GW * GH
local rnd = Rng(rb.current_tick() + now())

local BG, INK, DIM, HI = rgb(18, 22, 28), rgb(225, 230, 235), rgb(110, 120, 130), rgb(240, 200, 90)

-- ---------- 1. 生命游戏：44×33，环形边界，三行列和 ----------
local life_seed, life_gen
do
local L, L2, col = {}, {}, {}
local XL, XR, YU, YD = {}, {}, {}, {}
for x = 0, GW - 1 do XL[x] = mod(x - 1, GW); XR[x] = mod(x + 1, GW) end
for y = 0, GH - 1 do YU[y] = mod(y - 1, GH) * GW + 1; YD[y] = mod(y + 1, GH) * GW + 1 end
local BORN, SURV = { [3] = true }, { [2] = true, [3] = true } -- B3/S23
life_seed = function()
  for i = 1, N do L[i] = (rnd(3) == 0) and 1 or 0; L2[i] = 0 end
end
life_gen = function(draw)
  local a, b = L, L2
  for y = 0, GH - 1 do
    local up, me, dn = YU[y], y * GW + 1, YD[y]
    for x = 0, GW - 1 do col[x] = a[up + x] + a[me + x] + a[dn + x] end
    for x = 0, GW - 1 do
      local i = me + x
      local v = a[i]
      local n = col[XL[x]] + col[x] + col[XR[x]] - v
      local nv = 0
      if v == 1 then
        if SURV[n] then nv = 1 end
      elseif BORN[n] then nv = 1 end
      b[i] = nv
      if draw and nv ~= v then
        fg(nv == 1 and INK or BG)
        rb.lcd_fillrect(x * CELL, y * CELL, CELL, CELL)
      end
    end
  end
  L, L2 = b, a
  if draw then rb.lcd_update() end
end
end

-- ---------- 2. 画格子：每步 100 个 4×4 的 fillrect ----------
local function rect_step()
  for k = 1, 100 do
    fg(mod(k, 2) == 0 and INK or DIM)
    rb.lcd_fillrect(rnd(GW) * CELL, rnd(GH) * CELL, CELL, CELL)
  end
end

-- ---------- 3. 扫格子：落沙规则扫一遍整屏 ----------
local scan_seed, scan_step
do
local G, XC = {}, {}
for i = 1, N do XC[i] = mod(i - 1, GW) end
local gd, count = GW, 0
scan_seed = function()
  for i = 1, N do G[i] = (rnd(5) < 2) and 1 or 0 end
end
local function try(i, d)
  if G[d] == 0 then G[d] = 1; G[i] = 0; return 1 end
  local x = XC[i]
  if x > 0 and G[d - 1] == 0 then G[d - 1] = 1; G[i] = 0; return 1 end
  if x < GW - 1 and G[d + 1] == 0 then G[d + 1] = 1; G[i] = 0; return 1 end
  return 0
end
scan_step = function()
  local moved = 0
  if gd > 0 then
    for i = N - GW, 1, -1 do
      if G[i] == 1 then moved = moved + try(i, i + GW) end
    end
  else
    for i = GW + 1, N do
      if G[i] == 1 then moved = moved + try(i, i - GW) end
    end
  end
  count = count + 1
  if moved == 0 or count >= 30 then gd = -gd; count = 0 end -- 沙静下来就把重力倒过来
end
end

-- ---------- 4. 象棋走法生成：10×12 信箱棋盘，中局，每步生成白方全部走法并走、退 ----------
local board_setup, movegen_step
do
local OFF = 99
local b = {}
local KN = { -21, -19, -12, -8, 8, 12, 19, 21 }
local BI = { -11, -9, 9, 11 }
local RO = { -10, -1, 1, 10 }
local QK = { -11, -10, -9, -1, 1, 9, 10, 11 }
local DIRS = { nil, KN, BI, RO, QK, QK }
local SLIDE = { false, false, true, true, true, false }
local CODE = { p = 1, n = 2, b = 3, r = 4, q = 5, k = 6 }
local POS = { -- 第 8 横排到第 1 横排
  "r.bqk..r", "ppp..ppp", "..n..n..", "...pp.b.",
  "..BPP...", "..N..N..", "PPP..PPP", "R..QK..R",
}
board_setup = function()
  for i = 0, 119 do b[i] = OFF end
  for r = 1, 8 do
    local row = POS[r]
    for c = 1, 8 do
      local ch = string.sub(row, c, c)
      local v = 0
      if ch ~= "." then
        local lo = string.lower(ch)
        v = CODE[lo]
        if lo == ch then v = -v end -- 小写是黑方
      end
      b[(r + 1) * 10 + c] = v
    end
  end
end
local function try(from, to, cap) -- 走一步再退回
  b[to] = b[from]; b[from] = 0
  b[from] = b[to]; b[to] = cap
  return 1
end
movegen_step = function()
  local n = 0
  for sq = 21, 98 do
    local p = b[sq]
    if p ~= OFF and p > 0 then
      if p == 1 then
        if b[sq - 10] == 0 then n = n + try(sq, sq - 10, 0) end
        local t = b[sq - 9]
        if t ~= OFF and t < 0 then n = n + try(sq, sq - 9, t) end
        t = b[sq - 11]
        if t ~= OFF and t < 0 then n = n + try(sq, sq - 11, t) end
      else
        local dirs, slide = DIRS[p], SLIDE[p]
        for d = 1, #dirs do
          local o = dirs[d]
          local to = sq + o
          local t = b[to]
          while t ~= OFF and t <= 0 do
            n = n + try(sq, to, t)
            if t < 0 or not slide then break end
            to = to + o
            t = b[to]
          end
        end
      end
    end
  end
  return n
end
end

-- ---------- 测试表 ----------
-- { 名字, 单位, 准备, 一步, 一步算几个单位, 会不会画满屏幕 }
local TESTS = {
  { "life", "gen/s", life_seed, function() life_gen(false) end, 1, false },
  { "life+lcd", "gen/s", function() fg(BG); rect(0, 0, W, H); life_seed() end, function() life_gen(true) end, 1, true },
  { "rect4", "/s", nil, rect_step, 100, true },
  { "lcd_upd", "/s", nil, rb.lcd_update, 1, true },
  { "scan", "scan/s", scan_seed, scan_step, 1, false },
  { "movegen", "gen/s", board_setup, movegen_step, 1, false },
}
local MEASURE = 2 * HZ   -- 每个测试量 2 秒的纯计算时间
local MAX_FRAMES = 40    -- 桌面测试环境里时钟不走，靠这个结束
local PER_FRAME = 40     -- 每帧最多跑几步，保证 Menu 随时能退出

local results = {}
local cur, units, ticks, frames = 1, 0, 0, 0
local done = false
local moves_per_gen = 0

local function fmt(r10)
  if not r10 then return "?" end
  if r10 >= 1000 then return tostring(div(r10, 10)) end
  return div(r10, 10) .. "." .. mod(r10, 10)
end

local function rate10(u, t)
  if t <= 0 then return nil end
  return div(u * HZ * 10, t)
end

local function mem_k()
  local ok, k = pcall(collectgarbage, "count")
  if ok and type(k) == "number" then return math.floor(k) end
  return nil
end

local function draw_results()
  fg(BG); rect(0, 0, W, H)
  text(4, 2, done and "bench  done" or "bench  running", done and HI or DIM, BG)
  for i, t in ipairs(TESTS) do
    local y = 16 + (i - 1) * 14
    local c = DIM
    local v = "..."
    if results[i] then c = INK; v = fmt(results[i]) .. " " .. t[2]
    elseif i == cur and not done then c = HI end
    text(4, y, t[1], c, BG)
    text_r(W - 4, y, v, c, BG)
  end
  local m = mem_k()
  text(4, H - 26, "moves " .. moves_per_gen .. "  mem " .. (m and (m .. "k") or "?"), DIM, BG)
  text(4, H - 12, done and "select: again" or "menu: quit", DIM, BG)
  rb.lcd_update()
end

local function start(i)
  cur, units, ticks, frames = i, 0, 0, 0
  local t = TESTS[i]
  if t[3] then t[3]() end
  if not t[6] then draw_results() end
end

local function finish()
  results[cur] = rate10(units, ticks)
  if cur < #TESTS then
    start(cur + 1)
  else
    done = true
    local out = { t = now() }
    for i, t in ipairs(TESTS) do out[t[1]] = results[i] and fmt(results[i]) or "?" end
    out.moves = moves_per_gen
    out.mem_k = mem_k() or "?"
    save_kv(SAVE, out)
    draw_results()
  end
end

-- ---------- 主循环 ----------
light_start()
board_setup()
moves_per_gen = movegen_step()
start(1)

local running = true
while running do
  for _, e in ipairs(poll()) do
    if e.k == "menu" and not e.rel then running = false
    elseif done and select_gesture(e) == "short" then
      results = {}
      done = false
      start(1)
    end
  end

  if running and not done then
    local t = TESTS[cur]
    local step, per = t[4], t[5]
    local t0 = rb.current_tick()
    local k = 0
    repeat
      step()
      k = k + 1
    until rb.current_tick() - t0 >= div(HZ, 5) or k >= PER_FRAME
    ticks = ticks + rb.current_tick() - t0
    units = units + k * per
    frames = frames + 1
    if ticks >= MEASURE or frames >= MAX_FRAMES then finish() end
  end

  keep_light()
  rb.sleep(1)
end

light_end()
