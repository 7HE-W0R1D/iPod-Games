-- 由 tools/build.sh 生成，改源码请改 src/ 下的文件
-- ==== 共用部分（build.sh 会把它拼到每个游戏前面） ====
-- 注意：Rockbox 的 Lua 只有整数。除法一律用 div()，不要直接写 a / b。

local rb = rb
local W = rb.LCD_WIDTH or 176
local H = rb.LCD_HEIGHT or 132
local HZ = rb.HZ or 100

-- ---------- 整数数学 ----------
local function div(a, b) -- 向下取整的除法，b > 0
  if a >= 0 then return math.floor(a / b) end
  return -math.floor((-a + b - 1) / b)
end
local function mod(a, b) return a - div(a, b) * b end
local function clamp(v, lo, hi)
  if v < lo then return lo elseif v > hi then return hi end
  return v
end
local function iabs(v) if v < 0 then return -v end return v end
local function lerp(a, b, num, den) return a + div((b - a) * num, den) end

-- 小随机数发生器（ZX81 式线性同余，不会溢出 32 位）
local function Rng(seed)
  local s = mod(seed, 65536) + 1
  return function(n)
    s = mod(s * 75 + 74, 65537)
    return mod(s, n)
  end
end
local function hash(a, b) return mod(a * 7919 + b * 104729 + 12345, 65521) end

-- ---------- 时间 ----------
-- 注意：Rockbox 的 Lua 每个函数最多 100 个 local、30 个 upvalue。
-- 只给游戏用的名字放在外面，内部用的都包在 do ... end 里。
local now
do
local fallback_t0
now = function()
  if os and os.time then
    local ok, t = pcall(os.time)
    if ok and type(t) == "number" and t > 1000000000 then return math.floor(t) end
  end
  if rb.mktime and rb.get_time then
    local ok, t = pcall(function() return rb.mktime(rb.get_time()) end)
    if ok and type(t) == "number" and t > 1000000000 then return t end
  end
  if not fallback_t0 then fallback_t0 = 1795435200 end -- 找不到时钟：假装是某天中午
  return fallback_t0 + div(rb.current_tick(), HZ)
end
end

-- unix 秒 → 日期（Rockbox 的时钟就是本地时间，所以这里不处理时区）
local function civil(t)
  local days = div(t, 86400)
  local secs = t - days * 86400
  local z = days + 719468
  local era = div(z, 146097)
  local doe = z - era * 146097
  local yoe = div(doe - div(doe, 1460) + div(doe, 36524) - div(doe, 146096), 365)
  local y = yoe + era * 400
  local doy = doe - (365 * yoe + div(yoe, 4) - div(yoe, 100))
  local mp = div(5 * doy + 2, 153)
  local d = doy - div(153 * mp + 2, 5) + 1
  local m = mp < 10 and mp + 3 or mp - 9
  if m <= 2 then y = y + 1 end
  return { y = y, m = m, d = d, hh = div(secs, 3600), mm = mod(div(secs, 60), 60),
           ss = mod(secs, 60), day = days, min = div(secs, 60) }
end
local function timestr(t)
  local c = civil(t)
  return string.format("%04d-%02d-%02d %02d:%02d", c.y, c.m, c.d, c.hh, c.mm)
end

-- ---------- 存档（key=value 每行一条） ----------
local save_kv, load_kv
do
local DATA_DIRS = { "/.rockbox/rocks.data/", "/.rockbox/" }
save_kv = function(name, t)
  for _, dir in ipairs(DATA_DIRS) do
    local f = io.open(dir .. name, "w")
    if f then
      for k, v in pairs(t) do f:write(k, "=", tostring(v), "\n") end
      f:close()
      return true
    end
  end
  return false
end
load_kv = function(name)
  local t = {}
  for _, dir in ipairs(DATA_DIRS) do
    local f = io.open(dir .. name, "r")
    if f then
      while true do
        local line = f:read("*l")
        if not line then break end
        local k, v = string.match(line, "^([^=]+)=(.*)$")
        if k then t[k] = v end
      end
      f:close()
      return t, true
    end
  end
  return t, false
end
end
local function num(v, default)
  local n = tonumber(v)
  if n == nil then return default end
  return math.floor(n)
end

