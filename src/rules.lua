-- 规则旋钮：一个生命游戏的宇宙，转盘转的是它的物理规则
-- 转盘：换规则   Select：收藏这个宇宙   长按 Select：在中间撒一把活格子
-- Play：看收藏（转盘翻，Select 把它搬回来）   Menu：退出

local SAVE = "slow_rules.txt"
local CELL = 4
local GW, GH = div(W, CELL), div(H, CELL) -- 44 × 33
local N = GW * GH
local MAX_FAV = 8
local BG_SECS = 300      -- 不在场时每 5 分钟走一代
local CATCHUP_MAX = 600  -- 打开时最多补 600 代（约两天）
local LIVE_PERIOD = div(HZ, 5)  -- 平时每秒 5 代
local TURN_PERIOD = div(HZ, 2)  -- 转盘刚动过：每秒 2 代
local TURN_HOLD = 2 * HZ        -- 转盘停住 2 秒后恢复

-- 按“相近”排好的规则表：相邻两条只差几个数字（在桌面上用汉明距离贪心排的）
local RULES = {
  "B3/S23", "B3/S023", "B37/S23", "B36/S23", "B38/S23", "B3/S1234", "B3/S12345",
  "B36/S125", "B368/S245", "B34/S456", "B34/S34", "B234/S", "B2/S", "B2/S0",
  "B3/S45678", "B3/S012345678", "B378/S235678", "B3678/S235678", "B4678/S35678",
  "B3678/S34678", "B35678/S5678", "B357/S1358", "B357/S238", "B1357/S02468",
  "B1357/S1357", "B45678/S2345",
}

local BG = rgb(14, 16, 22)
local BAND = { [0] = BG, rgb(235, 238, 215), rgb(110, 185, 165), rgb(45, 95, 110) }
local INK = rgb(150, 160, 170)
local HI = rgb(240, 200, 90)

-- ---------- 宇宙 ----------
-- A/A2：活 1 死 0（两份轮流用）；AGE：活了几代，封顶 99
local A, A2, AGE, SHOWN = {}, {}, {}, {}
local world = { rule = 1, t = now() } -- t：这个宇宙已经算到的时刻
local favs = {}                       -- { {rule=, t=, cells=字符串}, ... }
local rnd = Rng(rb.current_tick() + world.t)
local BORN, SURV = {}, {}

local function set_rule(r)
  world.rule = r
  for n = 0, 8 do BORN[n] = false; SURV[n] = false end
  local s = RULES[r]
  local b, sv = string.match(s, "^B(%d*)/S(%d*)$")
  for k = 1, #b do BORN[tonumber(string.sub(b, k, k))] = true end
  for k = 1, #sv do SURV[tonumber(string.sub(sv, k, k))] = true end
end

-- 存成字符串：每格一个字符，0 是死，1..9 是年龄（封顶 9）
local function encode()
  local p = {}
  for i = 1, N do local a = AGE[i]; if a > 9 then a = 9 end; p[i] = a end
  return table.concat(p)
end
local function decode(s)
  for i = 1, N do
    local a = num(string.sub(s or "", i, i), 0)
    AGE[i] = a
    A[i] = (a > 0) and 1 or 0
  end
end
local function seed(x0, y0, w, h, pct)
  for y = y0, y0 + h - 1 do
    for x = x0, x0 + w - 1 do
      local i = y * GW + x + 1
      if rnd(100) < pct then A[i] = 1; if AGE[i] == 0 then AGE[i] = 1 end end
    end
  end
end

