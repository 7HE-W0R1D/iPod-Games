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
-- 返回关掉它的那个键（比如 "play"），应用可以拿来在说明页里切换设置。
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
      elseif (e.k == "menu" or not e.rel) and e.k ~= "help" and not e.rep then return e.k end -- 返回关掉它的键
    end
    keep_light()
    rb.sleep(div(HZ, 20))
  end
end
-- ==== 共用部分结束 ====

-- 台球（八球）：一张小小的八球台，深夜台球厅的感觉。7 红、7 黄、1 黑、1 白。
-- 开局界面：转盘选 人对人 / 人对电脑 / 电脑对电脑，Select 开始
-- 瞄准：转盘让球杆绕白球转（慢转微调，快转大步），Select 确认方向
-- 力度：转盘往后拉杆（逆时针加力、顺时针减力），Select 出杆，Menu 退回瞄准
-- 自由球：转盘把白球沿开球线上下移动，Select 放下
-- 上一首：悔一杆（人对电脑）   观战时 Play：每杆至少隔 5 / 10 / 20 秒
-- 长按 Select：回开局界面   短按 Menu 退出，长按 Menu 看说明

local SAVE = "slow_pool.txt"

-- ================= 物理 =================
-- 坐标以球台台呢左上角为原点，单位是 1/256 像素。台呢 160×80 像素，球直径 5 像素。
local P = {}
do
local U = 256
local L, WD = 160 * U, 80 * U
local R, D = 640, 1280          -- 半径、直径
local D2 = D * D
local JAW, MJAW = 7 * U, 4 * U  -- 角袋、中袋的袋口半宽
local FR, DEC, STOP = 140, 2, 6 -- 摩擦：每子步减去 速度/FR + DEC，低于 STOP 停下
local BOUNCE = 13               -- 碰库后保留 13/16 的速度
local Q = { [0] = 0, 6, 13, 19, 25, 31, 38, 44, 50, 56, 62, 68, 74, 80, 86, 92, 98, 104, 109, 115, 121, 126, 132,
  137, 142, 147, 152, 157, 162, 167, 172, 177, 181, 185, 190, 194, 198, 202, 206, 209, 213, 216, 220, 223, 226,
  229, 231, 234, 237, 239, 241, 243, 245, 247, 248, 250, 251, 252, 253, 254, 255, 255, 256, 256, 256 }
P.U, P.L, P.WD, P.R, P.D = U, L, WD, R, D
P.HEADX = div(L, 4)
P.POCKETS = { { 0, 0 }, { div(L, 2), -U }, { L, 0 }, { 0, WD }, { div(L, 2), WD + U }, { L, WD } }

local function sin256(i)
  i = mod(i, 256)
  if i <= 64 then return Q[i] elseif i <= 128 then return Q[128 - i]
  elseif i <= 192 then return -Q[i - 128] end
  return -Q[256 - i]
end
-- 角度 a：0..1023 一圈。返回 ×256 的正弦 / 余弦（在 256 方向的表之间插值）
P.sin = function(a)
  a = mod(a, 1024)
  local i, f = div(a, 4), mod(a, 4)
  local s0 = sin256(i)
  return s0 + div((sin256(i + 1) - s0) * f, 4)
end
P.cos = function(a) return P.sin(a + 256) end

local function isqrt(n)
  if n <= 0 then return 0 end
  local x = 1
  while x * x < n and x < 46340 do x = x * 2 end
  local y = div(x + div(n, x), 2)
  while y < x do x = y; y = div(x + div(n, x), 2) end
  return x
end
P.isqrt = isqrt

-- 由向量求角度：先 64 个方向粗找，再逐格细找
P.atan = function(ax, ay)
  local best, ba = nil, 0
  for k = 0, 1008, 16 do
    local d = div(ax, 64) * P.cos(k) + div(ay, 64) * P.sin(k)
    if not best or d > best then best, ba = d, k end
  end
  local a0 = ba
  for k = a0 - 15, a0 + 15 do
    local d = div(ax, 64) * P.cos(k) + div(ay, 64) * P.sin(k)
    if d > best then best, ba = d, k end
  end
  return mod(ba, 1024)
end

P.new = function()
  local s = { x = {}, y = {}, vx = {}, vy = {}, on = {}, pots = {} }
  for i = 0, 15 do s.x[i], s.y[i], s.vx[i], s.vy[i], s.on[i] = 0, 0, 0, 0, false end
  return s
end
P.copy = function(s)
  local t = P.new()
  for i = 0, 15 do
    t.x[i], t.y[i], t.vx[i], t.vy[i], t.on[i] = s.x[i], s.y[i], s.vx[i], s.vy[i], s.on[i]
  end
  return t
end

