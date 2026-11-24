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