-- ---------- 一代 ----------
local step, recent_clear, recent_check
do
local col, XL, XR, YU, YD = {}, {}, {}, {}, {}
for x = 0, GW - 1 do XL[x] = mod(x - 1, GW); XR[x] = mod(x + 1, GW) end
for y = 0, GH - 1 do YU[y] = mod(y - 1, GH) * GW + 1; YD[y] = mod(y + 1, GH) * GW + 1 end
local seen, seen_n, gen = {}, 0, 0
-- 走一代，返回这一代的指纹（活格子数和下标和），用来认出循环
step = function()
  local a, b = A, A2
  local cnt, sum = 0, 0
  for y = 0, GH - 1 do
    local up, me, dn = YU[y], y * GW + 1, YD[y]
    for x = 0, GW - 1 do col[x] = a[up + x] + a[me + x] + a[dn + x] end
    for x = 0, GW - 1 do
      local i = me + x
      local v = a[i]
      local n = col[XL[x]] + col[x] + col[XR[x]] - v
      if (v == 1 and SURV[n]) or (v == 0 and BORN[n]) then
        b[i] = 1
        cnt = cnt + 1; sum = sum + i
        local g = AGE[i]
        if g < 99 then AGE[i] = g + 1 end
      else
        b[i] = 0
        AGE[i] = 0
      end
    end
  end
  A, A2 = b, a
  gen = gen + 1
  return cnt .. ":" .. sum
end
recent_clear = function() seen, seen_n, gen = {}, 0, 0 end
-- 这个指纹以前见过的话，返回周期
recent_check = function(key)
  local g = seen[key]
  if g then return gen - g end
  seen[key] = gen
  seen_n = seen_n + 1
  if seen_n > 400 then seen, seen_n = {}, 0 end
  return nil
end
end

-- 补算从 world.t 到现在。返回还要补几代（分几帧补，每帧补一点，画面看得到它快进）
local function pending_gens()
  local n = div(now() - world.t, BG_SECS)
  if n <= 0 then return 0 end
  if n > CATCHUP_MAX then
    world.t = now() - CATCHUP_MAX * BG_SECS
    n = CATCHUP_MAX
  end
  return n
end

-- ---------- 画面 ----------
local function band(a)
  if a == 0 then return 0 elseif a == 1 then return 1 elseif a <= 5 then return 2 end
  return 3
end
local function paint()
  for i = 1, N do
    local bd = band(AGE[i])
    if SHOWN[i] ~= bd then
      SHOWN[i] = bd
      fg(BAND[bd])
      local k = i - 1
      local y = div(k, GW)
      rb.lcd_fillrect((k - y * GW) * CELL, y * CELL, CELL, CELL)
    end
  end
end
local function invalidate(x, y, w, h) -- 文字底下的格子下次重画
  for cy = div(y, CELL), clamp(div(y + h, CELL), 0, GH - 1) do
    for cx = div(x, CELL), clamp(div(x + w, CELL), 0, GW - 1) do SHOWN[cy * GW + cx + 1] = -1 end
  end
end
local label_w, label_h = 0, 0
local function draw_label(s, c)
  local w, h = text_size(s)
  if w < label_w then invalidate(2, 2, label_w, label_h); paint() end
  label_w, label_h = w, h
  text(2, 2, s, c, BG)
end

