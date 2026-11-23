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
