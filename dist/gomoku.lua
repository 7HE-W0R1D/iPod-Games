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

-- 五子棋：15×15，黑先，连成五子赢
-- 开局界面：转盘选 人对人 / 执黑 / 执白 / 电脑对电脑，Select 开始
-- 跳点（默认）：转盘在已有棋子附近的空位之间跳，从最后一手由近到远；Select 落子
-- Play：切换到自由光标（转盘在一行里左右走，上一首 / 下一首换行）
-- 长按上一首：悔一步（人对电脑）   观战时 Play：每步至少隔 5 / 10 / 20 秒
-- 长按 Select：回开局界面   短按 Menu 退出，长按 Menu 看说明（在说明页按 Play 切换黑方禁手）

local SAVE = "slow_gomoku.txt"
local N = 15

-- ================= 规则和电脑 =================
-- 棋盘 B[r*15+c]：0 空，1 黑，2 白
local A = { B = {} }
do
local B = A.B
for i = 0, N * N - 1 do B[i] = 0 end
local DR, DC = { 0, 1, 1, 1 }, { 1, 0, 1, -1 }
local buf = {}

-- 以 p 为中心、方向 d 上的 11 格：中心当作 who 的子 → "1"，who 的子 "1"，空 "0"，对方或出界 "2"
-- 第二个返回值：中心两边 4 格内 who 自己的子数
local function line(p, d, who)
  local r0, c0 = div(p, N), mod(p, N)
  local dr, dc, own = DR[d], DC[d], 0
  for k = -5, 5 do
    local r, c = r0 + k * dr, c0 + k * dc
    local ch
    if k == 0 then ch = "1"
    elseif r < 0 or r >= N or c < 0 or c >= N then ch = "2"
    else
      local v = B[r * N + c]
      if v == 0 then ch = "0" elseif v == who then
        ch = "1"
        if k >= -4 and k <= 4 then own = own + 1 end
      else ch = "2" end
    end
    buf[k + 6] = ch
  end
  return table.concat(buf), own
end
-- 这个棋形有没有一处盖住中心（第 6 格）
local function covers(s, pat)
  local i = 1
  while true do
    i = string.find(s, pat, i, true)
    if not i then return false end
    if i <= 6 and i + #pat - 1 >= 6 then return true end
    i = i + 1
  end
end
-- 棋形表：{棋形, 分, 子数}，从大到小
local PATS = {
  { "11111", 100000 }, { "011110", 12000 },
  { "11110", 1500 }, { "01111", 1500 }, { "11011", 1500 }, { "10111", 1500 }, { "11101", 1500 },
  { "011100", 900 }, { "001110", 900 }, { "011010", 900 }, { "010110", 900 },
  { "11100", 150 }, { "00111", 150 }, { "11010", 150 }, { "01011", 150 }, { "10110", 150 },
  { "01101", 150 }, { "10011", 150 }, { "11001", 150 }, { "10101", 150 }, { "01110", 150 },
  { "001100", 110 }, { "011000", 90 }, { "000110", 90 }, { "001010", 90 }, { "010100", 90 }, { "010010", 70 },
  { "11000", 20 }, { "00011", 20 }, { "01100", 20 }, { "00110", 20 }, { "01010", 20 }, { "10100", 20 }, { "00101", 20 },
}
for _, pt in ipairs(PATS) do
  local n = 0
  for k = 1, #pt[1] do if string.sub(pt[1], k, k) == "1" then n = n + 1 end end
  pt[3] = n
end
local function pat_score(s, own)
  for _, pt in ipairs(PATS) do
    if pt[3] <= own + 1 and covers(s, pt[1]) then return pt[2] end
  end
  return 1
end

-- 在 p（空位）下 who 的子值多少分：四个方向的棋形加起来，双三、四三再加
local function eval(p, who)
  local sum, n4, n3 = 0, 0, 0
  for d = 1, 4 do
    local s, own = line(p, d, who)
    local v = (own == 0) and 1 or pat_score(s, own)
    sum = sum + v
    if v >= 1500 and v < 100000 then n4 = n4 + 1 elseif v == 900 then n3 = n3 + 1 end
  end
  if n4 >= 2 or (n4 >= 1 and n3 >= 1) then sum = sum + 20000
  elseif n3 >= 2 then sum = sum + 6000 end
  return sum
