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

-- 洒水器：黄昏的球场，洒水器一个个打开。转盘就是喷头
-- 转盘：喷头方向（手指在哪，水往哪喷）；转得慢落得近、湿得透，转得快洒得远、只湿一层皮
-- Select：白天手动开 / 关（黄昏自动开，夜里不开）   Menu：退出

local SAVE = "slow_sprinkler.txt"
local CELL = 4
local GW, GH = div(W, CELL), div(H, CELL) -- 44 × 33
local N = GW * GH
local WET_MAX, SOAKED = 12, 8   -- 湿度 0..12；到 8 算“浇透”
local DRY_SECS = 300            -- 每 5 分钟干一点
local OPEN_BEFORE, OPEN_AFTER = 30, 40 -- 日落前 30 分钟开，日落后 40 分钟关
local WHEEL_ZERO = 24           -- 转盘位置 0 对应的喷头方向（24 = 朝上）；上机后按手感调
local MAXDROP = 40

-- 32 个方向的余弦 ×64（0 朝右，顺时针，屏幕坐标 y 向下）
local COS = { [0] = 64, 63, 59, 53, 45, 36, 24, 12, 0, -12, -24, -36, -45, -53, -59, -63,
  -64, -63, -59, -53, -45, -36, -24, -12, 0, 12, 24, 36, 45, 53, 59, 63 }
local function sin32(a) return COS[mod(a - 8, 32)] end

-- 草色：健康 0..3（枯黄 → 深绿）× 湿 0..3（越湿越深）
local GRASS = { [0] = { 186, 166, 92 }, { 150, 158, 78 }, { 92, 140, 62 }, { 46, 112, 52 } }
local WETC = { 24, 58, 70 }
local HEAD, BIRD = { 150, 150, 158 }, { 40, 36, 34 }

-- ---------- 状态 ----------
local HL, WV, WD = {}, {}, {}    -- 健康；湿度；最后一次浇透是哪天
local DIRTY = {}
local AUTO = {}                  -- 远处自动洒水器管的格子
local S = { day = div(now(), 86400), dry_t = now(), rain_day = -1, manual = false, aim = 24 }
local drops = {}
local rnd = Rng(rb.current_tick() + now())
local PAL = {}                   -- [健康*4+湿] → 颜色，跟着光变
local HEADS = { { x = 6 * CELL + 2, y = 6 * CELL + 2, a = 0, r = 7 }, { x = 37 * CELL + 2, y = 26 * CELL + 2, a = 16, r = 7 } }
local CX, CY = div(W, 2), div(H, 2)

for _, h in ipairs(HEADS) do
  local hx, hy = div(h.x, CELL), div(h.y, CELL)
  for y = 0, GH - 1 do
    for x = 0, GW - 1 do
      if (x - hx) * (x - hx) + (y - hy) * (y - hy) <= h.r * h.r then AUTO[y * GW + x + 1] = true end
    end
  end
end

