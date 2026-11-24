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

-- 高尔夫：一座安静的小球场。慢转瞄准，快拨出杆。一天只开放一个洞。
-- 转盘：慢转调角度，快拨一下出杆（只看那一下的峰值速度）   Select：打完后看一眼杆数   Menu：退出

local SAVE = "slow_golf.txt"
local CW = W * 3                -- 球场宽度
local FP = 16                   -- 定点：位置 ×16
-- 转速单位：每秒转过多少格，一圈 96 格（读转盘的绝对位置算出来的）
local T = {
  -- 上机实测（窗口 0.2 秒时）：慢转 50～100，快拨峰值才 105 左右，所以改用更短的窗口抓快拨
  AIM_MAX = 110,                -- 慢于这个算瞄准
  SHOT_MIN = 170,               -- 快于这个算出杆；中间是死区
  SHOT_FULL = 420,              -- 到这个速度就是满力
  WINDOW = div(HZ, 10),         -- 量转速的时间窗（0.1 秒）：快拨很短，窗口长了会被摊薄
  POWER_MIN = 14,               -- 最轻的一杆（满力是 120）
  GIMME = 8,                    -- 球在果岭上停在离洞这么多像素以内，就算进了
}
-- 按 Play 显示转速读数（now 当前 / peak 最近 3 秒最快），用来上机调上面几个数
local G = 2                     -- 重力（1/16 像素 / tick²）
local CAPTURE = 36              -- 球速低于这个经过洞口才会进

-- cos 表：0°,5°,…,90°，×256
local COS = { 256, 255, 252, 247, 241, 232, 222, 210, 196, 181, 165, 147, 128, 108, 88, 66, 44, 22, 0 }
local function cosd(a)
  a = clamp(a, 0, 90)
  local i = div(a, 5)
  if i >= 18 then return 0 end
  return lerp(COS[i + 1], COS[i + 2], a - i * 5, 5)
end
local function sind(a) return cosd(90 - a) end

-- ---------- 球场：每天一个新地形 ----------
local GRASS, SAND, WATER, GREEN = 0, 1, 2, 3
local ground, kind = {}, {}
local far = {}
local course = {}

local function build(day)
  local r = Rng(hash(day, 3))
  for x = 0, CW - 1 do ground[x] = 100; kind[x] = GRASS end
  -- 缓坡和小丘
  for _ = 1, 6 do
    local cx, w, a = r(CW), 30 + r(90), r(29) - 12
    for x = math.max(0, cx - w), math.min(CW - 1, cx + w) do
      local d = x - cx
      ground[x] = ground[x] - div(a * (w * w - d * d), w * w)
    end
  end
  local tilt = r(21) - 10 -- 整体略微上坡或下坡
  for x = 0, CW - 1 do ground[x] = ground[x] + div(x * tilt, CW) end
  -- 果岭：最后一段压平
  local gx0, gx1 = CW - 90, CW - 10
  local gy = ground[gx0]
  local gslope = r(5) - 2 -- 果岭只有一点点坡
  for x = gx0, CW - 1 do
    ground[x] = lerp(ground[x], gy + div((x - gx0) * gslope, 80), clamp(x - gx0, 0, 20), 20)
    if x <= gx1 then kind[x] = GREEN end
  end
  -- 发球台
  for x = 0, 34 do ground[x] = ground[34] end
  -- 小溪
  local c0 = 120 + r(CW - 300)
  for x = c0, c0 + 15 do ground[x] = ground[x] + 9; kind[x] = WATER end
  -- 沙坑（在溪和果岭之间，或者溪前面）
  local s0 = c0 + 40 + r(math.max(1, gx0 - c0 - 70))
  for x = s0, s0 + 19 do
    if kind[x] == GRASS then ground[x] = ground[x] + clamp(4 - div(iabs(x - s0 - 10), 3), 0, 4); kind[x] = SAND end
  end
  for x = 0, CW - 1 do ground[x] = clamp(ground[x], 66, 122) end
  local rf = Rng(hash(day, 4))
  local h = 84
  for x = 0, W + div(CW, 2) do h = clamp(h + rf(3) - 1, 76, 94); far[x] = h end
  course = { hole = CW - 40, creek = c0, tee = 20, rabbit = r(3) == 0, rx = gx0 - 8 }
  -- 洞
  local hx = course.hole
  for x = hx - 1, hx + 1 do ground[x] = ground[hx - 2] end
end

