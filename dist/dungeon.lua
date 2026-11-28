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

-- 地下城：很小的 roguelike。每局随机生成洞穴，回合制，你走一步，怪物走一步。
-- 转盘：转动角色周围的箭头（8 个方向）   Select：做箭头指着的事（走、打、下楼、捡）
-- 长按 Select：原地等一回合   Play：道具栏   Menu：退出（地下城停在原地）   长按 Menu：说明
-- 死了就从头再来。你死在哪一层，以后的每一局在那一层都可能碰到你的墓碑。

local SAVE = "slow_dungeon.txt"
local MW, MH, TS = 22, 14, 8       -- 地图 22×14 格，每格 8 像素
local N = MW * MH
local BAR = MH * TS                -- 状态栏从这里开始（112）
local HPMAX, SIGHT2 = 10, 40       -- 视野半径约 6 格
local DX = { 0, 1, 1, 1, 0, -1, -1, -1 } -- 方向 0..7：北、东北、东……（下标 +1）
local DY = { -1, -1, 0, 1, 1, 1, 0, -1 }

-- 地形：0 地面 1 墙 2 楼梯 3 墓碑
local FLOOR, WALL, STAIRS, GRAVE = 0, 1, 2, 3
-- 怪物和道具
local MON = {
  rat = { hp = 2, dmg = 1, c = { 205, 95, 70 } },    -- 看见你就追
  moth = { hp = 1, dmg = 1, c = { 225, 210, 245 } }, -- 怕光：在你视野里就逃，离得近跑得更快
  shade = { hp = 3, dmg = 2, c = { 120, 100, 215 } },-- 只在你停下时靠近
  newt = { hp = 1, dmg = 0, c = { 110, 200, 120 } }, -- 路过而已
}
local ITEMS = { "potion", "lamp", "charm" }
local ITEMC = { { 235, 80, 120 }, { 250, 210, 90 }, { 90, 200, 225 } }