local function level(i) return div(WV[i] + 3, 4) end -- 0..3
local function mark(i) DIRTY[#DIRTY + 1] = i end
local function mark_px(px, py) -- 屏幕上这个点下面的格子要重画
  local x, y = div(px, CELL), div(py, CELL)
  if x >= 0 and x < GW and y >= 0 and y < GH then mark(y * GW + x + 1) end
end

-- ---------- 时间 ----------
-- 一天结束时结算：浇透过（或下过雨、在自动洒水器范围里）的格子好一档，两天以上没浇的差一档
local function settle(d)
  local rainy = weather_of(d).rainy
  for i = 1, N do
    if WD[i] == d or rainy or AUTO[i] then
      if HL[i] < 3 then HL[i] = HL[i] + 1 end
    elseif d - WD[i] >= 2 and HL[i] > 0 then
      HL[i] = HL[i] - 1
    end
  end
end
local function tick_time()
  local t = now()
  local today = div(t, 86400)
  if today > S.day then
    for d = math.max(S.day, today - 30), today - 1 do settle(d) end
    S.day = today
    for i = 1, N do mark(i) end
  end
  local steps = div(t - S.dry_t, DRY_SECS)
  if steps > 0 then
    S.dry_t = S.dry_t + steps * DRY_SECS
    for i = 1, N do
      local v = WV[i]
      if v > 0 then
        local old = level(i)
        v = v - steps; if v < 0 then v = 0 end
        WV[i] = v
        if level(i) ~= old then mark(i) end
      end
    end
  end
  if S.rain_day ~= today and weather_of(today).rainy then -- 下雨天：整片草地是湿的
    S.rain_day = today
    for i = 1, N do if WV[i] < SOAKED then WV[i] = SOAKED; mark(i) end; WD[i] = today end
  end
end

-- 现在的状态："auto" 黄昏自动开；"day" 白天（可手动开）；"night" 不开
local function phase(L)
  if L.min >= L.ss - OPEN_BEFORE and L.min <= L.ss + OPEN_AFTER then return "auto" end
  if L.min >= L.sr and L.min < L.ss - OPEN_BEFORE then return "day" end
  return "night"
end

local function make_palette(L)
  local l = L.land -- 草地比天空亮一些，黄昏不至于一片漆黑
  local light = { 60 + div(l[1] * 3, 4), 60 + div(l[2] * 3, 4), 60 + div(l[3] * 3, 4) }
  for h = 0, 3 do
    for w = 0, 3 do
      local c = GRASS[h]
      if w > 0 then c = mix(c, { 20, 50, 60 }, WETC[w], 100) end
      PAL[h * 4 + w] = pack(tint(c, light))
    end
  end
  for i = 1, N do mark(i) end
end

-- ---------- 水 ----------
local function wet(i, amount)
  local old = level(i)
  local v = WV[i] + amount
  if v > WET_MAX then v = WET_MAX end
  WV[i] = v
  if v >= SOAKED then WD[i] = S.day end
  if level(i) ~= old then mark(i) end
end
local function spray(x, y, a, range, jitter, amount)
  if #drops >= MAXDROP then return end
  local ang = mod(a + rnd(2 * jitter + 1) - jitter, 32)
  local life = 8
  local v = div(range * CELL * 16, life)
  drops[#drops + 1] = { x = x * 16, y = y * 16, vx = div(COS[ang] * v, 64), vy = div(sin32(ang) * v, 64),
                        life = life, amount = amount }
end
local function move_drops()
  local k = 1
  while k <= #drops do
    local d = drops[k]
    local ox, oy = div(d.x, 16), div(d.y, 16)
    mark_px(ox, oy); mark_px(ox + 1, oy + 1) -- 2×2 的水点可能跨两格
    d.x, d.y, d.life = d.x + d.vx, d.y + d.vy, d.life - 1
    local px, py = div(d.x, 16), div(d.y, 16)
    if d.life <= 0 or px < 0 or py < 0 or px >= W or py >= H then
      if px >= 0 and py >= 0 and px < W and py < H then
        local cx, cy = div(px, CELL), div(py, CELL)
        wet(cy * GW + cx + 1, d.amount)
        local nx, ny = clamp(cx + rnd(3) - 1, 0, GW - 1), clamp(cy + rnd(3) - 1, 0, GH - 1)
        wet(ny * GW + nx + 1, 1) -- 溅开一点
      end
      table.remove(drops, k)
    else
      k = k + 1
    end
  end
end

-- ---------- 鸟 ----------
local bird = nil
local function bird_step(aim, open)
  if bird then
    mark_px(bird.x, bird.y); mark_px(bird.x + 3, bird.y + 2)
    if bird.vx ~= 0 or bird.vy ~= 0 then
      bird.x, bird.y = bird.x + bird.vx, bird.y + bird.vy
      if bird.x < -6 or bird.x > W + 6 or bird.y < -6 or bird.y > H + 6 then bird = nil end
      return
    end
    -- 喷头转到它那边，或者待够了，就飞走
    local dx, dy = bird.x - CX, bird.y - CY
    local best, ba = -1, 0
    for a = 0, 31 do
      local dot = COS[a] * dx + sin32(a) * dy
      if dot > best then best, ba = dot, a end
    end
    local diff = iabs(mod(ba - aim + 16, 32) - 16)
    if (open and diff <= 2) or rb.current_tick() > bird.until_t then
      bird.vx = (dx >= 0) and 3 or -3
      bird.vy = -2
    end
    return
  end
  if rnd(600) ~= 0 then return end
  local puddles, spot = 0, nil
  for _ = 1, 60 do
    local i = rnd(N) + 1
    if level(i) == 3 then puddles = puddles + 1; spot = i end
  end
  if puddles >= 6 and spot then
    local x, y = mod(spot - 1, GW), div(spot - 1, GW)
    bird = { x = x * CELL, y = y * CELL, vx = 0, vy = 0, until_t = rb.current_tick() + (30 + rnd(30)) * HZ }
  end
end

-- ---------- 存档 ----------
local function load()
  local s, found = load_kv(SAVE)
  local hs, ws, ds = s.health or "", s.wet or "", s.wday or ""
  local saved_day = num(s.day, S.day)
  for i = 1, N do
    HL[i] = num(string.sub(hs, i, i), 2)
    WV[i] = tonumber(string.sub(ws, i, i), 16) or 0
    WD[i] = saved_day - num(string.sub(ds, i, i), 1)
  end
  if found then
    S.day = saved_day
    S.dry_t = num(s.dry_t, S.dry_t)
    S.rain_day = num(s.rain_day, -1)
    S.aim = clamp(num(s.aim, 24), 0, 31)
  else -- 第一次：大片是绿的，有几块发黄
    for i = 1, N do HL[i] = 3 end
    for _ = 1, 4 do
      local px, py, r = rnd(GW), rnd(GH), 3 + rnd(4)
      for y = 0, GH - 1 do
        for x = 0, GW - 1 do
          local d2 = (x - px) * (x - px) + (y - py) * (y - py)
          if d2 <= r * r then
            local i = y * GW + x + 1
            HL[i] = math.min(HL[i], div(d2 * 3, r * r) + rnd(2) - 1 < 0 and 0 or div(d2 * 3, r * r))
          end
        end
      end
    end
  end
end
local function save()
  local hs, ws, ds = {}, {}, {}
  for i = 1, N do
    hs[i] = HL[i]
    ws[i] = string.format("%x", WV[i])
    ds[i] = clamp(S.day - WD[i], 0, 9)
  end
  save_kv(SAVE, { health = table.concat(hs), wet = table.concat(ws), wday = table.concat(ds),
                  day = S.day, dry_t = S.dry_t, rain_day = S.rain_day, aim = S.aim })
end

-- ---------- 画面 ----------
local function draw_dirty(budget)
  local n = #DIRTY
  local stop = (n > budget) and (n - budget) or 0
  for k = n, stop + 1, -1 do
    local i = DIRTY[k]
    DIRTY[k] = nil
    fg(PAL[HL[i] * 4 + level(i)])
    local y = div(i - 1, GW)
    rect((i - 1 - y * GW) * CELL, y * CELL, CELL, CELL)
  end
end
local function draw_head(x, y, a, light)
  fg(pack(tint(HEAD, light)))
  rect(x - 2, y - 2, 4, 4)
  rect(x + div(COS[a] * 5, 64) - 1, y + div(sin32(a) * 5, 64) - 1, 2, 2)
  for dy = -2, 2, 4 do for dx = -2, 2, 4 do mark_px(x + dx, y + dy) end end
  mark_px(x + div(COS[a] * 5, 64), y + div(sin32(a) * 5, 64))
end

-- ---------- 主循环 ----------
load()
light_start()
tick_time()
local L = light_at(now())
make_palette(L)
local light_min = L.min
local running = true
local frame = 0
local last_pos = -1

while running do
  for _, e in ipairs(poll()) do
    if e.k == "menu" and not e.rel then running = false
    elseif (e.k == "fwd" or e.k == "back") and not e.rel and last_pos < 0 then
      -- 读不到转盘位置时，退回数事件转喷头
      S.aim = mod(S.aim + ((e.k == "fwd") and 1 or -1), 32)
    elseif select_gesture(e) == "short" then
      if phase(L) == "day" then S.manual = not S.manual end
    end
  end

  if rb.wheel_status then
    local ok, p = pcall(rb.wheel_status)
    if ok and type(p) == "number" then
      last_pos = p
      if p >= 0 then S.aim = mod(WHEEL_ZERO + div(p, 3), 32) end
    end
  end

  -- 光每分钟更新一次；换了就慢慢重画整片草地
  if mod(frame, 250) == 0 then
    tick_time()
    L = light_at(now())
    if L.min ~= light_min then light_min = L.min; make_palette(L) end
  end
  local ph = phase(L)
  if ph ~= "day" then S.manual = false end
  local open = (ph == "auto") or S.manual

  if open then
    local sp = wheel_speed(div(HZ, 5))
    for _ = 1, 2 do
      if sp > 150 then spray(CX, CY, S.aim, 9 + rnd(7), 2, 1)   -- 快：远、散、薄
      else spray(CX, CY, S.aim, 5 + rnd(5), 1, 3) end            -- 慢：近、集中、透
    end
  end
  if ph == "auto" then -- 远处的洒水器自己转
    for _, h in ipairs(HEADS) do
      if mod(frame, 6) == 0 then h.a = mod(h.a + 1, 32) end
      if mod(frame, 2) == 0 then spray(h.x, h.y, h.a, 3 + rnd(h.r - 2), 1, 2) end
    end
  end
  move_drops()
  bird_step(S.aim, open)

  draw_dirty(220)
  -- 水点颜色跟着天色：黄昏是地平线的橘色，白天偏白
  local dc = (ph == "auto") and pack(mix(L.bot, { 255, 255, 255 }, 30, 100)) or pack(tint({ 225, 235, 245 }, L.land))
  fg(dc)
  for _, d in ipairs(drops) do rect(div(d.x, 16), div(d.y, 16), 2, 2) end
  draw_head(CX, CY, S.aim, L.land)
  for _, h in ipairs(HEADS) do draw_head(h.x, h.y, h.a, L.land) end
  if bird then
    fg(pack(BIRD))
    rect(bird.x, bird.y + 1, 4, 2)
    if mod(div(frame, 4), 2) == 0 or bird.vx == 0 then rect(bird.x + 1, bird.y, 1, 1) end
  end
  rb.lcd_update()
  keep_light()

  frame = frame + 1
  if mod(frame, 1500) == 0 then save() end
  rb.sleep(div(HZ, 25))
end

save()
light_end()