-- ---------- 状态 ----------
local today = civil(now()).day
local wx = weather_of(today)
local bx, by, vx, vy = 20 * FP, 0, 0, 0
local state = "aim"           -- aim / fly / roll / splash / holed
local angle, strokes = 35, 0
local show_strokes = false
local rabbit_x, rabbit_run = 0, 0
local splash_until, flag_wiggle = 0, 0
local cam = 0

local function load()
  local s = load_kv(SAVE)
  build(today)
  bx = course.tee * FP
  if num(s.day, -1) == today then
    strokes = num(s.strokes, 0)
    bx = num(s.bx, bx)
    angle = num(s.angle, 35)
    if s.holed == "1" then state = "holed" end
  end
  by = ground[div(bx, FP)] * FP
  rabbit_x = course.rx
end
local function save()
  save_kv(SAVE, { day = today, strokes = strokes, bx = bx, angle = angle, holed = state == "holed" and "1" or "0" })
end

local function facing() return bx <= course.hole * FP and 1 or -1 end

local function shoot(power)
  local f = facing()
  if kind[clamp(div(bx, FP), 0, CW - 1)] == GREEN then power = div(power, 2) end -- 果岭上推杆，力度减半
  vx = div(f * power * cosd(angle), 256)
  vy = -div(power * sind(angle), 256)
  state = "fly"
  strokes = strokes + 1
end

local function gnd(x) return ground[clamp(x, 0, CW - 1)] end

-- 进洞：球落进洞里，旗子晃一下
local function sink(tk)
  local hx = course.hole
  bx, by, vx, vy, state = hx * FP, (gnd(hx) + 3) * FP, 0, 0, "holed"
  flag_wiggle = tk + 2 * HZ
  save()
end

-- 一步物理
local function physics(tk)
  local px = div(bx, FP)
  if state == "fly" then
    vy = vy + G
    if mod(tk, 6) == 0 then vx = vx + wx.wind end -- 一点风
    bx, by = bx + vx, by + vy
    if bx < 0 then bx, vx = 0, -div(vx, 2) elseif bx >= (CW - 1) * FP then bx, vx = (CW - 1) * FP, -div(vx, 2) end
    px = div(bx, FP)
    local gy = gnd(px) * FP
    if by >= gy then
      local k = kind[px]
      if k == WATER then
        state, splash_until = "splash", tk + HZ
        return
      end
      by = gy
      if vy > 18 then
        local rest = k == SAND and 8 or (k == GREEN and 3 or 2)
        vy = -div(vy, rest + 1)
        vx = div(vx * (k == SAND and 1 or 4), 5)
      else
        vy, state = 0, "roll"
      end
    end
  elseif state == "roll" then
    local slope = gnd(px + 1) - gnd(px - 1) -- 往右下坡为正
    vx = vx + clamp(slope, -3, 3)
    local k = kind[px]
    local f = k == SAND and 3 or (k == GREEN and 40 or 16)
    vx = vx - div(vx, f) - (vx > 0 and 1 or (vx < 0 and -1 or 0))
    local nx = bx + vx
    local npx = div(nx, FP)
    -- 经过洞口，够慢就进
    local hx = course.hole
    if (px - hx) * (npx - hx) <= 0 and px ~= npx or npx == hx then
      if iabs(vx) < CAPTURE then sink(tk); return end
    end
    bx = nx
    px = clamp(div(bx, FP), 0, CW - 1)
    if kind[px] == WATER then state, splash_until = "splash", tk + HZ; return end
    local gy = gnd(px) * FP
    if gy - by > 2 * FP then state, vy = "fly", 0 -- 滚下了坎
    else by = gy end
    if bx < 0 or bx >= (CW - 1) * FP then bx, vx = clamp(bx, 0, (CW - 1) * FP), 0 end
    if iabs(vx) < 2 and iabs(slope) <= 1 then
      vx = 0
      -- 停在果岭上、离洞足够近，就算进了
      if kind[px] == GREEN and iabs(px - course.hole) <= T.GIMME then sink(tk)
      else state = "aim"; save() end
    end
  elseif state == "splash" then
    if tk >= splash_until then
      -- 不罚杆，在岸边重新放好
      bx = (course.creek - 6) * FP
      by, vx, vy, state = gnd(course.creek - 6) * FP, 0, 0, "aim"
      save()
    end
  end
end