-- 摆球：三角形顶点在置球点，黑球在第三排中间，两个后角一红一黄
P.rack = function(s, rng)
  local reds, yels = { 1, 2, 3, 4, 5, 6, 7 }, { 9, 10, 11, 12, 13, 14, 15 }
  local function take(t) return table.remove(t, rng(#t) + 1) end
  local order, k = {}, 0
  local corner_red = rng(2) == 0
  for row = 0, 4 do
    for i = 0, row do
      k = k + 1
      local id
      if k == 5 then id = 8
      elseif k == 11 then id = corner_red and take(reds) or take(yels)
      elseif k == 15 then id = corner_red and take(yels) or take(reds)
      else
        local pool = {}
        if #reds > (corner_red and 0 or 1) then pool[#pool + 1] = reds end
        if #yels > (corner_red and 1 or 0) then pool[#pool + 1] = yels end
        id = take(pool[rng(#pool) + 1])
      end
      order[#order + 1] = { id, row, i }
    end
  end
  for i = 0, 15 do s.on[i], s.vx[i], s.vy[i] = false, 0, 0 end
  local fx, fy, gap = div(L * 3, 4), div(WD, 2), D + 16
  for _, o in ipairs(order) do
    local id, row, i = o[1], o[2], o[3]
    s.x[id] = fx + div(row * gap * 222, 256)       -- 每排往后 √3/2 个球
    s.y[id] = fy + div((i * 2 - row) * gap, 2)
    s.on[id] = true
  end
  s.x[0], s.y[0], s.on[0] = P.HEADX, fy, true
end

-- 开球线上 y 这个位置能不能放白球
P.free_ok = function(s, y)
  for j = 1, 15 do
    if s.on[j] and iabs(s.x[j] - P.HEADX) < D + 64 and iabs(s.y[j] - y) < D + 64 then return false end
  end
  return true
end
-- 黑球提前落袋（只在开球时）：放回置球点，被占了就往后挪
P.respot = function(s, id)
  local x = div(L * 3, 4)
  local function free(xx)
    for j = 0, 15 do
      if j ~= id and s.on[j] and iabs(s.x[j] - xx) < D and iabs(s.y[j] - div(WD, 2)) < D then return false end
    end
    return true
  end
  while x < L - R - D and not free(x) do x = x + D end
  s.x[id], s.y[id], s.vx[id], s.vy[id], s.on[id] = x, div(WD, 2), 0, 0, true
end

P.shoot = function(s, a, speed)
  s.vx[0], s.vy[0] = div(P.cos(a) * speed, 256), div(P.sin(a) * speed, 256)
  s.first, s.pots = nil, {}
end

local function collide(s, i, j, dx, dy, d2)
  local x, y, vx, vy = s.x, s.y, s.vx, s.vy
  local d = isqrt(d2)
  if d == 0 then d, dx, dy = 1, 1, 0 end
  local nx, ny = div(dx * 256, d), div(dy * 256, d)
  local p = div((vx[i] - vx[j]) * nx + (vy[i] - vy[j]) * ny, 256)
  if p > 0 then
    p = div(p * 31, 32)
    vx[i], vy[i] = vx[i] - div(p * nx, 256), vy[i] - div(p * ny, 256)
    vx[j], vy[j] = vx[j] + div(p * nx, 256), vy[j] + div(p * ny, 256)
    if not s.first and (i == 0 or j == 0) then s.first = (i == 0) and j or i end
  end
  local o = D - d
  if o > 0 then -- 推开重叠
    local hx, hy = div(nx * o, 512) + 1, div(ny * o, 512)
    if nx < 0 then hx = hx - 2 end
    x[i], y[i] = clamp(x[i] - hx, R, L - R), clamp(y[i] - hy, R, WD - R)
    x[j], y[j] = clamp(x[j] + hx, R, L - R), clamp(y[j] + hy, R, WD - R)
  end
end

local function pot(s, i)
  s.on[i], s.vx[i], s.vy[i] = false, 0, 0
  s.pots[#s.pots + 1] = i
end

-- 一个子步：先走、碰库、落袋、摩擦，再查球与球的碰撞。返回还有没有球在动
P.step = function(s)
  local x, y, vx, vy, on = s.x, s.y, s.vx, s.vy, s.on
  local any = false
  local mv = {}
  for i = 0, 15 do
    if on[i] and (vx[i] ~= 0 or vy[i] ~= 0) then
      any = true
      mv[i] = true
      local nx, ny = x[i] + vx[i], y[i] + vy[i]
      local sidex = nx < R or nx > L - R
      local sidey = ny < R or ny > WD - R
      if (sidex and (ny < JAW or ny > WD - JAW)) or
         (sidey and (nx < JAW or nx > L - JAW or iabs(nx - div(L, 2)) < MJAW)) then
        pot(s, i)
      else
        if nx < R then nx = R + R - nx; vx[i] = -div(vx[i] * BOUNCE, 16)
        elseif nx > L - R then nx = (L - R) * 2 - nx; vx[i] = -div(vx[i] * BOUNCE, 16) end
        if ny < R then ny = R + R - ny; vy[i] = -div(vy[i] * BOUNCE, 16)
        elseif ny > WD - R then ny = (WD - R) * 2 - ny; vy[i] = -div(vy[i] * BOUNCE, 16) end
        x[i], y[i] = nx, ny
        local a, b = iabs(vx[i]), iabs(vy[i])
        local sp = (a > b) and (a + div(b * 3, 8)) or (b + div(a * 3, 8))
        local ns = sp - div(sp, FR) - DEC
        if ns <= STOP then vx[i], vy[i] = 0, 0
        else vx[i], vy[i] = div(vx[i] * ns, sp), div(vy[i] * ns, sp) end
      end
    end
  end
  if not any then return false end
  for i = 0, 14 do
    if on[i] then
      for j = i + 1, 15 do
        if on[j] and (mv[i] or mv[j]) then
          local dx = x[j] - x[i]
          if dx > -D and dx < D then
            local dy = y[j] - y[i]
            if dy > -D and dy < D then
              local d2 = dx * dx + dy * dy
              if d2 < D2 then collide(s, i, j, dx, dy, d2) end
            end
          end
        end
      end
    end
  end
  return true
end

-- 一直模拟到全停（电脑试杆用）
P.settle = function(s, cap)
  for _ = 1, cap or 4000 do
    if not P.step(s) then return end
  end
end

-- 瞄准线：从白球沿角度 a 走，第一次碰到球或库边的距离（像素×64），和碰到的球
P.trace = function(s, a)
  local c, sn = P.cos(a), P.sin(a)
  local cx, cy = div(s.x[0], 4), div(s.y[0], 4)
  local dq = div(D, 4)
  local best, hit = 1000000, nil
  for j = 1, 15 do
    if s.on[j] then
      local dx, dy = div(s.x[j], 4) - cx, div(s.y[j], 4) - cy
      local t = div(dx * c + dy * sn, 256)
      if t > 0 then
        local perp = dx * dx + dy * dy - t * t
        if perp < dq * dq then
          local tt = t - isqrt(dq * dq - perp)
          if tt < best then best, hit = tt, j end
        end
      end
    end
  end
  local r4 = div(R, 4)
  if c > 0 then best = math.min(best, div((div(L, 4) - r4 - cx) * 256, c))
  elseif c < 0 then best = math.min(best, div((r4 - cx) * 256, c)) end
  if sn > 0 then best = math.min(best, div((div(WD, 4) - r4 - cy) * 256, sn))
  elseif sn < 0 then best = math.min(best, div((r4 - cy) * 256, sn)) end
  if best == math.min(best, 0) then best = 0 end
  return best, hit, c, sn
end

-- 电脑的候选杆：对每颗能打的球、每个袋口，算“假想球”的位置，角度合适、路上不挡的留下
P.plan = function(s, targets)
  local list = {}
  for _, t in ipairs(targets) do
    for _, pk in ipairs(P.POCKETS) do
      local ux, uy = div(pk[1] - s.x[t], 4), div(pk[2] - s.y[t], 4)
      local len = isqrt(ux * ux + uy * uy)
      if len > 0 then
        local gx, gy = s.x[t] - div(ux * D, len), s.y[t] - div(uy * D, len)
        local ax, ay = gx - s.x[0], gy - s.y[0]
        local al = isqrt(div(ax, 4) * div(ax, 4) + div(ay, 4) * div(ay, 4))
        if al > 0 then
          local cut = div(div(ax, 4) * ux + div(ay, 4) * uy, math.max(1, div(al * len, 256)))
          if cut > 60 then
            local a = P.atan(ax, ay)
            local _, hit = P.trace(s, a)
            if hit == t then
              local px = div(al + len, 64)
              list[#list + 1] = { a = a, pw = clamp(4 + div(px, 9), 4, 17), q = cut * 2 - px }
            end
          end
        end
      end
    end
  end
  table.sort(list, function(p, q) return p.q > q.q end)
  local out = {}
  for i = 1, math.min(#list, 8) do
    out[#out + 1] = list[i]
    out[#out + 1] = { a = list[i].a, pw = clamp(list[i].pw + 5, 4, 20), q = list[i].q }
  end
  -- 没有好打的：直接冲着球打，至少碰得到
  for _, t in ipairs(targets) do
    if #out >= 20 then break end
    local a = P.atan(s.x[t] - s.x[0], s.y[t] - s.y[0])
    local _, hit = P.trace(s, a)
    if hit == t then out[#out + 1] = { a = a, pw = 9, q = -1000 } end
  end
  return out
end
end

-- ================= 规则 =================
-- 颜色组：0 白，1 红，2 黄，3 黑
local function colour(i)
  if i == 0 then return 0 elseif i < 8 then return 1 elseif i == 8 then return 3 end
  return 2
end
-- 一杆打完后的判定。g：这一方的组（nil 表示还没分组）；brk：是不是开球
local function outcome(s, g, brk)
  local o = { own = 0, opp = 0 }
  local left = 0 -- 这一杆之前自己这组还剩几颗
  if g then for i = 1, 15 do if s.on[i] and colour(i) == g then left = left + 1 end end end
  local cue_in, black_in, first_pot = false, false, nil
  for _, i in ipairs(s.pots) do
    local c = colour(i)
    if c == 0 then cue_in = true elseif c == 3 then black_in = true
    else
      first_pot = first_pot or c
      if c == g then left = left + 1 end
    end
  end
  local foul = cue_in or not s.first
  if s.first then
    if g then foul = foul or colour(s.first) ~= ((left > 0) and g or 3)
    else foul = foul or s.first == 8 end
  end
  o.foul = foul
  o.ng = g
  if not g and not foul and first_pot then o.ng = first_pot end
  for _, i in ipairs(s.pots) do
    local c = colour(i)
    if c == 1 or c == 2 then
      if c == o.ng then o.own = o.own + 1 elseif o.ng then o.opp = o.opp + 1 end
    end
  end
  if black_in then
    if brk then o.respot = true
    elseif g and left == 0 and not foul then o.win = true
    else o.lose = true end
  end
  o.cont = not foul and not o.win and not o.lose and o.own > 0
  return o
end

-- ================= 界面 =================
local main = function()
local U = P.U
local CX0, CY0 = 8, 22          -- 台呢左上角在屏幕上的位置
local CLW, CLH = 160, 80
local C = {
  room = rgb(14, 12, 12), wood = rgb(92, 54, 30), wood2 = rgb(64, 36, 20), cush = rgb(22, 74, 44),
  cloth = { rgb(28, 88, 54), rgb(34, 102, 63), rgb(40, 116, 72) }, hole = rgb(6, 6, 8), dot = rgb(210, 190, 140),
  ball = { [0] = rgb(240, 238, 226), rgb(206, 44, 40), rgb(238, 196, 52), rgb(22, 22, 26) },
  shine = { [0] = rgb(255, 255, 255), rgb(250, 130, 120), rgb(255, 240, 170), rgb(110, 110, 120) },
  aim = rgb(190, 214, 196), ghost = rgb(150, 190, 165), shaft = rgb(222, 192, 140), butt = rgb(80, 44, 24),
  tip = rgb(90, 150, 230), ink = rgb(232, 228, 216), dim = rgb(140, 132, 118), hi = rgb(240, 150, 60),
  bar = rgb(46, 40, 34),
}
-- 台灯的光：三层，越靠中间越亮
local ZONES = { { 0, 0, CLW, CLH }, { 18, 9, CLW - 36, CLH - 18 }, { 44, 22, CLW - 88, CLH - 44 } }
local KINDS = { "2 players", "you vs cpu", "cpu vs cpu" }
local NAMES = { { "P1", "P2" }, { "you", "cpu" }, { "cpu A", "cpu B" } }
local PACES = { 5, 10, 20 }
local MAXPOW = 20
local SUBSTEPS = 4

local G = {
  scr = "menu", kind = 2, sel = 2, pace = 2, s = P.new(), grp = {}, turn = 1, shots = 0, run = 0,
  phase = "aim", aim = 0, pow = 10, placey = div(P.WD, 2), winner = nil, note = nil, note_until = 0,
  games = { 0, 0, 0 }, w1 = { 0, 0, 0 }, w2 = { 0, 0, 0 }, best = { 0, 0, 0 },
  drawn = {}, full = true, shown = {}, quit = false, rng = Rng(now()), wait_until = 0, over_at = 0,
  cpu = nil, undo = nil, missed = { false, false },
}

local function human(who) return G.kind == 1 or (G.kind == 2 and who == 1) end
local function say(s, secs) G.note, G.note_until = s, rb.current_tick() + (secs or 2) * HZ end

-- ---------- 存档 ----------
local function enc_balls(s)
  local t = {}
  for i = 0, 15 do
    t[#t + 1] = s.on[i] and (s.x[i] .. ":" .. s.y[i]) or "-"
  end
  return table.concat(t, ",")
end
local function save()
  local st = { kind = G.kind, pace = G.pace, scr = G.scr }
  for k = 1, 3 do st["g" .. k] = G.games[k] .. "," .. G.w1[k] .. "," .. G.w2[k] .. "," .. G.best[k] end
  if G.scr == "play" then
    st.balls = enc_balls(G.s)
    st.turn, st.shots, st.run = G.turn, G.shots, G.run
    st.grp = (G.grp[1] or 0) .. "," .. (G.grp[2] or 0)
    st.phase = (G.phase == "place" or G.phase == "over") and G.phase or "aim"
    st.winner = G.winner or 0
  end
  save_kv(SAVE, st)
end
local function load()
  local st, found = load_kv(SAVE)
  G.kind = clamp(num(st.kind, 2), 1, 3)
  G.sel, G.pace = G.kind, clamp(num(st.pace, 2), 1, #PACES)
  for k = 1, 3 do
    local a, b, c, d = string.match(st["g" .. k] or "", "(%d+),(%d+),(%d+),(%d+)")
    G.games[k], G.w1[k], G.w2[k], G.best[k] = num(a, 0), num(b, 0), num(c, 0), num(d, 0)
  end
  if st.scr == "play" and st.balls then
    local s, i = P.new(), 0
    for item in string.gmatch(st.balls, "[^,]+") do
      if i > 15 then break end
      local x, y = string.match(item, "(%-?%d+):(%-?%d+)")
      if x then s.x[i], s.y[i], s.on[i] = num(x, 0), num(y, 0), true end
      i = i + 1
    end
    local g1, g2 = string.match(st.grp or "", "(%d),(%d)")
    G.s, G.scr = s, "play"
    G.grp = { (num(g1, 0) > 0) and num(g1, 0) or nil, (num(g2, 0) > 0) and num(g2, 0) or nil }
    G.turn, G.shots, G.run = clamp(num(st.turn, 1), 1, 2), num(st.shots, 0), num(st.run, 0)
    G.phase = st.phase or "aim"
    G.winner = (num(st.winner, 0) > 0) and num(st.winner, 0) or nil
    if G.phase == "over" then G.over_at = rb.current_tick() end
    if not s.on[0] and G.phase ~= "over" then G.phase = "place" end
  end
  return found
end

-- ---------- 画面 ----------
local function sx(x) return CX0 + div(x, U) end
local function sy(y) return CY0 + div(y, U) end

-- 把台呢上的一块恢复成台呢（按台灯的三层颜色）
local function cloth_rect(x, y, w, h)
  local x1, y1 = math.max(x, CX0), math.max(y, CY0)
  local x2, y2 = math.min(x + w, CX0 + CLW), math.min(y + h, CY0 + CLH)
  for k, z in ipairs(ZONES) do
    local zx1, zy1 = math.max(x1, CX0 + z[1]), math.max(y1, CY0 + z[2])
    local zx2, zy2 = math.min(x2, CX0 + z[1] + z[3]), math.min(y2, CY0 + z[2] + z[4])
    if zx2 > zx1 and zy2 > zy1 then fg(C.cloth[k]); rect(zx1, zy1, zx2 - zx1, zy2 - zy1) end
  end
end
local POCKET_PX = { { CX0, CY0 }, { CX0 + 80, CY0 - 1 }, { CX0 + CLW, CY0 }, { CX0, CY0 + CLH },
  { CX0 + 80, CY0 + CLH + 1 }, { CX0 + CLW, CY0 + CLH } }
local function pocket(k)
  local x, y = POCKET_PX[k][1], POCKET_PX[k][2]
  fg(C.hole)
  rect(x - 2, y - 4, 5, 1); rect(x - 3, y - 3, 7, 7); rect(x - 4, y - 2, 9, 5); rect(x - 2, y + 4, 5, 1)
end
local function ball(i, px, py)
  fg(C.ball[colour(i)])
  rect(px - 1, py - 2, 3, 1); rect(px - 2, py - 1, 5, 3); rect(px - 1, py + 2, 3, 1)
  fg(C.shine[colour(i)]); rect(px - 1, py - 1, 1, 1)
end
local function draw_balls()
  local s = G.s
  for i = 0, 15 do
    if s.on[i] then
      local px, py = sx(s.x[i]), sy(s.y[i])
      ball(i, px, py)
      G.drawn[i] = { px, py }
    else G.drawn[i] = nil end
  end
end

local function draw_table()
  fg(C.room); rect(0, 12, W, 100)
  fg(C.wood2); rect(CX0 - 8, CY0 - 8, CLW + 16, CLH + 16)
  fg(C.wood); rect(CX0 - 7, CY0 - 7, CLW + 14, CLH + 14)
  fg(C.cush); rect(CX0 - 2, CY0 - 2, CLW + 4, CLH + 4)
  cloth_rect(CX0, CY0, CLW, CLH)
  fg(C.dot) -- 库边上的菱形点
  for k = 1, 7 do
    if k ~= 4 then rect(CX0 + k * 20, CY0 - 5, 1, 1); rect(CX0 + k * 20, CY0 + CLH + 4, 1, 1) end
  end
  for k = 1, 3 do rect(CX0 - 5, CY0 + k * 20, 1, 1); rect(CX0 + CLW + 4, CY0 + k * 20, 1, 1) end
  for k = 1, 6 do pocket(k) end
end

-- 瞄准线（虚线，到第一次碰撞为止）和假想球
local function draw_aim()
  local s = G.s
  local t, hit, c, sn = P.trace(s, G.aim)
  local cx, cy = sx(s.x[0]), sy(s.y[0])
  local tp = div(t, 64)
  fg(C.aim)
  for k = 5, tp - 2, 3 do rect(cx + div(c * k, 256), cy + div(sn * k, 256), 1, 1) end
  if hit then
    local gx, gy = cx + div(c * tp, 256), cy + div(sn * tp, 256)
    fg(C.ghost)
    rect(gx - 1, gy - 2, 3, 1); rect(gx - 1, gy + 2, 3, 1); rect(gx - 2, gy - 1, 1, 3); rect(gx + 2, gy - 1, 1, 3)
  end
end
local function draw_cue(pull, chalk)
  local s = G.s
  local c, sn = P.cos(G.aim), P.sin(G.aim)
  local cx, cy = sx(s.x[0]), sy(s.y[0])
  local g = 4 + pull
  for k = g, g + 46 do
    local x, y = cx - div(c * k, 256), cy - div(sn * k, 256)
    if x >= 0 and x < W and y >= 12 and y < 112 then
      if k < g + 2 then fg(chalk and C.tip or C.ink)
      elseif k < g + 32 then fg(C.shaft) else fg(C.butt) end
      rect(x, y, 1, 1)
      if k >= g + 32 then rect(x + 1, y, 1, 1) end
    end
  end
end
local function draw_headline()
  fg(C.ghost)
  local x = sx(P.HEADX)
  for y = CY0 + 1, CY0 + CLH - 2, 4 do rect(x, y, 1, 2) end
end

-- 顶上的状态栏：两边是两方，当前该打的一方是橘色；组的颜色块后面是还剩几颗
local function remaining(g)
  local n = 0
  for i = 1, 15 do if G.s.on[i] and colour(i) == g then n = n + 1 end end
  return n
end
local function draw_status()
  local nm = NAMES[G.kind]
  local key = table.concat({ G.turn, G.grp[1] or 0, G.grp[2] or 0, remaining(1), remaining(2), G.kind,
    tostring(G.winner) }, ",")
  if G.shown.status == key then return end
  G.shown.status = key
  fg(C.room); rect(0, 0, W, 12)
  for who = 1, 2 do
    local active = (G.turn == who and not G.winner) or G.winner == who
    local col = active and C.hi or C.dim
    local g = G.grp[who]
    local label = nm[who]
    if g then label = label .. " " .. remaining(g) end
    local w = text_size(label)
    local x = (who == 1) and 10 or (W - 10 - w)
    text(x, 2, label, col, C.room)
    local bx = (who == 1) and 3 or (W - 7)
    if g then fg(C.ball[g]); rect(bx, 3, 4, 6)
    else fg(C.ball[1]); rect(bx, 3, 2, 6); fg(C.ball[2]); rect(bx + 2, 3, 2, 6) end
    if active and not G.winner then fg(C.hi); rect((who == 1) and 1 or (W - 2), 3, 1, 6) end
  end
end

-- 底下一条：提示文字和力度条
local function bottom_text()
  if G.note then return G.note end
  if G.phase == "over" then
    return NAMES[G.kind][G.winner or 1] .. " wins  sel:new"
  end
  if not human(G.turn) then
    if G.phase == "roll" then return "" end
    return (G.kind == 3) and ("auto " .. PACES[G.pace] .. "s") or "thinking"
  end
  if G.phase == "place" then return (G.shots == 0) and "place the cue ball" or "free ball: place"
  elseif G.phase == "aim" then return "aim  sel:power"
  elseif G.phase == "power" then return "power" end
  return ""
end
local function draw_bottom()
  local tx = bottom_text()
  local showpow = G.phase == "power" or (G.cpu and G.cpu.pull)
  local pw = G.cpu and G.cpu.pull or G.pow
  local key = tx .. "|" .. (showpow and pw or -1)
  if G.shown.bottom == key then return end
  G.shown.bottom = key
  fg(C.room); rect(0, 112, W, H - 112)
  text(3, 118, tx, G.note and C.hi or C.ink, C.room)
  if showpow then
    local bx, bw = W - 64, 60
    fg(C.bar); rect(bx, 119, bw, 6)
    fg(C.hi); rect(bx, 119, div(bw * pw, MAXPOW), 6)
  end
end

local function render_full()
  draw_table()
  local ph = G.phase
  if G.scr == "play" and ph == "place" then draw_headline() end
  draw_balls()
  local aiming = (ph == "aim" or ph == "power") and human(G.turn)
  local cpu = G.cpu and ph == "think"
  if aiming or cpu then
    if aiming then draw_aim() end
    local pull = (ph == "power") and G.pow or (cpu and G.cpu.pull or 0)
    draw_cue(pull, cpu and rb.current_tick() < (G.cpu.chalk_until or 0))
  end
  G.shown = {}
  draw_status()
  draw_bottom()
  rb.lcd_update()
end

-- 球在滚的时候：只擦掉动过的球，再把所有球画一遍
local function render_roll()
  local s = G.s
  for i = 0, 15 do
    local d = G.drawn[i]
    if d then
      local px, py = s.on[i] and sx(s.x[i]) or -99, s.on[i] and sy(s.y[i]) or -99
      if px ~= d[1] or py ~= d[2] then
        cloth_rect(d[1] - 2, d[2] - 2, 5, 5)
        for k = 1, 6 do
          if iabs(POCKET_PX[k][1] - d[1]) < 9 and iabs(POCKET_PX[k][2] - d[2]) < 9 then pocket(k) end
        end
      end
    end
  end
  draw_balls()
  draw_status()
  draw_bottom()
  rb.lcd_update()
end

local function draw_menu()
  local bg = C.room
  fg(bg); rect(0, 0, W, H)
  text(4, 3, "POOL", C.hi, bg)
  for k = 1, 3 do
    local y = 20 + (k - 1) * 30
    if k == G.sel then fg(C.hi); rect(2, y - 1, 3, 19) end
    text(10, y, KINDS[k], (k == G.sel) and C.hi or C.ink, bg)
    local nm = NAMES[k]
    text(10, y + 10, G.games[k] .. "g " .. nm[1] .. " " .. G.w1[k] .. " " .. nm[2] .. " " .. G.w2[k] ..
      " run " .. G.best[k], C.dim, bg)
  end
  rb.lcd_update()
  G.full = true
end

-- ---------- 一局 ----------
-- 人瞄准时，先把球杆对着最近的一颗能打的球
local function targets(who)
  local g = G.grp[who]
  local out = {}
  for i = 1, 15 do
    local c = colour(i)
    if G.s.on[i] and ((g and c == g) or (not g and c ~= 3)) then out[#out + 1] = i end
  end
  if #out == 0 and G.s.on[8] then out[1] = 8 end
  return out
end
local function aim_nearest()
  local s, best, bd = G.s, nil, nil
  for _, i in ipairs(targets(G.turn)) do
    local d = iabs(s.x[i] - s.x[0]) + iabs(s.y[i] - s.y[0])
    if not bd or d < bd then best, bd = i, d end
  end
  if best then G.aim = P.atan(s.x[best] - s.x[0], s.y[best] - s.y[0]) end
end

local function begin_turn()
  G.cpu = nil
  if G.phase ~= "place" then G.phase = "aim" end
  if human(G.turn) then
    if G.phase == "aim" then aim_nearest() end
  elseif G.phase == "aim" then
    G.phase = "think"
  end
  G.full = true
  save()
end

local function new_game(kind)
  G.kind, G.scr = kind, "play"
  G.s = P.new()
  P.rack(G.s, G.rng)
  G.grp, G.shots, G.run, G.winner, G.undo = {}, 0, 0, nil, nil
  G.turn = (kind == 2) and 1 or (mod(G.games[kind], 2) + 1) -- 人对电脑时你先开球
  G.phase, G.placey = "place", div(P.WD, 2)
  G.missed = { false, false }
  G.wait_until = 0
  if not human(G.turn) then G.phase = "think"; G.s.x[0], G.s.y[0] = P.HEADX, div(P.WD, 2) end
  G.cpu = nil
  begin_turn()
end

local function finish(winner)
  G.winner, G.phase, G.over_at = winner, "over", rb.current_tick()
  local k = G.kind
  G.games[k] = G.games[k] + 1
  if winner == 1 then G.w1[k] = G.w1[k] + 1 else G.w2[k] = G.w2[k] + 1 end
  G.full = true
  save()
end

local function take_shot()
  if human(G.turn) and G.kind == 2 then
    G.undo = { s = P.copy(G.s), turn = G.turn, grp = { G.grp[1], G.grp[2] }, shots = G.shots, run = G.run }
  end
  P.shoot(G.s, G.aim, 30 + G.pow * 24)
  G.phase = "roll"
  G.shot_at = rb.current_tick()
  G.full = true
end

-- 全停之后判定这一杆
local function judge()
  local s, me = G.s, G.turn
  local o = outcome(s, G.grp[me], G.shots == 0)
  G.shots = G.shots + 1
  if o.respot then P.respot(s, 8) end
  G.missed[me] = o.foul or not o.cont
  if o.win then finish(me); return end
  if o.lose then finish(3 - me); return end
  if o.ng and not G.grp[me] then G.grp[me], G.grp[3 - me] = o.ng, 3 - o.ng; say(o.ng == 1 and "red" or "yellow") end
  if o.cont then
    G.run = G.run + o.own
    if G.run > G.best[G.kind] then G.best[G.kind] = G.run end
    G.phase = "aim"
  else
    G.run = 0
    G.turn = 3 - me
    if o.foul then
      if not s.on[0] then s.on[0] = true; s.vx[0], s.vy[0] = 0, 0 end
      say("foul - free ball")
      G.phase, G.placey = "place", s.y[0]
      if not P.free_ok(s, G.placey) or s.x[0] ~= P.HEADX then G.placey = div(P.WD, 2) end
    else G.phase = "aim" end
  end
  if G.phase == "place" then
    s.x[0] = P.HEADX
    local y = G.placey
    for k = 0, 40 do
      local yy = y + ((mod(k, 2) == 0) and 1 or -1) * div(k + 1, 2) * U
      if yy >= P.R and yy <= P.WD - P.R and P.free_ok(s, yy) then G.placey = yy; break end
    end
    s.y[0] = G.placey
  end
  begin_turn()
end

-- ---------- 电脑 ----------
local function cpu_start()
  local me = G.turn
  local s = G.s
  local c = { t0 = rb.current_tick(), i = 0, best = nil, bestv = nil }
  if G.phase == "place" then -- 自由球：在开球线上挑一个空位
    local tries = { 0, -12, 12, -24, 24, -6, 6, -18, 18, -30, 30 }
    for _, d in ipairs(tries) do
      local y = div(P.WD, 2) + d * U
      if P.free_ok(s, y) then s.x[0], s.y[0] = P.HEADX, y; break end
    end
    s.on[0] = true
    G.phase = "think"
    G.full = true
  end
  if G.shots == 0 then -- 开球：大力冲着三角顶点
    c.list = { { a = P.atan(div(P.L * 3, 4) - s.x[0], div(P.WD, 2) - s.y[0]) + G.rng(9) - 4, pw = MAXPOW } }
  else
    c.list = P.plan(s, targets(me))
  end
  -- 再加几个随便的方向，没得打的时候用
  for _ = 1, 3 do c.list[#c.list + 1] = { a = G.rng(1024), pw = 6 + G.rng(8), q = -2000 } end
  c.budget = (G.missed[me] and 7 or 4) * HZ -- 上一杆打丢了，这一杆想得更久
  if G.rng(4) == 0 then c.chalk_until = rb.current_tick() + HZ end
  G.cpu = c
end

local function cpu_score(o, sim)
  if o.win then return 100000 end
  if o.lose then return -100000 end
  local v = o.own * 300 - o.opp * 80
  if o.foul then v = v - 1000 end
  if o.cont and sim.on[0] then -- 白球停得好：离下一颗能打的球不远也不贴着
    local best = 9999
    for i = 1, 15 do
      if sim.on[i] and colour(i) == (o.ng or 0) then
        local d = div(iabs(sim.x[i] - sim.x[0]) + iabs(sim.y[i] - sim.y[0]), U)
        best = math.min(best, iabs(d - 40))
      end
    end
    v = v + 60 - math.min(best, 60)
  end
  return v
end

local function cpu_tick()
  if not G.cpu then cpu_start() end
  local c = G.cpu
  local tk = rb.current_tick()
  if c.pull then -- 拉杆的动画，然后出杆
    c.pull = c.pull + 2
    if c.pull >= c.final.pw then
      G.aim, G.pow = c.final.a, c.final.pw
      G.cpu = nil
      take_shot()
    end
    G.full = true
    return
  end
  local me = G.turn
  if c.i < #c.list and (tk - c.t0 < c.budget or not c.best) then
    -- 每帧试一杆：球杆就在这个角度上比划
    c.i = c.i + 1
    local cand = c.list[c.i]
    local sim = P.copy(G.s)
    P.shoot(sim, cand.a, 30 + cand.pw * 24)
    P.settle(sim)
    local v = cpu_score(outcome(sim, G.grp[me], G.shots == 0), sim) + G.rng(20)
    if not c.bestv or v > c.bestv then c.best, c.bestv = cand, v end
    G.aim = cand.a
    G.full = true
    return
  end
  -- 想好了：至少想 2 秒，电脑对电脑还要等够每杆的间隔
  if tk - c.t0 < 2 * HZ or tk < G.wait_until then
    if G.aim ~= c.best.a then G.aim = c.best.a; G.full = true end
    return
  end
  local shake = (G.kind == 3) and 5 or 4 -- 手抖
  c.final = { a = mod(c.best.a + G.rng(shake * 2 + 1) - shake, 1024), pw = clamp(c.best.pw + G.rng(3) - 1, 2, MAXPOW) }
  G.aim, c.pull = c.final.a, 0
  if G.kind == 3 then G.wait_until = tk + PACES[G.pace] * HZ end
  G.full = true
end

-- ---------- 按键 ----------
local function help()
  help_screen("POOL", {
    "Eight-ball. 7 red, 7",
    "yellow, the black, the",
    "white. The first ball you",
    "pot after the break sets",
    "your colour. Clear your",
    "colour, then the black.",
    "Black too early = you lose.",
    "Foul (white in, or wrong",
    "ball first): the other",
    "side gets a free ball on",
    "the line.",
    "",
    "*Aim",
    "wheel  turn the cue",
    "       (slow = fine)",
    "select set the aim",
    "*Power",
    "wheel  pull back / ease",
    "select shoot",
    "menu   back to aim",
    "*Free ball",
    "wheel  slide the white",
    "select put it down",
    "",
    "prev   undo a shot (cpu)",
    "hold select  modes",
    "play   watching: 5/10/20 s",
    "menu   quit",
  })
  G.full = true
  if G.scr == "menu" then draw_menu() end
end

local function undo()
  local u = G.undo
  if not u or G.kind ~= 2 then return end
  G.s, G.turn, G.grp, G.shots, G.run = u.s, u.turn, u.grp, u.shots, u.run
  G.winner, G.undo = nil, nil
  G.phase = "aim"
  say("undo")
  begin_turn()
end

local function aim_step()
  local sp = wheel_speed(div(HZ, 10))
  if sp < 60 then return 1 elseif sp < 120 then return 2 elseif sp < 250 then return 6 end
  return 16
end

local function on_key(e)
  local g = select_gesture(e)
  if e.k == "help" then help(); return end
  local turn_ = (e.k == "fwd" or e.k == "back") and not e.rel
  local d = (e.k == "fwd") and 1 or -1
  if G.scr == "menu" then
    if e.k == "menu" then G.quit = true
    elseif turn_ then G.sel = mod(G.sel - 1 + d, 3) + 1; draw_menu()
    elseif g == "short" then new_game(G.sel) end
    return
  end
  if e.k == "menu" then
    if G.phase == "power" and human(G.turn) then G.phase = "aim"; G.full = true else G.quit = true end
    return
  end
  if g == "long" then
    if G.phase ~= "roll" then G.sel, G.scr = G.kind, "menu"; save(); draw_menu() end
    return
  end
  if e.k == "prev" and not e.rel and not e.rep then
    if G.phase ~= "roll" then undo() end
    return
  end
  if e.k == "play" and not e.rel and not e.rep and G.kind == 3 then
    G.pace = mod(G.pace, #PACES) + 1
    say("every " .. PACES[G.pace] .. "s")
    save()
    return
  end
  if G.phase == "over" then
    if g == "short" then
      if G.kind == 3 then new_game(3) else G.sel, G.scr = G.kind, "menu"; save(); draw_menu() end
    end
    return
  end
  if not human(G.turn) then return end
  local s = G.s
  if G.phase == "place" then
    if turn_ then
      local y = G.placey
      for _ = 1, 40 do
        y = y + d * 128
        if y < P.R or y > P.WD - P.R then break end
        if P.free_ok(s, y) then G.placey = y; break end
      end
      s.x[0], s.y[0], s.on[0] = P.HEADX, G.placey, true
      G.full = true
    elseif g == "short" then G.phase = "aim"; aim_nearest(); G.full = true end
  elseif G.phase == "aim" then
    if turn_ then G.aim = mod(G.aim + d * aim_step(), 1024); G.full = true
    elseif g == "short" then G.phase = "power"; G.full = true end
  elseif G.phase == "power" then
    if turn_ then G.pow = clamp(G.pow - d, 1, MAXPOW); G.full = true
    elseif g == "short" then take_shot() end
  end
end

-- ---------- 主循环 ----------
local found = load()
light_start()
if not found then help() end
if G.scr == "menu" then draw_menu() elseif G.phase ~= "over" then begin_turn() end

while not G.quit do
  for _, e in ipairs(poll()) do on_key(e) end
  if G.quit then break end
  if G.note and rb.current_tick() > G.note_until then G.note = nil end
  if G.scr == "play" then
    if G.phase == "roll" then
      local moving = false
      for _ = 1, SUBSTEPS do if P.step(G.s) then moving = true end end
      if moving then render_roll() else judge() end
    elseif G.phase == "think" or (G.phase == "place" and not human(G.turn)) then
      cpu_tick()
    elseif G.phase == "over" and G.kind == 3 and rb.current_tick() > G.over_at + 60 * HZ then
      new_game(3) -- 观战：终局停一分钟，没人按就开下一局
    end
    if G.phase ~= "roll" and not G.quit then
      if G.full then G.full = false; render_full() else draw_status(); draw_bottom(); rb.lcd_update() end
    end
  end
  keep_light()
  rb.sleep(div(HZ, 25))
end

save()
light_end()
end
main()