-- 8×8 小像素图：# 是主色，其余透明
local SPR = {
  you = { "...##...", "...##...", "..####..", ".#.##.#.", "...##...", "..#..#..", "..#..#..", "........" },
  rat = { "........", "........", "....##..", "..#####.", ".#######", "#.#..#..", "........", "........" },
  moth = { "#......#", "##....##", "###..###", ".######.", "..####..", ".##..##.", "#......#", "........" },
  shade = { "..####..", ".######.", "##.##.##", "########", "########", "########", "#.#.#.#.", "........" },
  newt = { "........", "......#.", ".....##.", "#.####..", ".#####..", "..#..#..", "........", "........" },
  [STAIRS] = { "........", "......##", "......#.", "....###.", "....#...", "..###...", "..#.....", "####...." },
  [GRAVE] = { "...##...", "..####..", ".##..##.", ".######.", ".##..##.", ".######.", ".######.", "########" },
  potion = { "...##...", "...##...", "..#..#..", ".######.", ".######.", ".######.", "..####..", "........" },
  lamp = { "...##...", "..#..#..", "..####..", ".######.", ".######.", "..####..", "...##...", "........" },
  charm = { "........", "..#..#..", ".##..##.", ".######.", "..####..", "...##...", "........", "........" },
}
-- 每张图拆成每行的连续段 {x, y, w}，画的时候少调几次 fillrect
for k, rows in pairs(SPR) do
  local runs = {}
  for y = 1, 8 do
    local row, x = rows[y], 1
    while x <= 8 do
      if string.sub(row, x, x) == "#" then
        local x0 = x
        while x <= 8 and string.sub(row, x, x) == "#" do x = x + 1 end
        runs[#runs + 1] = { x0 - 1, y - 1, x - x0 }
      else x = x + 1 end
    end
  end
  SPR[k] = runs
end

local C = {
  void = rgb(6, 6, 10), wall = rgb(78, 68, 88), wall2 = rgb(58, 50, 66), wdim = rgb(50, 44, 60),
  floor = rgb(34, 31, 40), dot = rgb(48, 44, 56), fdim = rgb(22, 21, 28),
  you = rgb(245, 225, 150), aim = rgb(250, 200, 80), bar = rgb(16, 16, 22), ink = rgb(215, 210, 220),
  dim = rgb(120, 115, 130), red = rgb(230, 90, 80), stairs = rgb(210, 195, 160), grave = rgb(150, 150, 162),
  sdim = rgb(90, 84, 76), gdim = rgb(70, 70, 78),
}
do local n = 0; for _, k in ipairs({ "rat", "moth", "shade", "newt" }) do n = n + 1; MON[k].id = n; MON[k].p = pack(MON[k].c) end end
for k = 1, 3 do ITEMC[k] = pack(ITEMC[k]) end

-- ---------- 状态 ----------
-- S：这一局和记录；G：当前这一层
local S = { seed = 1, depth = 1, hp = HPMAX, pos = 1, dir = 2, inv = { 0, 0, 0 }, charm_k = "", charm_t = 0,
            turns = 0, best = 0, dead = false, cause = "", graves = {}, msg = "", msg_until = 0 }
local G = { t = {}, seen = {}, mons = {}, items = {}, lit = false, grave_txt = "" }
local V = {}                          -- 这一回合看得见的格子
local shown = {}                      -- 每格上次画的样子，没变就不重画
local rnd = Rng(rb.current_tick() + now())

local function idx(x, y) if x < 0 or y < 0 or x >= MW or y >= MH then return nil end return y * MW + x + 1 end
local function xy(i) return mod(i - 1, MW), div(i - 1, MW) end
local function cheb(a, b)
  local ax, ay = xy(a); local bx, by = xy(b)
  return math.max(iabs(ax - bx), iabs(ay - by))
end
local function mon_at(i)
  for _, m in ipairs(G.mons) do if m.i == i then return m end end
  return nil
end
local function item_at(i) return G.items[i] end
local function passable(i) return i and G.t[i] ~= WALL end

-- ---------- 生成 ----------
-- 从 src 出发的步数（8 邻接，墙不通）
local function bfs(src)
  local d, q, h = {}, { src }, 1
  d[src] = 0
  while h <= #q do
    local i = q[h]; h = h + 1
    local x, y = xy(i)
    for k = 1, 8 do
      local j = idx(x + DX[k], y + DY[k])
      if j and d[j] == nil and G.t[j] ~= WALL then d[j] = d[i] + 1; q[#q + 1] = j end
    end
  end
  return d
end

local new_level
do
local function cave(r)
  local t = G.t
  for y = 0, MH - 1 do
    for x = 0, MW - 1 do
      local edge = x == 0 or y == 0 or x == MW - 1 or y == MH - 1
      t[idx(x, y)] = (edge or r(100) < 45) and WALL or FLOOR
    end
  end
  -- 元胞自动机：周围墙多就变墙，墙少就变空
  for _ = 1, 4 do
    local nt = {}
    for y = 0, MH - 1 do
      for x = 0, MW - 1 do
        local i = idx(x, y)
        if x == 0 or y == 0 or x == MW - 1 or y == MH - 1 then nt[i] = WALL
        else
          local n = 0
          for k = 1, 8 do if t[idx(x + DX[k], y + DY[k])] == WALL then n = n + 1 end end
          if n >= 5 then nt[i] = WALL elseif n <= 3 then nt[i] = FLOOR else nt[i] = t[i] end
        end
      end
    end
    for i = 1, N do t[i] = nt[i] end
  end
  -- 只留最大的一片连通区
  local best, bestd = 0, nil
  local done = {}
  for i = 1, N do
    if t[i] == FLOOR and not done[i] then
      local d, n = bfs(i), 0
      for j in pairs(d) do done[j] = true; n = n + 1 end
      if n > best then best, bestd = n, d end
    end
  end
  if not bestd then return 0 end
  for i = 1, N do if not bestd[i] then t[i] = WALL end end
  return best
end

local function random_floor(r, away_from, mind)
  for _ = 1, 400 do
    local i = r(N) + 1
    if G.t[i] == FLOOR and i ~= S.pos and not mon_at(i) and not G.items[i] and
       (not away_from or (away_from[i] or 0) >= mind) then return i end
  end
  return nil
end

new_level = function()
  local r = Rng(hash(S.seed, S.depth))
  while cave(r) < 70 do end
  G.seen, G.mons, G.items, G.lit, G.grave_txt = {}, {}, {}, false, ""
  S.pos = random_floor(r)
  local d = bfs(S.pos)
  local far, fi = -1, S.pos
  for i, v in pairs(d) do if v > far then far, fi = v, i end end
  G.t[fi] = STAIRS
  -- 怪物：越往下越多、越硬
  local kinds = { "rat", "rat", "moth", "newt" }
  if S.depth >= 2 then kinds[#kinds + 1] = "shade" end
  if S.depth >= 4 then kinds[#kinds + 1] = "shade"; kinds[#kinds + 1] = "rat" end
  for _ = 1, math.min(8, 2 + div(S.depth, 2) + r(2)) do
    local i = random_floor(r, d, 5)
    if i then
      local k = kinds[r(#kinds) + 1]
      G.mons[#G.mons + 1] = { k = k, i = i, hp = MON[k].hp + div(S.depth - 1, 2), alert = 0 }
    end
  end
  for _ = 1, r(3) do
    local i = random_floor(r, d, 2)
    if i then G.items[i] = r(3) + 1 end
  end
  -- 以前的你留下的墓碑
  for _, g in ipairs(S.graves) do
    if g.d == S.depth and r(2) == 0 then
      local i = random_floor(r, d, 3)
      if i then G.t[i] = GRAVE; G.grave_txt = g.txt end
      break
    end
  end
  shown = {}
end
end

-- ---------- 视野 ----------
local function line_clear(a, b)
  local x0, y0 = xy(a); local x1, y1 = xy(b)
  local dx, dy = iabs(x1 - x0), -iabs(y1 - y0)
  local sx, sy = x0 < x1 and 1 or -1, y0 < y1 and 1 or -1
  local err = dx + dy
  while true do
    if x0 == x1 and y0 == y1 then return true end
    local i = idx(x0, y0)
    if i ~= a and G.t[i] == WALL then return false end
    local e2 = 2 * err
    if e2 >= dy then err = err + dy; x0 = x0 + sx end
    if e2 <= dx then err = err + dx; y0 = y0 + sy end
  end
end

local function compute_fov()
  V = {}
  local px, py = xy(S.pos)
  for y = math.max(0, py - 6), math.min(MH - 1, py + 6) do
    for x = math.max(0, px - 6), math.min(MW - 1, px + 6) do
      local i = idx(x, y)
      if (x - px) * (x - px) + (y - py) * (y - py) <= SIGHT2 and (G.lit or line_clear(S.pos, i)) then
        V[i] = true; G.seen[i] = true
      end
    end
  end
  if G.lit then for i = 1, N do if G.t[i] ~= WALL or G.seen[i] then V[i] = true; G.seen[i] = true end end end
end

-- ---------- 存档 ----------
local function save()
  local t, sn = {}, {}
  for i = 1, N do t[i] = tostring(G.t[i]); sn[i] = G.seen[i] and "1" or "0" end
  local ms = {}
  for _, m in ipairs(G.mons) do ms[#ms + 1] = m.k .. "," .. m.i .. "," .. m.hp .. "," .. m.alert end
  local it = {}
  for i, k in pairs(G.items) do it[#it + 1] = i .. "," .. k end
  local gs = {}
  for _, g in ipairs(S.graves) do gs[#gs + 1] = g.d .. "|" .. g.txt end
  save_kv(SAVE, {
    seed = S.seed, depth = S.depth, hp = S.hp, pos = S.pos, dir = S.dir, turns = S.turns, best = S.best,
    inv = table.concat(S.inv, ","), charm_k = S.charm_k, charm_t = S.charm_t, dead = S.dead and 1 or 0,
    cause = S.cause, map = table.concat(t), seen = table.concat(sn), mons = table.concat(ms, ";"),
    items = table.concat(it, ";"), lit = G.lit and 1 or 0, grave_txt = G.grave_txt, graves = table.concat(gs, ";"),
  })
end

local function new_run()
  S.seed = hash(now(), rnd(60000)); S.depth, S.hp, S.inv, S.turns = 1, HPMAX, { 0, 0, 0 }, 0
  S.charm_k, S.charm_t, S.dead, S.cause = "", 0, false, ""
  new_level()
  S.msg, S.msg_until = "a new cave", S.turns + 3
end

local function load()
  local s, ok = load_kv(SAVE)
  S.best = num(s.best, 0)
  for part in string.gmatch(s.graves or "", "[^;]+") do
    local d, txt = string.match(part, "^(%d+)|(.*)$")
    if d then S.graves[#S.graves + 1] = { d = tonumber(d), txt = txt } end
  end
  if not ok or not s.map or #s.map ~= N or #(s.seen or "") ~= N then return false end
  S.seed, S.depth, S.hp, S.pos = num(s.seed, 1), num(s.depth, 1), num(s.hp, HPMAX), num(s.pos, 1)
  S.dir, S.turns = num(s.dir, 2), num(s.turns, 0)
  S.charm_k, S.charm_t = s.charm_k or "", num(s.charm_t, 0)
  S.dead, S.cause = num(s.dead, 0) == 1, s.cause or ""
  local k = 1
  for v in string.gmatch(s.inv or "", "%d+") do S.inv[k] = tonumber(v); k = k + 1 end
  for i = 1, N do G.t[i] = string.byte(s.map, i) - 48; G.seen[i] = string.sub(s.seen, i, i) == "1" end
  for part in string.gmatch(s.mons or "", "[^;]+") do
    local mk, mi, mh, ma = string.match(part, "^(%a+),(%d+),(%-?%d+),(%-?%d+)$")
    if mk and MON[mk] then G.mons[#G.mons + 1] = { k = mk, i = tonumber(mi), hp = tonumber(mh), alert = tonumber(ma) } end
  end
  for part in string.gmatch(s.items or "", "[^;]+") do
    local ii, ik = string.match(part, "^(%d+),(%d+)$")
    if ii then G.items[tonumber(ii)] = tonumber(ik) end
  end
  G.lit, G.grave_txt = num(s.lit, 0) == 1, s.grave_txt or ""
  return true
end

-- ---------- 回合 ----------
local function say(s) S.msg, S.msg_until = s, S.turns + 2 end

local function die(cause)
  S.dead, S.cause, S.hp = true, cause, 0
  table.insert(S.graves, 1, { d = S.depth, txt = cause .. " (D" .. S.depth .. ")" })
  while #S.graves > 20 do table.remove(S.graves) end
  save()
end

-- 在 8 个邻格里挑一个：score 越小越好；只走空着的格子
local function step(m, score)
  local x, y = xy(m.i)
  local best, bi = score(m.i), nil
  local start = rnd(8)
  for n = 0, 7 do
    local k = mod(start + n, 8) + 1
    local j = idx(x + DX[k], y + DY[k])
    if passable(j) and j ~= S.pos and not mon_at(j) then
      local s = score(j)
      if s < best then best, bi = s, j end
    end
  end
  if bi then m.i = bi; return true end
  return false
end

local function wander(m)
  if rnd(2) == 0 then step(m, function() return rnd(10) end) end
end

local function monsters_act(stood_still, dist)
  local i = 1
  while i <= #G.mons do
    local m = G.mons[i]
    local k = m.k
    local charmed = S.charm_t > 0 and S.charm_k == k
    local near = cheb(m.i, S.pos)
    if charmed or k == "newt" then wander(m)
    elseif k == "rat" then
      -- rat 旁边有 moth 时先追 moth
      local prey
      for _, o in ipairs(G.mons) do if o.k == "moth" and cheb(o.i, m.i) <= 3 then prey = o end end
      if prey and cheb(prey.i, m.i) == 1 then
        prey.hp = 0
        if V[m.i] then say("a rat eats a moth") end
      elseif prey then step(m, function(j) return cheb(j, prey.i) end)
      elseif V[m.i] or m.alert > 0 then
        if near == 1 then
          S.hp = S.hp - MON.rat.dmg - (S.depth >= 4 and 1 or 0)
          say("the rat bites")
          if S.hp <= 0 then die("bitten by a rat"); return end
        else step(m, function(j) return dist[j] or 99 end) end
        m.alert = math.max(0, m.alert - 1)
      else wander(m) end
    elseif k == "moth" then
      if V[m.i] then
        -- 怕光：逃；离你两格以内跑两步
        local moved = step(m, function(j) return -(dist[j] or 0) end)
        if near <= 2 and moved then step(m, function(j) return -(dist[j] or 0) end) end
        if not moved and near == 1 and rnd(2) == 0 then
          S.hp = S.hp - MON.moth.dmg; say("a cornered moth bites")
          if S.hp <= 0 then die("bitten by a moth"); return end
        end
      else wander(m) end
    elseif k == "shade" then
      if stood_still then
        if near == 1 then
          S.hp = S.hp - MON.shade.dmg; say("the shade touches you")
          if S.hp <= 0 then die("taken by a shade"); return end
        else step(m, function(j) return dist[j] or 99 end) end
      end
    end
    if m.hp <= 0 then table.remove(G.mons, i) else i = i + 1 end
  end
  -- 被 rat 吃掉的 moth
  for j = #G.mons, 1, -1 do if G.mons[j].hp <= 0 then table.remove(G.mons, j) end end
end

-- 一个回合：玩家做完动作之后
local function end_turn(stood_still)
  S.turns = S.turns + 1
  if S.charm_t > 0 then S.charm_t = S.charm_t - 1 end
  if mod(S.turns, 12) == 0 and S.hp < HPMAX then S.hp = S.hp + 1 end
  compute_fov()
  monsters_act(stood_still, bfs(S.pos))
  compute_fov()
  if mod(S.turns, 20) == 0 then save() end
end

local function descend()
  S.depth = S.depth + 1
  if S.depth > S.best then S.best = S.depth end
  -- 过场：一帧「D4」
  fg(C.void); rect(0, 0, W, H)
  text_r(div(W, 2) + 9, div(H, 2) - 4, "D" .. S.depth, C.ink, C.void)
  rb.lcd_update()
  new_level()
  compute_fov()
  say("down to D" .. S.depth)
  save()
end

-- 箭头指着的格子上会发生什么
local function intent()
  local x, y = xy(S.pos)
  local j = idx(x + DX[S.dir + 1], y + DY[S.dir + 1])
  if not passable(j) then return "wall", j end
  local m = mon_at(j)
  if m and V[j] then return "attack " .. m.k, j, m end
  if G.items[j] then return "take " .. ITEMS[G.items[j]], j end
  if G.t[j] == STAIRS then return "go down", j end
  if G.t[j] == GRAVE then return "read grave", j end
  return "walk", j
end

local function act()
  local what, j, m = intent()
  if what == "wall" then say("a wall"); return end
  if m then
    local dmg = 1 + rnd(2)
    m.hp = m.hp - dmg
    -- 打斗的声音把附近的 rat 引过来
    for _, o in ipairs(G.mons) do if o.k == "rat" and cheb(o.i, S.pos) <= 8 then o.alert = 6 end end
    if m.hp <= 0 then
      for k, o in ipairs(G.mons) do if o == m then table.remove(G.mons, k); break end end
      say(m.k == "newt" and "the newt meant no harm" or ("the " .. m.k .. " is gone"))
    else say("you hit the " .. m.k) end
    end_turn(true)
    return
  end
  if mon_at(j) then say("something moves"); end_turn(true); return end -- 看不见的怪物挡着
  S.pos = j
  if G.items[j] then
    local k = G.items[j]; G.items[j] = nil
    S.inv[k] = S.inv[k] + 1; say("got a " .. ITEMS[k])
  end
  if G.t[j] == STAIRS then descend(); return end
  end_turn(false)
  if G.t[j] == GRAVE then say(G.grave_txt ~= "" and G.grave_txt or "an old grave") end
end

local function use_item(k)
  if S.inv[k] <= 0 then return end
  S.inv[k] = S.inv[k] - 1
  if k == 1 then S.hp = math.min(HPMAX, S.hp + 5); say("you feel better")
  elseif k == 2 then G.lit = true; say("the whole floor lights up")
  else
    -- 护符：视野里离你最近的那种怪物，暂时不理你
    local best, bk = 99, nil
    for _, m in ipairs(G.mons) do
      if V[m.i] and m.k ~= "newt" and cheb(m.i, S.pos) < best then best, bk = cheb(m.i, S.pos), m.k end
    end
    if bk then S.charm_k, S.charm_t = bk, 30; say(bk .. "s ignore you") else say("nothing to charm") end
  end
  end_turn(true)
end

-- ---------- 画面 ----------
local draw_map, draw_dead, draw_inv
do
local function sprite(px, py, runs, c)
  fg(c)
  for _, r in ipairs(runs) do rect(px + r[1], py + r[2], r[3], 1) end
end

-- 每格的样子编成一个数，和上次一样就不重画
local function sig(i, target)
  local v = V[i] and 2 or (G.seen[i] and 1 or 0)
  local s = v * 10 + G.t[i]
  if v == 2 then
    local m = mon_at(i)
    if m then s = s + 100 * MON[m.k].id end
    if G.items[i] then s = s + 1000 * G.items[i] end
    if i == S.pos then s = s + 5000 + 10000 * S.dir end
  end
  if i == target then s = s + 100000 end
  return s
end

local function draw_cell(i, target)
  local x, y = xy(i)
  local px, py = x * TS, y * TS
  local v = V[i] and 2 or (G.seen[i] and 1 or 0)
  local t = G.t[i]
  if v == 0 then fg(C.void); rect(px, py, TS, TS)
  elseif t == WALL then
    fg(v == 2 and C.wall or C.wdim); rect(px, py, TS, TS)
    if v == 2 then fg(C.wall2); rect(px, py + 3, TS, 1); rect(px + mod(y, 2) * 4 + 1, py, 1, 3); rect(px + mod(y + 1, 2) * 4 + 1, py + 4, 1, 4) end
  else
    fg(v == 2 and C.floor or C.fdim); rect(px, py, TS, TS)
    if v == 2 and mod(x * 3 + y * 5, 7) == 0 then fg(C.dot); rect(px + 3, py + 4, 1, 1) end
    if t == STAIRS then sprite(px, py, SPR[STAIRS], v == 2 and C.stairs or C.sdim)
    elseif t == GRAVE then sprite(px, py, SPR[GRAVE], v == 2 and C.grave or C.gdim) end
  end
  if v == 2 then
    if G.items[i] then sprite(px, py, SPR[ITEMS[G.items[i]]], ITEMC[G.items[i]]) end
    local m = mon_at(i)
    if m then sprite(px, py, SPR[m.k], MON[m.k].p) end
    if i == S.pos then
      sprite(px, py, SPR.you, C.you)
      -- 箭头：朝向那一边的边上一个小点
      fg(C.aim); rect(px + 3 + DX[S.dir + 1] * 3, py + 3 + DY[S.dir + 1] * 3, 2, 2)
    end
  end
  if i == target then -- 目标格的四个角
    fg(C.aim)
    rect(px, py, 2, 1); rect(px, py, 1, 2); rect(px + 6, py, 2, 1); rect(px + 7, py, 1, 2)
    rect(px, py + 7, 2, 1); rect(px, py + 6, 1, 2); rect(px + 6, py + 7, 2, 1); rect(px + 7, py + 6, 1, 2)
  end
end

local function draw_bar(what)
  fg(C.bar); rect(0, BAR, W, H - BAR)
  local hp_c = S.hp <= 3 and C.red or C.ink
  text(3, BAR + 2, "HP " .. S.hp .. "/" .. HPMAX, hp_c, C.bar)
  text(70, BAR + 2, "D" .. S.depth, C.ink, C.bar)
  if S.charm_t > 0 then text_r(W - 3, BAR + 2, S.charm_k .. " " .. S.charm_t, C.dim, C.bar) end
  local line = (S.turns <= S.msg_until and S.msg ~= "") and S.msg or ("> " .. what)
  text(3, BAR + 11, string.sub(line, 1, 28), S.turns <= S.msg_until and C.dim or C.aim, C.bar)
end

draw_map = function()
  local what, target = intent()
  for i = 1, N do
    local s = sig(i, target)
    if shown[i] ~= s then shown[i] = s; draw_cell(i, target) end
  end
  draw_bar(what)
  rb.lcd_update()
end

draw_dead = function()
  fg(C.void); rect(0, 0, W, H)
  text(10, 30, "You died on D" .. S.depth, C.red, C.void)
  text(10, 44, string.sub(S.cause, 1, 26), C.ink, C.void)
  text(10, 64, "deepest  D" .. S.best, C.dim, C.void)
  text(10, 74, "graves   " .. #S.graves, C.dim, C.void)
  text(10, 100, "select: a new cave", C.aim, C.void)
  rb.lcd_update()
  shown = {}
end

draw_inv = function(sel, list)
  local bx, by, bw = 30, 30, 116
  local bh = 16 + math.max(1, #list) * 10
  fg(C.wall); rect(bx - 1, by - 1, bw + 2, bh + 2)
  fg(C.bar); rect(bx, by, bw, bh)
  text(bx + 4, by + 3, "ITEMS", C.aim, C.bar)
  if #list == 0 then text(bx + 4, by + 14, "(empty)", C.dim, C.bar) end
  for n, k in ipairs(list) do
    local c = n == sel and C.aim or C.ink
    text(bx + 4, by + 4 + n * 10, (n == sel and "> " or "  ") .. ITEMS[k] .. " x" .. S.inv[k], c, C.bar)
  end
  rb.lcd_update()
  shown = {}
end
end

local HELP = {
  "A tiny cave crawl. You take",
  "a step, every monster takes",
  "a step. Die, and start a",
  "new cave; your grave stays",
  "on that floor for later.",
  "",
  "*Keys",
  "wheel   turn the arrow",
  "select  do it: walk, hit,",
  "        go down, take",
  "hold select  wait a turn",
  "play    items",
  "menu    quit (cave waits)",
  "hold menu  this help",
  "",
  "*Who lives here",
  "rat    chases you",
  "moth   flees your light",
  "shade  comes when you stop",
  "newt   just passing by",
  "",
  "*Items",
  "potion  +5 HP",
  "lamp    light the floor",
  "charm   one kind ignores",
  "        you for 30 turns",
}

-- ---------- 主循环 ----------
if not load() then new_run() end
if S.best < S.depth then S.best = S.depth end
light_start()
compute_fov()

-- 主函数的 local 很紧（Rockbox 上限 100）：循环状态收进 U，按键处理放进函数
local U = { running = true, inv_open = false, inv_sel = 1, dirty = true }
local function inv_list()
  local list = {}
  for k = 1, 3 do if S.inv[k] > 0 then list[#list + 1] = k end end
  return list
end

local function on_key(e)
  local g = select_gesture(e)
  if e.k == "help" then help_screen("DUNGEON", HELP); shown = {}; U.dirty = true
  elseif U.inv_open then
    local list = inv_list()
    if e.k == "menu" then U.inv_open = false
    elseif e.k == "fwd" and not e.rel then U.inv_sel = clamp(U.inv_sel + 1, 1, math.max(1, #list))
    elseif e.k == "back" and not e.rel then U.inv_sel = clamp(U.inv_sel - 1, 1, math.max(1, #list))
    elseif g == "short" then
      U.inv_open = false
      if list[U.inv_sel] then use_item(list[U.inv_sel]) end
    elseif e.k == "play" and not e.rel and not e.rep then U.inv_open = false end
    U.dirty = true
  elseif e.k == "menu" then U.running = false
  elseif S.dead then
    if g == "short" then new_run(); compute_fov(); U.dirty = true end
  elseif e.k == "fwd" and not e.rel then S.dir = mod(S.dir + 1, 8); U.dirty = true
  elseif e.k == "back" and not e.rel then S.dir = mod(S.dir + 7, 8); U.dirty = true
  elseif g == "short" then act(); U.dirty = true
  elseif g == "long" then say("you wait"); end_turn(true); U.dirty = true
  elseif e.k == "play" and not e.rel and not e.rep then U.inv_open, U.inv_sel = true, 1; U.dirty = true
  end
end

while U.running do
  for _, e in ipairs(poll()) do on_key(e) end
  if U.dirty and U.running then
    U.dirty = false
    if S.dead then draw_dead()
    elseif U.inv_open then draw_map(); draw_inv(U.inv_sel, inv_list())
    else draw_map() end
  end
  keep_light()
  rb.sleep(div(HZ, 20))
end

save()
light_end()