-- ---------- 画面 ----------
local COL = {
  [GRASS] = { 70, 130, 60 }, [SAND] = { 215, 195, 140 }, [WATER] = { 60, 110, 170 }, [GREEN] = { 95, 165, 75 },
}
-- 画面分成几块画：Rockbox 的 Lua 每个函数最多 30 个 upvalue
local function draw_land(L)
  for y = 0, H - 1, 4 do fg(pack(mix(L.top, L.bot, y, 110))); rect(0, y, W, 4) end
  -- 远山（视差，一半速度），淡一些，靠近天边的颜色
  fg(pack(mix(tint({ 90, 110, 120 }, L.land), L.bot, 2, 3)))
  local fo = div(cam, 2)
  for x = 0, W - 1 do local h = far[x + fo] or 84; rect(x, h, 1, H - h) end
  local cols = {}
  for k, c in pairs(COL) do cols[k] = pack(tint(c, L.land)) end
  local dirt = pack(tint({ 90, 70, 45 }, L.land))
  for x = 0, W - 1 do
    local cx = x + cam
    local gy = ground[cx]
    local k = kind[cx]
    if k == WATER then
      fg(dirt); rect(x, gy, 1, H - gy)
      fg(cols[WATER]); rect(x, gy - 6, 1, 6)
    else
      fg(cols[k]); rect(x, gy, 1, 3); fg(dirt); rect(x, gy + 3, 1, H - gy - 3)
    end
  end
end

-- 影子：太阳越低越长；早上往左，傍晚往右
local function shadow_of(L)
  local len = 0
  if L.sun > 0 then len = clamp(div(1000 - L.sun, 45), 1, 24) end
  return len, L.min < div(L.sr + L.ss, 2) and -1 or 1, pack(tint({ 35, 60, 30 }, L.land))
end

local function draw_flag_rabbit(L, tk, shadow, sdir, shc)
  local hx = course.hole - cam
  if hx > -30 and hx < W + 30 then
    local hy = ground[course.hole]
    fg(rgb(10, 10, 10)); rect(hx - 1, hy, 3, 3)
    if shadow > 0 then fg(shc); rect(sdir > 0 and hx or hx - shadow * 2, hy, shadow * 2, 1) end
    fg(rgb(230, 230, 230)); rect(hx, hy - 16, 1, 16)
    local wig = tk < flag_wiggle and (mod(div(tk, 3), 3) - 1) or 0
    fg(pack(tint({ 230, 60, 50 }, L.land)))
    rect(hx + 1, hy - 16 + wig, 6, 2); rect(hx + 1, hy - 14 + wig, 4, 2); rect(hx + 1, hy - 12 + wig, 2, 1)
  end
  if course.rabbit and rabbit_x > -10 and rabbit_x < CW + 10 then
    local rx = rabbit_x - cam
    local ry = ground[clamp(rabbit_x, 0, CW - 1)]
    fg(pack(tint({ 150, 130, 110 }, L.land)))
    rect(rx, ry - 3, 4, 3); rect(rx + 3, ry - 6, 1, 3); rect(rx + 4, ry - 5, 1, 2)
  end
end

local function draw_ball(shadow, sdir, shc)
  local px, py = div(bx, FP) - cam, div(by, FP)
  if state ~= "holed" then
    if shadow > 0 then
      local gy = ground[clamp(div(bx, FP), 0, CW - 1)]
      fg(shc); rect(sdir > 0 and px or px - shadow, gy, shadow, 1)
    end
    fg(rgb(250, 250, 250)); rect(px - 1, py - 2, 2, 2)
  end
  if state == "aim" then
    local f = facing()
    fg(rgb(250, 250, 250))
    for k = 2, 4 do
      rect(px + div(f * k * 4 * cosd(angle), 256), py - 2 - div(k * 4 * sind(angle), 256), 1, 1)
    end
  end
end

local function draw_extras(L, tk)
  if state == "splash" then
    fg(pack(tint({ 200, 225, 250 }, L.land)))
    local cxw = course.creek + 8 - cam
    local age = HZ - (splash_until - tk)
    for k = -3, 3 do rect(cxw + k * 2, ground[course.creek] - 6 - div(age * (4 - iabs(k)), 25), 1, 1) end
  end
  if state == "holed" then
    -- 左上角一个小日历：今天的洞打完了，明天再来
    fg(rgb(235, 235, 230)); rect(3, 3, 9, 8)
    fg(rgb(200, 60, 50)); rect(3, 3, 9, 2)
    fg(rgb(90, 90, 90)); rect(5, 7, 1, 1); rect(7, 7, 1, 1); rect(9, 7, 1, 1)
    if show_strokes then text_r(W - 2, 2, tostring(strokes), rgb(255, 255, 255), pack(L.top)) end
  end
end

