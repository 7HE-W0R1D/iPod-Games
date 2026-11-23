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

-- 国际象棋：和机器里的对手下棋。它思考时，正在考虑的走法会在棋盘上淡淡闪过
-- 选子：转盘在能动的棋子之间跳，落点提示跟着显示；Select 选中
-- 落子：转盘在合法落点之间跳；Select 落子；Menu 退回选子
-- 上一首：悔一步   Play：思考时间 3 / 10 / 30 秒   Menu（选子时）：退出
-- 下一首：电脑对电脑，你只看；再按一次，轮到白方时交还给你

local SAVE = "slow_chess.txt"

-- ================= 引擎 =================
-- 10×12 信箱棋盘：a8 = 21，h8 = 28，a1 = 91，h1 = 98；外圈是 OFF
-- 棋子：兵 1 马 2 象 3 车 4 后 5 王 6，白正黑负
local E = (function()
local OFF = 99
local B, K, CR = {}, {}, {}          -- 棋盘；王的位置 K[1]/K[-1]；易位权 CR[1..4]：白短 白长 黑短 黑长
local SQ, ROW, COL = {}, {}, {}
local PSQ = {}                       -- PSQ[棋子][格] = 子力 + 位置分（白正黑负）
local MF, MT, MP, MX, MS = {}, {}, {}, {}, {} -- 走法栈：起点 终点 升变 标记 排序分
local U = { cap = {}, ep = {}, cr = {}, ev = {}, m = {} } -- 每层的撤销信息
local st = { side = 1, ep = 0, ev = 0, ply = 0, top = 0, nodes = 0, abort = false }
local KN = { -21, -19, -12, -8, 8, 12, 19, 21 }
local DIAG = { -11, -9, 9, 11 }
local ORTH = { -10, -1, 1, 10 }
local ALL8 = { -11, -10, -9, -1, 1, 9, 10, 11 }
local VAL = { 100, 320, 330, 500, 900, 0 }
local MATE = 30000
-- 每格的危险：动了这些格子（王或车）就失去对应的易位权
local CR_LOSE = { [95] = { 1, 2 }, [98] = { 1 }, [91] = { 2 }, [25] = { 3, 4 }, [28] = { 3 }, [21] = { 4 } }

-- 位置分（白方视角，a8 → h1）
local T = {
  { 0, 0, 0, 0, 0, 0, 0, 0, 50, 50, 50, 50, 50, 50, 50, 50, 10, 10, 20, 30, 30, 20, 10, 10, 5, 5, 10, 25, 25, 10, 5, 5,
    0, 0, 0, 20, 20, 0, 0, 0, 5, -5, -10, 0, 0, -10, -5, 5, 5, 10, 10, -20, -20, 10, 10, 5, 0, 0, 0, 0, 0, 0, 0, 0 },
  { -50, -40, -30, -30, -30, -30, -40, -50, -40, -20, 0, 0, 0, 0, -20, -40, -30, 0, 10, 15, 15, 10, 0, -30, -30, 5, 15, 20, 20, 15, 5, -30,
    -30, 0, 15, 20, 20, 15, 0, -30, -30, 5, 10, 15, 15, 10, 5, -30, -40, -20, 0, 5, 5, 0, -20, -40, -50, -40, -30, -30, -30, -30, -40, -50 },
  { -20, -10, -10, -10, -10, -10, -10, -20, -10, 0, 0, 0, 0, 0, 0, -10, -10, 0, 5, 10, 10, 5, 0, -10, -10, 5, 5, 10, 10, 5, 5, -10,
    -10, 0, 10, 10, 10, 10, 0, -10, -10, 10, 10, 10, 10, 10, 10, -10, -10, 5, 0, 0, 0, 0, 5, -10, -20, -10, -10, -10, -10, -10, -10, -20 },
  { 0, 0, 0, 0, 0, 0, 0, 0, 5, 10, 10, 10, 10, 10, 10, 5, -5, 0, 0, 0, 0, 0, 0, -5, -5, 0, 0, 0, 0, 0, 0, -5,
    -5, 0, 0, 0, 0, 0, 0, -5, -5, 0, 0, 0, 0, 0, 0, -5, -5, 0, 0, 0, 0, 0, 0, -5, 0, 0, 0, 5, 5, 0, 0, 0 },
  { -20, -10, -10, -5, -5, -10, -10, -20, -10, 0, 0, 0, 0, 0, 0, -10, -10, 0, 5, 5, 5, 5, 0, -10, -5, 0, 5, 5, 5, 5, 0, -5,
    0, 0, 5, 5, 5, 5, 0, -5, -10, 5, 5, 5, 5, 5, 0, -10, -10, 0, 5, 0, 0, 0, 0, -10, -20, -10, -10, -5, -5, -10, -10, -20 },
  { -30, -40, -40, -50, -50, -40, -40, -30, -30, -40, -40, -50, -50, -40, -40, -30, -30, -40, -40, -50, -50, -40, -40, -30, -30, -40, -40, -50, -50, -40, -40, -30,
    -20, -30, -30, -40, -40, -30, -30, -20, -10, -20, -20, -20, -20, -20, -20, -10, 20, 20, 0, 0, 0, 0, 20, 20, 20, 30, 10, 0, 0, 10, 30, 20 },
}
for k = 1, 64 do
  local r, f = div(k - 1, 8), mod(k - 1, 8)
  local sq = (r + 2) * 10 + f + 1
  SQ[k], ROW[sq], COL[sq] = sq, r + 2, f + 1
end
PSQ[0] = {}
for t = 1, 6 do
  PSQ[t], PSQ[-t] = {}, {}
  for k = 1, 64 do
    local sq = SQ[k]
    local r, f = div(k - 1, 8), mod(k - 1, 8)
    PSQ[t][sq] = VAL[t] + T[t][k]
    PSQ[-t][sq] = -(VAL[t] + T[t][(7 - r) * 8 + f + 1])
  end
end
for i = 0, 119 do PSQ[0][i] = 0 end

local function attacked(sq, by) -- by 方有没有子攻击 sq
  if by == 1 then
    if B[sq + 9] == 1 or B[sq + 11] == 1 then return true end
  elseif B[sq - 9] == -1 or B[sq - 11] == -1 then return true end
  for i = 1, 8 do
    if B[sq + KN[i]] == 2 * by then return true end
    if B[sq + ALL8[i]] == 6 * by then return true end
  end
  for i = 1, 4 do
    local o = DIAG[i]
    local t = sq + o
    while B[t] == 0 do t = t + o end
    if B[t] == 3 * by or B[t] == 5 * by then return true end
    o = ORTH[i]
    t = sq + o
    while B[t] == 0 do t = t + o end
    if B[t] == 4 * by or B[t] == 5 * by then return true end
  end
  return false
end

local function add(from, to, pr, fl, score)
  local n = st.top + 1
  st.top = n
  MF[n], MT[n], MP[n], MX[n], MS[n] = from, to, pr, fl, score
end
local function add_pawn(from, to, cap_score, promo_row)
  if ROW[to] == promo_row then
    add(from, to, 5, 0, 900 + cap_score); add(from, to, 2, 0, 300 + cap_score)
    add(from, to, 4, 0, 1 + cap_score); add(from, to, 3, 0, 1 + cap_score)
  else
    add(from, to, 0, 0, cap_score)
  end
end

-- 生成当前一方的伪合法走法，放在栈顶；caps：只要吃子（静态搜索用）
local function gen(caps)
  local s = st.side
  local fwd = -10 * s
  local promo_row = (s == 1) and 2 or 9
  local start_row = (s == 1) and 8 or 3
  for k = 1, 64 do
    local sq = SQ[k]
    local p = B[sq] * s
    if p > 0 and p ~= OFF and p ~= -OFF then
      if p == 1 then
        local to = sq + fwd
        if not caps and B[to] == 0 then
          add_pawn(sq, to, 0, promo_row)
          if ROW[sq] == start_row and B[to + fwd] == 0 then add(sq, to + fwd, 0, 1, 0) end
        end
        for d = -1, 1, 2 do
          local t2 = to + d
          local q = B[t2]
          if q ~= OFF and q * s < 0 then add_pawn(sq, t2, -q * s * 10, promo_row)
          elseif t2 == st.ep then add(sq, t2, 0, 2, 9) end
        end
      else
        local dirs, slide = ALL8, false
        if p == 2 then dirs = KN elseif p == 3 then dirs, slide = DIAG, true
        elseif p == 4 then dirs, slide = ORTH, true elseif p == 5 then slide = true end
        for i = 1, #dirs do
          local o = dirs[i]
          local to = sq + o
          local q = B[to]
          while q ~= OFF do
            if q == 0 then
              if not caps then add(sq, to, 0, 0, 0) end
            else
              if q * s < 0 then add(sq, to, 0, 0, -q * s * 10 - p) end
              break
            end
            if not slide then break end
            to = to + o
            q = B[to]
          end
        end
        if p == 6 and not caps then -- 王车易位
          local home = (s == 1) and 95 or 25
          local ks, qs = (s == 1) and 1 or 3, (s == 1) and 2 or 4
          if sq == home and not attacked(home, -s) then
            if CR[ks] and B[home + 1] == 0 and B[home + 2] == 0 and B[home + 3] == 4 * s
              and not attacked(home + 1, -s) and not attacked(home + 2, -s) then add(home, home + 2, 0, 3, 0) end
            if CR[qs] and B[home - 1] == 0 and B[home - 2] == 0 and B[home - 3] == 0 and B[home - 4] == 4 * s
              and not attacked(home - 1, -s) and not attacked(home - 2, -s) then add(home, home - 2, 0, 3, 0) end
          end
        end
      end
    end
  end
end

local function unmake()
  local ply = st.ply
  local i = U.m[ply]
  st.ply = ply - 1
  st.side = -st.side
  local s = st.side
  local from, to, fl = MF[i], MT[i], MX[i]
  local p = B[to]
  if MP[i] > 0 then p = s end -- 升变：退回成兵
  B[from] = p
  B[to] = U.cap[ply]
  if fl == 2 then B[to] = 0; B[to + 10 * s] = -s end
  if fl == 3 then
    if to > from then B[from + 3] = B[from + 1]; B[from + 1] = 0
    else B[from - 4] = B[from - 1]; B[from - 1] = 0 end
  end
  if p == 6 * s then K[s] = from end
  st.ep, st.ev = U.ep[ply], U.ev[ply]
  local c = U.cr[ply]
  CR[1], CR[2], CR[3], CR[4] = c[1], c[2], c[3], c[4]
end

-- 走第 i 步；不合法（走完自己的王被将）就退回并返回 false
local function make(i)
  local s = st.side
  local from, to, pr, fl = MF[i], MT[i], MP[i], MX[i]
  local p, cap = B[from], B[to]
  local ply = st.ply + 1
  st.ply = ply
  U.m[ply], U.cap[ply], U.ep[ply], U.ev[ply] = i, cap, st.ep, st.ev
  local c = U.cr[ply]
  if not c then c = {}; U.cr[ply] = c end
  c[1], c[2], c[3], c[4] = CR[1], CR[2], CR[3], CR[4]
  local ev = st.ev - PSQ[p][from] - PSQ[cap][to]
  local np = p
  if pr > 0 then np = pr * s end
  B[to], B[from] = np, 0
  ev = ev + PSQ[np][to]
  if fl == 2 then -- 吃过路兵
    local cs = to + 10 * s
    ev = ev - PSQ[-s][cs]
    B[cs] = 0
  elseif fl == 3 then -- 易位：车跟着走
    local rf, rt = from + 3, from + 1
    if to < from then rf, rt = from - 4, from - 1 end
    local r = B[rf]
    ev = ev - PSQ[r][rf] + PSQ[r][rt]
    B[rt], B[rf] = r, 0
  end
  st.ev = ev
  if p == 6 * s then K[s] = to end
  st.ep = (fl == 1) and (from - 10 * s) or 0
  local l = CR_LOSE[from]
  if l then for _, k in ipairs(l) do CR[k] = false end end
  l = CR_LOSE[to]
  if l then for _, k in ipairs(l) do CR[k] = false end end
  st.side = -s
  if attacked(K[s], -s) then unmake(); return false end
  return true
end

local function pick_best(i, last) -- 把 i..last 里排序分最高的换到 i；都是 0 就不排了
  local best, bi = MS[i], i
  for j = i + 1, last do if MS[j] > best then best, bi = MS[j], j end end
  if bi ~= i then
    MF[i], MF[bi] = MF[bi], MF[i]; MT[i], MT[bi] = MT[bi], MT[i]
    MP[i], MP[bi] = MP[bi], MP[i]; MX[i], MX[bi] = MX[bi], MX[i]; MS[i], MS[bi] = MS[bi], MS[i]
  end
  return best > 0
end

local deadline, node_cap = 0, 0
local function tick_check()
  st.nodes = st.nodes + 1
  if mod(st.nodes, 64) == 0 and (rb.current_tick() > deadline or st.nodes > node_cap) then st.abort = true end
end

local function qsearch(alpha, beta, depth)
  tick_check()
  local stand = st.ev * st.side
  if stand >= beta then return stand end
  if stand > alpha then alpha = stand end
  if depth <= 0 or st.abort then return alpha end
  local base = st.top
  gen(true)
  local last = st.top
  for i = base + 1, last do
    pick_best(i, last)
    if make(i) then
      local sc = -qsearch(-beta, -alpha, depth - 1)
      unmake()
      if sc > alpha then alpha = sc end
      if alpha >= beta or st.abort then break end
    end
  end
  st.top = base
  return alpha
end

local function negamax(depth, alpha, beta, root_ply)
  if depth <= 0 then return qsearch(alpha, beta, 4) end
  tick_check()
  local base = st.top
  gen(false)
  local last = st.top
  local legal, sorting = 0, true
  for i = base + 1, last do
    if sorting then sorting = pick_best(i, last) end
    if make(i) then
      legal = legal + 1
      local sc = -negamax(depth - 1, -beta, -alpha, root_ply)
      unmake()
      if sc > alpha then alpha = sc end
      if alpha >= beta or st.abort then break end
    end
  end
  st.top = base
  if legal == 0 and not st.abort then
    if attacked(K[st.side], -st.side) then return -MATE + (st.ply - root_ply) end
    return 0
  end
  return alpha
end

local api = { B = B }
-- 测试用：数走法（perft），和摆 FEN 局面
local function perft(d)
  if d == 0 then return 1 end
  local base = st.top
  gen(false)
  local last, n = st.top, 0
  for i = base + 1, last do
    if make(i) then n = n + perft(d - 1); unmake() end
  end
  st.top = base
  return n
end
api.perft = perft
api.fen = function(f)
  local board, side, cast, ep = string.match(f, "^(%S+) (%S) (%S+) (%S+)")
  for i = 0, 119 do B[i] = OFF end
  local r, c = 2, 1
  local CODE = { p = 1, n = 2, b = 3, r = 4, q = 5, k = 6 }
  for k = 1, #board do
    local ch = string.sub(board, k, k)
    if ch == "/" then r, c = r + 1, 1
    elseif tonumber(ch) then for _ = 1, tonumber(ch) do B[r * 10 + c] = 0; c = c + 1 end
    else
      local lo = string.lower(ch)
      local v = (lo == ch) and -CODE[lo] or CODE[lo]
      B[r * 10 + c] = v
      if v == 6 then K[1] = r * 10 + c elseif v == -6 then K[-1] = r * 10 + c end
      c = c + 1
    end
  end
  st.side = (side == "w") and 1 or -1
  CR[1], CR[2] = string.find(cast, "K") ~= nil, string.find(cast, "Q") ~= nil
  CR[3], CR[4] = string.find(cast, "k") ~= nil, string.find(cast, "q") ~= nil
  st.ep = 0
  if ep ~= "-" then st.ep = (10 - tonumber(string.sub(ep, 2, 2))) * 10 + string.byte(ep, 1) - 96 end
  st.ply, st.top = 0, 0
  local ev = 0
  for k = 1, 64 do local sq = SQ[k]; ev = ev + PSQ[B[sq]][sq] end
  st.ev = ev
end
api.side = function() return st.side end
api.in_check = function() return attacked(K[st.side], -st.side) end
api.new_game = function()
  for i = 0, 119 do B[i] = OFF end
  local back = { 4, 2, 3, 5, 6, 3, 2, 4 }
  for f = 1, 8 do
    B[20 + f], B[30 + f] = -back[f], -1
    B[80 + f], B[90 + f] = 1, back[f]
    for r = 4, 7 do B[r * 10 + f] = 0 end
  end
  K[1], K[-1] = 95, 25
  CR[1], CR[2], CR[3], CR[4] = true, true, true, true
  st.side, st.ep, st.ply, st.top = 1, 0, 0, 0
  local ev = 0
  for k = 1, 64 do local sq = SQ[k]; ev = ev + PSQ[B[sq]][sq] end
  st.ev = ev
end
-- 当前一方的全部合法走法：{ {f=, t=, p=}, ... }
api.legal = function()
  st.top = 0
  gen(false)
  local out = {}
  for i = 1, st.top do
    if make(i) then
      unmake()
      out[#out + 1] = { f = MF[i], t = MT[i], p = MP[i] }
    end
  end
  st.top = 0
  return out
end
-- 走一步棋（对局里真正走的）。找不到返回 false
api.play = function(f, t, p)
  st.top = 0
  gen(false)
  for i = 1, st.top do
    if MF[i] == f and MT[i] == t and MP[i] == p and make(i) then
      st.ply, st.top = 0, 0
      return true
    end
  end
  st.top = 0
  return false
end
-- 局面结束了没有："mate" / "stalemate" / "draw"（只剩王，或王加一个轻子） / nil
api.status = function()
  local minors, others = 0, 0
  for k = 1, 64 do
    local a = B[SQ[k]]
    if a < 0 then a = -a end
    if a == 2 or a == 3 then minors = minors + 1 elseif a == 1 or a == 4 or a == 5 then others = others + 1 end
  end
  if others == 0 and minors <= 1 then return "draw" end
  if #api.legal() > 0 then return nil end
  if api.in_check() then return "mate" end
  return "stalemate"
end
-- 逐步加深搜索。hook(from, to) 在根节点每换一个候选走法时调用（画“看得见的思考”，也读按键）
api.search = function(secs, hook)
  st.top, st.ply, st.nodes, st.abort = 0, 0, 0, false
  deadline = rb.current_tick() + secs * HZ
  node_cap = secs * 3000
  gen(false)
  local n = 0
  for i = 1, st.top do -- 只留合法的，挪到前面
    if make(i) then
      unmake()
      n = n + 1
      MF[n], MT[n], MP[n], MX[n], MS[n] = MF[i], MT[i], MP[i], MX[i], MS[i]
    end
  end
  st.top = n
  if n == 0 then return nil end
  for i = 1, n do pick_best(i, n) end
  local best_i, best_sc = 1, -MATE
  for depth = 1, 6 do
    local alpha, cur_i, done = -MATE - 1, 1, true
    for i = 1, n do
      if hook then hook(MF[i], MT[i]) end
      make(i)
      local sc = -negamax(depth - 1, -MATE - 1, -alpha, 0)
      unmake()
      if st.abort and depth > 1 then done = false; break end
      if sc > alpha then alpha, cur_i = sc, i end
    end
    if not done then break end
    best_i, best_sc = cur_i, alpha
    -- 最好的一步挪到最前面，下一层先搜它
    MF[1], MF[best_i] = MF[best_i], MF[1]; MT[1], MT[best_i] = MT[best_i], MT[1]
    MP[1], MP[best_i] = MP[best_i], MP[1]; MX[1], MX[best_i] = MX[best_i], MX[1]
    best_i = 1
    if best_sc >= MATE - 50 or st.abort then break end
  end
  local f, t, p = MF[best_i], MT[best_i], MP[best_i]
  st.top = 0
  return f, t, p, best_sc, st.nodes
end
return api
end)()

-- ================= 界面 =================
local main = function()
local SQS, BX, BY = 16, 0, 2         -- 每格 16 像素；棋盘左上角
local SX = 128                       -- 右边的窄条
local LIGHT, DARK = { 214, 202, 172 }, { 122, 146, 112 }
local C = {
  wfill = rgb(246, 243, 232), wline = rgb(40, 36, 32),
  bfill = rgb(46, 42, 40), bline = rgb(10, 8, 8),
  hint = rgb(240, 196, 70), cursor = rgb(250, 220, 90),
  strip = rgb(30, 32, 36), ink = rgb(190, 192, 196), dim = rgb(110, 114, 120),
}
-- 每格的底色：普通 / 上一步 / 被将 / 选中 / 思考中
local TINT = { last = { 236, 214, 120 }, check = { 230, 90, 80 }, sel = { 150, 200, 120 }, think = { 120, 150, 230 } }
local SQC = {}
for _, base in ipairs({ LIGHT, DARK }) do
  local t = { plain = pack(base) }
  for k, v in pairs(TINT) do t[k] = pack(mix(base, v, (k == "think") and 45 or 55, 100)) end
  SQC[#SQC + 1] = t
end

-- 棋子点阵：o 是轮廓，x 是填充；12 宽，底部对齐
local ART = {
  { "....oooo....", "...oxxxxo...", "...oxxxxo...", "....oxxo....", "...oxxxxo...", "....oxxo....",
    "....oxxo....", "...oxxxxo...", "..oxxxxxxo..", ".oxxxxxxxxo.", ".oooooooooo." },
  { "....oo......", "...oxxoo....", "..oxxxxxoo..", ".oxxoxxxxxo.", ".oxxxxxxxxo.", "..ooooxxxxo.",
    "....oxxxxo..", "...oxxxxxo..", "...oxxxxxo..", "..oxxxxxxxo.", ".oxxxxxxxxo.", ".oooooooooo." },
  { ".....oo.....", "....oxxo....", "...oxxoxo...", "...oxoxxo...", "...oxxxxo...", "....oxxo....",
    "...oooooo...", "....oxxo....", "...oxxxxo...", "..oxxxxxxo..", ".oxxxxxxxxo.", ".oooooooooo." },
  { ".oo.oooo.oo.", ".oxooxxooxo.", ".oxxxxxxxxo.", ".oooxxxxooo.", "...oxxxxo...", "...oxxxxo...",
    "...oxxxxo...", "...oxxxxo...", "..oxxxxxxo..", ".oxxxxxxxxo.", ".oooooooooo." },
  { "o...o..o...o", "ox.oxooxo.xo", "oxxoxxxxoxxo", ".oxxxxxxxxo.", "..oxxxxxxo..", "...oxxxxo...",
    "...oxxxxo...", "..oooooooo..", "...oxxxxo...", "..oxxxxxxo..", ".oxxxxxxxxo.", ".oooooooooo." },
  { ".....oo.....", "...ooxxoo...", "...ooxxoo...", ".oooooooooo.", ".oxxxxxxxxo.", "..oxxxxxxo..",
    "...oxxxxo...", "..oooooooo..", "...oxxxxo...", "..oxxxxxxo..", ".oxxxxxxxxo.", ".oooooooooo." },
}
-- 预先转成游程：{ 是否轮廓, x, y, 长度 }；small 是缩小一半的版本（窄条里用）
local RUNS, SMALL = {}, {}
for t = 1, 6 do
  local rows, runs, small = ART[t], {}, {}
  local top = 15 - #rows
  for y, row in ipairs(rows) do
    local x = 1
    while x <= 12 do
      local ch = string.sub(row, x, x)
      if ch ~= "." then
        local x2 = x
        while x2 < 12 and string.sub(row, x2 + 1, x2 + 1) == ch do x2 = x2 + 1 end
        runs[#runs + 1] = { ch == "o", x + 1, top + y - 1, x2 - x + 1 }
        x = x2
      end
      x = x + 1
    end
    if mod(y, 2) == 1 then
      for sx = 1, 12, 2 do
        local ch = string.sub(row, sx, sx)
        if ch ~= "." then small[#small + 1] = { ch == "o", div(sx - 1, 2), div(y - 1, 2) } end
      end
    end
  end
  RUNS[t], SMALL[t] = runs, small
end

local function sq_xy(sq) -- 信箱格 → 屏幕左上角
  local r = div(sq, 10) - 2
  return BX + (sq - (r + 2) * 10 - 1) * SQS, BY + r * SQS
end
local function draw_piece(p, x, y)
  if p == 0 then return end
  local t, white = p, true
  if p < 0 then t, white = -p, false end
  for _, r in ipairs(RUNS[t]) do
    if r[1] then fg(white and C.wline or C.bline) else fg(white and C.wfill or C.bfill) end
    rect(x + r[2], y + r[3], r[4], 1)
  end
end

-- ---------- 状态 ----------
local LEVELS = { 3, 10, 30 }
local G = {
  mode = "pick", level = 1, hist = {}, legal = {}, pieces = {}, targets = {},
  cur = 1, tcur = 1, pcur = 1, sel = 0, last_f = 0, last_t = 0, think_f = 0, think_t = 0,
  games = 0, wins = 0, undos = 0, last_undos = 0, result = nil, note = nil, note_until = 0,
  quit = false, shown = {}, strip_key = "", watch = false, over_at = 0, reps = {}, half = 0,
}
local PROMOS = { 5, 4, 3, 2 }

local function save()
  local h = {}
  for i, m in ipairs(G.hist) do h[i] = m.f .. "," .. m.t .. "," .. m.p end
  save_kv(SAVE, { moves = table.concat(h, ";"), level = G.level, games = G.games, wins = G.wins,
                  undos = G.undos, last_undos = G.last_undos, result = G.result or "",
                  watch = G.watch and 1 or 0 })
end

-- 轮到玩家：算出能动的棋子和各自的落点
local function refresh_turn()
  G.legal = E.legal()
  local seen, list = {}, {}
  for _, m in ipairs(G.legal) do
    if not seen[m.f] then seen[m.f] = true; list[#list + 1] = m.f end
  end
  -- 从左到右、从下到上排，转盘转起来像扫过棋盘
  table.sort(list, function(a, b)
    local ca, cb = mod(a, 10), mod(b, 10)
    if ca ~= cb then return ca < cb end
    return a > b
  end)
  G.pieces = list
  if G.cur > #list then G.cur = 1 end
end
local function targets_of(f)
  local seen, list = {}, {}
  for _, m in ipairs(G.legal) do
    if m.f == f and not seen[m.t] then seen[m.t] = true; list[#list + 1] = m.t end
  end
  table.sort(list, function(a, b)
    local ca, cb = mod(a, 10), mod(b, 10)
    if ca ~= cb then return ca < cb end
    return a > b
  end)
  return list
end

-- 和棋规则要用：同一局面出现几次；多少步没动兵也没吃子
local function position_key()
  local t = {}
  for r = 2, 9 do for f = 1, 8 do t[#t + 1] = string.char(E.B[r * 10 + f] + 70) end end
  t[#t + 1] = E.side()
  return table.concat(t)
end
local function note_position(reset)
  if reset then G.half = 0 else G.half = G.half + 1 end
  local k = position_key()
  G.reps[k] = (G.reps[k] or 0) + 1
end
-- 所有真正走的棋都从这里走
local function play_move(m)
  local p, cap = E.B[m.f], E.B[m.t]
  if not E.play(m.f, m.t, m.p) then return false end
  note_position(p == 1 or p == -1 or cap ~= 0)
  return true
end

local function finish_game(result)
  G.result = result
  G.mode = "over"
  G.over_at = rb.current_tick()
  if not G.watch then -- 电脑对电脑的局不算进你的记录
    G.games = G.games + 1
    if result == "1-0" then G.wins = G.wins + 1 end
    G.last_undos = G.undos
  end
  save()
end
local function check_over()
  local s = E.status()
  if not s and (G.half >= 100 or (G.reps[position_key()] or 0) >= 3) then s = "draw" end -- 50 步、三次重复
  if not s then return false end
  if s == "mate" then finish_game((E.side() == 1) and "0-1" or "1-0") else finish_game("1/2") end
  return true
end

local function new_game()
  E.new_game()
  G.reps, G.half = {}, 0
  note_position(true)
  G.hist, G.result, G.undos = {}, nil, 0
  G.last_f, G.last_t, G.cur = 0, 0, 1
  G.mode = G.watch and "think" or "pick"
  if G.last_undos > 0 and not G.watch then G.note, G.note_until = "undo " .. G.last_undos, rb.current_tick() + 6 * HZ end
  refresh_turn()
end

-- 从走法记录重新摆出局面（读档、悔棋都用它）
local function replay(hist)
  E.new_game()
  G.reps, G.half = {}, 0
  note_position(true)
  local ok = {}
  for _, m in ipairs(hist) do
    if not play_move(m) then break end
    ok[#ok + 1] = m
  end
  G.hist = ok
  local l = ok[#ok]
  G.last_f, G.last_t = l and l.f or 0, l and l.t or 0
end

local function load()
  local s, found = load_kv(SAVE)
  G.level = clamp(num(s.level, 1), 1, #LEVELS)
  G.games, G.wins = num(s.games, 0), num(s.wins, 0)
  G.last_undos = num(s.last_undos, 0)
  G.watch = s.watch == "1"
  new_game()
  G.note = nil
  if not found then return end
  local hist = {}
  for f, t, p in string.gmatch(s.moves or "", "(%d+),(%d+),(%d+)") do
    hist[#hist + 1] = { f = num(f, 0), t = num(t, 0), p = num(p, 0) }
  end
  replay(hist)
  G.undos = num(s.undos, 0)
  if s.result and s.result ~= "" then G.result, G.mode, G.over_at = s.result, "over", rb.current_tick()
  elseif E.side() == -1 or G.watch then G.mode = "think"
  else refresh_turn() end
end

-- ---------- 画面 ----------
-- 每格算一个“该长什么样”的键，和上次画的不一样才重画
local function square_look(sq)
  local look = "plain"
  if sq == G.think_f or sq == G.think_t then look = "think"
  elseif G.mode == "target" and sq == G.sel then look = "sel"
  elseif sq == G.last_f or sq == G.last_t then look = "last" end
  if G.check_sq == sq then look = "check" end
  local p = E.B[sq]
  if G.mode == "promo" and sq == G.targets[G.tcur] then p = PROMOS[G.pcur] end
  -- 落点提示：选子时预览光标那颗子的落点，落子时显示选中那颗子的落点
  local hint = G.hint_set[sq] and ((E.B[sq] ~= 0) and "cap" or "dot") or ""
  local cursor = (sq == G.cursor_sq)
  return look, p, hint, cursor
end
local function draw_square(sq, look, p, hint, cursor)
  local x, y = sq_xy(sq)
  local r = div(sq, 10)
  local light = mod(r + sq, 2) == 1
  fg(SQC[light and 1 or 2][look])
  rect(x, y, SQS, SQS)
  draw_piece(p, x, y)
  if hint == "dot" then
    fg(C.hint); rect(x + 6, y + 6, 4, 4)
  elseif hint == "cap" then -- 能吃的子：四个角
    fg(C.hint)
    rect(x, y, 4, 2); rect(x, y, 2, 4); rect(x + 12, y, 4, 2); rect(x + 14, y, 2, 4)
    rect(x, y + 14, 4, 2); rect(x, y + 12, 2, 4); rect(x + 12, y + 14, 4, 2); rect(x + 14, y + 12, 2, 4)
  end
  if cursor then
    fg(C.cursor)
    rect(x, y, SQS, 1); rect(x, y + SQS - 1, SQS, 1); rect(x, y, 1, SQS); rect(x + SQS - 1, y, 1, SQS)
    rect(x + 1, y + 1, SQS - 2, 1); rect(x + 1, y + SQS - 2, SQS - 2, 1); rect(x + 1, y + 1, 1, SQS - 2); rect(x + SQS - 2, y + 1, 1, SQS - 2)
  end
end

local function draw_strip()
  -- 被吃掉的子：上面是你吃掉的（黑子），下面是它吃掉的（白子）
  local count = { [1] = {}, [-1] = {} }
  for t = 1, 6 do count[1][t], count[-1][t] = 0, 0 end
  for r = 2, 9 do for f = 1, 8 do
    local p = E.B[r * 10 + f]
    if p > 0 then count[1][p] = count[1][p] + 1 elseif p < 0 then count[-1][-p] = count[-1][-p] + 1 end
  end end
  local START = { 8, 2, 2, 2, 1, 1 }
  local lost = { [1] = {}, [-1] = {} }
  local key = G.mode .. (G.result or "") .. G.level .. (G.note or "") .. (G.watch and "w" or "")
  for _, s in ipairs({ 1, -1 }) do
    for _, t in ipairs({ 5, 4, 3, 2, 1 }) do
      local n = START[t] - count[s][t]
      for _ = 1, n do lost[s][#lost[s] + 1] = t end
      key = key .. n
    end
  end
  if key == G.strip_key then return end
  G.strip_key = key
  fg(C.strip); rect(SX, 0, W - SX, H)
  for side, y0 in pairs({ [-1] = 4, [1] = 40 }) do
    for k, t in ipairs(lost[side]) do
      local x = SX + 3 + mod(k - 1, 7) * 6
      local y = y0 + div(k - 1, 7) * 8
      for _, d in ipairs(SMALL[t]) do
        if d[1] then fg(side == 1 and C.wline or C.ink) else fg(side == 1 and C.wfill or C.bfill) end
        rect(x + d[2], y + d[3], 1, 1)
      end
    end
  end
  if G.result then
    text(SX + 4, H - 40, G.result, C.cursor, C.strip)
    text(SX + 4, H - 28, G.wins .. "/" .. G.games, C.ink, C.strip)
  elseif G.note then
    text(SX + 4, H - 28, G.note, C.ink, C.strip)
  end
  text(SX + 4, H - 14, (G.watch and "auto " or "") .. LEVELS[G.level] .. "s", G.watch and C.ink or C.dim, C.strip)
end

local function render()
  G.hint_set = {}
  G.cursor_sq = 0
  if G.mode == "pick" and #G.pieces > 0 then
    G.cursor_sq = G.pieces[G.cur]
    for _, t in ipairs(targets_of(G.cursor_sq)) do G.hint_set[t] = true end
  elseif G.mode == "target" or G.mode == "promo" then
    for _, t in ipairs(G.targets) do G.hint_set[t] = true end
    G.cursor_sq = G.targets[G.tcur]
  end
  G.check_sq = 0
  if G.mode ~= "over" or G.result ~= "1/2" then
    if E.in_check() then
      for r = 2, 9 do for f = 1, 8 do if E.B[r * 10 + f] == 6 * E.side() then G.check_sq = r * 10 + f end end end
    end
  end
  for r = 2, 9 do
    for f = 1, 8 do
      local sq = r * 10 + f
      local look, p, hint, cursor = square_look(sq)
      local key = look .. p .. hint .. (cursor and "c" or "")
      if G.shown[sq] ~= key then
        G.shown[sq] = key
        draw_square(sq, look, p, hint, cursor)
      end
    end
  end
  draw_strip()
  rb.lcd_update()
end

-- ---------- 对手 ----------
local function think_hook(f, t)
  G.think_f, G.think_t = f, t
  render()
  for _, e in ipairs(poll()) do
    if e.k == "menu" and not e.rel then G.quit = true
    elseif e.k == "next" and not e.rel and not e.rep then G.watch = not G.watch end
  end
  if G.quit then return end
  keep_light()
  if rb.yield then rb.yield() end
end
local function engine_move()
  local secs = LEVELS[G.level]
  -- 它输了不认输，只是想得越来越久
  local ev = 0
  if G.last_eval and G.last_eval < -300 then ev = clamp(div(-G.last_eval - 300, 150), 0, 4) end
  secs = secs + div(secs * ev, 2)
  local f, t, p, sc = E.search(secs, function(a, b)
    think_hook(a, b)
    if G.quit then error("quit") end
  end)
  G.think_f, G.think_t = 0, 0
  if not f then return end
  G.last_eval = sc
  local m = { f = f, t = t, p = p }
  play_move(m)
  G.hist[#G.hist + 1] = m
  G.last_f, G.last_t = f, t
  if not check_over() then
    -- 电脑对电脑：接着替另一方想；否则轮到白方时交给你
    if G.watch or E.side() == -1 then G.mode = "think" else G.mode = "pick" end
    refresh_turn()
  end
end

-- ---------- 主循环 ----------
load()
light_start()
fg(C.strip); rect(0, 0, W, H)
render()

while not G.quit do
  for _, e in ipairs(poll()) do
    if not e.rel then
      local k = e.k
      if k == "menu" then
        if G.mode == "target" then G.mode = "pick"
        elseif G.mode == "promo" then G.mode = "target"
        else G.quit = true end
      elseif k == "fwd" or k == "back" then
        local d = (k == "fwd") and 1 or -1
        if G.mode == "pick" and #G.pieces > 0 then G.cur = mod(G.cur - 1 + d, #G.pieces) + 1
        elseif G.mode == "target" then G.tcur = mod(G.tcur - 1 + d, #G.targets) + 1
        elseif G.mode == "promo" then G.pcur = mod(G.pcur - 1 + d, #PROMOS) + 1 end
      elseif k == "play" and not e.rep then
        G.level = mod(G.level, #LEVELS) + 1
      elseif k == "next" and not e.rep then
        G.watch = not G.watch
        if G.watch and (G.mode == "pick" or G.mode == "target" or G.mode == "promo") then G.mode = "think" end
      elseif k == "prev" and not e.rep and (G.mode == "pick" or G.mode == "target") then
        -- 悔棋：退回到上一次轮到你的时候
        local h = G.hist
        local n = #h
        if n > 0 then
          n = n - 1
          if mod(n, 2) == 1 then n = n - 1 end
          local keep = {}
          for i = 1, n do keep[i] = h[i] end
          replay(keep)
          G.undos = G.undos + 1
          G.result, G.mode = nil, "pick"
          refresh_turn()
          save()
        end
      elseif k == "select" and not e.rep then
        if G.mode == "pick" and #G.pieces > 0 then
          G.sel = G.pieces[G.cur]
          G.targets = targets_of(G.sel)
          G.tcur, G.mode = 1, "target"
        elseif G.mode == "target" then
          local t = G.targets[G.tcur]
          local promo = false
          for _, m in ipairs(G.legal) do if m.f == G.sel and m.t == t and m.p > 0 then promo = true end end
          if promo then G.pcur, G.mode = 1, "promo"
          else G.pending = { f = G.sel, t = t, p = 0 } end
        elseif G.mode == "promo" then
          G.pending = { f = G.sel, t = G.targets[G.tcur], p = PROMOS[G.pcur] }
        elseif G.mode == "over" then
          new_game()
        end
      end
    end
  end

  if G.pending then
    local m = G.pending
    G.pending = nil
    if play_move(m) then
      G.hist[#G.hist + 1] = m
      G.last_f, G.last_t = m.f, m.t
      if not check_over() then G.mode = "think" end
      save()
    end
  end

  if G.note and rb.current_tick() > G.note_until then G.note = nil end
  -- 电脑对电脑：一局结束停 10 秒，再开下一局
  if G.watch and G.mode == "over" and rb.current_tick() > G.over_at + 10 * HZ then new_game() end
  render()

  if G.mode == "think" then
    local ok = pcall(engine_move)
    if not ok then G.quit = true end
    if not G.quit then save() end
  end

  keep_light()
  rb.sleep(div(HZ, 20))
end

save()
light_end()
end
main()
