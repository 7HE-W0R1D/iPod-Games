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