local function draw(L, tk)
  draw_land(L)
  local shadow, sdir, shc = shadow_of(L)
  draw_flag_rabbit(L, tk, shadow, sdir, shc)
  draw_ball(shadow, sdir, shc)
  draw_extras(L, tk)
  rb.lcd_update()
end

-- ---------- 主循环 ----------
load()
light_start()
local running = true
local fl = { on = false, peak = 0 } -- 正在快拨、这一下的峰值
local meter = { on = false, peak = 0, t = 0 } -- 转速读数
local view = { pan = nil } -- 打完以后用转盘左右看球场：镜头位置
local angle_hist = {}
local tk = 0

while running do
  tk = rb.current_tick()
  local clicks = 0
  for _, e in ipairs(poll()) do
    if e.k == "menu" and not e.rel then running = false
    elseif e.k == "help" then
      help_screen("GOLF", {
        "One quiet hole a day.",
        "Turn slowly to aim. Flick",
        "fast to swing: a faster",
        "flick hits harder.",
        "",
        "*Keys",
        "wheel slow   aim",
        "wheel flick  swing",
        "play    power meter on/off",
        "select  strokes (in hole)",
        "wheel   look around after",
        "        the ball is in",
        "menu    quit",
        "hold menu  this help",
      })
    elseif (e.k == "fwd" or e.k == "back") and not e.rel then clicks = clicks + (e.k == "fwd" and 1 or -1)
    elseif e.k == "play" and not e.rel and not e.rep then meter.on = not meter.on
    elseif select_gesture(e) == "short" and state == "holed" then show_strokes = not show_strokes end
  end

  -- 跨天：换一个新地形
  local d = civil(now()).day
  if d ~= today then
    today, wx, strokes, state, angle = d, weather_of(d), 0, "aim", 35
    build(today); bx = course.tee * FP; by = ground[course.tee] * FP; rabbit_x = course.rx
  end

  if state == "aim" then
    -- 记下最近 1/4 秒的角度，快拨时退回到拨之前
    angle_hist[#angle_hist + 1] = { tk, angle }
    while #angle_hist > 1 and tk - angle_hist[2][1] >= div(HZ, 4) do table.remove(angle_hist, 1) end
    local rate = wheel_speed(T.WINDOW)
    if rate >= T.SHOT_MIN then
      if not fl.on then
        fl.on, fl.peak = true, rate
        angle = angle_hist[1][2] -- 快拨开头那几格不算瞄准，退回去
      end
      fl.peak = math.max(fl.peak, rate)
    elseif fl.on then
      fl.on = false
      shoot(T.POWER_MIN + div(clamp(fl.peak - T.SHOT_MIN, 0, T.SHOT_FULL - T.SHOT_MIN) * (120 - T.POWER_MIN), T.SHOT_FULL - T.SHOT_MIN)) -- 越快力度越大
    elseif rate <= T.AIM_MAX and clicks ~= 0 then
      angle = clamp(angle + clicks, 5, 80)
    end
  end
  physics(tk)
  physics(tk) -- 每帧两步，动作更顺

  -- 兔子：球滚近了就跑开
  if course.rabbit then
    if rabbit_run == 0 and iabs(div(bx, FP) - rabbit_x) < 30 and state ~= "aim" then rabbit_run = rabbit_x < div(bx, FP) and -3 or 3 end
    rabbit_x = rabbit_x + rabbit_run
  end

  -- 镜头跟着球；打完以后改由转盘左右看整个球场，像打完球散步回头看一眼
  local target = clamp(div(bx, FP) - div(W, 3), 0, CW - W)
  if facing() < 0 then target = clamp(div(bx, FP) - div(W * 2, 3), 0, CW - W) end
  if state == "holed" then
    if not view.pan then view.pan = target end -- 从镜头要去的地方（球洞那边）开始
    view.pan = clamp(view.pan + clicks * 6, 0, CW - W)
    target = view.pan
  else
    view.pan = nil
  end
  cam = cam + div(target - cam, 6)
  if iabs(target - cam) < 6 then cam = target end

  draw(light_at(now()), tk)
  if meter.on then
    local r, src = wheel_speed(T.WINDOW)
    if r >= meter.peak or tk - meter.t > 3 * HZ then meter.peak, meter.t = r, tk end
    text(2, 2, string.format("now %d  peak %d  %s", r, meter.peak, src), rgb(255, 255, 255), rgb(0, 0, 0))
    rb.lcd_update()
  end
  keep_light()
  rb.sleep(div(HZ, 30))
end

save()
light_end()
