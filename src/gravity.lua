-- 旋转重力：一个装着沙、水和种子的小盒子，转盘转动重力的方向
-- 转盘：重力转 45 度   Select：从上游撒一把材料（沙、水、种子轮流）
-- 下一首：看活得最久的那株植物   Menu：退出

local SAVE = "slow_gravity.txt"
local CELL = 4
local GW, GH = div(W, CELL), div(H, CELL) -- 44 × 33
local PW = GW + 2                         -- 四周包一圈墙，省掉出界判断
local NP = PW * (GH + 2)
local EMPTY, SAND, WATER, STONE, SEED, PLANT, WALL = 0, 1, 2, 3, 4, 5, 9
local DIE_DAYS = 3        -- 没水的植物几天后枯成沙
local CHECK_FRAMES = 50   -- 每 50 帧（约 2 秒）数一次植物，顺便看有没有枯死

local COL = {
  [EMPTY] = rgb(20, 18, 26), [SAND] = rgb(212, 182, 112), [WATER] = rgb(66, 116, 200),
  [STONE] = rgb(110, 108, 116), [SEED] = rgb(150, 105, 60), [PLANT] = rgb(84, 162, 72),
}
local FRAME, HI, INK = rgb(60, 58, 72), rgb(240, 200, 90), rgb(170, 170, 180)

-- 8 个方向，顺时针，相邻两个差 45 度；0 是向下
local DX = { [0] = 0, -1, -1, -1, 0, 1, 1, 1 }
local DY = { [0] = 1, 1, 0, -1, -1, -1, 0, 1 }
local OFF = {}
for d = 0, 7 do OFF[d] = DY[d] * PW + DX[d] end

-- ---------- 状态 ----------
local G, ST, DIRTY = {}, {}, {}   -- 材料；这一帧动过的盖章；要重画的格子
local PDAY, PBORN = {}, {}        -- 植物：最后喝到水是哪天；哪天长出来
local S = { dir = 0, fid = 0, pick = 0, plants = 0, oldest = 0, best = 0, t = now() }
local ORDER = {}
local rnd = Rng(rb.current_tick() + S.t)
local function today() return div(now(), 86400) end
local function inside(p)
  local y = div(p, PW)
  local x = p - y * PW
  return x >= 1 and x <= GW and y >= 1 and y <= GH