end
A.eval = eval

-- 黑方禁手（规则打开时）：长连、双四、双三。只看一层，不追究“假禁手”
A.forbidden = function(p)
  B[p] = 1
  local five, over, fours, threes = false, false, 0, 0
  for d = 1, 4 do
    local s = line(p, d, 1)
    if covers(s, "11111") then
      if covers(s, "111111") then over = true else five = true end
    else
      local f, t = false, false
      for k = 2, 10 do
        if k ~= 6 and string.sub(s, k, k) == "0" then
          local s2 = string.sub(s, 1, k - 1) .. "1" .. string.sub(s, k + 1)
          if covers(s2, "11111") and not covers(s2, "111111") then f = true
          elseif covers(s2, "011110") then t = true end
        end
      end
      if f then fours = fours + 1 elseif t then threes = threes + 1 end
    end
  end
  B[p] = 0
  if five then return false end
  return over or fours >= 2 or threes >= 2
end

-- p 刚落了子：连成五子（exact：黑方有禁手时要正好五子）就返回那条线上的格子
A.win_line = function(p, exact)
  local who = B[p]
  local r0, c0 = div(p, N), mod(p, N)
  for d = 1, 4 do
    local cells = { p }
    for _, sgn in ipairs({ 1, -1 }) do
      local r, c = r0 + sgn * DR[d], c0 + sgn * DC[d]
      while r >= 0 and r < N and c >= 0 and c < N and B[r * N + c] == who do
        cells[#cells + 1] = r * N + c
        r, c = r + sgn * DR[d], c + sgn * DC[d]
      end
    end
    if #cells == 5 or (#cells > 5 and not exact) then return cells end
  end
  return nil
end

-- 候选点：已有棋子周围两格内的空位；空棋盘只有天元
A.cands = function(moves)
  local seen, list = {}, {}
  for _, m in ipairs(moves) do
    local r0, c0 = div(m, N), mod(m, N)
    for r = math.max(0, r0 - 2), math.min(N - 1, r0 + 2) do
      for c = math.max(0, c0 - 2), math.min(N - 1, c0 + 2) do
        local q = r * N + c
        if B[q] == 0 and not seen[q] then seen[q] = true; list[#list + 1] = q end
      end
    end
  end
  if #moves == 0 then list[1] = 7 * N + 7 end
  return list
end

-- 电脑想一步：先按棋形给每个候选点打分（进攻 + 防守），
-- 再把前几名各试下一下，看对方接下来最好能得多少分，减掉。
-- hook(p)：每试一个点调用一次，界面拿来在棋盘上淡淡地显示它
A.choose = function(moves, who, rule, r, jitter, hook)
  local opp = 3 - who
  local list = A.cands(moves)
  if #moves == 0 then return list[1] end
  local scored = {}
  for _, p in ipairs(list) do
    if not (rule and who == 1 and A.forbidden(p)) then
      local a = eval(p, who)
      if a >= 100000 then return p end -- 能赢就赢
      scored[#scored + 1] = { p, a + div(eval(p, opp) * 85, 100) }
    end
  end
  if #scored == 0 then return list[1] end
  table.sort(scored, function(x, y) return x[2] > y[2] end)
  local best, bv = scored[1][1], -99999999
  for k = 1, math.min(6, #scored) do
    local p, v = scored[k][1], scored[k][2]
    if hook and hook(p) then return nil end
    B[p] = who
    moves[#moves + 1] = p
    local oa = 0
    for _, q in ipairs(A.cands(moves)) do
      local s = eval(q, opp)
      if s > oa then oa = s end
    end
    moves[#moves] = nil
    B[p] = 0
    v = v - div(oa * 6, 10) + r(jitter + 1)
    if v > bv then best, bv = p, v end
  end
  return best
end
end

-- ================= 界面 =================
local main = function()
local B = A.B
local C = {
  wood = rgb(214, 170, 100), grid = rgb(128, 88, 44), black = rgb(26, 26, 30), shine = rgb(110, 110, 118),
  white = rgb(242, 238, 226), wedge = rgb(150, 138, 116), mark = rgb(222, 56, 40), cursor = rgb(28, 86, 220),
  strip = rgb(58, 62, 70), ink = rgb(236, 236, 230), dim = rgb(170, 172, 178), hi = rgb(240, 150, 60),
  bg = rgb(24, 26, 30),
}
C.ghost = { pack(mix({ 214, 170, 100 }, { 26, 26, 30 }, 40, 100)), pack(mix({ 214, 170, 100 }, { 242, 238, 226 }, 55, 100)) }
local BX, BY, SX = 4, 6, 128
local KINDS = { "2 players", "you black", "you white", "cpu vs cpu" }
local PACES = { 5, 10, 20 }
local THINK_T = div(HZ * 3, 2)
local STAR = { [3 * N + 3] = true, [3 * N + 11] = true, [11 * N + 3] = true, [11 * N + 11] = true, [7 * N + 7] = true }
-- 7×7 的圆：每行 {缩进, 宽}
local DISC = { { 2, 3 }, { 1, 5 }, { 0, 7 }, { 0, 7 }, { 0, 7 }, { 1, 5 }, { 2, 3 } }

local G = {
  scr = "menu", kind = 2, sel = 2, moves = {}, cands = {}, ci = 1, free = false, fr = 7, fc = 7,
  rule = false, pace = 2, games = { 0, 0, 0, 0 }, bw = { 0, 0, 0, 0 }, ww = { 0, 0, 0, 0 },
  result = nil, winline = nil, flash_until = 0, ghost = -1, wait_until = 0, over_at = 0,
  shown = {}, full = true, quit = false, note = nil, note_until = 0, rng = Rng(now()),
}

local function turn() return (mod(#G.moves, 2) == 0) and 1 or 2 end
local function human(who)
  return G.kind == 1 or (G.kind == 2 and who == 1) or (G.kind == 3 and who == 2)
end

-- ---------- 存档 ----------
local function save()
  local s = { moves = table.concat(G.moves, ","), kind = G.kind, rule = G.rule and 1 or 0, pace = G.pace,
              scr = G.scr, result = G.result or "" }
  for k = 1, 4 do s["g" .. k] = G.games[k] .. "," .. G.bw[k] .. "," .. G.ww[k] end
  save_kv(SAVE, s)
end

-- 候选点按“好用”排序：要紧的点（堵对方、接自己）先按分数，其余从最后一手由近到远
local function refresh()
  local who = turn()
  local last = G.moves[#G.moves]
  local lr, lc = 7, 7
  if last then lr, lc = div(last, N), mod(last, N) end
  local list = {}
  for _, p in ipairs(A.cands(G.moves)) do
    if not (G.rule and who == 1 and A.forbidden(p)) then
      local v = A.eval(p, who) + A.eval(p, 3 - who)
      local dr, dc = iabs(div(p, N) - lr), iabs(mod(p, N) - lc)
      list[#list + 1] = { p = p, v = v, urgent = v >= 900, d = math.max(dr, dc) * 100 + dr + dc }
    end
  end
  table.sort(list, function(a, b)
    if a.urgent ~= b.urgent then return a.urgent end
    if a.urgent and a.v ~= b.v then return a.v > b.v end
    if a.d ~= b.d then return a.d < b.d end
    if a.v ~= b.v then return a.v > b.v end
    return a.p < b.p
  end)
  G.cands, G.ci = {}, 1
  for i, it in ipairs(list) do G.cands[i] = it.p end
end

local function rebuild(moves)
  for i = 0, N * N - 1 do B[i] = 0 end
  for i, p in ipairs(moves) do B[p] = (mod(i, 2) == 1) and 1 or 2 end
  G.moves, G.result, G.winline = moves, nil, nil
end

local function load()
  local s, found = load_kv(SAVE)
  G.kind = clamp(num(s.kind, 2), 1, 4)
  G.sel, G.rule, G.pace = G.kind, s.rule == "1", clamp(num(s.pace, 2), 1, #PACES)
  for k = 1, 4 do
    local a, b, c = string.match(s["g" .. k] or "", "(%d+),(%d+),(%d+)")
    G.games[k], G.bw[k], G.ww[k] = num(a, 0), num(b, 0), num(c, 0)
  end
  if s.scr == "play" or s.scr == "over" then
    local mv, used = {}, {}
    for v in string.gmatch(s.moves or "", "%d+") do
      local p = num(v, -1)
      if p >= 0 and p < N * N and not used[p] then used[p] = true; mv[#mv + 1] = p end
    end
    rebuild(mv)
    G.scr = s.scr
    if s.result and s.result ~= "" then G.result = s.result end
    local last = mv[#mv]
    if last and G.scr == "over" then G.winline = A.win_line(last, G.rule) end
    G.over_at = rb.current_tick()
    refresh()
  end
  return found
end

-- ---------- 画面 ----------
local function cursor_at()
  if G.scr ~= "play" or not human(turn()) then return -1 end
  if G.free then return G.fr * N + G.fc end
  return G.cands[G.ci] or -1
end
local function disc(x, y, col)
  fg(col)
  for k = 1, 7 do rect(x + DISC[k][1], y + k - 1, DISC[k][2], 1) end
end
local function draw_cell(p, stone, mark, cur, ghost)
  local r, c = div(p, N), mod(p, N)
  local x, y = BX + c * 8, BY + r * 8
  fg(C.wood); rect(x, y, 8, 8)
  fg(C.grid)
  local x0, x1 = (c == 0) and 3 or 0, (c == N - 1) and 3 or 7
  local y0, y1 = (r == 0) and 3 or 0, (r == N - 1) and 3 or 7
  rect(x + x0, y + 3, x1 - x0 + 1, 1)
  rect(x + 3, y + y0, 1, y1 - y0 + 1)
  if STAR[p] then rect(x + 2, y + 2, 3, 3) end
  if stone == 1 then
    disc(x, y, C.black)
    fg(C.shine); rect(x + 2, y + 2, 1, 1)
  elseif stone == 2 then
    disc(x, y, C.wedge)
    fg(C.white)
    rect(x + 2, y + 1, 3, 1); rect(x + 1, y + 2, 5, 3); rect(x + 2, y + 5, 3, 1)
  elseif ghost > 0 then
    disc(x, y, C.ghost[ghost])
  end
  if mark then fg(C.mark); rect(x + 2, y + 2, 3, 3) end
  if cur then
    fg(C.cursor)
    rect(x, y, 3, 1); rect(x, y, 1, 3); rect(x + 5, y, 3, 1); rect(x + 7, y, 1, 3)
    rect(x, y + 7, 3, 1); rect(x, y + 5, 1, 3); rect(x + 5, y + 7, 3, 1); rect(x + 7, y + 5, 1, 3)
  end
end

local function strip_lines()
  local who = turn()
  local t = {}
  if G.scr == "over" then
    t[1] = (G.result == "draw") and "draw" or ((G.result == "b") and "black" or "white")
    t[2] = (G.result == "draw") and "" or "wins"
    t[3] = "sel:new"
  else
    t[1] = (who == 1) and "black" or "white"
    t[2] = human(who) and "" or "thinks"
    t[3] = ""
  end
  t[4] = "#" .. #G.moves
  if G.kind == 4 then t[5], t[6] = "auto", PACES[G.pace] .. "s"
  else t[5] = ({ "2P", "you B", "you W" })[G.kind]; t[6] = G.free and "free" or "jump" end
  t[7] = G.rule and "limits" or ""
  t[8] = G.note or ""
  return t, who
end
local function draw_strip()
  local t, who = strip_lines()
  local key = table.concat(t, "|") .. who
  if G.shown.strip == key then return end
  G.shown.strip = key
  fg(C.strip); rect(SX, 0, W - SX, H)
  if G.scr ~= "over" then
    if who == 1 then disc(SX + 4, 6, C.black) else disc(SX + 4, 6, C.wedge); fg(C.white); rect(SX + 5, 7, 5, 5) end
    text(SX + 14, 6, t[1], C.ink, C.strip)
  else text(SX + 3, 6, t[1], C.hi, C.strip) end
  text(SX + 3, 18, t[2], (G.scr == "over") and C.hi or C.dim, C.strip)
  text(SX + 3, 30, t[3] or "", C.ink, C.strip)
  text(SX + 3, 50, t[4], C.dim, C.strip)
  text(SX + 3, 70, t[5], C.ink, C.strip)
  text(SX + 3, 80, t[6], C.dim, C.strip)
  text(SX + 3, 100, t[7], C.dim, C.strip)
  text(SX + 3, 116, t[8], C.hi, C.strip)
end

local function render()
  if G.full then
    fg(C.wood); rect(0, 0, SX, H)
    G.shown, G.full = {}, false
  end
  local cur, last = cursor_at(), G.moves[#G.moves]
  local hide = {}
  -- 连成五子：那条线闪几下
  if G.winline and rb.current_tick() < G.flash_until and mod(div(rb.current_tick() * 10, HZ * 3), 2) == 1 then
    for _, p in ipairs(G.winline) do hide[p] = true end
  end
  local gw = (G.ghost >= 0) and turn() or 0
  for p = 0, N * N - 1 do
    local st = hide[p] and 0 or B[p]
    local gh = (p == G.ghost and st == 0) and gw or 0
    local key = st * 1000 + gh * 100 + ((p == last) and 10 or 0) + ((p == cur) and 1 or 0)
    if G.shown[p] ~= key then
      G.shown[p] = key
      draw_cell(p, st, p == last and st > 0, p == cur, gh)
    end
  end
  draw_strip()
  rb.lcd_update()
end

local function draw_menu()
  fg(C.bg); rect(0, 0, W, H)
  text(4, 3, "GOMOKU", C.hi, C.bg)
  for k = 1, 4 do
    local y = 18 + (k - 1) * 24
    if k == G.sel then fg(C.hi); rect(2, y - 1, 3, 19) end
    text(10, y, KINDS[k], (k == G.sel) and C.hi or C.ink, C.bg)
    text(10, y + 10, G.games[k] .. " games  B " .. G.bw[k] .. "  W " .. G.ww[k], C.dim, C.bg)
  end
  text(10, 118, G.rule and "rule: black limits" or "rule: free", C.dim, C.bg)
  rb.lcd_update()
  G.full = true
end

-- ---------- 走棋 ----------
local function new_game(kind)
  G.kind, G.scr, G.free, G.ghost, G.wait_until = kind, "play", false, -1, 0
  rebuild({})
  refresh()
  G.full = true
  save()
end
local function finish(result)
  G.result, G.scr, G.over_at = result, "over", rb.current_tick()
  local k = G.kind
  G.games[k] = G.games[k] + 1
  if result == "b" then G.bw[k] = G.bw[k] + 1 elseif result == "w" then G.ww[k] = G.ww[k] + 1 end
  save()
end
local function place(p)
  local who = turn()
  B[p] = who
  G.moves[#G.moves + 1] = p
  local wl = A.win_line(p, G.rule and who == 1)
  if wl then
    G.winline, G.flash_until = wl, rb.current_tick() + 3 * HZ
    finish((who == 1) and "b" or "w")
  elseif #G.moves >= N * N then finish("draw")
  else refresh(); save() end
end
local function say(s) G.note, G.note_until = s, rb.current_tick() + 2 * HZ end

local function think()
  local started, who = rb.current_tick(), turn()
  local hook = function(p)
    G.ghost = p
    render()
    for _, e in ipairs(poll()) do
      if e.k == "menu" then G.quit = true elseif e.k == "help" then G.help_req = true end
    end
    keep_light()
    rb.sleep(div(HZ, 8))
    return G.quit
  end
  local jitter = (G.kind == 4) and 60 or 3
  local p = A.choose(G.moves, who, G.rule, G.rng, jitter, hook)
  if not p or G.quit then G.ghost = -1; return end
  -- 每步有固定的思考时间：想完了也在选中的点上停一会儿
  G.ghost = p
  while not G.quit and rb.current_tick() < started + THINK_T do
    render()
    for _, e in ipairs(poll()) do if e.k == "menu" then G.quit = true end end
    rb.sleep(div(HZ, 10))
  end
  G.ghost = -1
  if G.quit then return end
  if G.kind == 4 then G.wait_until = started + PACES[G.pace] * HZ end
  place(p)
end

local function help()
  local k = help_screen("GOMOKU", {
    "Five in a row wins.",
    "Black plays first.",
    "",
    "*Keys",
    "wheel  jump to spots near",
    "       the stones",
    "select place a stone",
    "play   jump / free cursor",
    "free:  wheel along the row,",
    "       prev / next: row",
    "hold prev    undo (vs cpu)",
    "hold select  back to modes",
    "menu   quit",
    "",
    "*Watching",
    "play   5 / 10 / 20 s a move",
    "select next game",
    "",
    G.rule and "*Black limits: ON" or "*Black limits: OFF",
    "no 3-3, 4-4 or 6+ for black",
    "PLAY here to switch",
  })
  if k == "play" then
    G.rule = not G.rule
    say(G.rule and "limits" or "free")
    if G.scr == "play" then refresh() end
    save()
  end
  G.full = true
  if G.scr == "menu" then draw_menu() end
end

local function undo()
  local me = (G.kind == 3) and 2 or 1
  local mv = G.moves
  while #mv > 0 do
    local n = #mv
    table.remove(mv)
    if ((mod(n, 2) == 1) and 1 or 2) == me then break end -- 退掉了自己的一手就停
  end
  rebuild(mv)
  G.scr = "play"
  refresh()
  save()
end

local function try_place(p)
  if p < 0 or B[p] ~= 0 then return end
  if G.rule and turn() == 1 and A.forbidden(p) then say("no!"); return end
  place(p)
end

local function on_key(e)
  local g = select_gesture(e)
  if e.k == "help" then help(); return end
  if e.k == "menu" then G.quit = true; return end
  local turn_ = (e.k == "fwd" or e.k == "back") and not e.rel
  if G.scr == "menu" then
    if turn_ then G.sel = mod(G.sel - 1 + ((e.k == "fwd") and 1 or -1), 4) + 1; draw_menu()
    elseif g == "short" then new_game(G.sel) end
    return
  end
  if g == "long" then G.sel, G.scr = G.kind, "menu"; save(); draw_menu(); return end
  -- 上一首：短按换行（自由光标），按住悔棋
  if e.k == "prev" then
    if not e.rel and not e.rep then G.prev_down, G.prev_fired = rb.current_tick(), false
    elseif e.rep and G.prev_down and not G.prev_fired and rb.current_tick() - G.prev_down >= div(HZ * 4, 5) then
      G.prev_fired = true
      if G.kind == 2 or G.kind == 3 then undo() end
    elseif e.rel then
      if G.prev_down and not G.prev_fired and G.free then G.fr = mod(G.fr - 1, N) end
      G.prev_down = nil
    end
    return
  end
  if G.scr == "over" then
    if g == "short" then
      if G.kind == 4 then new_game(4) else G.sel, G.scr = G.kind, "menu"; draw_menu() end
    end
    return
  end
  if e.k == "play" and not e.rel and not e.rep then
    if G.kind == 4 then G.pace = mod(G.pace, #PACES) + 1; save()
    else
      G.free = not G.free
      local p = G.cands[G.ci]
      if G.free and p then G.fr, G.fc = div(p, N), mod(p, N) end
    end
    return
  end
  if not human(turn()) then return end
  if turn_ then
    local d = (e.k == "fwd") and 1 or -1
    if G.free then G.fc = mod(G.fc + d, N)
    elseif #G.cands > 0 then G.ci = mod(G.ci - 1 + d, #G.cands) + 1 end
  elseif e.k == "next" and not e.rel and not e.rep and G.free then G.fr = mod(G.fr + 1, N)
  elseif g == "short" then
    if G.free then try_place(G.fr * N + G.fc) else try_place(G.cands[G.ci] or -1) end
  end
end

-- ---------- 主循环 ----------
local found = load()
light_start()
if not found then help() end
if G.scr == "menu" then draw_menu() else render() end

while not G.quit do
  for _, e in ipairs(poll()) do on_key(e) end
  if G.quit then break end
  if G.help_req then G.help_req = nil; help() end
  if G.note and rb.current_tick() > G.note_until then G.note = nil end
  if G.scr == "play" and not human(turn()) and rb.current_tick() >= G.wait_until then
    render()
    think()
  end
  -- 电脑对电脑：终局停一分钟，没人按 Select 就自己开下一局（可以放一整晚）
  if G.scr == "over" and G.kind == 4 and rb.current_tick() > G.over_at + 60 * HZ then new_game(4) end
  if G.scr ~= "menu" and not G.quit then render() end
  keep_light()
  rb.sleep(div(HZ, 20))
end

save()
light_end()
end
main()
