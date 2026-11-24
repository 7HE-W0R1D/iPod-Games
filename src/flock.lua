-- 鸟群：十几只鸟各自只看身边的同伴，聚成一整团飞行的形状（Boids）
-- 转盘：时间流速   Select：惊扰一下   Menu：退出   长按 Menu：说明
-- 白天飞，傍晚越飞越低，夜里落成一排，天亮再起飞。角落的数字是今天转了多少次弯。
-- 天空跟着时间和天气变：晴天的傍晚有晚霞和紫色暮光，雨天发灰，雾天地平线发白，夜里有星星。
-- 夜里惊扰：几只鸟飞起来绕一下就落回电线；连着按，它们习惯了，飞起来的越来越少。

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

-- ---------- 天空 ----------
-- 关键帧：{锚点, 偏移分钟, 天顶, 中间, 地平线}。傍晚的紫色取自一张暮光天空的照片。
local SKY = {
  { "sr", -80, { 6, 8, 22 }, { 10, 12, 32 }, { 18, 20, 44 } },        -- 夜
  { "sr", -30, { 30, 40, 80 }, { 70, 78, 120 }, { 140, 130, 160 } },  -- 黎明灰蓝
  { "sr", 20, { 80, 110, 170 }, { 150, 160, 200 }, { 235, 200, 180 } }, -- 日出，地平线微粉
  { "sr", 100, { 60, 120, 200 }, { 110, 165, 225 }, { 195, 220, 240 } }, -- 白天
  { "ss", -80, { 60, 120, 200 }, { 115, 165, 222 }, { 205, 222, 236 } },
  { "ss", -30, { 80, 115, 185 }, { 170, 170, 190 }, { 250, 200, 140 } }, -- 金色
  { "ss", 0, { 90, 80, 150 }, { 200, 120, 140 }, { 250, 150, 90 } },     -- 晚霞
  { "ss", 20, { 50, 62, 130 }, { 100, 78, 150 }, { 165, 115, 155 } },    -- 紫色暮光
  { "ss", 45, { 28, 30, 80 }, { 55, 45, 100 }, { 90, 60, 110 } },        -- 入夜深紫
  { "ss", 85, { 6, 8, 22 }, { 10, 12, 32 }, { 18, 20, 44 } },
}
-- 晚霞里被照亮的云：{偏移分钟, 颜色}
local GLOWK = { { -50, { 250, 225, 190 } }, { -20, { 255, 190, 120 } }, { 0, { 255, 140, 120 } },
                { 20, { 200, 120, 175 } }, { 45, { 70, 50, 95 } } }
