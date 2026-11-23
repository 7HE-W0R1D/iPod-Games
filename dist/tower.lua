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

-- 瞭望塔：在森林火警塔上 360 度环视。大部分时候什么都没有，你的工作只是看和记录。
-- 转盘：转身   Select：记日志（附时间和方位）   长按 Select：翻日志   Menu：退出

local SAVE = "slow_tower.txt"
local PW = W * 4                -- 一圈全景的宽度
local DEG_PER_CLICK = 3         -- 一格转几度（转盘一圈大约看一圈，上机再调）
local VIEW_DEG = div(360 * W, PW) -- 屏幕一次看到的角度（90°）
local SCAR_DAYS = 35            -- 焦黑的山坡多少天后完全返绿
local BUSY_CLICKS = 1500        -- 一天转身超过这么多格就算“太勤快”

-- ---------- 全景：三层山脊，每列一个高度 ----------
local far, mid, near = {}, {}, {}
local function ridge(arr, seed, spacing, lo, hi, jag)
  local r = Rng(seed)
  local n = div(PW, spacing)
  local pts = {}
  for i = 0, n - 1 do pts[i] = lo + r(hi - lo + 1) end
  for x = 0, PW - 1 do
    local i = div(x, spacing)
    local a, b = pts[i], pts[mod(i + 1, n)]
    arr[x] = lerp(a, b, x - i * spacing, spacing) - (jag > 0 and r(jag) or 0)
  end
end
ridge(far, 11, 44, 36, 66, 0)
ridge(mid, 22, 22, 64, 84, 3)
ridge(near, 33, 11, 96, 112, 6)
local stars = {}
do local r = Rng(5); for i = 1, 70 do stars[i] = { r(PW), r(60) } end end

local C = {
  far = { 150, 165, 185 }, mid = { 70, 100, 80 }, near = { 25, 48, 34 },
  smoke = { 200, 200, 205 }, deer = { 120, 80, 45 }, bird = { 20, 20, 25 }, burnt = { 35, 25, 20 },
}

-- ---------- 状态 ----------
local t_open = now()
local today = civil(t_open).day
local bearing = 0
local log = {}               -- { {t, b, code}, ... }
local scars = {}             -- { {b, t}, ... }
local first_day, resolved_day, smoke_logged = today, today - 1, -1
local smoke_logged_min = 0   -- 记下烟的那一分钟；之后 30 分钟烟就散了
local clicks_day, clicks, busy_noted = today, 0, false

