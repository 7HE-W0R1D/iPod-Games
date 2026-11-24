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
-- Menu 特别处理：短按在松开时才发一个 {k="menu"}（退出），按住 0.8 秒发 {k="help"}（说明页）
local menu_down, menu_fired = nil, false
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
      if k == "menu" then
        if rel then
          if menu_down and not menu_fired then ev[#ev + 1] = { k = "menu" } end
          menu_down, menu_fired = nil, false
        elseif not menu_down then
          menu_down, menu_fired = rb.current_tick(), false
        end
      elseif k then
        if (k == "fwd" or k == "back") and not rel then wheel_note() end
        ev[#ev + 1] = { k = k, rel = rel, rep = rep }
      end
    end
  end
  -- 按住不放：不用等系统的重复事件，自己看时间
  if menu_down and not menu_fired and rb.current_tick() - menu_down >= div(HZ * 4, 5) then
    menu_fired = true
    ev[#ev + 1] = { k = "help" }
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

-- ---------- 说明页（每个应用里长按 Menu 打开） ----------
-- lines：一行一句，最多约 28 个字符；转盘上下翻，按任意键关掉。关掉以后应用自己重画整屏。
local function help_screen(title, lines)
  local bg, ink, hi, dim = rgb(22, 26, 34), rgb(220, 224, 230), rgb(240, 150, 60), rgb(120, 128, 140)
  local rows = div(H - 16, 10)
  local top, shown = 1, -1
  local maxtop = math.max(1, #lines - rows + 1)
  while true do
    if shown ~= top then
      shown = top
      fg(bg); rect(0, 0, W, H)
      text(4, 2, title, hi, bg)
      if maxtop > 1 then text_r(W - 3, 2, top .. "/" .. maxtop, dim, bg) end
      for k = 0, rows - 1 do
        local s = lines[top + k]
        if s then
          local c = ink
          if string.sub(s, 1, 1) == "*" then s, c = string.sub(s, 2), hi end -- 星号开头：标题行
          text(4, 15 + k * 10, s, c, bg)
        end
      end
      rb.lcd_update()
    end
    for _, e in ipairs(poll()) do
      if e.k == "fwd" and not e.rel then top = clamp(top + 1, 1, maxtop)
      elseif e.k == "back" and not e.rel then top = clamp(top - 1, 1, maxtop)
      elseif (e.k == "menu" or not e.rel) and e.k ~= "help" and not e.rep then return end
    end
    keep_light()
    rb.sleep(div(HZ, 20))
  end
end
-- ==== 共用部分结束 ====

-- 由 tools/yosemite.py 从优胜美地隧道观景台的照片生成，不要手改
-- rows：每行的游程，两字符一段：类别 chr(48+v)、长度 chr(48+n)。v=0 天空，1..12 材质×档，13..24 会被辉光照到
local SCENE = {
  levels = 6,
  skyline = [==[::;<>@AABCEFIJKLLMNOPQRSWYZZZ^^]\\[ZZZYYYYYYYVVVWWWWYYZZ[[[[[[]^]^^```````````_ZYVUUVVWXXXXXWWWWWXXYZZZ[[ZZYYXWWVUUTTSRRRRRQQQQPPOONNNNMMMMMMLLLLLLLKKKJJIIIIIIHHHHHHGGFFEEEEEEE]==],
  pal = { { 38, 55, 73 }, { 55, 79, 101 }, { 68, 90, 110 }, { 103, 115, 124 }, { 167, 160, 156 }, { 236, 221, 205 }, { 33, 49, 62 }, { 52, 62, 67 }, { 70, 76, 72 }, { 88, 89, 77 }, { 104, 102, 86 }, { 142, 135, 116 }, { 43, 59, 76 }, { 58, 80, 101 }, { 70, 92, 112 }, { 98, 115, 130 }, { 157, 161, 167 }, { 224, 209, 196 }, { 33, 49, 62 }, { 52, 62, 67 }, { 70, 76, 72 }, { 88, 89, 77 }, { 104, 102, 86 }, { 142, 135, 116 } },
  rows = [==[
0v0v0T
0v0v0T
0v0v0T
0v0v0T
0v0v0T
0v0v0T
0v0v0T
0v0v0T
0v0v0T
0v0v0T
B1A10v0v0R
B30v0v0Q
B40v0v0P
B2A20v0v0P
B50v0v0O
A1B40v0v0O
A3B30v0v0N
A4B3A10v0v0L
B6A30v0v0K
B:0v0v0J
B9A10v0v0J
B8A2B10v0v0BA7
B7A3B20v0v0?A1@2A6
B7A3B20v0v0=A2@2A7
B<0v0v07@9A8
B3A2B3A2B30v0v@@A7
B>0v0s@1?5@4?6@5A4
B?0v0o@3?3@2?;@9
B=A3B10v0f@7?4@2?F
A1B<A4B10v0_@8?<>2?4>3=5>5?1@1
B=A3B30v0Z@4?8@3?9>2?2>4=;>1?1
B>A3B30v0W@3?H>2?4>9=3>2
62B:A6B30v0T@2?5>2@4?1>3?<>2?3>;=2>2
63B;A4B40v0O@4?9@5?1>2?1@2?7>7=1?6@1>7
64B9A5B50v0IA2@3?:@2?5@6?:>4=2A1@1>1?4>1=6
64B9A5B60v0G@1?FA1@3>5?1@2>1?7=1>1@2?1>3=8
65BC0v0EA1@1?2@3?3@2?:>2?1@4>:?4>1=3?3>2=4>2=3
65BC0jA20MA1@2?4@1A2?2@3>1?7>2?2@2?2>;?3=4?1>4=2>4=3
66BB0EB30QA50JA1@4?3@2A1?1@4?6@1>3?3A1@1>8?2>4?1=4?1>8=5
68B7A2B80DA5B20MA605B50=A1@1?3@2?2@6?;>2?3A1@1>7?7>1=4>3=;
69B<A2B20DA70MA3@5A2B80:A1?5@2?2@5?<>2?3A2?2>5?4@2?1>1=3>3=<
6:B?A10<B6A:0JA4@5?1A2B807A2@8?2@2A3?1>2?1@2?;@1A1?1>6?2@5?1=8>2=8
6:B4A2B5A2B606AE0GA5@4?2@2A1B6A3B102B1A1?4@6?4A3?1>2?1@5A1?2>2?6>7?3@3=9>5?2>1=2
6;B:A2B3A305AL0AA4@5?2@3A1B2A8@1?6@2?2@2?4A3?1>2?2@6?5>2?2>8?5=:>227
6<B>A303AN0AA4@;B2A6@1?7@3?2@2?4A3?1>2?3@6?4>2?1@1>;?1=9>221122531
6<B8A4B2A302A=B8A:B101A10>A4@;A6@2?2@<?3@2A3?6@7?6@1>:?2=92;
6<B9A3B3AAB:A5B4A40<A3@=A4@1?4@<?3@2A3?6@5A1?7@1><=3192612
6=B8A4B4A>B;A5B6A20;A3@?A1?6@9?7@1A4@1?5@4?9@1>6?2>1311F
6>B7A4B3A>B<A5B6A=@B?7@:?6@1A4@1?5A3@2A1?8>6?1331F
6?B6A3B4A<B>A8B2A=@A?7@<?6@1A3B1@1?5A6?5>2?2>325311F
6AB3A5B3A;B>A3@2A=B2A4@=A2@1?8@<?6@1A5@1?4@2A3@1?52232291F
6BB2A5B3A=B5A8@2A3B3A:B3A1@A?7@<?7@1A5@1?3@1A542382232241E22
6CB2A5B<A4B2A5B6A4B5A<@??7@>?7@1A6@1?2@1A144524336241J
6DB2A4B9A=B5A9B4A5@A?7@8A3@4?:A5@4415342524334241L
6EB1A2B9ABB5A4@2A4B2A5@@?6@>?;A5@25245534334231M
6FA3B3A2B2ADB4AA@@?4@??<A352425642524433231M
6F51A2B2A=B2A6@3A3B2A1@3A3@2A3B2A2@PA2@1?3@2?6325A4136221N
6F52A1B2A=B2A4@6A5@2A4@2A1B4A1@S?1>2?4>2?233425743554134231O
6G51B3A2B2A8B2A5@6A4@2A1B2A1@2A6@2?2@P?7>235425@4133231O
6C55AP@3A9@1?6@4?342@F?6>122355A4131261N21
6D54A:@2A3@3A353A7@7A5?9@2?33144@E?524344253625444524131261O
6>52645461B1A8@8A34156A7@4A3@2?:>2?1324331@545@=3223364158465135231F221621
6>5:61B1A=@2A3@1425441A=@4?7>4?1314A@7?331253543574537231F251321
6>5;61A4B2A65742534351A3@2A4@8?9314B31@5?231273542574636231H24311221
6>5:6253A665544458A1@2A4@8?7>1324>3543@24131283445534836231H261131
6>5:635141A2B351655542594353@9?6>221314?3545243322344355463641241J22321141
6>53635841A35262594258445241@9?2>635455749253941574934241L34
6=53655741A25263574458425345@6?2>5?134465246534431253:5:43344231241M43
6>536855425;43524253435447@1?5>6334<5645253:415942322233251M2152
6>5L42524352455249?6>521324;574136243322344259332233261N4151
6?5:635=4>54483424322232423246593226392143524738251P41
6C5764584A55493327334>534131273:42534539261P31
6A526;5942524;53463343332436423247372839493;261Q
6?5463526552425;4B34433<433<2=3:47362332261Q
6?546;52425:4A3443332436433324332=3>44372;1Q
6?536>5<4:52453C433525322>3748392:1Q
6@566<5:4A334238223442362E322233433>291R
6=596954635649524538293?2=322336423?291R
6=596;52625748534439283A2<322336423>2:1R
6>5<6651425861485342334434283>2A39423=2:1S
695368524458425264534;3443322437223<2A32223824382:1S
69536653475462514251645446524135433;433125362A342238233322332:1S
695<48546254635545523@463126382B374126362;1T
695143584:536856443:4;3228372A3:2639281T
6953425748556:55413;4;312<342A3;2A32231U
6951455645596955413947362R3722322F1U
6952435C6:5363413F2Q3322332J1U
6951475463536E523:423243352P3422332B12261U
6951495162556E533945352E322:352O1U
51694951625242526G413943352T332G1224311V
51694:5442536F513A2C322^321V
4169524>546F413C2>332Y3224321:22311I
<4665144544;516D523D2<332X32281923321H
<8625146544:546B51423B2934273222352H33281;2232211F
<;5246534;526B5335223<2:3221433342362H33281=21331F
<?514353475244516@52624134223<2835443243332I322:1>241E
<C4153465345516>553A253D24332O1<271D
<F4;5343516=553;2433493D2G13261=261D
<J;5<2534551635464554132223622324<36423543312H14271>42112316221;
<\625=413122384@3442392G15271>4224152717
<K;2<2;2<L;1:2;5<:;2<9;9:19388988<9112221?421<2132423115
;1<N;2<M;5<8;2<<;5<2;3:19@8F7<81<1;1811;21324315
91;1<m:4;6<:;4<2;::29M887=968:91;28175
91:2<O;4<I;3:G94:792;2:89H817=82;1978;75
8193;1<4;2<J:1;1<8;3<>:1;7:<;2:494:1;5:191;8:19;:8;192;291817;867194:182728478
8293:1<3;5<Q;5<<:4;9:2;K:2;4:191;1:8;<9181748276847291:3837>
9182:192;2<2;4<?;2<C;1:1<3;7<2:4;6<1:1;4:6;4<1:3;3:2;1<1:1;D:8;491817=837381:371847;81
;1<194:3;8<=;8<A;2<2;5:2;8<1:1;7:2;891:@;3:2;2:797:291827=83738191:1;2827<82
;1:1<1;18191;291:5<1;2<>;2:1<;;=:2;4:7;@:G;2:198:3918692817F81;192817>81
<4;181:7;7<2;2<4;8<6;2:2;592:1;2<1::93:992:28191:2;2:492:295:296:2928892847F8274847?81
<5;1:191;1:?;3<1:2;4<1:1;191:68191:2938292:29C:28392839682928296897S827581927A81
<1;1:2<3;18295:2;1<1:1;192::;2:19<849788:1958391:181938<92869272867S837581:191817@81
;4<4;18391:C91;1:1938:9285928:968392887289:191857U827481:19181748374827:82
82;5<2;193:4;191:392;5:2;19682917184948O788:7`81928172928374827<
;181:37181;1<3:182:4;294;2<2;1:4988H938@7o9372819284798276
<191:4;1<4;1:6;1<2;18191:2;89;8D958492839271847j918171937281:191837:819176
<4:1;4<3;1:38191;1:7;4:2;3:2958G968391:381928573837d968171947484748672
<692;1<5:292:4;6<7;391:4918?9288948298837287917]81:194:18196:185937283948172
;4<2:191;4<4:4;4<6:2<3;591:2;182:291837285948691:29681:1938>7?827D82769::1;195718193817191:1819582
:1;3<3;2<;;7<4:1;2<4;68191<1;2:291839285;19181:392:482:4938?72918791:182:191837:9181728191:184917294:295:1;191:39782:198
91:1;2<791;1<6:4<2;2:1<4;3<8;8:4;2:5;2:6;2:196:18K91:1;29487758491:1;198:59B:;
<1:191<9;2<1:2<29183;1<3;5<1:1;4<5;A:191;1:392:583:4918:73849171839481:2;19286788194:2;2:295:59:8292:294:8
<?91:1;1<2;193:2;3<4;2:191;2<7:6;6:294:292:29482958;738:9281:2;1918476819;:782:4;191839683:197:691
<3;2<2;2<6;78193:2;6<2;1:2;4<3;191:391;1:5<1;192;49;:2918C748591:291817::68194;1:18191:39181:4;19183:287:19281;1:692:181
<7:2;1<6;2:69183:3;2:1<3;6<3;191:1<1;2<1:191;;:298829488728@91:373827691829384948792;1:293:28291:28191:29181;1:192:18195
<7:1;1<9;6918394;3<6;3<2;181:1<5;6<2;5:29181:398:281938693829<:181728375899:83:1;194:28391:28192;1:78195
<C91:2;3:6;4<2:1;1<2:1;2<2;3<5:3;2:1<1;8:196:18194:49287:2819<827381938794:18198:293;295;18391:28291;291:5819281:191
;3<7;3<5;192:1;5:1<1;193:2;8<7;4:3<1;1:3;291:1;2:9819582;1:295:3;199:483728192:1819::492:=;191:1;19381:28198:1;19183:1;1
;2<8;2:2;1<:;4938291:2<3;7:1<1;5:18191;2:3;191:7;3:982;3:18193:3;192:692:4928497:1;191:792:1;194:1;191:1;191:1;191:3817191:6;18191:3;184:1<1
<;;7<8;3:1817281:5<1;7<2:5;192;38191;1:391<1;1:3;1<1:5;591:2<1;1:88191:3;2:2998291:7;191:291;4:3;191:18194:1;191:693:6;19381:19184:1;1
;3<6;1:2;5:191;1<7;49481:3;4<2;::191;391:1;3:2;3:;;391:6;2:3;182:89981:193;1:?;38191:1<191:1;191:1;59281;2:4;19282:195:1;1
92;1<5;4:2;2<2;191<6;3<2;194:4;2:1<2;191:4;991:1<1;5:4;2:391;181:2;2:3;2:191;1::91;1:39281:398;1:891;291:3;3:3;191:1;191:4;28192:6;192:491;2:3
]==],
}

-- 穹顶与雾霭：半穹顶和山谷，光跟着真实的时间和季节变，雾在谷底生长、上升、散去
-- 转盘：拨动时间（松手后慢慢退回现在）   Select：藏起/显示角落的日期   Menu：退出
-- 山谷来自优胜美地隧道观景台的照片（tools/yosemite.py 生成 src/data/dome.lua 里的 SCENE）：
-- 左边酋长岩，中间远处半穹顶，右边教堂岩一带，下面谷底的林子。天空不用照片，按真实时间画。

local SAVE = "slow_dome.txt"
local CELL = 4
local FW, FH = div(W, CELL), div(H, CELL)
local FOG_TOP = 9           -- 雾只在这一行（格）以下
local FOG_STEP = 10         -- 现实中每 10 秒雾走一步
local SHIFT_PER_CLICK = 8   -- 转一格拨 8 分钟

-- ---------- 场景：把游程解出来 ----------
-- RUNS.x/y/w/v：每段的起点、长度、类别（天空的段不存，天空另画）
local RUNS = { x = {}, y = {}, w = {}, v = {}, n = 0 }
local skyline = {}
do
  local y = 0
  for line in string.gmatch(SCENE.rows, "[^\n]+") do
    local x = 0
    for i = 1, #line - 1, 2 do
      local v, n = string.byte(line, i) - 48, string.byte(line, i + 1) - 48
      if v > 0 then
        local k = RUNS.n + 1
        RUNS.x[k], RUNS.y[k], RUNS.w[k], RUNS.v[k], RUNS.n = x, y, n, v, k
      end
      x = x + n
    end
    y = y + 1
  end
  for x = 0, W - 1 do skyline[x] = string.byte(SCENE.skyline, x + 1) - 48 end
  SCENE.rows = nil -- 解完就不要了，省内存
end
local stars = {}
do
  local r = Rng(77)
  for i = 1, 45 do
    local x = r(W)
    stars[i] = { x, r(math.max(1, skyline[x] - 2)) }
  end
end

local GLOWC = { 300, 165, 135 } -- 高山辉光：把岩石本色往暖粉色上推（每个分量 /256）
local FOGC = { 232, 234, 240 }

-- ---------- 雾 ----------
local fog = {}
for i = 1, FW * FH do fog[i] = 0 end
local rnd = Rng(rb.current_tick() + now())

-- 每天雾从谷底哪里冒出来不一样：沿着山谷的一条起伏的浓淡曲线（0..100）
local fog_src = { day = -1 }
local function fog_sources(day)
  if fog_src.day == day then return fog_src end
  local r = Rng(hash(day, 9))
  local d = 30 + r(50)
  for x = 0, FW - 1 do
    d = clamp(d + r(41) - 20, 0, 100)
    fog_src[x] = d
  end
  fog_src.day = day
  return fog_src
end

local function fog_step(L, wx)
  local m, sr = L.min, L.sr
  local src = fog_sources(L.day)
  local gen = 0
  if m >= sr - 150 and m < sr + 45 then gen = wx.fog end   -- 清晨在谷底生成
  if wx.rainy and m >= sr and m < sr + 300 then gen = gen + 20 end
  local evap = L.sun > 0 and div(L.sun, 220) or 0           -- 太阳越高蒸发越快
  if wx.inversion then evap = div(evap, 2) end
  local cap = wx.inversion and 16 or FOG_TOP                 -- 云海：雾停在半山腰，半穹顶浮在上面
  local new = {}
  for y = 0, FH - 1 do
    for x = 0, FW - 1 do
      local i = y * FW + x + 1
      local v = fog[i]
      if y >= cap then
        local l = x > 0 and fog[i - 1] or v
        local rr = x < FW - 1 and fog[i + 1] or v
        local b = y < FH - 1 and fog[i + FW] or v
        v = div(v * 3 + l + rr + b * 3 + rnd(3), 8)        -- 向四周扩散一点，向上飘一点
        if y >= FH - 5 and gen > 0 and rnd(100) < div(gen * src[x], 160) then v = v + 1 + rnd(3) end
        if wx.inversion and y <= cap + 1 and v > 4 then v = v + 1 end
        if evap > 0 and rnd(4) < evap then v = v - 1 end
        if not wx.inversion and y < cap + 3 and rnd(3) == 0 then v = v - 1 end
      else
        v = 0
      end
      new[i] = clamp(v, 0, 14)
    end
  end
  fog = new
end

-- ---------- 画面 ----------
local show_date = true

-- 这一刻每一类的颜色：照片本色 × 当前的光；辉光类在日落前后被染成暖粉
local function scene_colors(L)
  local col = {}
  local half = div(#SCENE.pal, 2)
  for v = 1, #SCENE.pal do
    local base = SCENE.pal[v]
    local c = tint(base, L.land)
    if v > half and L.glow > 0 then c = mix(c, tint(base, GLOWC), L.glow, 256) end
    col[v] = pack(c)
  end
  return col
end

local function draw_scene(L)
  -- 天空：4 像素一条的渐变，只画到最低的天际线
  for y = 0, 60, 4 do
    fg(pack(mix(L.top, L.bot, y, 64)))
    rect(0, y, W, 4)
  end
  if L.night then
    fg(rgb(200, 205, 220))
    for _, st in ipairs(stars) do rect(st[1], st[2], 1, 1) end
  end
  local col = scene_colors(L)
  local R = RUNS
  local last = -1
  for i = 1, R.n do
    local v = R.v[i]
    if v ~= last then fg(col[v]); last = v end
    rect(R.x[i], R.y[i], R.w[i], 1)
  end
end

-- 雾和日期单独画（Rockbox 的 Lua 每个函数最多 30 个 upvalue）
local function draw_fog(L, t)
  -- 雾：0～3 四档，用横线疏密表示透明度
  fg(pack(tint(FOGC, L.land)))
  for y = FOG_TOP, FH - 1 do
    for x = 0, FW - 1 do
      local lv = div(fog[y * FW + x + 1], 4)
      if lv > 0 then
        local px, py = x * CELL, y * CELL
        -- 相邻格子的花纹错开，看起来是一团薄雾，而不是一条条横线
        local o = mod(x + y, 2)
        if lv == 3 then rect(px, py, CELL, CELL)
        elseif lv == 2 then rect(px, py + o, CELL, 1); rect(px + 1, py + 2 + o, 2, 1)
        else rect(px + o * 2, py + 1 + o, 2, 1) end
      end
    end
  end
  if show_date then
    local c = civil(t)
    text_r(W - 2, H - 9, string.format("%02d-%02d %02d:%02d", c.m, c.d, c.hh, c.mm),
      pack(mix(tint(FOGC, L.land), L.top, 1, 3)), pack(tint({ 30, 38, 34 }, L.land)))
  end
end

local function draw(L, t)
  draw_scene(L)
  draw_fog(L, t)
  rb.lcd_update()
end

-- ---------- 主循环 ----------
local s = load_kv(SAVE)
show_date = s.date ~= "off"
light_start()

-- 打开时补算：从今天清晨（或最近 2 小时）开始把雾跑到现在
do
  local t = now()
  local L = light_at(t)
  local wx = weather_of(L.day)
  local back = clamp(L.min - (L.sr - 150), 0, 120) -- 分钟
  local n = div(back * 60, FOG_STEP * 6)          -- 补算时一步顶 6 步
  for k = n, 1, -1 do
    local tk = t - k * FOG_STEP * 6
    fog_step(light_at(tk), wx)
    if mod(k, 20) == 0 then fg(rgb(80, 80, 90)); rect(0, H - 2, div((n - k) * W, n), 2); rb.lcd_update() end
  end
end

local shift, last_wheel = 0, 0
local next_fog = rb.current_tick()
local last_min, last_shift = -1, 0
local running = true
local dirty = true
while running do
  for _, e in ipairs(poll()) do
    if e.k == "menu" and not e.rel then running = false
    elseif e.k == "help" then
      help_screen("HALF DOME", {
        "A valley under Half Dome.",
        "Light follows the real time",
        "and season. Fog grows in",
        "the valley, rises, clears.",
        "",
        "*Keys",
        "wheel   shift time (drifts",
        "        back when you stop)",
        "select  show / hide date",
        "menu    quit",
        "hold menu  this help",
      })
      dirty = true
    elseif e.k == "fwd" and not e.rel then shift = clamp(shift + SHIFT_PER_CLICK, -1440, 1440); last_wheel = rb.current_tick()
    elseif e.k == "back" and not e.rel then shift = clamp(shift - SHIFT_PER_CLICK, -1440, 1440); last_wheel = rb.current_tick()
    elseif select_gesture(e) == "short" then show_date = not show_date; dirty = true end
  end
  -- 松手 2 秒后慢慢退回现在
  if shift ~= 0 and rb.current_tick() - last_wheel > 2 * HZ then
    local d = clamp(div(iabs(shift), 15), 1, 30)
    if shift > 0 then shift = math.max(0, shift - d) else shift = math.min(0, shift + d) end
  end

  local t = now()
  if rb.current_tick() >= next_fog then
    next_fog = rb.current_tick() + FOG_STEP * HZ
    local L = light_at(t)
    fog_step(L, weather_of(L.day))
    dirty = true
  end
  local m = div(t, 60)
  if dirty or m ~= last_min or shift ~= last_shift then
    draw(light_at(t, shift), t + shift * 60)
    last_min, last_shift, dirty = m, shift, false
  end
  keep_light()
  rb.sleep(div(HZ, 10))
end

save_kv(SAVE, { date = show_date and "on" or "off" })
light_end()
