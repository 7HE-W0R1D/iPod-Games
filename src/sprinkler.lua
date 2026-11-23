-- 洒水器：黄昏的球场，洒水器一个个打开。转盘就是喷头
-- 转盘：喷头方向（手指在哪，水往哪喷）；转得慢落得近、湿得透，转得快洒得远、只湿一层皮
-- 上一首 / 下一首：水量小 / 大   Play：开 / 关（白天手动开；黄昏自动开，也能关；夜里不开）   Menu：退出

local SAVE = "slow_sprinkler.txt"
local CELL = 4
local GW, GH = div(W, CELL), div(H, CELL) -- 44 × 33
local N = GW * GH
local WET_MAX, SOAKED = 12, 8   -- 湿度 0..12；到 8 算“浇透”
local DRY_SECS = 300            -- 每 5 分钟干一点
local OPEN_BEFORE, OPEN_AFTER = 30, 40 -- 日落前 30 分钟开，日落后 40 分钟关
local WHEEL_ZERO = 24           -- 转盘位置 0 对应的喷头方向（24 = 朝上）；上机后按手感调
local MAXDROP = 60
local FLOW = { 1, 2, 3, 4, 6 }   -- 水量：每帧喷几滴

-- 32 个方向的余弦 ×64（0 朝右，顺时针，屏幕坐标 y 向下）
local COS = { [0] = 64, 63, 59, 53, 45, 36, 24, 12, 0, -12, -24, -36, -45, -53, -59, -63,
  -64, -63, -59, -53, -45, -36, -24, -12, 0, 12, 24, 36, 45, 53, 59, 63 }
local function sin32(a) return COS[mod(a - 8, 32)] end

-- 草色：健康 0..3（枯黄 → 深绿）× 湿 0..3（越湿越深）
local GRASS = { [0] = { 186, 166, 92 }, { 150, 158, 78 }, { 92, 140, 62 }, { 46, 112, 52 } }
local WETC = { 24, 58, 70 }
local HEAD, BIRD = { 150, 150, 158 }, { 40, 36, 34 }

-- ---------- 状态 ----------
local HL, WV, WD = {}, {}, {}    -- 健康；湿度；最后一次浇透是哪天
local DIRTY = {}
local AUTO = {}                  -- 远处自动洒水器管的格子
local S = { day = div(now(), 86400), dry_t = now(), rain_day = -1, manual = false, aim = 24,
            flow = 2, flow_until = 0, auto_off = false }
local drops = {}
local rnd = Rng(rb.current_tick() + now())
local PAL = {}                   -- [健康*4+湿] → 颜色，跟着光变
local HEADS = { { x = 6 * CELL + 2, y = 6 * CELL + 2, a = 0, r = 7 }, { x = 37 * CELL + 2, y = 26 * CELL + 2, a = 16, r = 7 } }
local CX, CY = div(W, 2), div(H, 2)

for _, h in ipairs(HEADS) do
  local hx, hy = div(h.x, CELL), div(h.y, CELL)
  for y = 0, GH - 1 do
    for x = 0, GW - 1 do
      if (x - hx) * (x - hx) + (y - hy) * (y - hy) <= h.r * h.r then AUTO[y * GW + x + 1] = true end
    end
  end
end