-- ---------- 画图 ----------
local function rgb(r, g, b) return rb.lcd_rgbpack(clamp(r, 0, 255), clamp(g, 0, 255), clamp(b, 0, 255)) end
local function fg(c) rb.lcd_set_foreground(c) end
local function rect(x, y, w, h) if w > 0 and h > 0 then rb.lcd_fillrect(x, y, w, h) end end
local function mix(c1, c2, num_, den) -- c1/c2 是 {r,g,b}
  return { lerp(c1[1], c2[1], num_, den), lerp(c1[2], c2[2], num_, den), lerp(c1[3], c2[3], num_, den) }
end
local function tint(c, t) -- t 是 {r,g,b}，每个 0..256
  return { div(c[1] * t[1], 256), div(c[2] * t[2], 256), div(c[3] * t[3], 256) }
end
local function pack(c) return rgb(c[1], c[2], c[3]) end

if rb.FONT_SYSFIXED and rb.lcd_setfont then pcall(rb.lcd_setfont, rb.FONT_SYSFIXED) end
local function text_size(s)
  if rb.lcd_getstringsize then
    local w, h = rb.lcd_getstringsize(s)
    if w then return w, h end
  end
  return #s * 6, 8
end
local function text(x, y, s, c, bg)
  if bg then rb.lcd_set_background(bg) end
  fg(c)
  rb.lcd_putsxy(x, y, s)
end
local function text_r(xr, y, s, c, bg) -- 右对齐
  local w = text_size(s)
  text(xr - w, y, s, c, bg)
end

-- ---------- 按键与转盘 ----------
local poll, wheel_rate, wheel_speed, select_gesture
do
-- rb.buttons 要 require("buttons") 之后才有；万一加载失败，就用 iPod Nano 2G 的键值
pcall(require, "buttons")
local BT = rb.buttons or {
  BUTTON_NONE = 0, BUTTON_SELECT = 0x01, BUTTON_MENU = 0x02, BUTTON_LEFT = 0x04, BUTTON_RIGHT = 0x08,
  BUTTON_SCROLL_FWD = 0x10, BUTTON_SCROLL_BACK = 0x20, BUTTON_PLAY = 0x40,
  BUTTON_REL = 0x02000000, BUTTON_REPEAT = 0x04000000,
}
local KEY = {
  [BT.BUTTON_MENU or -1] = "menu", [BT.BUTTON_SELECT or -2] = "select",
  [BT.BUTTON_PLAY or -3] = "play", [BT.BUTTON_LEFT or -4] = "prev",
  [BT.BUTTON_RIGHT or -5] = "next", [BT.BUTTON_SCROLL_FWD or -6] = "fwd",
  [BT.BUTTON_SCROLL_BACK or -7] = "back",
}
local B_REL = BT.BUTTON_REL or 0x02000000
local B_REP = BT.BUTTON_REPEAT or 0x04000000
local function has_flag(b, f) return mod(div(b, f), 2) == 1 end