local function load()
  local s, found = load_kv(SAVE)
  if not found then return end
  bearing = num(s.bearing, 0)
  first_day = num(s.first_day, today)
  resolved_day = num(s.resolved_day, today - 1)
  smoke_logged = num(s.smoke_logged, -1)
  smoke_logged_min = num(s.smoke_logged_min, 0)
  if num(s.clicks_day, -1) == today then clicks = num(s.clicks, 0); busy_noted = s.busy == "1" end
  for t, b, c in string.gmatch(s.log or "", "(%d+),(%d+),(%a)") do log[#log + 1] = { tonumber(t), tonumber(b), c } end
  for b, t in string.gmatch(s.scars or "", "(%d+),(%d+)") do scars[#scars + 1] = { tonumber(b), tonumber(t) } end
end
local function save()
  local lp, sp = {}, {}
  for i, e in ipairs(log) do lp[i] = e[1] .. "," .. e[2] .. "," .. e[3] end
  for i, s in ipairs(scars) do sp[i] = s[1] .. "," .. s[2] end
  save_kv(SAVE, { bearing = bearing, first_day = first_day, resolved_day = resolved_day,
    smoke_logged = smoke_logged, smoke_logged_min = smoke_logged_min, clicks_day = clicks_day, clicks = clicks, busy = busy_noted and "1" or "0",
    log = table.concat(lp, ";"), scars = table.concat(sp, ";") })
end

-- ---------- 每天的事件（同一天算出来总是一样的） ----------
local function smoke_of(day)
  local r = Rng(hash(day, 7))
  if r(100) >= 25 then return nil end -- 大约四天一次
  local start = 600 + r(420)
  return { start = start, stop = start + 180 + r(240), b = r(360) }
end
local function passers_of(day, L) -- 鹿和鸟群
  local r = Rng(hash(day, 8))
  local list = {}
  for i = 1, 2 + r(3) do
    list[i] = { kind = r(2) == 0 and "deer" or "birds", start = L.sr + r(L.ss - L.sr), b = r(360),
                dir = r(2) == 0 and -1 or 1 }
  end
  return list
end

-- 补算：没被发现的烟自己熄掉，或者留下一块焦黑的山坡
local function resolve_smoke(t)
  local c = civil(t)
  while resolved_day < c.day do
    local d = resolved_day + 1
    local ev = smoke_of(d)
    if ev then
      local stop_t = d * 86400 + ev.stop * 60
      if stop_t > t then break end
      if smoke_logged ~= d and mod(hash(d, 99), 2) == 0 then scars[#scars + 1] = { ev.b, stop_t } end
    elseif d == c.day then break end
    resolved_day = d
  end
  for i = #scars, 1, -1 do
    if t - scars[i][2] > SCAR_DAYS * 86400 then table.remove(scars, i) end
  end
end

-- 角度差（-180..179）
local function adiff(a, b) return mod(a - b + 180, 360) - 180 end
local function col_of(b) return div(mod(b, 360) * PW, 360) end

-- 这一刻全景里有哪些东西：返回 { {kind, b, ...} }
local function things(t, L, wx)
  local out = {}
  local m = L.min
  local ev = smoke_of(L.day)
  if ev and m >= ev.start and m < ev.stop then
    local over = smoke_logged == L.day and m >= smoke_logged_min + 30
    if not over then out[#out + 1] = { kind = "smoke", b = ev.b, age = m - ev.start } end
  end
  for _, p in ipairs(passers_of(L.day, L)) do
    local secs = (m - p.start) * 60 + mod(t, 60)
    if secs >= 0 and secs < 180 then
      out[#out + 1] = { kind = p.kind, b = p.b + p.dir * div(secs * 25, 180), secs = secs }
    end
  end
  if wx.rainy and m >= wx.storm_start and m < wx.storm_start + 240 then
    out[#out + 1] = { kind = "rain", b = wx.storm_bearing + wx.storm_dir * div((m - wx.storm_start) * 15, 60) }
  end
  if L.night and mod(div(t, 600) * 7, 5) == 0 and mod(t, 600) < 3 then
    out[#out + 1] = { kind = "light", b = 217 } -- 远处另一座塔
  end
  return out
end

-- ---------- 画面 ----------
-- 画面分两块画：Rockbox 的 Lua 每个函数最多 30 个 upvalue
local function draw_land(t, L, wx, left)
  for y = 0, H - 1, 4 do fg(pack(mix(L.top, L.bot, y, 100))); rect(0, y, W, 4) end
  if L.night then
    fg(rgb(205, 210, 225))
    for _, s in ipairs(stars) do
      local x = mod(s[1] - left, PW)
      if x < W and s[2] < far[mod(s[1], PW)] then rect(x, s[2], 1, 1) end
    end
  end
  -- 焦黑程度：每列查一下附近有没有疤
  local burn = {}
  for _, s in ipairs(scars) do
    local age = div(t - s[2], 86400)
    local k = age < 7 and 256 or clamp(256 - div((age - 7) * 256, SCAR_DAYS - 7), 0, 256)
    local c0 = col_of(s[1])
    for dx = -14, 14 do
      local x = mod(c0 + dx - left, PW)
      if x < W then burn[x] = math.max(burn[x] or 0, div(k * (15 - iabs(dx)), 15)) end
    end
  end
  local fc, mc, nc = pack(mix(tint(C.far, L.land), L.bot, 1, 2)), tint(C.mid, L.land), pack(tint(C.near, L.land))
  local mcp = pack(mc)
  for x = 0, W - 1 do
    local px = mod(left + x, PW)
    fg(fc); rect(x, far[px], 1, H - far[px])
    if burn[x] then fg(pack(mix(mc, tint(C.burnt, L.land), burn[x], 256))) else fg(mcp) end
    rect(x, mid[px], 1, H - mid[px])
    fg(nc); rect(x, near[px], 1, H - near[px])
  end
  -- 晨雾：山谷里一层淡淡的横线
  if wx.fog > 20 and L.min > L.sr - 60 and L.min < L.sr + 150 then
    fg(pack(tint({ 225, 228, 235 }, L.land)))
    local thick = clamp(div(wx.fog, 25), 1, 4)
    for k = 0, thick - 1 do rect(0, 90 + k * 3, W, 1) end
  end
end

local function draw_things(t, L, list, left)
  for _, e in ipairs(list) do
    local x = mod(col_of(e.b) - left, PW)
    if e.kind == "smoke" and x < W then
      local px = mod(left + x, PW)
      local base = mid[px]
      local tall = clamp(div(e.age, 2) + 12, 12, 56)
      fg(pack(mix(tint(C.smoke, L.land), C.smoke, 1, 2)))
      for k = 0, tall - 1, 2 do
        local wob = iabs(mod(div(t, 2) + div(k, 2), 6) - 3) + div(k, 5) -- 风把烟往一边带
        rect(x + wob - 1, base - k, 2 + div(k, 10), 2)
      end
    elseif e.kind == "deer" and x < W - 3 then
      local px = mod(left + x, PW)
      fg(pack(tint(C.deer, L.land))); rect(x, mid[px] - 3, 3, 2); rect(x + 2, mid[px] - 4, 1, 1)
      rect(x, mid[px] - 1, 1, 1); rect(x + 2, mid[px] - 1, 1, 1)
    elseif e.kind == "birds" then
      fg(pack(C.bird))
      local r = Rng(e.secs) -- 群里每只的位置略有抖动
      for k = 0, 6 do
        local bx = x + mod(k * 5, 13) - 6 + r(3)
        local by = 40 + mod(k * 7, 9) + div(iabs(mod(e.secs + k * 3, 20) - 10), 4)
        if bx >= 0 and bx < W then rect(bx, by, 1, 1) end
      end
    elseif e.kind == "rain" then
      local x0 = mod(col_of(e.b - 25) - left, PW)
      local wcol = col_of(50)
      fg(pack(mix(L.bot, { 90, 95, 105 }, 1, 2)))
      for k = 0, wcol - 1, 3 do
        local xx = mod(x0 + k, PW)
        if xx < W then rect(xx, mod(t * 5 + k, 7), 1, H) end
      end
    elseif e.kind == "light" and x < W then
      fg(rgb(255, 230, 150)); rect(x, far[mod(left + x, PW)] - 2, 1, 1)
    end
  end
end

local function draw(t, L, wx, list)
  local left = col_of(bearing) - div(W, 2)
  draw_land(t, L, wx, left)
  draw_things(t, L, list, left)
  text(div(W, 2) - 9, 2, string.format("%03d", bearing), pack(mix(L.top, { 255, 255, 255 }, 2, 3)), pack(L.top))
  rb.lcd_update()
end

local NAMES = { s = "smoke", d = "deer", b = "birds", r = "rain", l = "a light", n = "nothing", x = "looked a lot. nothing." }

local function draw_log(top)
  -- 日志：最新的在上面；没有记录的日子写 nothing
  local lines = {}
  local by_day = {}
  for _, e in ipairs(log) do
    local d = div(e[1], 86400)
    by_day[d] = by_day[d] or {}
    table.insert(by_day[d], e)
  end
  for d = today, first_day, -1 do
    local es = by_day[d]
    if es then
      for i = #es, 1, -1 do
        local e = es[i]
        local c = civil(e[1])
        lines[#lines + 1] = string.format("%02d-%02d %02d:%02d %03d %s", c.m, c.d, c.hh, c.mm, e[2], NAMES[e[3]] or "?")
      end
    else
      local c = civil(d * 86400)
      lines[#lines + 1] = string.format("%02d-%02d       nothing", c.m, c.d)
    end
  end
  fg(rgb(235, 228, 210)); rect(0, 0, W, H)
  local ink = rgb(60, 50, 40)
  for i = 0, 13 do
    local s = lines[top + i]
    if s then text(3, 3 + i * 9, s, ink, rgb(235, 228, 210)) end
  end
  rb.lcd_update()
  return #lines
end

-- ---------- 主循环 ----------
load()
light_start()
resolve_smoke(now())

local mode, log_top, log_len = "look", 1, 0
local running, last_draw = true, -1
while running do
  local t = now()
  local L = light_at(t)
  local wx = weather_of(L.day)
  if L.day ~= today then today = L.day end
  if clicks_day ~= today then clicks_day, clicks, busy_noted = today, 0, false end
  local list = things(t, L, wx)

  for _, e in ipairs(poll()) do
    local g = select_gesture(e)
    if e.k == "menu" and not e.rel then
      if mode == "log" then mode = "look" else running = false end
      last_draw = -1
    elseif mode == "log" then
      if e.k == "fwd" and not e.rel then log_top = clamp(log_top + 1, 1, math.max(1, log_len - 13))
      elseif e.k == "back" and not e.rel then log_top = clamp(log_top - 1, 1, math.max(1, log_len))
      elseif g == "short" or g == "long" then mode = "look" end
      last_draw = -1
    elseif e.k == "fwd" and not e.rel then bearing = mod(bearing + DEG_PER_CLICK, 360); clicks = clicks + 1; last_draw = -1
    elseif e.k == "back" and not e.rel then bearing = mod(bearing - DEG_PER_CLICK, 360); clicks = clicks + 1; last_draw = -1
    elseif g == "short" then
      -- 记下当前视野里能看到的东西
      local code = "n"
      for _, th in ipairs(list) do
        if iabs(adiff(th.b, bearing)) <= div(VIEW_DEG, 2) then
          code = ({ smoke = "s", deer = "d", birds = "b", rain = "r", light = "l" })[th.kind]
          if code == "s" then smoke_logged, smoke_logged_min = L.day, L.min end
          break
        end
      end
      log[#log + 1] = { t, bearing, code }
      if #log > 400 then table.remove(log, 1) end
      fg(rgb(255, 255, 255)); rect(0, 0, W, 2); rb.lcd_update() -- 一闪，表示记下了
      save()
    elseif g == "long" then
      mode, log_top = "log", 1
      last_draw = -1
    end
  end

  -- 转身转得太勤快
  if not busy_noted and clicks > BUSY_CLICKS then
    local any = false
    for _, e in ipairs(log) do if div(e[1], 86400) == today and e[3] ~= "n" then any = true end end
    if not any then log[#log + 1] = { t, bearing, "x" } end
    busy_noted = true
  end

  if mod(t, 60) == 0 then resolve_smoke(t) end
  local stamp = div(rb.current_tick(), div(HZ, 5)) -- 每秒最多 5 帧
  if mode == "log" then
    if last_draw < 0 then log_len = draw_log(log_top); last_draw = stamp end
  elseif stamp ~= last_draw then
    draw(t, L, wx, list)
    last_draw = stamp
  end
  keep_light()
  rb.sleep(div(HZ, 20))
end

save()
light_end()