end
local function set(p, m)
  G[p] = m
  DIRTY[#DIRTY + 1] = p
end

-- 换方向时排一次扫描顺序：沿重力方向的坐标从大到小（下游先算）
local function build_order()
  local gx, gy = DX[S.dir], DY[S.dir]
  local buckets, lo, hi = {}, 0, 0
  for y = 1, GH do
    for x = 1, GW do
      local k = x * gx + y * gy
      local b = buckets[k]
      if not b then b = {}; buckets[k] = b end
      b[#b + 1] = y * PW + x
      if k < lo then lo = k end
      if k > hi then hi = k end
    end
  end
  local n = 0
  for k = hi, lo, -1 do
    local b = buckets[k]
    if b then for j = 1, #b do n = n + 1; ORDER[n] = b[j] end end
  end
end

-- 附近 r 格内（由近到远）找一格水，返回它的下标。沙子是湿的：水不用紧挨着
local near_water
do
local NEAR = {}
for dy = -3, 3 do for dx = -3, 3 do
  if dx ~= 0 or dy ~= 0 then NEAR[#NEAR + 1] = { dy * PW + dx, math.max(iabs(dx), iabs(dy)), dx * dx + dy * dy } end
end end
table.sort(NEAR, function(a, b) return a[3] < b[3] end)
near_water = function(p, r)
  for k = 1, #NEAR do
    local n = NEAR[k]
    if n[2] <= r then
      local q = p + n[1]
      if q >= 0 and q < NP and G[q] == WATER then return q end
    end
  end
  return nil
end
end

-- ---------- 物理 ----------
local physics
do
local flip = false
local function mv(p, t) -- p 的东西去 t，t 的东西（空或水）回 p
  local a = G[t]
  G[t] = G[p]; G[p] = a
  ST[t] = S.fid; ST[p] = S.fid
  DIRTY[#DIRTY + 1] = p; DIRTY[#DIRTY + 1] = t
end
local function sprout(p) -- 种子停稳了、3 格内有水：吸掉一格水，变成植物，往重力反方向长一格
  local w = near_water(p, 3)
  if not w then return end
  local d = today()
  set(w, EMPTY)
  set(p, PLANT); PDAY[p] = d; PBORN[p] = d
  local up = p - OFF[S.dir]
  if G[up] == EMPTY then set(up, PLANT); PDAY[up] = d; PBORN[up] = d end
end
-- 走一帧，返回动了几格
physics = function()
  S.fid = S.fid + 1
  local fid = S.fid
  local D = OFF[S.dir]
  local L1, R1 = OFF[mod(S.dir + 7, 8)], OFF[mod(S.dir + 1, 8)]
  local L2, R2 = OFF[mod(S.dir + 6, 8)], OFF[mod(S.dir + 2, 8)]
  local moved = 0
  for k = 1, #ORDER do
    local p = ORDER[k]
    local m = G[p]
    if (m == SAND or m == WATER or m == SEED) and ST[p] ~= fid then
      local t = p + D
      local below = G[t]
      local a, b = L1, R1
      flip = not flip
      if flip then a, b = R1, L1 end
      if below == EMPTY or (below == WATER and m ~= WATER) then mv(p, t); moved = moved + 1
      elseif G[p + a] == EMPTY then mv(p, p + a); moved = moved + 1
      elseif G[p + b] == EMPTY then mv(p, p + b); moved = moved + 1
      elseif m == WATER then
        if flip then a, b = L2, R2 else a, b = R2, L2 end
        -- 水在平地上横着流不算“动”，不然一滴水就能让盒子永远醒着
        if G[p + a] == EMPTY then mv(p, p + a)
        elseif G[p + b] == EMPTY then mv(p, p + b) end
      elseif m == SEED then sprout(p) end
    end
  end
  return moved
end
end

-- 植物慢慢长：随便挑几格，是 2 格内有水的植物就有机会吸水、往上（重力反方向）长一格
local function grow(tries, chance)
  local d = today()
  local up = OFF[S.dir]
  for _ = 1, tries do
    local p = (rnd(GH) + 1) * PW + rnd(GW) + 1
    if G[p] == PLANT and rnd(chance) == 0 then
      local w = near_water(p, 2)
      if w then
        local t = p - up
        if G[t] ~= EMPTY then t = p - OFF[mod(S.dir + 7 + rnd(3), 8)] end -- 斜上方
        if G[t] == EMPTY then
          set(w, EMPTY)
          set(t, PLANT); PDAY[t] = d; PBORN[t] = PBORN[p] or d
        end
        PDAY[p] = d
      end
    end
  end
end

-- 查一遍植物：连在一起的算一株；整株只要有一格 2 格内有水就算喝到了；太久没水的枯成沙
local function check_plants()
  local d = today()
  local seen, stack = {}, {}
  local plants, oldest = 0, 0
  for y = 1, GH do
    for x = 1, GW do
      local p0 = y * PW + x
      if G[p0] == PLANT and not seen[p0] then
        local cells, wet, born = {}, false, d
        local sp = 1
        stack[1] = p0; seen[p0] = true
        while sp > 0 do
          local p = stack[sp]; sp = sp - 1
          cells[#cells + 1] = p
          if (PBORN[p] or d) < born then born = PBORN[p] end
          if not wet and near_water(p, 2) then wet = true end
          for _, o in ipairs({ 1, -1, PW, -PW }) do
            local q = p + o
            if G[q] == PLANT and not seen[q] then seen[q] = true; sp = sp + 1; stack[sp] = q end
          end
        end
        local last = 0
        for _, p in ipairs(cells) do
          if wet then PDAY[p] = d end
          if (PDAY[p] or 0) > last then last = PDAY[p] end
        end
        if d - last >= DIE_DAYS then
          for _, p in ipairs(cells) do set(p, SAND); PDAY[p] = nil; PBORN[p] = nil end
        else
          plants = plants + 1
          if d - born > oldest then oldest = d - born end
        end
      end
    end
  end
  S.plants, S.oldest = plants, oldest
  if oldest > S.best then S.best = oldest end
end

-- 从上游那条边撒一把
local function sprinkle()
  local kinds = { SAND, WATER, SEED }
  S.pick = mod(S.pick, 3) + 1
  local m = kinds[S.pick]
  local n = #ORDER
  local count = (m == SEED) and 3 or 8
  for _ = 1, 40 do
    if count <= 0 then break end
    local p = ORDER[n - rnd(60)]
    if G[p] == EMPTY then set(p, m); count = count - 1 end
  end
end

-- ---------- 存档 ----------
local function fresh()
  for y = 1, GH do
    for x = 1, GW do
      local p = y * PW + x
      G[p] = (y > GH - 7 - rnd(2)) and SAND or EMPTY
    end
  end
  for _ = 1, 4 do -- 几块石头
    local x0, y0 = rnd(GW - 4) + 1, rnd(GH - 10) + 8
    for y = y0, y0 + 1 + rnd(2) do for x = x0, x0 + 1 + rnd(3) do G[y * PW + x] = STONE end end
  end
  for x = 14, 30 do for y = 6, 9 do G[y * PW + x] = WATER end end
  for k = 1, 5 do G[2 * PW + k * 7] = SEED end
end
local function load()
  for p = 0, NP - 1 do G[p] = WALL; ST[p] = 0 end
  local s, found = load_kv(SAVE)
  if not found or not s.grid then fresh(); return end
  local g = s.grid
  local k = 0
  for y = 1, GH do
    for x = 1, GW do
      k = k + 1
      G[y * PW + x] = num(string.sub(g, k, k), EMPTY)
    end
  end
  S.dir = clamp(num(s.dir, 0), 0, 7)
  S.best = num(s.best, 0)
  S.t = num(s.t, S.t)
  for ps, a, b in string.gmatch(s.plants or "", "(%d+):(%d+):(%d+)") do
    local p = num(ps, 0)
    if G[p] == PLANT then PDAY[p] = num(a, 0); PBORN[p] = num(b, 0) end
  end
end
local function save()
  local g, pl = {}, {}
  for y = 1, GH do
    for x = 1, GW do
      local p = y * PW + x
      g[#g + 1] = G[p]
      if G[p] == PLANT then pl[#pl + 1] = p .. ":" .. (PDAY[p] or 0) .. ":" .. (PBORN[p] or 0) end
    end
  end
  save_kv(SAVE, { grid = table.concat(g), dir = S.dir, best = S.best, t = now(), plants = table.concat(pl, ";") })
end

-- ---------- 画面 ----------
local function draw_cell(p)
  local y = div(p, PW)
  fg(COL[G[p]] or FRAME)
  rect((p - y * PW - 1) * CELL, (y - 1) * CELL, CELL, CELL)
end
local function cells_under(x, y, w, h) -- 屏幕上一块区域盖住的格子，标成要重画
  for cy = div(y, CELL), clamp(div(y + h, CELL), 0, GH - 1) do
    for cx = div(x, CELL), clamp(div(x + w, CELL), 0, GW - 1) do DIRTY[#DIRTY + 1] = (cy + 1) * PW + cx + 1 end
  end
end
local mark_x, mark_y, label_w, label_h = 0, 0, 0, 0
local function draw_overlay(label)
  fg(FRAME)
  rect(0, 0, W, 1); rect(0, H - 1, W, 1); rect(0, 0, 1, H); rect(W - 1, 0, 1, H)
  -- 重力方向：框上一个小方块
  local mx = div(W, 2) + DX[S.dir] * (div(W, 2) - 4) - 3
  local my = div(H, 2) + DY[S.dir] * (div(H, 2) - 4) - 3
  if mx ~= mark_x or my ~= mark_y then cells_under(mark_x, mark_y, 6, 6); mark_x, mark_y = mx, my end
  fg(HI); rect(mx, my, 6, 6)
  local w, h = text_size(label)
  if w < label_w then cells_under(3, 3, label_w, label_h) end
  label_w, label_h = w, h
  text(3, 3, label, INK, COL[EMPTY])
end

-- ---------- 主循环 ----------
load()
light_start()
build_order()
-- 不在场的时候：植物按时间长（最多补 60 次），然后查一遍有没有枯死
do
  local steps = clamp(div(now() - S.t, 600), 0, 60)
  for _ = 1, steps do grow(400, 1) end
end
check_plants()
DIRTY = {}
for y = 1, GH do for x = 1, GW do draw_cell(y * PW + x) end end

local running = true
local frame, idle, still_since = 0, 0, rb.current_tick()
local msg, msg_until = nil, 0

while running do
  for _, e in ipairs(poll()) do
    if e.k == "menu" and not e.rel then running = false
    elseif (e.k == "fwd" or e.k == "back") and not e.rel then
      S.dir = mod(S.dir + ((e.k == "fwd") and 1 or -1), 8)
      build_order()
      idle = 0
    elseif e.k == "next" and not e.rel and not e.rep then
      msg, msg_until = "best " .. S.best .. "d", rb.current_tick() + 2 * HZ
    elseif select_gesture(e) == "short" then
      sprinkle(); idle = 0
    end
  end

  -- 静下来以后少算：每 8 帧才扫一次
  local moved = 0
  if idle < 3 or mod(frame, 8) == 0 then
    moved = physics()
    if moved > 0 then idle = 0; still_since = rb.current_tick() else idle = idle + 1 end
  end
  grow(20, 4)

  -- 静止超过一分钟：随便推一粒沙
  if rb.current_tick() - still_since > 60 * HZ then
    still_since = rb.current_tick()
    for _ = 1, 30 do
      local p = (rnd(GH) + 1) * PW + rnd(GW) + 1
      local t = p + OFF[mod(S.dir + 1 + rnd(2) * 6, 8)]
      if G[p] == SAND and G[t] == EMPTY then set(p, EMPTY); set(t, SAND); idle = 0; break end
    end
  end

  if mod(frame, CHECK_FRAMES) == 0 then check_plants() end

  -- 只画动过的格子；一帧最多画 250 个，剩下的下一帧画
  local n = #DIRTY
  local stop = (n > 250) and (n - 250) or 0
  for k = n, stop + 1, -1 do
    local p = DIRTY[k]
    DIRTY[k] = nil
    if inside(p) then draw_cell(p) end
  end
  local label = tostring(S.plants)
  if msg and rb.current_tick() < msg_until then label = msg else msg = nil end
  draw_overlay(label)
  rb.lcd_update()
  keep_light()

  frame = frame + 1
  if mod(frame, 900) == 0 then save() end
  rb.sleep(div(HZ, 25))
end

save()
light_end()
