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
