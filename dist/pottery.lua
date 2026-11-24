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

-- 陶艺转盘：泥在拉坯机上自己转。转盘把双手上下移动，上一首 / 下一首把那一层收窄 / 甩宽。
-- 转盘：手的高度（看架子时横向浏览）   上一首 / 下一首：收窄 / 加宽   Select 或 Play：送进窑
-- 长按 Select：看架子   Menu：退出   长按 Menu：说明
-- 收窄的地方会被拔高，加宽的地方变扁；悬出去太多会歪掉。进窑一小时后才看到成品，窑上的小钟走一圈就好了。

local SAVE = "slow_pottery.txt"
local NL = 30                  -- 层数
local KILN_SECONDS = 3600      -- 烧窑一小时
local RMIN, RMAX = 4, 46       -- 每层半径的范围
local OVERHANG = 10            -- 比下面一层宽出这么多就开始失稳
local CX, BASE = div(W, 2), H - 10

local CLAY = { 168, 112, 80 }
local GLAZES = {
  { 150, 190, 160 }, { 70, 42, 28 }, { 185, 172, 140 }, { 45, 72, 150 },
  { 222, 202, 182 }, { 150, 45, 38 }, { 95, 120, 70 }, { 210, 160, 70 },
}

-- ---------- 存档 ----------
local shelf = {}  -- 每只罐子：{ r = {}, h = {}, off = {}, glaze = {r,g,b}, drip = {r,g,b}, bad = bool }
local kiln = nil  -- 正在烧的：{ pot = ..., ready = unix 秒 }

local function enc(p)
  local r, h, o = {}, {}, {}
  for i = 1, NL do
    r[i] = string.char(48 + p.r[i]); h[i] = string.char(48 + p.h[i]); o[i] = string.char(80 + (p.off[i] or 0))
  end
  local g, d = p.glaze or CLAY, p.drip or CLAY
  return table.concat(r) .. "|" .. table.concat(h) .. "|" .. table.concat(o) .. "|" ..
    g[1] .. "," .. g[2] .. "," .. g[3] .. "|" .. d[1] .. "," .. d[2] .. "," .. d[3] .. "|" .. (p.bad and "1" or "0")
end
local function dec(s)
  local a, b, c, g, d, bad = string.match(s, "^([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)|(%d)$")
  if not a or #a ~= NL then return nil end
  local p = { r = {}, h = {}, off = {}, bad = bad == "1" }
  for i = 1, NL do
    p.r[i] = string.byte(a, i) - 48; p.h[i] = string.byte(b, i) - 48; p.off[i] = string.byte(c, i) - 80
  end
  local function rgb3(x) local r_, g_, b_ = string.match(x, "(%d+),(%d+),(%d+)"); return { tonumber(r_), tonumber(g_), tonumber(b_) } end
  p.glaze, p.drip = rgb3(g), rgb3(d)
  return p
end

