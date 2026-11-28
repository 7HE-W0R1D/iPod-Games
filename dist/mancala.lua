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

-- 播棋（卡拉哈规则）：拿起一坑种子，一颗一颗往下撒
-- 开局界面：转盘选 人对人 / 人对电脑 / 电脑对电脑，Select 开始
-- 转盘：在该走一方的非空坑之间跳   Select：撒种   上一首：悔一步（人对电脑）
-- 观战时 Play：每步至少隔 5 / 10 / 20 秒   长按 Select：回开局界面
-- 短按 Menu 退出，长按 Menu 看说明

local SAVE = "slow_mancala.txt"

-- 坑的编号：0..5 是下方（先手）从左到右，6 是右边的大仓；
-- 7..12 是上方从右到左，13 是左边的大仓。逆时针撒种就是编号加一。
-- 对面的坑：i ↔ 12 - i。side 1 是下方，2 是上方。

-- ================= 规则和电脑 =================
local E = {}
do
local function copy(b)
  local t = {}
  for i = 0, 13 do t[i] = b[i] end
  return t
end
local function store_of(side) return side == 1 and 6 or 13 end
local function low_of(side) return side == 1 and 0 or 7 end

-- 撒一坑（就地改 b）。返回 最后一颗落在哪、是否再走一次、吃了几颗
local function sow(b, side, pit)
  local n = b[pit]
  b[pit] = 0
  local skip = store_of(3 - side)
  local i = pit
  while n > 0 do
    i = i + 1
    if i > 13 then i = 0 end
    if i ~= skip then b[i] = b[i] + 1; n = n - 1 end
  end
  local st = store_of(side)
  if i == st then return i, true, 0 end
  local lo = low_of(side)
  if i >= lo and i <= lo + 5 and b[i] == 1 and b[12 - i] > 0 then
    local cap = b[12 - i] + 1
    b[st] = b[st] + cap
    b[i], b[12 - i] = 0, 0
    return i, false, cap
  end
  return i, false, 0
end

-- 任何一侧空了：剩下的种子归各自的仓。返回是否结束
local function finish(b)
  local a, c = 0, 0
  for i = 0, 5 do a = a + b[i] end
  for i = 7, 12 do c = c + b[i] end
  if a > 0 and c > 0 then return false end
  for i = 0, 5 do b[i] = 0 end
  for i = 7, 12 do b[i] = 0 end
  b[6], b[13] = b[6] + a, b[13] + c
  return true
end

-- 走一步，不改原棋盘。返回 新棋盘、下一个该谁、详情
E.apply = function(b, side, pit)
  local c = copy(b)
  local last, extra, cap = sow(c, side, pit)
  local over = finish(c)
  local nxt = side
  if not extra then nxt = 3 - side end
  return c, nxt, { last = last, extra = extra, cap = cap, over = over }