local function level(i) return div(WV[i] + 3, 4) end -- 0..3
local function mark(i) DIRTY[#DIRTY + 1] = i end
local function mark_px(px, py) -- 屏幕上这个点下面的格子要重画
  local x, y = div(px, CELL), div(py, CELL)
  if x >= 0 and x < GW and y >= 0 and y < GH then mark(y * GW + x + 1) end
end

-- ---------- 时间 ----------
-- 一天结束时结算：浇透过（或下过雨、在自动洒水器范围里）的格子好一档，两天以上没浇的差一档
local function settle(d)
  local rainy = weather_of(d).rainy
  for i = 1, N do
    if WD[i] == d or rainy or AUTO[i] then
      if HL[i] < 3 then HL[i] = HL[i] + 1 end
    elseif d - WD[i] >= 2 and HL[i] > 0 then
      HL[i] = HL[i] - 1
    end
  end
end
local function tick_time()
  local t = now()
  local today = div(t, 86400)
  if today > S.day then
    for d = math.max(S.day, today - 30), today - 1 do settle(d) end
    S.day = today
    for i = 1, N do mark(i) end
  end
  local steps = div(t - S.dry_t, DRY_SECS)
  if steps > 0 then
    S.dry_t = S.dry_t + steps * DRY_SECS
    for i = 1, N do
      local v = WV[i]
      if v > 0 then
        local old = level(i)
        v = v - steps; if v < 0 then v = 0 end
        WV[i] = v
        if level(i) ~= old then mark(i) end
      end
    end
  end
  if S.rain_day ~= today and weather_of(today).rainy then -- 下雨天：整片草地是湿的
    S.rain_day = today
    for i = 1, N do if WV[i] < SOAKED then WV[i] = SOAKED; mark(i) end; WD[i] = today end
  end
end

-- 现在的状态："auto" 黄昏自动开；"day" 白天（可手动开）；"night" 不开
local function phase(L)
  if L.min >= L.ss - OPEN_BEFORE and L.min <= L.ss + OPEN_AFTER then return "auto" end
  if L.min >= L.sr and L.min < L.ss - OPEN_BEFORE then return "day" end
  return "night"
end

local function make_palette(L)
  local l = L.land -- 草地比天空亮一些，黄昏不至于一片漆黑
  local light = { 60 + div(l[1] * 3, 4), 60 + div(l[2] * 3, 4), 60 + div(l[3] * 3, 4) }
  for h = 0, 3 do
    for w = 0, 3 do
      local c = GRASS[h]
      if w > 0 then c = mix(c, { 20, 50, 60 }, WETC[w], 100) end
      PAL[h * 4 + w] = pack(tint(c, light))
    end
  end
  for i = 1, N do mark(i) end
end

-- ---------- 水 ----------
local function wet(i, amount)
  local old = level(i)
  local v = WV[i] + amount
  if v > WET_MAX then v = WET_MAX end
  WV[i] = v
  if v >= SOAKED then WD[i] = S.day end
  if level(i) ~= old then mark(i) end
end
local function spray(x, y, a, range, jitter, amount)
  if #drops >= MAXDROP then return end
  local ang = mod(a + rnd(2 * jitter + 1) - jitter, 32)
  local life = 8
  local v = div(range * CELL * 16, life)
  drops[#drops + 1] = { x = x * 16, y = y * 16, vx = div(COS[ang] * v, 64), vy = div(sin32(ang) * v, 64),
                        life = life, amount = amount }
end
local function move_drops()
  local k = 1
  while k <= #drops do
    local d = drops[k]
    local ox, oy = div(d.x, 16), div(d.y, 16)
    mark_px(ox, oy); mark_px(ox + 1, oy + 1) -- 2×2 的水点可能跨两格
    d.x, d.y, d.life = d.x + d.vx, d.y + d.vy, d.life - 1
    local px, py = div(d.x, 16), div(d.y, 16)
    if d.life <= 0 or px < 0 or py < 0 or px >= W or py >= H then
      if px >= 0 and py >= 0 and px < W and py < H then
        local cx, cy = div(px, CELL), div(py, CELL)
        wet(cy * GW + cx + 1, d.amount)
        local nx, ny = clamp(cx + rnd(3) - 1, 0, GW - 1), clamp(cy + rnd(3) - 1, 0, GH - 1)
        wet(ny * GW + nx + 1, 1) -- 溅开一点
      end
      table.remove(drops, k)
    else
      k = k + 1
    end
  end
end

-- ---------- 鸟 ----------
local bird = nil
local function bird_step(aim, open)
  if bird then
    mark_px(bird.x, bird.y); mark_px(bird.x + 3, bird.y + 2)
    if bird.vx ~= 0 or bird.vy ~= 0 then
      bird.x, bird.y = bird.x + bird.vx, bird.y + bird.vy
      if bird.x < -6 or bird.x > W + 6 or bird.y < -6 or bird.y > H + 6 then bird = nil end
      return
    end
    -- 喷头转到它那边，或者待够了，就飞走
    local dx, dy = bird.x - CX, bird.y - CY
    local best, ba = -1, 0
    for a = 0, 31 do
      local dot = COS[a] * dx + sin32(a) * dy
      if dot > best then best, ba = dot, a end
    end
    local diff = iabs(mod(ba - aim + 16, 32) - 16)
    if (open and diff <= 2) or rb.current_tick() > bird.until_t then
      bird.vx = (dx >= 0) and 3 or -3
      bird.vy = -2
    end
    return
  end
  if rnd(600) ~= 0 then return end
  local puddles, spot = 0, nil
  for _ = 1, 60 do
    local i = rnd(N) + 1
    if level(i) == 3 then puddles = puddles + 1; spot = i end
  end
  if puddles >= 6 and spot then
    local x, y = mod(spot - 1, GW), div(spot - 1, GW)
    bird = { x = x * CELL, y = y * CELL, vx = 0, vy = 0, until_t = rb.current_tick() + (30 + rnd(30)) * HZ }
  end
end

-- ---------- 存档 ----------
local function load()
  local s, found = load_kv(SAVE)
  local hs, ws, ds = s.health or "", s.wet or "", s.wday or ""
  local saved_day = num(s.day, S.day)
  for i = 1, N do
    HL[i] = num(string.sub(hs, i, i), 2)
    WV[i] = tonumber(string.sub(ws, i, i), 16) or 0
    WD[i] = saved_day - num(string.sub(ds, i, i), 1)
  end
  if found then
    S.day = saved_day
    S.dry_t = num(s.dry_t, S.dry_t)
    S.rain_day = num(s.rain_day, -1)
    S.aim = clamp(num(s.aim, 24), 0, 31)
    S.flow = clamp(num(s.flow, 2), 1, #FLOW)
  else -- 第一次：大片是绿的，有几块发黄
    for i = 1, N do HL[i] = 3 end
    for _ = 1, 4 do
      local px, py, r = rnd(GW), rnd(GH), 3 + rnd(4)
      for y = 0, GH - 1 do
        for x = 0, GW - 1 do
          local d2 = (x - px) * (x - px) + (y - py) * (y - py)
          if d2 <= r * r then
            local i = y * GW + x + 1
            HL[i] = math.min(HL[i], div(d2 * 3, r * r) + rnd(2) - 1 < 0 and 0 or div(d2 * 3, r * r))
          end
        end
      end
    end
  end
end
local function save()
  local hs, ws, ds = {}, {}, {}
  for i = 1, N do
    hs[i] = HL[i]
    ws[i] = string.format("%x", WV[i])
    ds[i] = clamp(S.day - WD[i], 0, 9)
  end
  save_kv(SAVE, { health = table.concat(hs), wet = table.concat(ws), wday = table.concat(ds),
                  day = S.day, dry_t = S.dry_t, rain_day = S.rain_day, aim = S.aim, flow = S.flow })
end

-- ---------- 画面 ----------
local function draw_dirty(budget)
  local n = #DIRTY
  local stop = (n > budget) and (n - budget) or 0
  for k = n, stop + 1, -1 do
    local i = DIRTY[k]
    DIRTY[k] = nil
    fg(PAL[HL[i] * 4 + level(i)])
    local y = div(i - 1, GW)
    rect((i - 1 - y * GW) * CELL, y * CELL, CELL, CELL)
  end
end
local function draw_head(x, y, a, light)
  fg(pack(tint(HEAD, light)))
  rect(x - 2, y - 2, 4, 4)
  rect(x + div(COS[a] * 5, 64) - 1, y + div(sin32(a) * 5, 64) - 1, 2, 2)
  for dy = -2, 2, 4 do for dx = -2, 2, 4 do mark_px(x + dx, y + dy) end end
  mark_px(x + div(COS[a] * 5, 64), y + div(sin32(a) * 5, 64))
end

-- ---------- 主循环 ----------
load()
light_start()
tick_time()
local L = light_at(now())
make_palette(L)
local light_min = L.min
local running = true
local frame = 0
local last_pos = -1

while running do
  for _, e in ipairs(poll()) do
    if e.k == "menu" and not e.rel then running = false
    elseif (e.k == "fwd" or e.k == "back") and not e.rel and last_pos < 0 then
      -- 读不到转盘位置时，退回数事件转喷头
      S.aim = mod(S.aim + ((e.k == "fwd") and 1 or -1), 32)
    elseif (e.k == "prev" or e.k == "next") and not e.rel then
      S.flow = clamp(S.flow + ((e.k == "next") and 1 or -1), 1, #FLOW)
      S.flow_until = rb.current_tick() + 2 * HZ
    elseif e.k == "play" and not e.rel and not e.rep then
      local ph = phase(L)
      if ph == "day" then S.manual = not S.manual
      elseif ph == "auto" then S.auto_off = not S.auto_off end
    end
  end

  if rb.wheel_status then
    local ok, p = pcall(rb.wheel_status)
    if ok and type(p) == "number" then
      last_pos = p
      if p >= 0 then S.aim = mod(WHEEL_ZERO + div(p, 3), 32) end
    end
  end

  -- 光每分钟更新一次；换了就慢慢重画整片草地
  if mod(frame, 250) == 0 then
    tick_time()
    L = light_at(now())
    if L.min ~= light_min then light_min = L.min; make_palette(L) end
  end
  local ph = phase(L)
  if ph ~= "day" then S.manual = false end
  if ph ~= "auto" then S.auto_off = false end
  local open = (ph == "auto" and not S.auto_off) or S.manual

  if open then
    local sp = wheel_speed(div(HZ, 5))
    for _ = 1, FLOW[S.flow] do
      if sp > 150 then spray(CX, CY, S.aim, 9 + rnd(7), 2, 1)   -- 快：远、散、薄
      else spray(CX, CY, S.aim, 5 + rnd(5), 1, 3) end            -- 慢：近、集中、透
    end
  end
  if ph == "auto" then -- 远处的洒水器自己转
    for _, h in ipairs(HEADS) do
      if mod(frame, 6) == 0 then h.a = mod(h.a + 1, 32) end
      if mod(frame, 2) == 0 then spray(h.x, h.y, h.a, 3 + rnd(h.r - 2), 1, 2) end
    end
  end
  move_drops()
  bird_step(S.aim, open)

  draw_dirty(220)
  -- 水点颜色跟着天色：黄昏是地平线的橘色，白天偏白
  local dc = (ph == "auto") and pack(mix(L.bot, { 255, 255, 255 }, 30, 100)) or pack(tint({ 225, 235, 245 }, L.land))
  fg(dc)
  for _, d in ipairs(drops) do rect(div(d.x, 16), div(d.y, 16), 2, 2) end
  draw_head(CX, CY, S.aim, L.land)
  for _, h in ipairs(HEADS) do draw_head(h.x, h.y, h.a, L.land) end
  if bird then
    fg(pack(BIRD))
    rect(bird.x, bird.y + 1, 4, 2)
    if mod(div(frame, 4), 2) == 0 or bird.vx == 0 then rect(bird.x + 1, bird.y, 1, 1) end
  end
  -- 换水量时，左上角亮 2 秒的刻度
  if S.flow_until > 0 then
    if rb.current_tick() < S.flow_until then
      for k = 1, #FLOW do
        fg((k <= S.flow) and dc or pack(tint(HEAD, L.land)))
        rect(3 + (k - 1) * 5, 11 - k * 2, 3, k * 2)
      end
    else
      S.flow_until = 0
      for x = 0, 28, CELL do for y = 0, 12, CELL do mark_px(x, y) end end
    end
  end
  rb.lcd_update()
  keep_light()

  frame = frame + 1
  if mod(frame, 1500) == 0 then save() end
  rb.sleep(div(HZ, 25))
end

save()
light_end()