local function save()
  local t = { count = #shelf }
  for i, p in ipairs(shelf) do t["pot" .. i] = enc(p) end
  if kiln then t.kiln = enc(kiln.pot); t.kiln_ready = kiln.ready end
  save_kv(SAVE, t)
end
local function load()
  local s = load_kv(SAVE)
  for i = 1, num(s.count, 0) do
    local p = s["pot" .. i] and dec(s["pot" .. i])
    if p then shelf[#shelf + 1] = p end
  end
  if s.kiln then
    local p = dec(s.kiln)
    if p then kiln = { pot = p, ready = num(s.kiln_ready, now()) } end
  end
end

-- ---------- 釉色：同样的形状，每次烧出来都不一样 ----------
local function fire(p, seed)
  local r = Rng(seed)
  local base = GLAZES[r(#GLAZES) + 1]
  local other = GLAZES[r(#GLAZES) + 1]
  p.glaze = { clamp(base[1] + r(41) - 20, 0, 255), clamp(base[2] + r(41) - 20, 0, 255), clamp(base[3] + r(41) - 20, 0, 255) }
  p.drip = mix(p.glaze, other, 40 + r(120), 256)
end

-- ---------- 画罐子 ----------
-- scale：1 原大，2 缩小一半。phase：转动的相位，让横线上的明暗流动。
local function draw_pot(cx, by, p, scale, body, phase, hand_layer)
  local y = by
  local hi = pack(mix(body, { 255, 255, 255 }, 1, 4))
  local lo = pack(mix(body, { 0, 0, 0 }, 1, 3))
  local mid = pack(body)
  local drip = p.drip and pack(p.drip)
  local total_h = 0
  for i = 1, NL do total_h = total_h + p.h[i] end
  local row = 0
  for i = 1, NL do
    if p.r[i] > 0 then
      for _ = 1, p.h[i] do
        row = row + 1
        if scale == 1 or mod(row, 2) == 0 then
          y = y - 1
          local r = div(p.r[i], scale)
          local x0 = cx - r + div(p.off[i], scale)
          local wcol = mid
          if drip and row > total_h - div(total_h, 3) - mod(i * 7, 5) then wcol = drip end -- 上半截挂釉
          fg(wcol); rect(x0, y, r * 2, 1)
          fg(lo); rect(x0, y, math.max(1, div(r, 4)), 1); rect(x0 + r * 2 - math.max(1, div(r, 4)), y, math.max(1, div(r, 4)), 1)
          if r > 3 then
            fg(hi); rect(x0 + div(r, 2), y, 2, 1)
            if phase then
              fg(lo); rect(x0 + mod(phase + row * 5, r * 2), y, 1, 1) -- 转动时流动的暗纹
            end
          end
          if hand_layer == i and scale == 1 then
            fg(rgb(225, 180, 150)); rect(x0 - 4, y - 1, 3, 3); rect(x0 + r * 2 + 1, y - 1, 3, 3)
          end
        end
      end
    end
  end
end

local function new_lump()
  local p = { r = {}, h = {}, off = {} }
  for i = 1, NL do p.r[i] = 24 - div(i * i, 90); p.h[i] = 1; p.off[i] = 0 end
  return p
end

local BG = rgb(38, 32, 30)
local function draw_wheel_scene(p, phase, hand_layer, wob)
  fg(BG); rect(0, 0, W, H)
  fg(rgb(90, 90, 95)); rect(CX - 50, BASE, 100, 4); fg(rgb(60, 60, 64)); rect(CX - 44, BASE + 4, 88, 6)
  local c = { CLAY[1], CLAY[2], CLAY[3] }
  if wob > 20 then -- 失稳时泥颜色发暗、发抖
    c = mix(CLAY, { 110, 70, 50 }, wob, 80)
  end
  draw_pot(CX + (wob > 30 and mod(phase, 3) - 1 or 0), BASE, p, 1, c, phase, hand_layer)
  text_r(W - 2, 2, tostring(#shelf), rgb(120, 105, 95), BG)
  rb.lcd_update()
end

-- 烧窑的小钟：转一圈 = 一小时。走过的部分填上火色，一根指针指着现在
local CLK_R = 10
local CLK_COS = { [0] = 64, 62, 55, 45, 32, 17, 0, -17, -32, -45, -55, -62, -64, -62, -55, -45, -32, -17, 0, 17, 32, 45, 55, 62 }
local CLK_SEC -- 每个点属于哪个扇区（从 12 点顺时针 0..23；圆外是 -1），第一次用时算一次
local function clock_sectors()
  CLK_SEC = {}
  for y = -CLK_R, CLK_R do
    local row = {}
    for x = -CLK_R, CLK_R do
      local bi = -1
      if x * x + y * y <= CLK_R * CLK_R then
        local best = -1000000
        for k = 0, 23 do
          local d = x * CLK_COS[mod(k + 18, 24)] + y * CLK_COS[mod(k + 12, 24)]
          if d > best then best, bi = d, k end
        end
      end
      row[x] = bi
    end
    CLK_SEC[y] = row
  end
end
local function draw_clock(cx, cy, done, fire)
  if not CLK_SEC then clock_sectors() end
  local face, rim, ink = rgb(52, 42, 36), rgb(120, 96, 80), rgb(235, 225, 200)
  local hot = pack(fire)
  local filled = div(done * 24, KILN_SECONDS) -- 24 个扇区里走过了几个
  for y = -CLK_R, CLK_R do
    local row = CLK_SEC[y]
    local x = -CLK_R
    while x <= CLK_R and row[x] < 0 do x = x + 1 end
    if x <= CLK_R then
      fg(rim); rect(cx + x - 1, cy + y, 1, 1); rect(cx - x + 1, cy + y, 1, 1)
      -- 按连续的同色段画，一行最多三四段
      while x <= CLK_R and row[x] >= 0 do
        local on = row[x] < filled
        local x0 = x
        while x <= CLK_R and row[x] >= 0 and (row[x] < filled) == on do x = x + 1 end
        fg(on and hot or face); rect(cx + x0, cy + y, x - x0, 1)
      end
    end
  end
  fg(rim); rect(cx - 1, cy - CLK_R - 1, 3, 1); rect(cx - 1, cy + CLK_R + 1, 3, 1)
  -- 刻度：12、3、6、9 点
  fg(rim); rect(cx, cy - CLK_R + 1, 1, 2); rect(cx, cy + CLK_R - 2, 1, 2); rect(cx - CLK_R + 1, cy, 2, 1); rect(cx + CLK_R - 2, cy, 2, 1)
  -- 指针
  local a = div(done * 24, KILN_SECONDS)
  local dx, dy = CLK_COS[mod(a + 18, 24)], CLK_COS[mod(a + 12, 24)]
  fg(ink)
  for k = 0, CLK_R - 2 do rect(cx + div(dx * k, 64), cy + div(dy * k, 64), 1, 1) end
  rect(cx, cy, 1, 1)
end

local function draw_kiln(t)
  local tk = rb.current_tick()
  local night = rgb(20, 16, 15)
  fg(night); rect(0, 0, W, H)
  -- 火候：刚进窑暗红，快烧好时橘黄
  local left = clamp(kiln.ready - t, 0, KILN_SECONDS)
  local p = KILN_SECONDS - left
  local fire = mix({ 150, 45, 20 }, { 255, 185, 80 }, p, KILN_SECONDS)
  local flame = mix(fire, { 255, 240, 170 }, 1, 2)
  -- 地面和门前的火光
  fg(rgb(34, 28, 25)); rect(0, 112, W, H - 112)
  for k = 0, 2 do
    fg(pack(mix({ 34, 28, 25 }, fire, 3 - k, 6)))
    rect(CX - 22 - k * 10, 112 + k * 5, 44 + k * 20, 5)
  end
  -- 烟囱和烟
  local brick, mortar = { 92, 60, 46 }, rgb(58, 40, 32)
  fg(pack(brick)); rect(CX + 22, 14, 12, 34)
  fg(mortar); for y = 20, 44, 6 do rect(CX + 22, y, 12, 1) end
  fg(rgb(85, 80, 78))
  for k = 0, 5 do
    local y = 12 - k * 3 - mod(div(tk, 8), 3)
    local x = CX + 26 + iabs(mod(div(tk, 6) + k * 2, 8) - 4) + k
    if y >= 0 then rect(x, y, 2 + div(k, 2), 2) end
  end
  -- 窑身：圆拱形砖窑
  local top = 40
  for y = top, 111 do
    local d = y - top
    local inset = d < 14 and div((14 - d) * (14 - d), 7) or 0
    local hw = 46 - inset
    fg(pack(brick)); rect(CX - hw, y, hw * 2, 1)
    if mod(d, 6) == 5 then fg(mortar); rect(CX - hw, y, hw * 2, 1)
    else
      fg(mortar)
      local off = mod(div(d, 6), 2) * 6
      for x = CX - hw + off, CX + hw - 1, 12 do rect(x, y, 1, 1) end
    end
  end
  -- 窑门：拱形开口，里面的火苗在跳
  for y = 76, 111 do
    local d = y - 76
    local hw = d < 6 and 16 - div((6 - d) * (6 - d), 3) or 16
    fg(pack(fire)); rect(CX - hw, y, hw * 2, 1)
  end
  local r = Rng(div(tk, 6))
  fg(pack(flame))
  for x = CX - 14, CX + 13, 3 do
    local h = 6 + r(10) + div(p * 8, KILN_SECONDS)
    rect(x, 112 - h, 2, h)
  end
  fg(mortar); rect(CX - 18, 74, 36, 2)
  draw_clock(24, 20, p, fire)
  text_r(W - 2, 2, tostring(#shelf), rgb(120, 105, 95), night)
  rb.lcd_update()
end

local function pot_width(p)
  local m = 0
  for i = 1, NL do m = math.max(m, p.r[i] + iabs(p.off[i])) end
  return m + 6
end
local function draw_shelf(scroll)
  fg(rgb(48, 40, 34)); rect(0, 0, W, H)
  local wood, wood2 = rgb(130, 92, 58), rgb(95, 66, 42)
  local rows = { { y = 62, bad = false }, { y = H - 6, bad = true } }
  for _, row in ipairs(rows) do
    fg(wood); rect(0, row.y, W, 3); fg(wood2); rect(0, row.y + 3, W, 2)
    local x = 6 - scroll
    for _, p in ipairs(shelf) do
      if p.bad == row.bad then
        local w = pot_width(p)
        if x + w > 0 and x - w < W then draw_pot(x + w, row.y, p, 2, p.glaze or CLAY) end
        x = x + w + 4
      end
    end
  end
  text(3, 68, "seconds", rgb(150, 130, 110), rgb(48, 40, 34))
  text_r(W - 2, 2, tostring(#shelf), rgb(150, 130, 110), rgb(48, 40, 34))
  rb.lcd_update()
end

-- ---------- 主循环 ----------
load()
light_start()
local mode = "wheel"           -- wheel / kiln / shelf
local pot = new_lump()
local hand = 1                 -- 手在第几层：开局在最宽的底层
local shaped = false           -- 动过泥才能送窑，免得误触
local wob, phase, bad = 0, 0, false
local scroll = 0
local running = true

-- 收窄 / 加宽手所在的那一层（上下各一层跟着动一半）
local function shape(dr)
  shaped = true
  for i = math.max(1, hand - 1), math.min(NL, hand + 1) do
    local d = (i == hand) and dr or div(dr, 2)
    pot.r[i] = clamp(pot.r[i] + d, RMIN, RMAX)
  end
  -- 收窄的地方被拔高，加宽的地方变扁
  local h = pot.h[hand]
  if dr < 0 and pot.r[hand] < 16 then h = h + 1 elseif dr > 0 and pot.r[hand] > 20 then h = h - 1 end
  pot.h[hand] = clamp(h, 1, 4)
  -- 泥是连着的：相邻两层粗细差得不能太多
  for i = 2, NL do pot.r[i] = clamp(pot.r[i], pot.r[i - 1] - 3, pot.r[i - 1] + 3) end
  for i = NL - 1, 1, -1 do pot.r[i] = clamp(pot.r[i], pot.r[i + 1] - 3, pot.r[i + 1] + 3) end
end

-- 悬出去太多就失稳：上面一层比下面宽出很多
local function overhang()
  local m, lo = 0, pot.r[1]
  for i = 2, NL do
    if pot.r[i] - lo > m then m = pot.r[i] - lo end
    if pot.r[i] < lo then lo = pot.r[i] end
  end
  return m
end

local function finish_throw()
  local p = pot
  p.bad = bad
  kiln = { pot = p, ready = now() + KILN_SECONDS }
  save()
  mode = "kiln"
  pot, hand, shaped, wob, bad = new_lump(), 1, false, 0, false
end

local function check_kiln()
  if kiln and now() >= kiln.ready then
    fire(kiln.pot, kiln.ready)
    shelf[#shelf + 1] = kiln.pot
    kiln = nil
    save()
    mode = "shelf"
    scroll = 0
  end
end

local function back_from_shelf() mode = kiln and "kiln" or "wheel" end

if kiln then mode = "kiln" end
check_kiln()

while running do
  for _, e in ipairs(poll()) do
    local g = select_gesture(e)
    if e.k == "menu" and not e.rel then running = false
    elseif e.k == "help" then
      help_screen("POTTERY", {
        "The clay spins on the",
        "wheel. Move your hands up",
        "and down and shape each",
        "layer. Narrow = taller,",
        "wide = flatter. Lean out",
        "too far and it wobbles.",
        "The kiln takes an hour;",
        "the little clock shows",
        "how far along it is.",
        "",
        "*Keys",
        "wheel   hands up / down",
        "        (shelf: scroll)",
        "next    widen",
        "prev    narrow",
        "select  fire it",
        "play    fire it",
        "hold select  shelf",
        "menu    quit",
        "hold menu  this help",
      })
    elseif g == "long" then
      if mode == "shelf" then back_from_shelf() else mode = "shelf" end
    elseif mode == "shelf" then
      if (e.k == "fwd" or e.k == "back") and not e.rel then scroll = math.max(0, scroll + (e.k == "fwd" and 4 or -4))
      elseif g == "short" or (e.k == "play" and not e.rel and not e.rep) then back_from_shelf() end
    elseif mode == "kiln" then
      if e.k == "play" and not e.rel and not e.rep then mode = "shelf" end
    else -- wheel
      if e.k == "fwd" and not e.rel then hand = clamp(hand + 1, 1, NL)
      elseif e.k == "back" and not e.rel then hand = clamp(hand - 1, 1, NL)
      elseif e.k == "next" and not e.rel then shape(2)
      elseif e.k == "prev" and not e.rel then shape(-2)
      elseif (g == "short" or (e.k == "play" and not e.rel and not e.rep)) and shaped then finish_throw() end
    end
  end

  if mode == "wheel" then
    phase = phase + 3
    -- 悬出去太多：慢慢歪掉
    if overhang() > OVERHANG then wob = wob + 2 elseif wob > 0 and not bad then wob = wob - 1 end
    if wob > 70 and not bad then
      bad = true
      for i = hand, NL do pot.off[i] = clamp(div((i - hand) * (i - hand), 6), 0, 40) end
    end
    draw_wheel_scene(pot, phase, hand, wob)
  elseif mode == "kiln" then
    check_kiln()
    if mode == "kiln" then draw_kiln(now()) end
  else
    draw_shelf(scroll)
  end
  keep_light()
  rb.sleep(div(HZ, 20))
end

save()
light_end()
