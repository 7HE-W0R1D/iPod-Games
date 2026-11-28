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

-- 沙堆：一粒一粒落沙，偶尔毫无预兆地崩塌一大片
-- 转盘：时间流速   Select：亲手放一粒   Play：中心落 / 随机落   下一首：看最大崩塌   Menu：退出

local SAVE = "slow_sandpile.txt"
local CELL = 4
local GW, GH = div(W, CELL), div(H, CELL) -- 44 × 33
local N = GW * GH

-- 每粒的间隔（毫秒）。默认 1 小时一粒。
local SPEEDS = { 86400000, 21600000, 3600000, 600000, 60000, 10000, 1000, 250, 100, 33 }
local SPEED_NAMES = { "1/day", "4/day", "1/hour", "6/hour", "1/min", "6/min", "1/s", "4/s", "10/s", "30/s" }
local CATCHUP_MAX = 20000 -- 打开时最多补算多少粒

local COLORS = {
  [0] = rgb(40, 30, 22), rgb(120, 90, 55), rgb(190, 150, 95), rgb(240, 215, 160),
}
local FLASH = rgb(255, 255, 255)
local INK = rgb(150, 130, 110)
local BG = COLORS[0]

-- ---------- 状态 ----------
local grid = {}
local total, speed, centered = 0, 3, true
local best_size, best_t = 0, 0
local last_t = now()
local rnd = Rng(rb.current_tick() + last_t)