local BAND = 6                     -- 天空分成 22 条横带
local NB = div(H + BAND - 1, BAND)
local SC = { key = -1 }            -- 天空缓存：每分钟算一次

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
local wary, wary_t = 0, 0 -- 夜里被惊扰了几次（每 30 秒忘掉一次）

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
      if b.fly_until and rb.current_tick() < b.fly_until then
        -- 被惊起：在电线上方乱飞一小会儿
        b.vx = b.vx + div(b.hx - b.x, 40) + rnd(9) - 4
        b.vy = b.vy + div(b.hy - b.y, 40) + rnd(9) - 4
        limit(b)
      elseif b.perched then
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
  if schedule() == "night" then
    -- 夜里：只惊起几只，很快落回来；按得越多，它们越不当回事
    local t = now()
    wary = math.max(0, wary - div(t - wary_t, 30)); wary_t = t
    local fly = clamp(6 - wary * 2 + rnd(3), 0, #birds)
    wary = wary + 1
    local hop = fly == 0 -- 都不飞了：只有一只扑腾一下
    if hop then fly = 1 end
    for _ = 1, fly do
      local b = birds[rnd(#birds) + 1]
      b.perched = false
      b.vx, b.vy = rnd(41) - 20, hop and -10 or -VMAX
      b.hx = b.x + (rnd(61) - 30) * FP
      b.hy = (PERCH_Y - (hop and 4 or 25 + rnd(40))) * FP
      b.fly_until = rb.current_tick() + (hop and div(HZ, 3) or (2 * HZ + rnd(2 * HZ)))
    end
    return
  end
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
-- 在关键帧之间插值（跨午夜首尾相接）
local function sky_at(L)
  local m, n, pts = L.min, #SKY, {}
  for i, k in ipairs(SKY) do pts[i] = (k[1] == "sr" and L.sr or L.ss) + k[2] end
  local a, b, num_, den
  if m < pts[1] or m >= pts[n] then
    a, b, den = n, 1, pts[1] + 1440 - pts[n]
    num_ = m >= pts[n] and m - pts[n] or m + 1440 - pts[n]
  else
    for i = 1, n - 1 do
      if m >= pts[i] and m < pts[i + 1] then a, b, num_, den = i, i + 1, m - pts[i], pts[i + 1] - pts[i]; break end
    end
  end
  local ka, kb = SKY[a], SKY[b]
  return mix(ka[3], kb[3], num_, den), mix(ka[4], kb[4], num_, den), mix(ka[5], kb[5], num_, den)
end

-- 晚霞云的颜色和亮度（0..100）
local function glow_at(L, strength)
  local d = L.min - L.ss
  if d < GLOWK[1][1] or d > GLOWK[#GLOWK][1] then return nil, 0 end
  for i = 1, #GLOWK - 1 do
    local a, b = GLOWK[i], GLOWK[i + 1]
    if d >= a[1] and d <= b[1] then
      local k = d > 25 and div((45 - d) * strength, 20) or strength
      return mix(a[2], b[2], d - a[1], b[1] - a[1]), clamp(k, 0, 100)
    end
  end
  return nil, 0
end

local function lum(c) return div(c[1] * 3 + c[2] * 6 + c[3], 10) end

-- 算好这一分钟的天：每条横带的颜色、鸟和尾迹的颜色、云和星星
local function build_sky(L)
  local top, midc, bot = sky_at(L)
  local w = weather_of(L.day)
  local r = Rng(hash(L.day, 77))
  local strength = 30 + r(71)                       -- 每天的晚霞强弱不一样
  if w.rainy then
    local grey = { 105, 110, 122 }
    local dark = lum(midc) < 60 and 2 or 1
    top, midc, bot = mix(top, grey, 5, 8), mix(midc, grey, 5, 8), mix(bot, grey, 5, 8)
    if dark == 2 then top, midc, bot = mix(top, { 0, 0, 0 }, 1, 2), mix(midc, { 0, 0, 0 }, 1, 2), mix(bot, { 0, 0, 0 }, 1, 2) end
    strength = 0
  elseif w.fog > 50 and lum(bot) > 60 then          -- 雾大：地平线发白，渐变变平
    local haze, k = mix(bot, { 215, 215, 222 }, 2, 3), w.fog - 50
    bot, midc = mix(bot, haze, k * 2, 100), mix(midc, haze, k, 100)
    strength = div(strength, 2)
  end
  local bright = lum(midc) > 90
  local bird = bright and { 28, 24, 44 } or (lum(midc) > 45 and { 235, 225, 240 } or { 150, 155, 185 })
  SC.band, SC.t1, SC.t2 = {}, {}, {}
  for i = 0, NB - 1 do
    local c
    if i * 2 < NB then c = mix(top, midc, i * 2, NB) else c = mix(midc, bot, i * 2 - NB, NB) end
    SC.band[i] = pack(c)
    SC.t1[i] = pack(mix(c, bird, 1, 3)); SC.t2[i] = pack(mix(c, bird, 2, 3))
  end
  SC.bird, SC.bot = pack(bird), pack(bot)
  SC.wire = pack(mix(bot, bird, 1, 2))
  SC.text = pack(mix(bot, bird, 1, 2))
  -- 云：位置由日期决定；白天淡白，晚霞时被照亮，其余时候是比天暗一点的影子
  local gc, gk = glow_at(L, strength)
  SC.clouds = {}
  if not w.rainy then
    for k = 1, 3 + r(3) do
      local y = 50 + r(60)
      local band = mix(top, bot, y, H)
      local base = bright and mix(band, { 255, 255, 255 }, 1, 3) or mix(band, { 0, 0, 0 }, 1, 5)
      local c = gc and mix(base, gc, gk, 100) or base
      SC.clouds[k] = { x = r(W + 40) - 20, y = y, w = 24 + r(50), h = 2 + r(2), c = pack(c),
                       e = pack(mix(c, band, 1, 2)) }
    end
  end
  -- 星星：暮光后半段开始出现，越晚越多
  local d = L.min - L.ss
  local ns = 0
  if d > 25 or L.min < L.sr - 20 then ns = (d > 25 and d < 85) and div((d - 25) * 20, 60) or 20 end
  if w.rainy then ns = div(ns, 4) end
  local sr_ = Rng(hash(L.day, 5))
  SC.stars = {}
  for k = 1, ns do SC.stars[k] = { sr_(W), sr_(H - 30) } end
  SC.star = pack(mix(top, { 235, 230, 255 }, 3, 4))
end

local overlay, overlay_until = nil, 0
local function draw(mode, L)
  local key = L.day * 1440 + L.min
  if SC.key ~= key then SC.key = key; build_sky(L) end
  for i = 0, NB - 1 do fg(SC.band[i]); rect(0, i * BAND, W, BAND) end
  fg(SC.star)
  for k, st in ipairs(SC.stars) do
    if mod(steps + k * 7, 23) ~= 0 then rect(st[1], st[2], 1, 1) end -- 偶尔闪一下
  end
  for _, c in ipairs(SC.clouds) do
    local q = div(c.w, 4)
    fg(c.e); rect(c.x - 4, c.y + 1, c.w + 8, c.h)
    fg(c.c); rect(c.x, c.y, c.w, c.h); rect(c.x + q, c.y - 1, c.w - q * 2, 1); rect(c.x + q + 2, c.y - 2, q, 1)
  end
  if mode == "night" then fg(SC.wire); rect(0, PERCH_Y + 2, W, 1) end -- 夜里那根电线
  for _, b in ipairs(birds) do
    for t = TRAIL, 2, -1 do
      local bi = clamp(div(b.ty[t], BAND), 0, NB - 1)
      fg(t > 3 and SC.t1[bi] or SC.t2[bi])
      rect(b.tx[t], b.ty[t], 1, 1)
    end
    fg(SC.bird); rect(b.tx[1], b.ty[1], 2, 2)
  end
  text_r(W - 2, H - 9, tostring(turns), SC.text, SC.band[NB - 1])
  if overlay and rb.current_tick() < overlay_until then text(2, 2, overlay, SC.text, SC.band[0]) end
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
        "The sky follows the hour",
        "and the weather: sunset",
        "glow, purple dusk, grey",
        "rain, stars at night.",
        "Corner: turns made today.",
        "",
        "*Keys",
        "wheel   time speed",
        "select  startle them",
        "        (night: a few fly up",
        "        and come back; they",
        "        get used to it)",
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