-- ---------- 存档 ----------
local function load()
  local s, found = load_kv(SAVE)
  set_rule(clamp(num(s.rule, 1), 1, #RULES))
  if found and s.cells then
    decode(s.cells)
    world.t = num(s.t, world.t)
  else
    for i = 1, N do A[i] = 0; AGE[i] = 0 end
    seed(0, 0, GW, GH, 35)
  end
  for k = 1, MAX_FAV do
    local v = s["fav" .. k]
    if v then
      local r, t, cells = string.match(v, "^(%d+),(%d+),(%d+)$")
      if r then favs[#favs + 1] = { rule = clamp(num(r, 1), 1, #RULES), t = num(t, 0), cells = cells } end
    end
  end
end
local function save()
  local out = { rule = world.rule, t = world.t, cells = encode() }
  for k, f in ipairs(favs) do out["fav" .. k] = f.rule .. "," .. f.t .. "," .. f.cells end
  save_kv(SAVE, out)
end

-- ---------- 主循环 ----------
load()
light_start()
for i = 1, N do A2[i] = 0; SHOWN[i] = -1 end
fg(BG); rect(0, 0, W, H)

local live = { rule = world.rule, t = world.t, cells = encode() } -- 看收藏时，主宇宙先存在这里
local viewing = 0      -- 0：主宇宙；k：正在看第 k 个收藏
local catch = pending_gens()
local settled = false  -- 补算时发现进入循环
local next_gen = rb.current_tick()
local turned_at = -TURN_HOLD
local msg, msg_until = nil, 0
local running = true
local frame = 0

-- 换到另一个宇宙：先把当前的写回去
local function stash()
  local rec = (viewing == 0) and live or favs[viewing]
  rec.rule, rec.t, rec.cells = world.rule, world.t, encode()
end
local function enter(k)
  viewing = k
  local rec = (k == 0) and live or favs[k]
  set_rule(rec.rule)
  world.t = rec.t
  decode(rec.cells)
  recent_clear()
  catch, settled = pending_gens(), false
end
local function say(s) msg, msg_until = s, rb.current_tick() + 2 * HZ end

while running do
  for _, e in ipairs(poll()) do
    local g = select_gesture(e)
    if e.k == "menu" and not e.rel then running = false
    elseif (e.k == "fwd" or e.k == "back") and not e.rel and catch == 0 then
      local d = (e.k == "fwd") and 1 or -1
      if viewing == 0 then
        set_rule(mod(world.rule - 1 + d, #RULES) + 1)
        turned_at = rb.current_tick()
      elseif #favs > 0 then
        stash()
        enter(mod(viewing - 1 + d, #favs) + 1)
      end
    elseif e.k == "play" and not e.rel and not e.rep then
      stash()
      if viewing == 0 then
        if #favs > 0 then enter(#favs) else say("no fav") end
      else
        enter(0)
      end
    elseif g == "short" then
      if viewing == 0 then
        if #favs >= MAX_FAV then table.remove(favs, 1) end
        favs[#favs + 1] = { rule = world.rule, t = now(), cells = encode() }
        save()
        say("fav " .. #favs)
      else -- 把这个收藏搬回主宇宙
        stash()
        live.rule, live.t, live.cells = world.rule, world.t, encode()
        enter(0)
        say("back")
      end
    elseif g == "long" then
      seed(div(GW, 2) - 4, div(GH, 2) - 4, 8, 8, 50)
    end
  end

  local tk = rb.current_tick()
  if catch > 0 then
    -- 快进补算：每帧算 4 代再画；进入循环就直接跳到结果
    for _ = 1, 4 do
      if catch <= 0 then break end
      local p = recent_check(step())
      catch = catch - 1
      world.t = world.t + BG_SECS
      if p and p > 0 then
        local skip = catch - mod(catch, p)
        world.t = world.t + skip * BG_SECS
        catch = catch - skip
        settled = true
      end
    end
    if catch == 0 then next_gen = tk end
  else
    local period = (tk - turned_at < TURN_HOLD) and TURN_PERIOD or LIVE_PERIOD
    if tk >= next_gen then
      step()
      world.t = now()
      next_gen = next_gen + period
      if next_gen < tk then next_gen = tk + period end
    end
  end

  paint()
  if msg and tk < msg_until then
    draw_label(msg, HI)
  else
    msg = nil
    local s = (viewing == 0) and string.format("%02d", world.rule) or ("F" .. viewing .. " " .. string.format("%02d", world.rule))
    if catch > 0 then s = s .. " +" .. catch elseif settled then s = s .. " loop" end
    draw_label(s, INK)
  end
  rb.lcd_update()
  keep_light()

  frame = frame + 1
  if mod(frame, 900) == 0 then stash(); save() end
  rb.sleep(div(HZ, 20))
end

stash()
if viewing ~= 0 then enter(0) end
save()
light_end()