end
E.copy, E.store_of, E.low_of = copy, store_of, low_of
E.legal = function(b, side)
  local t, lo = {}, low_of(side)
  for i = lo, lo + 5 do if b[i] > 0 then t[#t + 1] = i end end
  return t
end
E.new = function()
  local b = {}
  for i = 0, 13 do b[i] = 4 end
  b[6], b[13] = 0, 0
  return b
end

-- 负极大值搜索：分数 = 自己仓里的种子 - 对方仓里的（终局再加一千）
local S = { nodes = 0, limit = 0, deadline = 0, hook = nil, abort = false }
local function search(b, side, depth, alpha, beta)
  S.nodes = S.nodes + 1
  if mod(S.nodes, 200) == 0 then
    if S.hook then S.hook() end
    if S.nodes > S.limit or rb.current_tick() > S.deadline then S.abort = true end
  end
  local my, op = store_of(side), store_of(3 - side)
  if depth <= 0 then return b[my] - b[op] end
  local lo, best = low_of(side), -99999
  for k = 5, 0, -1 do -- 离仓近的坑先试：更容易“再走一次”，剪枝更多
    local pit = lo + k
    if b[pit] > 0 then
      local c = copy(b)
      local _, extra = sow(c, side, pit)
      local v
      if finish(c) then
        v = c[my] - c[op]
        if v > 0 then v = v + 1000 elseif v < 0 then v = v - 1000 end
      elseif extra then v = search(c, side, depth - 1, alpha, beta)
      else v = -search(c, 3 - side, depth - 1, -beta, -alpha) end
      if v > best then best = v end
      if best > alpha then alpha = best end
      if alpha >= beta or S.abort then break end
    end
  end
  return best
end

-- 想一步。返回 选的坑、想过的坑（按想的顺序）
-- maxd：最深几层；r：随机数（打平时随机挑一个，电脑对电脑每局才不一样）
E.think = function(b, side, maxd, secs, r, hook)
  S.nodes, S.limit, S.abort, S.hook = 0, 40000, false, hook
  S.deadline = rb.current_tick() + secs * HZ
  local moves = E.legal(b, side)
  local best = moves[1]
  local seen = {}
  for d = 1, maxd do
    local bs, ties = -999999, {}
    for _, pit in ipairs(moves) do
      seen[#seen + 1] = pit
      local c, nxt, info = E.apply(b, side, pit)
      local v
      if info.over then
        local my, op = store_of(side), store_of(3 - side)
        v = c[my] - c[op]
        if v > 0 then v = v + 1000 elseif v < 0 then v = v - 1000 end
      elseif nxt == side then v = search(c, side, d - 1, -999999, 999999)
      else v = -search(c, nxt, d - 1, -999999, 999999) end
      if S.abort then break end
      if v > bs then bs, ties = v, { pit } elseif v == bs then ties[#ties + 1] = pit end
    end
    if S.abort then break end
    best = ties[r(#ties) + 1]
    if bs > 900 or bs < -900 then break end -- 胜负已定
  end
  return best, seen
end
end

-- ================= 界面 =================
local main = function()
local C = {
  bg = rgb(34, 30, 28), wood = rgb(168, 112, 62), edge = rgb(120, 78, 42),
  pit = rgb(66, 40, 22), lit = rgb(118, 78, 46), seed = rgb(226, 190, 110), seedhi = rgb(255, 240, 196),
  ring = rgb(240, 150, 60), ink = rgb(232, 226, 214), dim = rgb(150, 140, 128),
}
-- 版面：坑 20 像素圆，间距 22；两头的大仓 14 宽
local L = { px = 23, pitch = 22, rowt = 28, rowb = 70, by = 22, bh = 76, sy = 28, sh = 62, bar = 102 }
local KINDS = { "2 players", "vs cpu", "cpu vs cpu" }
local PACES = { 5, 10, 20 }
local SOW_T, THINK_T = div(HZ * 22, 100), div(HZ * 12, 10)

-- 圆的每一行：{左边缩进, 宽度}
local function spans(d)
  local t = {}
  for y = 0, d - 1 do
    local dy = 2 * y + 1 - d
    local w = 0
    while (2 * w + 2) * (2 * w + 2) + dy * dy <= d * d do w = w + 1 end
    t[y] = { div(d, 2) - w, 2 * w }
  end
  return t
end
local OUT, INN = spans(20), spans(16)
-- 坑里 12 颗种子的位置（相对坑中心），先中间后外圈
local SLOTS = { { -2, -2 }, { 2, 2 }, { 2, -2 }, { -2, 2 }, { -6, -2 }, { 6, 2 }, { -2, -6 }, { 2, 6 },
                { 6, -2 }, { -6, 2 }, { 2, -6 }, { -2, 6 } }

local G = {
  scr = "menu", kind = 2, sel = 2, b = E.new(), side = 1, phase = "pick", cur = 1,
  pace = 2, games = { 0, 0, 0 }, w1 = { 0, 0, 0 }, w2 = { 0, 0, 0 }, best_chain = 0,
  chain = 0, last_side = 0, hist = {}, shown = {}, full = true, quit = false,
  hi = -1, hi2 = -1, t = 0, wait_until = 0, rng = Rng(now()),
}

local function human(side) return G.kind == 1 or (G.kind == 2 and side == 1) end

-- ---------- 存档 ----------
local function save()
  local b, side, over = G.b, G.side, G.scr == "over"
  if G.post then b, side, over = G.post, G.post_side, G.post_over end -- 撒到一半退出：存撒完的样子
  local t = {}
  for i = 0, 13 do t[#t + 1] = b[i] end
  local s = { board = table.concat(t, ","), side = side, kind = G.kind, pace = G.pace,
              scr = (G.scr == "menu") and "menu" or (over and "over" or "play"), best = G.best_chain,
              chain = G.chain, last_side = G.last_side }
  for k = 1, 3 do s["g" .. k] = G.games[k] .. "," .. G.w1[k] .. "," .. G.w2[k] end
  save_kv(SAVE, s)
end
local function load()
  local s, found = load_kv(SAVE)
  G.kind = clamp(num(s.kind, 2), 1, 3)
  G.sel = G.kind
  G.pace = clamp(num(s.pace, 2), 1, #PACES)
  G.best_chain = num(s.best, 0)
  for k = 1, 3 do
    local a, b, c = string.match(s["g" .. k] or "", "(%d+),(%d+),(%d+)")
    G.games[k], G.w1[k], G.w2[k] = num(a, 0), num(b, 0), num(c, 0)
  end
  local b, n = {}, 0
  for v in string.gmatch(s.board or "", "%d+") do b[n] = num(v, 0); n = n + 1 end
  if n == 14 and (s.scr == "play" or s.scr == "over") then
    G.b, G.side, G.scr = b, clamp(num(s.side, 1), 1, 2), s.scr
    G.chain, G.last_side = num(s.chain, 0), num(s.last_side, 0)
  end
  return found
end

-- ---------- 画面 ----------
local function pit_xy(i) -- 坑的左上角
  if i <= 5 then return L.px + i * L.pitch, L.rowb end
  return L.px + (12 - i) * L.pitch, L.rowt
end
local function seed(x, y)
  fg(C.seed); rect(x, y, 2, 2)
  fg(C.seedhi); rect(x, y, 1, 1)
end
local function draw_pit(i, n, ring, lit)
  local x, y = pit_xy(i)
  fg(ring and C.ring or C.pit)
  for r = 0, 19 do rect(x + OUT[r][1], y + r, OUT[r][2], 1) end
  fg(lit and C.lit or C.pit)
  for r = 0, 15 do rect(x + 2 + INN[r][1], y + 2 + r, INN[r][2], 1) end
  for k = 1, math.min(n, 12) do
    local s = SLOTS[k]
    local j = mod(hash(i, k), 3) - 1 -- 每个坑的种子摆得稍微不一样
    seed(x + 9 + s[1] + j, y + 9 + s[2] - j)
  end
  -- 太多了：画一堆，数字写在坑旁边（两排之间的空地）
  local ny = (i <= 5) and (y - 10) or (y + 22)
  fg(C.wood); rect(x - 1, ny, 22, 8)
  if n > 12 then
    seed(x + 9, y + 9)
    local s = tostring(n)
    text(x + 10 - div(#s * 6, 2), ny, s, C.ink, C.wood)
  end
end
local function draw_store(i, n, lit)
  local x = (i == 6) and 157 or 5
  fg(C.edge); rect(x, L.sy, 14, L.sh)
  fg(lit and C.lit or C.pit); rect(x + 1, L.sy + 1, 12, L.sh - 2)
  for k = 0, n - 1 do -- 从下往上堆，一行 3 颗
    local yy = L.sy + L.sh - 5 - div(k, 3) * 3
    if yy > L.sy + 1 then seed(x + 2 + mod(k, 3) * 4, yy) end
  end
end
local function draw_board()
  fg(C.bg); rect(0, 0, W, H)
  fg(C.edge); rect(2, L.by, W - 4, L.bh)
  fg(C.wood); rect(3, L.by + 1, W - 6, L.bh - 2)
end

-- 当前该高亮什么
local function looks()
  local ring, lit = -1, {}
  if G.phase == "pick" and human(G.side) then
    local moves = E.legal(G.b, G.side)
    if #moves > 0 then ring = moves[clamp(G.cur, 1, #moves)] end
  end
  if G.hi >= 0 then lit[G.hi] = true end
  if G.hi2 >= 0 then lit[G.hi2] = true end
  return ring, lit
end
local function bar_text()
  local a, b = G.b[6], G.b[13]
  local left
  if G.scr == "over" then
    if a > b then left = (G.kind == 2) and "you win" or "bottom wins"
    elseif b > a then left = (G.kind == 2) and "cpu wins" or "top wins"
    else left = "draw" end
    left = left .. "  sel:new"
  elseif G.kind == 3 then left = "auto " .. PACES[G.pace] .. "s"
  elseif G.kind == 2 then left = (G.side == 1) and "your move" or "thinking"
  else left = (G.side == 1) and "bottom to move" or "top to move" end
  return left, b .. ":" .. a
end
local function render()
  if G.full then
    draw_board()
    G.shown, G.full = {}, false
  end
  local ring, lit = looks()
  for i = 0, 13 do
    local key = G.b[i] .. (i == ring and "r" or "") .. (lit[i] and "l" or "")
    if G.shown[i] ~= key then
      G.shown[i] = key
      if i == 6 or i == 13 then draw_store(i, G.b[i], lit[i]) else draw_pit(i, G.b[i], i == ring, lit[i]) end
    end
  end
  -- 该走的一侧：一圈橙框正好围住自己那排 6 个坑（离坑 1 像素，圆角）
  local key = "s" .. ((G.scr == "over") and 0 or G.side)
  if G.shown.side ~= key then
    G.shown.side = key
    for side = 1, 2 do
      local y, x, w = ((side == 1) and L.rowb or L.rowt) - 2, L.px - 2, 6 * L.pitch
      fg((G.scr ~= "over" and G.side == side) and C.ring or C.wood)
      rect(x + 1, y, w - 2, 1); rect(x + 1, y + 23, w - 2, 1)
      rect(x, y + 1, 1, 22); rect(x + w - 1, y + 1, 1, 22)
    end
  end
  local left, right = bar_text()
  key = left .. right
  if G.shown.bar ~= key then
    G.shown.bar = key
    fg(C.bg); rect(0, L.bar, W, H - L.bar)
    text(4, L.bar + 8, left, C.ink, C.bg)
    text_r(W - 4, L.bar + 8, right, C.dim, C.bg)
  end
  rb.lcd_update()
end

local function draw_menu()
  fg(C.bg); rect(0, 0, W, H)
  text(4, 4, "MANCALA", C.ring, C.bg)
  for k = 1, 3 do
    local y = 22 + (k - 1) * 30
    if k == G.sel then fg(C.ring); rect(2, y - 2, 3, 22) end
    text(10, y, KINDS[k], (k == G.sel) and C.ring or C.ink, C.bg)
    local who = (k == 2) and "you %d cpu %d" or "bottom %d top %d"
    text(10, y + 11, G.games[k] .. " games  " .. string.format(who, G.w1[k], G.w2[k]), C.dim, C.bg)
  end
  text(10, 116, "most moves in a row: " .. G.best_chain, C.dim, C.bg)
  rb.lcd_update()
  G.full = true
end

-- ---------- 走棋 ----------
local function new_game(kind)
  G.kind, G.b, G.side, G.scr, G.phase = kind, E.new(), 1, "play", "pick"
  G.hist, G.cur, G.chain, G.last_side, G.hi, G.hi2, G.full = {}, 1, 0, 0, -1, -1, true
  G.post = nil
  G.wait_until = 0
  save()
end
local function start_move(pit)
  G.hist[#G.hist + 1] = { b = E.copy(G.b), side = G.side, chain = G.chain, last_side = G.last_side }
  G.post, G.post_side, G.info = E.apply(G.b, G.side, pit)
  G.post_over = G.info.over
  if G.last_side == G.side then G.chain = G.chain + 1 else G.chain = 1 end
  G.last_side = G.side
  if G.chain > G.best_chain then G.best_chain = G.chain end
  G.anim_i, G.anim_n = pit, G.b[pit]
  G.b[pit] = 0
  G.hi, G.hi2 = pit, -1
  G.phase, G.t = "sow", rb.current_tick() + SOW_T
end
local function end_game()
  local a, b, k = G.b[6], G.b[13], G.kind
  G.scr, G.phase = "over", "pick"
  G.games[k] = G.games[k] + 1
  if a > b then G.w1[k] = G.w1[k] + 1 elseif b > a then G.w2[k] = G.w2[k] + 1 end
  save()
end
-- 撒种动画：每一拍落一颗；撒完停一下（吃子、收尾时停久一点），再换成算好的结果
local function step_anim()
  if rb.current_tick() < G.t then return end
  if G.phase == "sow" then
    local skip = E.store_of(3 - G.side)
    local i = G.anim_i
    repeat i = i + 1; if i > 13 then i = 0 end until i ~= skip
    G.b[i] = G.b[i] + 1
    G.anim_i, G.anim_n, G.hi = i, G.anim_n - 1, i
    G.t = rb.current_tick() + SOW_T
    if G.anim_n == 0 then
      G.phase = "settle"
      if G.info.cap > 0 then G.hi2 = 12 - i; G.t = rb.current_tick() + div(HZ * 7, 10)
      elseif G.info.over then G.t = rb.current_tick() + div(HZ * 7, 10) end
    end
  elseif G.phase == "settle" then
    G.b, G.side, G.post = G.post, G.post_side, nil
    G.hi, G.hi2, G.cur = -1, -1, 1
    if G.info.over then end_game()
    else G.phase = "pick"; save() end
  end
end

local function think()
  local started = rb.current_tick()
  local hook = function()
    for _, e in ipairs(poll()) do
      if e.k == "menu" then G.quit = true elseif e.k == "help" then G.help_req = true end
    end
    keep_light()
    if rb.yield then rb.yield() end
    return G.quit
  end
  local maxd = (G.kind == 3) and 7 or 9
  local pit, seen = E.think(G.b, G.side, maxd, 3, G.rng, hook)
  -- 想过的坑轮流亮一下，像手指在棋盘上犹豫
  local n = math.min(#seen, 6)
  local first = #seen - n + 1
  local k = first
  while not G.quit and (rb.current_tick() < started + THINK_T or k <= #seen) do
    G.hi = seen[math.min(k, #seen)]
    render()
    for _, e in ipairs(poll()) do if e.k == "menu" then G.quit = true elseif e.k == "help" then G.help_req = true end end
    keep_light()
    rb.sleep(div(HZ, 5))
    k = k + 1
  end
  G.hi = pit
  -- 观战：每步至少隔几秒
  if G.kind == 3 then G.wait_until = started + PACES[G.pace] * HZ end
  return pit
end

local HELP = {
  "Kalah. Pick up a pit and",
  "sow its seeds one by one,",
  "counterclockwise.",
  "",
  "*Rules",
  "pass your store: drop one",
  "skip the other store",
  "last seed in your store:",
  "  move again",
  "last seed in your empty pit:",
  "  take it and the seeds",
  "  across into your store",
  "one side empty: game over,",
  "  more in the store wins",
  "",
  "*Keys",
  "wheel   choose a pit",
  "select  sow",
  "prev    undo (vs cpu)",
  "play    auto: 5/10/20 s",
  "hold select  back to modes",
  "menu    quit",
  "hold menu  this help",
}

local function undo()
  -- 退回到上一次轮到你的时候
  local h = G.hist
  while #h > 0 do
    local s = table.remove(h)
    if s.side == 1 then
      G.b, G.side, G.chain, G.last_side = s.b, s.side, s.chain, s.last_side
      G.cur, G.scr = 1, "play"
      save()
      return
    end
  end
end

local function on_key(e)
  local g = select_gesture(e)
  if e.k == "help" then help_screen("MANCALA", HELP); G.full = true; if G.scr == "menu" then draw_menu() end; return end
  if e.k == "menu" then G.quit = true; return end
  if G.scr == "menu" then
    if (e.k == "fwd" or e.k == "back") and not e.rel then
      G.sel = mod(G.sel - 1 + ((e.k == "fwd") and 1 or -1), 3) + 1
      draw_menu()
    elseif g == "short" then new_game(G.sel) end
    return
  end
  if g == "long" then G.sel = G.kind; G.scr = "menu"; save(); draw_menu(); return end
  if G.scr == "over" then
    if g == "short" then
      if G.kind == 3 then new_game(3) else G.sel = G.kind; G.scr = "menu"; draw_menu() end
    end
    return
  end
  if e.k == "play" and not e.rel and not e.rep and G.kind == 3 then G.pace = mod(G.pace, #PACES) + 1; save() end
  if G.phase ~= "pick" or not human(G.side) then return end
  local moves = E.legal(G.b, G.side)
  if (e.k == "fwd" or e.k == "back") and not e.rel and #moves > 0 then
    G.cur = mod(clamp(G.cur, 1, #moves) - 1 + ((e.k == "fwd") and 1 or -1), #moves) + 1
  elseif g == "short" and #moves > 0 then start_move(moves[clamp(G.cur, 1, #moves)])
  elseif e.k == "prev" and not e.rel and not e.rep and G.kind == 2 then undo() end
end

-- ---------- 主循环 ----------
local found = load()
light_start()
if G.scr == "menu" then draw_menu() else render() end
if not found then help_screen("MANCALA", HELP); draw_menu() end

while not G.quit do
  for _, e in ipairs(poll()) do on_key(e) end
  if G.quit then break end
  if G.help_req then G.help_req = nil; help_screen("MANCALA", HELP); G.full = true end
  if G.scr == "play" then
    if G.phase == "sow" or G.phase == "settle" then step_anim()
    elseif G.phase == "pick" and not human(G.side) and rb.current_tick() >= G.wait_until then
      render()
      local pit = think()
      if G.quit then break end
      if pit then start_move(pit) end
    end
    if G.scr ~= "menu" then render() end
  elseif G.scr == "over" then render() end
  keep_light()
  rb.sleep(div(HZ, 20))
end

save()
light_end()
end
main()
