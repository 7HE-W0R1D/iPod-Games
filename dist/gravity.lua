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

-- 旋转重力：一个装着沙、水和种子的小盒子，转盘转动重力的方向
-- 转盘：重力转 45 度   Select：从上游撒一把材料（沙、水、种子轮流）
-- 下一首：看活得最久的那株植物   Menu：退出

local SAVE = "slow_gravity.txt"
local CELL = 4
local GW, GH = div(W, CELL), div(H, CELL) -- 44 × 33
local PW = GW + 2                         -- 四周包一圈墙，省掉出界判断
local NP = PW * (GH + 2)
local EMPTY, SAND, WATER, STONE, SEED, PLANT, WALL = 0, 1, 2, 3, 4, 5, 9
local DIE_DAYS = 3        -- 没水的植物几天后枯成沙
local CHECK_FRAMES = 50   -- 每 50 帧（约 2 秒）数一次植物，顺便看有没有枯死

local COL = {
  [EMPTY] = rgb(20, 18, 26), [SAND] = rgb(212, 182, 112), [WATER] = rgb(66, 116, 200),
  [STONE] = rgb(110, 108, 116), [SEED] = rgb(150, 105, 60), [PLANT] = rgb(84, 162, 72),
}
local FRAME, HI, INK = rgb(60, 58, 72), rgb(240, 200, 90), rgb(170, 170, 180)

-- 8 个方向，顺时针，相邻两个差 45 度；0 是向下
local DX = { [0] = 0, -1, -1, -1, 0, 1, 1, 1 }
local DY = { [0] = 1, 1, 0, -1, -1, -1, 0, 1 }
local OFF = {}
for d = 0, 7 do OFF[d] = DY[d] * PW + DX[d] end

-- ---------- 状态 ----------
local G, ST, DIRTY = {}, {}, {}   -- 材料；这一帧动过的盖章；要重画的格子
local PDAY, PBORN = {}, {}        -- 植物：最后喝到水是哪天；哪天长出来
local S = { dir = 0, fid = 0, pick = 0, plants = 0, oldest = 0, best = 0, t = now() }
local ORDER = {}
local rnd = Rng(rb.current_tick() + S.t)
local function today() return div(now(), 86400) end
local function inside(p)
  local y = div(p, PW)
  local x = p - y * PW
  return x >= 1 and x <= GW and y >= 1 and y <= GH
