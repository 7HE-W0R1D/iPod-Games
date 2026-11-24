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

-- 鸟群：十几只鸟各自只看身边的同伴，聚成一整团飞行的形状（Boids）
-- 转盘：时间流速   Select：惊扰一下   Menu：退出
-- 白天飞，傍晚越飞越低，夜里落成一排，天亮再起飞。角落的数字是今天转了多少次弯。

local SAVE = "slow_flock.txt"
local MAXB = 15
local FP = 16 -- 定点：位置 ×16

local NEAR2 = (26 * FP) * (26 * FP) -- 看得见的范围
local SEP2 = (7 * FP) * (7 * FP)    -- 太近了要躲
local VMAX, VMIN = 40, 14           -- 每步 1/16 像素
local MARGIN = 14 * FP
local TRAIL = 6

-- 每一步的间隔（tick）：从每秒一帧到正常速度
local STEPS = { HZ, div(HZ, 2), div(HZ, 4), div(HZ, 8), div(HZ, 14), div(HZ, 25) }
local STEP_NAMES = { "1 fps", "2 fps", "4 fps", "8 fps", "14 fps", "25 fps" }

-- 4 种颜色：底、尾迹暗、尾迹亮、鸟
local PAL_DAY = { rgb(10, 20, 52), rgb(40, 60, 110), rgb(90, 120, 180), rgb(225, 235, 255) }
local PAL_NIGHT = { rgb(0, 0, 0), rgb(18, 22, 40), rgb(40, 48, 80), rgb(120, 130, 160) }

-- ---------- 状态 ----------
local t0 = now()
local rnd = Rng(rb.current_tick() + t0)
local birds = {}
local count = MAXB
local turns, turns_day = 0, civil(t0).day
local speed = #STEPS
local scared_until = 0
local steps = 0
local last_oct, oct_stable, oct_cand = -1, 0, -1