local function load()
  local s, found = load_kv(SAVE)
  local g = s.grid or ""
  for i = 1, N do grid[i] = num(string.sub(g, i, i), 0) end
  if not found then return end
  total = num(s.total, 0)
  speed = clamp(num(s.speed, 3), 1, #SPEEDS)
  centered = s.mode ~= "random"
  best_size, best_t = num(s.best_size, 0), num(s.best_t, 0)
  last_t = num(s.last_t, last_t)
end

local function save()
  local parts = {}
  for i = 1, N do parts[i] = grid[i] end
  save_kv(SAVE, {
    grid = table.concat(parts), total = total, speed = speed,
    mode = centered and "center" or "random",
    best_size = best_size, best_t = best_t, last_t = last_t,
  })
end

-- ---------- 规则 ----------
local stamp, stamp_id = {}, 0 -- 记录这次崩塌里倒过的格子，好算“多少格”
local flashing = {}           -- 这一帧要闪白的格子
local dirty = {}              -- 这一帧要重画的落点
local stack = {}

-- 往第 i 格放一粒，返回这次崩塌涉及的格子数
local function drop(i, record_flash)
  total = total + 1
  grid[i] = grid[i] + 1
  if record_flash then dirty[#dirty + 1] = i end
  if grid[i] < 4 then return 0 end
  stamp_id = stamp_id + 1
  local size = 0
  local sp = 1
  stack[1] = i
  while sp > 0 do
    local c = stack[sp]
    sp = sp - 1
    local v = grid[c]
    if v >= 4 then
      local k = div(v, 4)
      grid[c] = v - 4 * k
      if stamp[c] ~= stamp_id then
        stamp[c] = stamp_id
        size = size + 1
        if record_flash then flashing[#flashing + 1] = c end
      end
      local x = mod(c - 1, GW)
      -- 四个邻居；出界的沙就没了
      if x > 0 then local n = c - 1; grid[n] = grid[n] + k; if grid[n] >= 4 then sp = sp + 1; stack[sp] = n end end
      if x < GW - 1 then local n = c + 1; grid[n] = grid[n] + k; if grid[n] >= 4 then sp = sp + 1; stack[sp] = n end end
      if c > GW then local n = c - GW; grid[n] = grid[n] + k; if grid[n] >= 4 then sp = sp + 1; stack[sp] = n end end
      if c <= N - GW then local n = c + GW; grid[n] = grid[n] + k; if grid[n] >= 4 then sp = sp + 1; stack[sp] = n end end
    end
  end
  return size
end

local function where()
  if centered then return div(GH, 2) * GW + div(GW, 2) + 1 end
  return rnd(N) + 1
end

local function note_avalanche(size, t)
  if size > best_size then best_size, best_t = size, t end
end

-- ---------- 画面 ----------
local function draw_cell(i, c)
  fg(c)
  local x, y = mod(i - 1, GW), div(i - 1, GW)
  rect(x * CELL, y * CELL, CELL, CELL)
end
local function draw_all()
  for i = 1, N do draw_cell(i, COLORS[grid[i]]) end
end

local overlay, overlay_until = nil, 0
local function draw_corner()
  -- 角落的数字底下那几格先重画，免得残影
  local s = tostring(total)
  local tw, th = text_size(s)
  local cx0, cy0 = div(W - tw - 3, CELL), div(H - th - 2, CELL)
  for y = cy0, GH - 1 do for x = cx0, GW - 1 do draw_cell(y * GW + x + 1, COLORS[grid[y * GW + x + 1]]) end end
  text_r(W - 2, H - th - 1, s, INK, BG)
  if overlay and rb.current_tick() < overlay_until then
    text(2, 2, overlay, INK, BG)
  elseif overlay then
    overlay = nil
    draw_all()
  end
end
local function show(msg)
  overlay, overlay_until = msg, rb.current_tick() + 2 * HZ
end

-- ---------- 补算不在场的时间 ----------
local function catch_up()
  local t = now()
  local elapsed = t - last_t
  if elapsed <= 0 then last_t = t; return end
  local ms = SPEEDS[speed]
  local n
  if ms >= 1000 then
    local per = div(ms, 1000)
    n = div(elapsed, per)
    last_t = last_t + n * per
  else
    n = elapsed * div(1000, ms)
    last_t = t
  end
  if n > CATCHUP_MAX then n = CATCHUP_MAX; last_t = t end
  if n <= 0 then return end
  local start = t - elapsed
  local per_s = div(elapsed, n) -- 大致每粒间隔几秒，用来给“最大崩塌”标日期
  for k = 1, n do
    local size = drop(where(), false)
    if size > 0 then note_avalanche(size, start + k * per_s) end
    if mod(k, 500) == 0 then -- 进度条
      fg(INK); rect(0, H - 2, div(k * W, n), 2); rb.lcd_update()
    end
  end
end

-- ---------- 主循环 ----------
load()
light_start()
fg(BG); rect(0, 0, W, H)
catch_up()
draw_all()
draw_corner()
rb.lcd_update()

local acc = 0 -- 累积的毫秒
local prev_tick = rb.current_tick()
local flash_prev = {}
local running = true
local frame = 0

while running do
  for _, e in ipairs(poll()) do
    if e.k == "menu" and not e.rel then running = false
    elseif e.k == "help" then
      help_screen("SANDPILE", {
        "Sand falls grain by grain.",
        "Now and then, with no",
        "warning, a big avalanche.",
        "Corner: grains so far.",
        "",
        "*Keys",
        "wheel   time speed",
        "select  drop one grain",
        "play    centre / random",
        "next    biggest avalanche",
        "menu    quit",
        "hold menu  this help",
      })
      draw_all(); draw_corner()
    elseif e.k == "fwd" and not e.rel then speed = clamp(speed + 1, 1, #SPEEDS); acc = 0; show(SPEED_NAMES[speed])
    elseif e.k == "back" and not e.rel then speed = clamp(speed - 1, 1, #SPEEDS); acc = 0; show(SPEED_NAMES[speed])
    elseif e.k == "play" and not e.rel and not e.rep then
      centered = not centered
      show(centered and "center" or "random")
    elseif e.k == "next" and not e.rel and not e.rep then
      if best_size > 0 then show("max " .. best_size .. "  " .. timestr(best_t)) else show("max -") end
    elseif select_gesture(e) == "short" then
      local size = drop(where(), true)
      if size > 0 then note_avalanche(size, now()) end
    end
  end

  -- 按设定的速度落沙
  local tk = rb.current_tick()
  acc = acc + div((tk - prev_tick) * 1000, HZ)
  prev_tick = tk
  local ms = SPEEDS[speed]
  local budget = 40 -- 每帧最多落这么多，防止卡死
  while acc >= ms and budget > 0 do
    acc = acc - ms
    budget = budget - 1
    local size = drop(where(), true)
    if size > 0 then note_avalanche(size, now()) end
  end
  if acc > ms * 4 then acc = 0 end
  last_t = now() - div(acc, 1000)

  -- 上一帧闪白的格子和它们的邻居恢复原色；落点重画；这一帧倒塌的闪白
  for _, i in ipairs(flash_prev) do
    draw_cell(i, COLORS[grid[i]])
    local x = mod(i - 1, GW)
    if x > 0 then draw_cell(i - 1, COLORS[grid[i - 1]]) end
    if x < GW - 1 then draw_cell(i + 1, COLORS[grid[i + 1]]) end
    if i > GW then draw_cell(i - GW, COLORS[grid[i - GW]]) end
    if i <= N - GW then draw_cell(i + GW, COLORS[grid[i + GW]]) end
  end
  for _, i in ipairs(dirty) do draw_cell(i, COLORS[grid[i]]) end
  for _, i in ipairs(flashing) do draw_cell(i, FLASH) end
  flash_prev, flashing, dirty = flashing, {}, {}

  draw_corner()
  rb.lcd_update()
  keep_light()

  frame = frame + 1
  if mod(frame, 600) == 0 then save() end
  rb.sleep(div(HZ, 15))
end

save()
light_end()