end
local function set(p, m)
  G[p] = m
  DIRTY[#DIRTY + 1] = p
end

-- 换方向时排一次扫描顺序：沿重力方向的坐标从大到小（下游先算）
local function build_order()
  local gx, gy = DX[S.dir], DY[S.dir]
  local buckets, lo, hi = {}, 0, 0
  for y = 1, GH do
    for x = 1, GW do
      local k = x * gx + y * gy
      local b = buckets[k]
      if not b then b = {}; buckets[k] = b end
      b[#b + 1] = y * PW + x
      if k < lo then lo = k end
      if k > hi then hi = k end
    end
  end
  local n = 0
  for k = hi, lo, -1 do
    local b = buckets[k]
    if b then for j = 1, #b do n = n + 1; ORDER[n] = b[j] end end
  end
end

-- ---------- 物理 ----------
local physics
do
local flip = false
local function mv(p, t) -- p 的东西去 t，t 的东西（空或水）回 p
  local a = G[t]
  G[t] = G[p]; G[p] = a
  ST[t] = S.fid; ST[p] = S.fid
  DIRTY[#DIRTY + 1] = p; DIRTY[#DIRTY + 1] = t
end
local function sprout(p) -- 种子碰到水：吸掉一格水，变成植物，往重力反方向长一格
  local d = today()
  for _, o in ipairs({ 1, -1, PW, -PW }) do
    if G[p + o] == WATER then
      set(p + o, EMPTY)
      set(p, PLANT); PDAY[p] = d; PBORN[p] = d
      local up = p - OFF[S.dir]
      if G[up] == EMPTY then set(up, PLANT); PDAY[up] = d; PBORN[up] = d end
      return
    end
  end
end
-- 走一帧，返回动了几格
physics = function()
  S.fid = S.fid + 1
  local fid = S.fid
  local D = OFF[S.dir]
  local L1, R1 = OFF[mod(S.dir + 7, 8)], OFF[mod(S.dir + 1, 8)]
  local L2, R2 = OFF[mod(S.dir + 6, 8)], OFF[mod(S.dir + 2, 8)]
  local moved = 0
  for k = 1, #ORDER do
    local p = ORDER[k]
    local m = G[p]
    if (m == SAND or m == WATER or m == SEED) and ST[p] ~= fid then
      local t = p + D
      local below = G[t]
      local a, b = L1, R1
      flip = not flip
      if flip then a, b = R1, L1 end
      if below == EMPTY or (below == WATER and m ~= WATER) then mv(p, t); moved = moved + 1
      elseif G[p + a] == EMPTY then mv(p, p + a); moved = moved + 1
      elseif G[p + b] == EMPTY then mv(p, p + b); moved = moved + 1
      elseif m == WATER then
        if flip then a, b = L2, R2 else a, b = R2, L2 end
        -- 水在平地上横着流不算“动”，不然一滴水就能让盒子永远醒着
        if G[p + a] == EMPTY then mv(p, p + a)
        elseif G[p + b] == EMPTY then mv(p, p + b) end
      elseif m == SEED then sprout(p) end
    end
  end
  return moved
end
end

-- 植物慢慢长：随便挑几格，是挨着水的植物就有机会吸水、往上长一格
local function grow(tries, chance)
  local d = today()
  local up = OFF[S.dir]
  for _ = 1, tries do
    local p = (rnd(GH) + 1) * PW + rnd(GW) + 1
    if G[p] == PLANT and rnd(chance) == 0 then
      for _, o in ipairs({ 1, -1, PW, -PW }) do
        if G[p + o] == WATER then
          local t = p - up
          if G[t] ~= EMPTY then t = p - OFF[mod(S.dir + 7 + rnd(3), 8)] end -- 斜上方
          if G[t] == EMPTY then
            set(p + o, EMPTY)
            set(t, PLANT); PDAY[t] = d; PBORN[t] = PBORN[p] or d
            PDAY[p] = d
          end
          break
        end
      end
    end
  end
end

-- 查一遍植物：连在一起的算一株；整株只要有一格挨着水就算喝到了；太久没水的枯成沙
local function check_plants()
  local d = today()
  local seen, stack = {}, {}
  local plants, oldest = 0, 0
  for y = 1, GH do
    for x = 1, GW do
      local p0 = y * PW + x
      if G[p0] == PLANT and not seen[p0] then
        local cells, wet, born = {}, false, d
        local sp = 1
        stack[1] = p0; seen[p0] = true
        while sp > 0 do
          local p = stack[sp]; sp = sp - 1
          cells[#cells + 1] = p
          if (PBORN[p] or d) < born then born = PBORN[p] end
          for _, o in ipairs({ 1, -1, PW, -PW }) do
            local q = p + o
            if G[q] == WATER then wet = true
            elseif G[q] == PLANT and not seen[q] then seen[q] = true; sp = sp + 1; stack[sp] = q end
          end
        end
        local last = 0
        for _, p in ipairs(cells) do
          if wet then PDAY[p] = d end
          if (PDAY[p] or 0) > last then last = PDAY[p] end
        end
        if d - last >= DIE_DAYS then
          for _, p in ipairs(cells) do set(p, SAND); PDAY[p] = nil; PBORN[p] = nil end
        else
          plants = plants + 1
          if d - born > oldest then oldest = d - born end
        end
      end
    end
  end
  S.plants, S.oldest = plants, oldest
  if oldest > S.best then S.best = oldest end
end

-- 从上游那条边撒一把
local function sprinkle()
  local kinds = { SAND, WATER, SEED }
  S.pick = mod(S.pick, 3) + 1
  local m = kinds[S.pick]
  local n = #ORDER
  local count = (m == SEED) and 3 or 8
  for _ = 1, 40 do
    if count <= 0 then break end
    local p = ORDER[n - rnd(60)]
    if G[p] == EMPTY then set(p, m); count = count - 1 end
  end
end

-- ---------- 存档 ----------
local function fresh()
  for y = 1, GH do
    for x = 1, GW do
      local p = y * PW + x
      G[p] = (y > GH - 7 - rnd(2)) and SAND or EMPTY
    end
  end
  for _ = 1, 4 do -- 几块石头
    local x0, y0 = rnd(GW - 4) + 1, rnd(GH - 10) + 8
    for y = y0, y0 + 1 + rnd(2) do for x = x0, x0 + 1 + rnd(3) do G[y * PW + x] = STONE end end
  end
  for x = 14, 30 do for y = 6, 9 do G[y * PW + x] = WATER end end
  for k = 1, 5 do G[2 * PW + k * 7] = SEED end
end
local function load()
  for p = 0, NP - 1 do G[p] = WALL; ST[p] = 0 end
  local s, found = load_kv(SAVE)
  if not found or not s.grid then fresh(); return end
  local g = s.grid
  local k = 0
  for y = 1, GH do
    for x = 1, GW do
      k = k + 1
      G[y * PW + x] = num(string.sub(g, k, k), EMPTY)
    end
  end
  S.dir = clamp(num(s.dir, 0), 0, 7)
  S.best = num(s.best, 0)
  S.t = num(s.t, S.t)
  for ps, a, b in string.gmatch(s.plants or "", "(%d+):(%d+):(%d+)") do
    local p = num(ps, 0)
    if G[p] == PLANT then PDAY[p] = num(a, 0); PBORN[p] = num(b, 0) end
  end
end
local function save()
  local g, pl = {}, {}
  for y = 1, GH do
    for x = 1, GW do
      local p = y * PW + x
      g[#g + 1] = G[p]
      if G[p] == PLANT then pl[#pl + 1] = p .. ":" .. (PDAY[p] or 0) .. ":" .. (PBORN[p] or 0) end
    end
  end
  save_kv(SAVE, { grid = table.concat(g), dir = S.dir, best = S.best, t = now(), plants = table.concat(pl, ";") })
end

-- ---------- 画面 ----------
local function draw_cell(p)
  local y = div(p, PW)
  fg(COL[G[p]] or FRAME)
  rect((p - y * PW - 1) * CELL, (y - 1) * CELL, CELL, CELL)
end
local function cells_under(x, y, w, h) -- 屏幕上一块区域盖住的格子，标成要重画
  for cy = div(y, CELL), clamp(div(y + h, CELL), 0, GH - 1) do
    for cx = div(x, CELL), clamp(div(x + w, CELL), 0, GW - 1) do DIRTY[#DIRTY + 1] = (cy + 1) * PW + cx + 1 end
  end
end
local mark_x, mark_y, label_w, label_h = 0, 0, 0, 0
local function draw_overlay(label)
  fg(FRAME)
  rect(0, 0, W, 1); rect(0, H - 1, W, 1); rect(0, 0, 1, H); rect(W - 1, 0, 1, H)
  -- 重力方向：框上一个小方块
  local mx = div(W, 2) + DX[S.dir] * (div(W, 2) - 4) - 3
  local my = div(H, 2) + DY[S.dir] * (div(H, 2) - 4) - 3
  if mx ~= mark_x or my ~= mark_y then cells_under(mark_x, mark_y, 6, 6); mark_x, mark_y = mx, my end
  fg(HI); rect(mx, my, 6, 6)
  local w, h = text_size(label)
  if w < label_w then cells_under(3, 3, label_w, label_h) end
  label_w, label_h = w, h
  text(3, 3, label, INK, COL[EMPTY])
end

-- ---------- 主循环 ----------
load()
light_start()
build_order()
-- 不在场的时候：植物按时间长（最多补 60 次），然后查一遍有没有枯死
do
  local steps = clamp(div(now() - S.t, 600), 0, 60)
  for _ = 1, steps do grow(400, 1) end
end
check_plants()
DIRTY = {}
for y = 1, GH do for x = 1, GW do draw_cell(y * PW + x) end end

local running = true
local frame, idle, still_since = 0, 0, rb.current_tick()
local msg, msg_until = nil, 0

while running do
  for _, e in ipairs(poll()) do
    if e.k == "menu" and not e.rel then running = false
    elseif (e.k == "fwd" or e.k == "back") and not e.rel then
      S.dir = mod(S.dir + ((e.k == "fwd") and 1 or -1), 8)
      build_order()
      idle = 0
    elseif e.k == "next" and not e.rel and not e.rep then
      msg, msg_until = "best " .. S.best .. "d", rb.current_tick() + 2 * HZ
    elseif select_gesture(e) == "short" then
      sprinkle(); idle = 0
    end
  end

  -- 静下来以后少算：每 8 帧才扫一次
  local moved = 0
  if idle < 3 or mod(frame, 8) == 0 then
    moved = physics()
    if moved > 0 then idle = 0; still_since = rb.current_tick() else idle = idle + 1 end
  end
  grow(20, 4)

  -- 静止超过一分钟：随便推一粒沙
  if rb.current_tick() - still_since > 60 * HZ then
    still_since = rb.current_tick()
    for _ = 1, 30 do
      local p = (rnd(GH) + 1) * PW + rnd(GW) + 1
      local t = p + OFF[mod(S.dir + 1 + rnd(2) * 6, 8)]
      if G[p] == SAND and G[t] == EMPTY then set(p, EMPTY); set(t, SAND); idle = 0; break end
    end
  end

  if mod(frame, CHECK_FRAMES) == 0 then check_plants() end

  -- 只画动过的格子；一帧最多画 250 个，剩下的下一帧画
  local n = #DIRTY
  local stop = (n > 250) and (n - 250) or 0
  for k = n, stop + 1, -1 do
    local p = DIRTY[k]
    DIRTY[k] = nil
    if inside(p) then draw_cell(p) end
  end
  local label = tostring(S.plants)
  if msg and rb.current_tick() < msg_until then label = msg else msg = nil end
  draw_overlay(label)
  rb.lcd_update()
  keep_light()

  frame = frame + 1
  if mod(frame, 900) == 0 then save() end
  rb.sleep(div(HZ, 25))
end

save()
light_end()