local function load()
  local s = load_kv(SAVE)
  count = clamp(num(s.count, MAXB), 1, MAXB)
  speed = clamp(num(s.speed, #STEPS), 1, #STEPS)
  if num(s.day, -1) == turns_day then turns = num(s.turns, 0) end
end
local function save()
  save_kv(SAVE, { count = count, speed = speed, day = turns_day, turns = turns })
end

local function new_bird(x, y)
  local b = { x = x, y = y, vx = rnd(41) - 20, vy = rnd(41) - 20, tx = {}, ty = {},
              lost = false, lost_until = 0, leave = false, perched = false }
  for k = 1, TRAIL do b.tx[k] = div(x, FP); b.ty[k] = div(y, FP) end
  return b
end

-- ---------- 作息 ----------
-- 返回：模式（"day"/"dusk"/"night"），目标高度（定点），傍晚进度
local function schedule()
  local L = light_at(now())
  local m, sr, ss = L.min, L.sr, L.ss
  if m >= sr and m < ss - 90 then return "day", div(H * FP, 2), L end
  if m >= ss - 90 and m < ss + 25 then
    local p = clamp(m - (ss - 90), 0, 115)
    return "dusk", div(H * FP, 2) + div(p * (H * FP - div(H * FP, 2) - 30 * FP), 115), L
  end
  return "night", H * FP, L
end

local PERCH_Y = H - 20
local function perch_slot(i)
  local gap = div(W - 40, MAXB)
  return (20 + (i - 1) * gap + div(gap, 2)) * FP, PERCH_Y * FP
end

-- 三角波：让鸟群慢慢在屏幕里游走
local function tri(s, period)
  local p = mod(s, period)
  if p < div(period, 2) then return p end
  return period - p
end

-- 方向分成 8 个扇区（不用三角函数：tan 22.5° ≈ 5/12）
local function octant(dx, dy)
  local ax, ay = iabs(dx), iabs(dy)
  if ax == 0 and ay == 0 then return -1 end
  local o
  if ay * 12 < ax * 5 then o = 0
  elseif ax * 12 < ay * 5 then o = 2
  else o = 1 end
  -- o: 0=水平 1=斜 2=竖，再按象限展开到 0..7
  if dx >= 0 and dy < 0 then return ({ 0, 1, 2 })[o + 1]
  elseif dx < 0 and dy < 0 then return ({ 4, 3, 2 })[o + 1]
  elseif dx < 0 then return ({ 4, 5, 6 })[o + 1]
  else return ({ 0, 7, 6 })[o + 1] end
end

local function limit(b)
  local ax, ay = iabs(b.vx), iabs(b.vy)
  local len = ax > ay and ax + div(ay * 3, 8) or ay + div(ax * 3, 8) -- 近似长度，不开根号
  if len > VMAX then
    b.vx = div(b.vx * VMAX, len); b.vy = div(b.vy * VMAX, len)
  elseif len < VMIN and len > 0 then
    b.vx = div(b.vx * VMIN, len); b.vy = div(b.vy * VMIN, len)
  end
end

-- ---------- 一步 ----------
local function step(mode, ty)
  steps = steps + 1
  local scared = rb.current_tick() < scared_until
  local wx = (30 + div(tri(steps, 1800) * (W - 60), 900)) * FP -- 白天游走的目标
  local n = #birds
  for i = 1, n do
    local b = birds[i]
    if mode == "night" then
      local sx, sy = perch_slot(i)
      if b.perched then
        b.x, b.y, b.vx, b.vy = sx, sy, 0, 0
      else
        local dx, dy = sx - b.x, sy - b.y
        if iabs(dx) < FP * 2 and iabs(dy) < FP * 2 then b.perched = true
        else
          b.vx = clamp(div(dx, 10), -VMAX, VMAX); b.vy = clamp(div(dy, 10), -VMAX, VMAX)
          if iabs(b.vx) + iabs(b.vy) < 6 then b.vx = dx > 0 and 3 or -3 end
        end
      end
    else
      if b.perched then b.perched = false; b.vy = -30; b.vx = rnd(31) - 15 end -- 起飞
      local sepx, sepy, alx, aly, cx, cy, k = 0, 0, 0, 0, 0, 0, 0
      if not b.lost then
        for j = 1, n do
          if j ~= i then
            local o = birds[j]
            if not o.lost then
              local dx, dy = o.x - b.x, o.y - b.y
              local d2 = dx * dx + dy * dy
              if d2 < NEAR2 then
                k = k + 1
                alx, aly, cx, cy = alx + o.vx, aly + o.vy, cx + o.x, cy + o.y
                if d2 < SEP2 then sepx, sepy = sepx - dx, sepy - dy end
              end
            end
          end
        end
      end
      local ax, ay = div(sepx, 10), div(sepy, 10)                       -- 1. 分离
      if k > 0 and not scared then
        ax = ax + div(div(alx, k) - b.vx, 8)                            -- 2. 对齐
        ay = ay + div(div(aly, k) - b.vy, 8)
        ax = ax + div(div(cx, k) - b.x, 90)                             -- 3. 聚拢
        ay = ay + div(div(cy, k) - b.y, 90)
      end
      if b.lost then
        -- 迷路的鸟：沿着屏幕边缘自己飞
        local ex = b.x < div(W * FP, 2) and 8 * FP or (W - 8) * FP
        ax = ax + div(ex - b.x, 120)
        ay = ay + rnd(9) - 4
      else
        ax = ax + div(wx - b.x, 600) -- 大致的去向
        ay = ay + div(ty - b.y, 160) -- 作息决定的高度
      end
      b.vx, b.vy = b.vx + ax, b.vy + ay
      -- 边缘：轻轻掉头（要离开的迷路鸟除外）
      if not b.leave then
        if b.x < MARGIN then b.vx = b.vx + 4 elseif b.x > W * FP - MARGIN then b.vx = b.vx - 4 end
        if b.y < MARGIN then b.vy = b.vy + 4 elseif b.y > H * FP - MARGIN then b.vy = b.vy - 4 end
      end
      limit(b)
    end
    b.x, b.y = b.x + b.vx, b.y + b.vy
    for t = TRAIL, 2, -1 do b.tx[t] = b.tx[t - 1]; b.ty[t] = b.ty[t - 1] end
    b.tx[1], b.ty[1] = div(b.x, FP), div(b.y, FP)
  end

  -- 掉队与迷路：偶尔一只离群，过一阵要么回来，要么不见了
  if mode == "day" and n > 3 and rnd(4000) == 0 then
    local b = birds[rnd(n) + 1]
    if not b.lost then b.lost = true; b.lost_until = steps + 600 + rnd(1500) end
  end
  for i = #birds, 1, -1 do
    local b = birds[i]
    if b.lost and steps > b.lost_until then
      if b.leave then
        if b.x < -10 * FP or b.x > (W + 10) * FP or b.y < -10 * FP or b.y > (H + 10) * FP then
          table.remove(birds, i); count = #birds
        end
      elseif rnd(2) == 0 then b.lost = false
      else b.leave = true; b.vx = b.x < div(W * FP, 2) and -VMAX or VMAX end
    end
  end

  -- 数转弯：整团的平均方向换了扇区，并且稳定 10 步，算一次
  if mode ~= "night" then
    local sx, sy = 0, 0
    for i = 1, #birds do if not birds[i].lost then sx, sy = sx + birds[i].vx, sy + birds[i].vy end end
    local o = octant(sx, sy)
    if o ~= oct_cand then oct_cand, oct_stable = o, 0 else oct_stable = oct_stable + 1 end
    if oct_stable == 10 and o ~= last_oct and o >= 0 then
      if last_oct >= 0 then turns = turns + 1 end
      last_oct = o
    end
  end
end

local function scare()
  if #birds == 0 then return end
  local cx, cy = 0, 0
  for _, b in ipairs(birds) do cx, cy = cx + b.x, cy + b.y end
  cx, cy = div(cx, #birds), div(cy, #birds)
  for _, b in ipairs(birds) do
    if not b.perched then
      b.vx = b.vx + div(b.x - cx, 12) + rnd(41) - 20
      b.vy = b.vy + div(b.y - cy, 12) + rnd(41) - 20
    else
      b.perched = false; b.vy = -VMAX; b.vx = rnd(61) - 30
    end
  end
  scared_until = rb.current_tick() + 3 * HZ
end

-- ---------- 画面 ----------
local overlay, overlay_until = nil, 0
local function draw(mode, L)
  local pal = (mode == "night") and PAL_NIGHT or PAL_DAY
  fg(pal[1]); rect(0, 0, W, H)
  if mode == "night" then fg(pal[2]); rect(0, PERCH_Y + 2, W, 1) end -- 夜里那根电线
  for _, b in ipairs(birds) do
    for t = TRAIL, 2, -1 do
      fg(t > 3 and pal[2] or pal[3])
      rect(b.tx[t], b.ty[t], 1, 1)
    end
    fg(pal[4]); rect(b.tx[1], b.ty[1], 2, 2)
  end
  text_r(W - 2, H - 9, tostring(turns), pal[3], pal[1])
  if overlay and rb.current_tick() < overlay_until then text(2, 2, overlay, pal[3], pal[1]) end
  rb.lcd_update()
end

-- ---------- 主循环 ----------
load()
light_start()
do
  local mode = schedule()
  for i = 1, count do
    if mode == "night" then
      local sx, sy = perch_slot(i)
      local b = new_bird(sx, sy); b.perched = true; birds[i] = b
    else
      birds[i] = new_bird((40 + rnd(W - 80)) * FP, (30 + rnd(H - 60)) * FP)
    end
  end
end

local running = true
local next_step = rb.current_tick()
local last_mode = schedule()
while running do
  for _, e in ipairs(poll()) do
    if e.k == "menu" and not e.rel then running = false
    elseif e.k == "help" then
      help_screen("FLOCK", {
        "A flock of birds. Each bird",
        "only watches its neighbours.",
        "They fly by day, fly lower",
        "at dusk, roost at night.",
        "Corner: turns made today.",
        "",
        "*Keys",
        "wheel   time speed",
        "select  startle them",
        "menu    quit",
        "hold menu  this help",
      })
    elseif e.k == "fwd" and not e.rel then speed = clamp(speed + 1, 1, #STEPS); overlay, overlay_until = STEP_NAMES[speed], rb.current_tick() + 2 * HZ
    elseif e.k == "back" and not e.rel then speed = clamp(speed - 1, 1, #STEPS); overlay, overlay_until = STEP_NAMES[speed], rb.current_tick() + 2 * HZ
    elseif select_gesture(e) == "short" then scare() end
  end

  local tk = rb.current_tick()
  if tk >= next_step then
    next_step = tk + STEPS[speed]
    local mode, ty, L = schedule()
    -- 跨天：清零转弯数；天亮时如果鸟少了，补回来一只
    local today = civil(now()).day
    if today ~= turns_day then turns_day, turns = today, 0 end
    if last_mode == "night" and mode ~= "night" and #birds < MAXB then
      birds[#birds + 1] = new_bird(-8 * FP, (20 + rnd(40)) * FP); count = #birds
    end
    last_mode = mode
    step(mode, ty)
    draw(mode, L)
    if mod(steps, 500) == 0 then save() end
  end
  keep_light()
  rb.sleep(clamp(next_step - rb.current_tick(), 1, div(HZ, 10)))
end

save()
light_end()