-- 转盘：记录最近的点击时间，算速度（每秒格数）
local wheel_ticks = {}
local function wheel_note()
  local t = rb.current_tick()
  wheel_ticks[#wheel_ticks + 1] = t
  if #wheel_ticks > 80 then table.remove(wheel_ticks, 1) end
end
wheel_rate = function(window) -- window 单位 tick；返回 每秒事件数（转得快时会被合并，最多十几）
  local t = rb.current_tick()
  local n = 0
  for i = #wheel_ticks, 1, -1 do
    if t - wheel_ticks[i] <= window then n = n + 1 else break end
  end
  return div(n * HZ, window)
end

-- 真实转速：每帧读转盘的绝对位置（一圈 96 格，手指离开时是 -1）。
-- 转盘事件在转得快时会被系统合并，靠数事件分不出快慢，所以要读位置。
local pos_last, pos_hist = -1, {}
local has_pos = rb.wheel_status ~= nil
local function sample_wheel()
  if not has_pos then return end
  local ok, p = pcall(rb.wheel_status)
  if not ok or type(p) ~= "number" then has_pos = false; return end
  if p >= 0 and pos_last >= 0 then
    local d = mod(p - pos_last + 48, 96) - 48
    if d ~= 0 then
      pos_hist[#pos_hist + 1] = { rb.current_tick(), iabs(d) }
      if #pos_hist > 60 then table.remove(pos_hist, 1) end
    end
  end
  pos_last = p
end
-- 返回 每秒转过多少格（一圈 96 格），第二个值说明来源："pos" 真实位置 / "evt" 只能数事件
wheel_speed = function(window)
  if not has_pos then return wheel_rate(window) * 6, "evt" end -- 一个事件约等于 6 格
  local t = rb.current_tick()
  local n = 0
  for i = #pos_hist, 1, -1 do
    if t - pos_hist[i][1] <= window then n = n + pos_hist[i][2] else break end
  end
  return div(n * HZ, window), "pos"
end

-- 读出这一帧所有按键事件：{ {k="fwd"}, {k="select", rel=true}, ... }
poll = function()
  sample_wheel()
  local ev = {}
  for _ = 1, 64 do
    local b = rb.button_get(false)
    if not b or b == 0 or b == BT.BUTTON_NONE then break end
    if b > 0 then -- 负数/超大值是系统事件，忽略
      local rel, rep = has_flag(b, B_REL), has_flag(b, B_REP)
      local base = b
      if rel then base = base - B_REL end
      if rep then base = base - B_REP end
      local k = KEY[base]
      if k then
        if (k == "fwd" or k == "back") and not rel then wheel_note() end
        ev[#ev + 1] = { k = k, rel = rel, rep = rep }
      end
    end
  end
  return ev
end

-- Select 短按/长按识别。每帧把事件喂进来，返回 "short" / "long" / nil
local sel_down, sel_long_fired = nil, false
select_gesture = function(e)
  if e.k ~= "select" then return nil end
  if e.rel then
    local was = sel_down
    sel_down = nil
    if was and not sel_long_fired then return "short" end
    sel_long_fired = false
    return nil
  end
  if not sel_down then sel_down = rb.current_tick(); sel_long_fired = false end
  if not sel_long_fired and rb.current_tick() - sel_down >= div(HZ * 4, 5) then
    sel_long_fired = true
    return "long"
  end
  return nil
end
end

-- ---------- 背光 ----------
local keep_light, light_start, light_end
do
local KEEP_LIGHT = true
local last_bl = 0
keep_light = function()
  if not KEEP_LIGHT then return end
  local t = rb.current_tick()
  if t - last_bl > 3 * HZ then
    last_bl = t
    -- Rockbox 的 Lua 里叫 backlight_onoff(true)，没有 backlight_on
    if rb.backlight_onoff then pcall(rb.backlight_onoff, true) end
  end
end
light_start = function()
  if KEEP_LIGHT and rb.backlight_force_on then pcall(rb.backlight_force_on) end
end
light_end = function()
  if rb.backlight_use_settings then pcall(rb.backlight_use_settings) end
end
end

-- ---------- 共用的光和天气（穹顶、瞭望塔、高尔夫） ----------
local light_at, weather_of
do
-- 优胜美地大致的日出日落（本地时间，分钟）
local SUNRISE = { 435, 410, 425, 400, 360, 340, 350, 375, 400, 425, 400, 425 }
local SUNSET = { 1015, 1050, 1135, 1165, 1195, 1215, 1210, 1180, 1135, 1090, 1015, 1000 }
local SEASON = { -100, -80, -30, 20, 60, 100, 100, 70, 30, -20, -70, -100 } -- 冬 -100 … 夏 100

-- 关键帧：{锚点, 偏移分钟, 天顶色, 地平线色, 地面受光(0..256)}
local KEYS = {
  { "sr", -70, { 8, 10, 28 }, { 18, 22, 48 }, { 45, 50, 85 } },
  { "sr", -30, { 40, 50, 90 }, { 120, 130, 160 }, { 90, 100, 140 } },   -- 黎明灰蓝
  { "sr", 30, { 90, 130, 190 }, { 215, 222, 235 }, { 185, 198, 225 } }, -- 清晨冷白
  { "noon", 0, { 70, 130, 210 }, { 180, 205, 230 }, { 240, 240, 232 } }, -- 正午平淡
  { "ss", -80, { 90, 120, 190 }, { 240, 205, 160 }, { 250, 220, 185 } },
  { "ss", -15, { 110, 90, 150 }, { 250, 140, 110 }, { 225, 150, 130 } }, -- 傍晚橘粉
  { "ss", 15, { 60, 40, 90 }, { 140, 80, 110 }, { 115, 85, 120 } },
  { "ss", 50, { 25, 15, 50 }, { 60, 35, 80 }, { 65, 55, 100 } },        -- 入夜深紫
  { "ss", 90, { 8, 10, 28 }, { 18, 22, 48 }, { 45, 50, 85 } },
}

-- t: unix 秒；shift: 额外的分钟偏移（转盘拨时间用）
light_at = function(t, shift)
  local c = civil(t + (shift or 0) * 60)
  local m, mins = c.m, c.min
  local sr, ss = SUNRISE[m], SUNSET[m]
  local season = SEASON[m]
  local noon = div(sr + ss, 2)
  local stretch = 100 + (season > 0 and div(season * 35, 100) or 0) -- 夏天傍晚更长
  local pts = {}
  for i, k in ipairs(KEYS) do
    local at
    if k[1] == "sr" then at = sr + k[2]
    elseif k[1] == "ss" then at = ss + div(k[2] * stretch, 100)
    else at = noon end
    pts[i] = at
  end
  -- 找到所在的两个关键帧（首尾跨午夜相接）
  local n = #KEYS
  local a, b, num_, den
  if mins < pts[1] or mins >= pts[n] then
    a, b = n, 1
    local span = pts[1] + 1440 - pts[n]
    num_ = mins >= pts[n] and mins - pts[n] or mins + 1440 - pts[n]
    den = span
  else
    for i = 1, n - 1 do
      if mins >= pts[i] and mins < pts[i + 1] then
        a, b, num_, den = i, i + 1, mins - pts[i], pts[i + 1] - pts[i]
        break
      end
    end
  end
  local ka, kb = KEYS[a], KEYS[b]
  local top, bot, land = mix(ka[3], kb[3], num_, den), mix(ka[4], kb[4], num_, den), mix(ka[5], kb[5], num_, den)
  -- 冬天更冷更低
  if season < 0 then
    local w = -season
    top = { top[1] - div(15 * w, 100), top[2], top[3] + div(15 * w, 100) }
    bot = { bot[1] - div(12 * w, 100), bot[2], bot[3] + div(10 * w, 100) }
    land = { land[1] - div(25 * w, 100), land[2] - div(10 * w, 100), land[3] }
  end
  -- 太阳高度 0..1000（白天），夜里为负（日落后分钟数的相反数）
  local sun
  if mins >= sr and mins <= ss then
    local maxh = 700 + div(season * 3, 1) -- 冬天低、夏天高
    sun = div(4 * (mins - sr) * (ss - mins) * div(maxh, 10), (ss - sr) * (ss - sr)) * 10
  elseif mins > ss then sun = -(mins - ss)
  else sun = -(sr - mins) end
  -- 高山辉光：日落前后十来分钟，峰顶还亮着
  local glow = 0
  local g0, g1, g2 = ss - 8, ss + 4, ss + div(16 * stretch, 100)
  if mins >= g0 and mins < g1 then glow = div((mins - g0) * 256, g1 - g0)
  elseif mins >= g1 and mins < g2 then glow = 256 - div((mins - g1) * 256, g2 - g1) end
  local dawn_glow = 0
  if mins >= sr - 12 and mins < sr + 6 then dawn_glow = 120 - div(iabs(mins - (sr - 3)) * 120, 15) end
  if dawn_glow > glow then glow = clamp(dawn_glow, 0, 256) end
  local night = mins < sr - 60 or mins > ss + div(75 * stretch, 100)
  return { top = top, bot = bot, land = land, sun = sun, glow = glow, night = night,
           min = mins, sr = sr, ss = ss, month = m, season = season, day = c.day }
end

-- 每天的天气（同一天任何地方算出来都一样）
local RAIN = { 35, 35, 30, 20, 10, 3, 2, 2, 5, 12, 25, 35 }
local FOG = { 70, 60, 40, 30, 15, 8, 5, 5, 10, 25, 50, 70 }
weather_of = function(day)
  local c = civil(day * 86400)
  local r = Rng(hash(day, 31))
  local rainy = r(100) < RAIN[c.m]
  local yr = Rng(hash(day - 1, 31))
  local rained_yesterday = yr(100) < RAIN[civil((day - 1) * 86400).m]
  local fog = FOG[c.m] + (rained_yesterday and 35 or 0) + r(41) - 20
  if not rainy and c.m >= 6 and c.m <= 8 and r(3) == 0 then fog = 0 end -- 晴朗夏日可能整天无雾
  fog = clamp(fog, 0, 100)
  return {
    rainy = rainy, fog = fog,
    inversion = fog > 45 and r(100) < 15, -- 雾停在半山腰
    wind = r(7) - 3,
    storm_start = 600 + r(480), storm_bearing = r(360), storm_dir = r(2) == 0 and -1 or 1,
  }
end
end
-- ==== 共用部分结束 ====

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
