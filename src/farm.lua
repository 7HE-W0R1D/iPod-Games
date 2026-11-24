-- 小农场：5×3 块地，作物按真实时间生长。萝卜几个小时，麦子一天，南瓜几天，果树几周，一共 9 种作物。
-- 转盘：光标在 15 块地之间按蛇形移动   Select：做这块地“下一件该做的事”（拔草、翻地、播种、浇水、收获）
-- Play：种子袋（转盘选，Select 定）   Menu：退出   长按 Menu：说明
-- 不来的时候也在长：下雨自己湿，晴天慢慢干；熟了没收会落种自己发芽；杂草慢慢蔓延；乌鸦偶尔来叼一颗。
-- 相邻两种作物开花时蜜蜂传粉，收下的种子偶尔是颜色介于两者之间的新品种。
-- 偶尔有小动物路过：兔子（会啃熟了的矮作物）、雨天的青蛙、夜里的刺猬、花间的蝴蝶。
-- 没见过的作物不靠买：路过的动物偶尔带来一粒种子，或者被风吹来，在空地上自己发芽。

local SAVE = "slow_farm.txt"
local COLS, ROWS, PS = 5, 3, 32     -- 15 块地，每块 32×32
local NP = COLS * ROWS
local FX, FY = 8, 14                -- 田的左上角

-- 作物：名字、长熟要几分钟、原种颜色；keep = 收了还会再结（只回到开花）；low = 矮的，兔子够得着
-- 编号进了存档，只能往后加
local CROPS = {
  { name = "radish", grow = 240, col = { 225, 70, 95 }, low = true },
  { name = "wheat", grow = 1440, col = { 225, 190, 90 } },
  { name = "pumpkin", grow = 5760, col = { 235, 130, 40 } },
  { name = "apple", grow = 30240, col = { 215, 45, 50 }, keep = true },
  { name = "carrot", grow = 480, col = { 240, 130, 40 }, low = true },
  { name = "tomato", grow = 2880, col = { 230, 55, 45 }, keep = true },
  { name = "corn", grow = 4320, col = { 240, 205, 70 } },
  { name = "sunflower", grow = 7200, col = { 250, 200, 40 } },
  { name = "strawberry", grow = 2880, col = { 225, 40, 70 }, keep = true, low = true },
}
-- 地块种类
local WILD, WEEDS, SOIL, CROP = 1, 2, 3, 4

-- ---------- 状态 ----------
local P = {}                        -- 15 块地：{ k, c, col, g, w, o, wd }
local S = { last = 0, cur = 1, sel = "", msg = "", msg_t = 0 }
local BAG = {}                      -- 种子袋：key → { c, col, n }
local BARN = {}                     -- 每种作物收过多少
for c = 1, #CROPS do BARN[c] = 0 end
local VAR = {}                      -- 见过的品种
local crow = nil                    -- 落在篱笆上的乌鸦：{ i, leave }
local rnd = Rng(rb.current_tick() + now())

local function vkey(c, col) return c .. ":" .. div(col[1], 24) .. ":" .. div(col[2], 24) .. ":" .. div(col[3], 24) end
local function is_base(c, col) return vkey(c, col) == vkey(c, CROPS[c].col) end
local function stage(p) -- 0 种子 1 芽 2 长大 3 开花 4 成熟
  if p.k ~= CROP then return -1 end
  local gr = CROPS[p.c].grow
  if p.g >= gr then return 4 end
  return div(p.g * 4, gr)
end
local function neighbours(i) -- 上下左右
  local x, y = mod(i - 1, COLS), div(i - 1, COLS)
  local t = {}
  if x > 0 then t[#t + 1] = i - 1 end
  if x < COLS - 1 then t[#t + 1] = i + 1 end
  if y > 0 then t[#t + 1] = i - COLS end
  if y < ROWS - 1 then t[#t + 1] = i + COLS end
  return t
end
local function add_seed(c, col, n)
  local key = vkey(c, col)
  local b = BAG[key]
  if not b then b = { c = c, col = { col[1], col[2], col[3] }, n = 0 }; BAG[key] = b end
  b.n = b.n + n
  if not VAR[key] then VAR[key] = true; return not is_base(c, col) end
  return false
end
local function plant(i, c, col)
  local p = P[i]
  p.k, p.c, p.col, p.g, p.o, p.wd = CROP, c, { col[1], col[2], col[3] }, 0, 0, false
end

-- ---------- 一小时 ----------
local weather
do
local WCACHE = {}
weather = function(day)
  if not WCACHE[day] then WCACHE[day] = weather_of(day) end
  return WCACHE[day]
end
end

local function eat_one(i) -- 乌鸦叼走 / 兔子啃掉一颗
  local p = P[i]
  if CROPS[p.c].keep then p.g = div(CROPS[p.c].grow * 3, 4); p.o = 0
  else p.k, p.c = SOIL, 0 end
end

-- 一粒外来的种子落在空地上自己发芽：优先是还没见过的作物。返回地块，没有空地就是 nil
local function wild_seed()
  local spots, unseen = {}, {}
  for i = 1, NP do if P[i].k == WILD or P[i].k == SOIL then spots[#spots + 1] = i end end
  if #spots == 0 then return nil end
  for c = 1, #CROPS do
    local seen = BARN[c] > 0
    for key in pairs(VAR) do if string.match(key, "^(%d+):") == tostring(c) then seen = true end end
    if not seen then unseen[#unseen + 1] = c end
  end
  local c = #unseen > 0 and unseen[rnd(#unseen) + 1] or rnd(#CROPS) + 1
  local i = spots[rnd(#spots) + 1]
  plant(i, c, CROPS[c].col)
  return i
end

local catch_up
do
local MAX_CATCHUP = 60 * 24 -- 最多补算 60 天（按小时）
local function hour(t)
  local w = weather(div(t, 86400))
  local ripe = {}
  for i = 1, NP do
    local p = P[i]
    if w.rainy then p.w = 100 else p.w = math.max(0, p.w - 4) end
    if p.k == CROP then
      local st = stage(p)
      if st == 4 then
        p.o = p.o + 1
        ripe[#ripe + 1] = i
        -- 熟过头一天：落下种子，自己和旁边的空地上自己发芽
        local keep = CROPS[p.c].keep
        if p.o >= (keep and 72 or 24) then
          for _, j in ipairs(neighbours(i)) do
            local q = P[j]
            if (q.k == SOIL or q.k == WILD) and rnd(keep and 6 or 3) == 0 then plant(j, p.c, p.col) end
          end
          if keep then p.g, p.o = div(CROPS[p.c].grow * 3, 4), 0
          else plant(i, p.c, p.col) end
        end
      elseif p.w > 0 and not p.wd then
        p.g = p.g + 60
      end
    end
    -- 杂草：从长草的地块慢慢蔓延（平均几天多一块）；荒地偶尔自己长草
    if p.k == WEEDS or (p.k == CROP and p.wd) then
      for _, j in ipairs(neighbours(i)) do
        local q = P[j]
        if rnd(160) == 0 then
          if q.k == WILD or q.k == SOIL then q.k = WEEDS elseif q.k == CROP then q.wd = true end
        end
      end
    elseif p.k == WILD and rnd(500) == 0 then p.k = WEEDS end
  end
  -- 没人看着的时候，乌鸦偶尔叼走一颗；偶尔有一粒种子被风吹来（平均四天一次）
  if #ripe > 0 and rnd(48) == 0 then eat_one(ripe[rnd(#ripe) + 1]) end
  if rnd(96) == 0 then wild_seed() end
end

-- 补算：从上次到现在，按整小时一步步走
catch_up = function(t)
  local hours = div(t - S.last, 3600)
  if hours <= 0 then return 0 end
  if hours > MAX_CATCHUP then S.last = t - MAX_CATCHUP * 3600; hours = MAX_CATCHUP end
  for h = 1, hours do hour(S.last + h * 3600) end
  S.last = S.last + hours * 3600
  return hours
end
end

-- ---------- 存档 ----------
local save, load
do
local function cstr(col) return col[1] .. "." .. col[2] .. "." .. col[3] end
local function cparse(s)
  local r, g, b = string.match(s or "", "(%d+)%.(%d+)%.(%d+)")
  if not r then return { 128, 128, 128 } end
  return { tonumber(r), tonumber(g), tonumber(b) }
end

save = function()
  local ps, bs, vs = {}, {}, {}
  for i = 1, NP do
    local p = P[i]
    ps[i] = table.concat({ p.k, p.c, cstr(p.col), p.g, p.w, p.o, p.wd and 1 or 0 }, ",")
  end
  for _, b in pairs(BAG) do if b.n > 0 then bs[#bs + 1] = b.c .. "," .. cstr(b.col) .. "," .. b.n end end
  for key in pairs(VAR) do vs[#vs + 1] = key end
  save_kv(SAVE, { last = S.last, cur = S.cur, sel = S.sel, plots = table.concat(ps, ";"),
                  bag = table.concat(bs, ";"), barn = table.concat(BARN, ","), vars = table.concat(vs, ";") })
end

load = function()
  local s, ok = load_kv(SAVE)
  for i = 1, NP do P[i] = { k = WILD, c = 0, col = { 0, 0, 0 }, g = 0, w = 30, o = 0, wd = false } end
  if not ok or not s.plots then
    -- 第一次：几粒种子起步
    add_seed(1, CROPS[1].col, 3); add_seed(2, CROPS[2].col, 2); add_seed(3, CROPS[3].col, 1); add_seed(4, CROPS[4].col, 1)
    S.last, S.sel = now(), vkey(1, CROPS[1].col)
    return
  end
  local i = 0
  for part in string.gmatch(s.plots, "[^;]+") do
    i = i + 1
    local k, c, col, g, w, o, wd = string.match(part, "^(%d+),(%d+),([%d%.]+),(%d+),(%d+),(%d+),(%d)$")
    if k and i <= NP then
      P[i] = { k = tonumber(k), c = tonumber(c), col = cparse(col), g = tonumber(g), w = tonumber(w),
               o = tonumber(o), wd = wd == "1" }
      if P[i].k == CROP and not CROPS[P[i].c] then P[i].k = SOIL end
    end
  end
  for part in string.gmatch(s.bag or "", "[^;]+") do
    local c, col, n = string.match(part, "^(%d+),([%d%.]+),(%d+)$")
    if c and CROPS[tonumber(c)] then
      local key = vkey(tonumber(c), cparse(col))
      BAG[key] = { c = tonumber(c), col = cparse(col), n = tonumber(n) }
    end
  end
  local k = 1
  for v in string.gmatch(s.barn or "", "%d+") do BARN[k] = tonumber(v); k = k + 1 end
  for key in string.gmatch(s.vars or "", "[^;]+") do VAR[key] = true end
  S.last, S.cur, S.sel = num(s.last, now()), clamp(num(s.cur, 1), 1, NP), s.sel or ""
end
end

-- ---------- 一键操作 ----------
local function selected_seed()
  local b = BAG[S.sel]
  if b and b.n > 0 then return b end
  for key, x in pairs(BAG) do if x.n > 0 then S.sel = key; return x end end
  return nil
end

-- 这块地下一件该做的事：返回 动作名, 说明
local function next_job(i)
  local p = P[i]
  if crow and crow.i == i then return "shoo", "shoo the crow" end
  if p.k == WEEDS then return "pull", "pull weeds" end
  if p.k == WILD then return "till", "till" end
  if p.k == SOIL then
    local b = selected_seed()
    if b then return "plant", "plant " .. CROPS[b.c].name end
    return "none", "no seeds left"
  end
  if p.wd then return "pull", "pull weeds" end
  if stage(p) == 4 then return "harvest", "harvest" end
  if p.w < 50 then return "water", "water" end
  return "none", "let it grow"
end

local function say(s) S.msg, S.msg_t = s, rb.current_tick() + 3 * HZ end

local do_job
do
local function harvest(i)
  local p = P[i]
  local c = p.c
  BARN[c] = BARN[c] + 1
  -- 蜜蜂：相邻的另一种作物正开花或熟着，种子偶尔是混合品种
  local col = p.col
  local mate
  for _, j in ipairs(neighbours(i)) do
    local q = P[j]
    if q.k == CROP and q.c ~= c and stage(q) >= 3 then mate = q end
  end
  local new = false
  local seeds = CROPS[c].keep and rnd(2) or 1 + rnd(3)
  for _ = 1, seeds do
    if mate and rnd(4) == 0 then
      local mc = mix(col, mate.col, 1, 2)
      mc = { clamp(mc[1] + rnd(21) - 10, 0, 255), clamp(mc[2] + rnd(21) - 10, 0, 255), clamp(mc[3] + rnd(21) - 10, 0, 255) }
      if add_seed(c, mc, 1) then new = true end
    else add_seed(c, col, 1) end
  end
  if CROPS[c].keep then p.g, p.o = div(CROPS[c].grow * 3, 4), 0 else p.k, p.c = SOIL, 0 end
  say(new and ("a new " .. CROPS[c].name .. "!") or ("+1 " .. CROPS[c].name))
end

do_job = function(i)
  local job = next_job(i)
  local p = P[i]
  if job == "shoo" then crow = nil; say("the crow flies off")
  elseif job == "pull" then
    if p.k == WEEDS then p.k = WILD else p.wd = false end
    say("weeds pulled")
  elseif job == "till" then p.k = SOIL; say("tilled")
  elseif job == "plant" then
    local b = selected_seed()
    b.n = b.n - 1
    plant(i, b.c, b.col)
    say("planted")
  elseif job == "water" then p.w = 100; say("watered")
  elseif job == "harvest" then harvest(i)
  else
    if p.k == CROP and p.w < 100 then p.w = 100; say("watered") end
  end
end
end

-- ---------- 小动物 ----------
-- 一次最多一只，只在你看着的时候路过
local critter -- { kind, x, y, dir, t, hop, run, ate }
local function plot_at(x, y)
  local cx, cy = div(x - FX, PS), div(y - FY, PS)
  if x < FX or y < FY or cx >= COLS or cy >= ROWS then return nil end
  return cy * COLS + cx + 1
end
local critter_step, critter_spawn
do
local function low_ripe(i) local p = P[i]; return p.k == CROP and CROPS[p.c].low and stage(p) == 4 end
-- 每 10 秒问一次：雨天青蛙，夜里刺猬，白天兔子，有花开时蝴蝶
critter_spawn = function(L, w)
  if critter then return end
  local kind
  if w.rainy then if rnd(40) == 0 then kind = "frog" end
  elseif L.night then if rnd(180) == 0 then kind = "hedgehog" end
  else
    local bloom = false
    for i = 1, NP do if stage(P[i]) == 3 then bloom = true end end
    if bloom and rnd(60) == 0 then kind = "butterfly" elseif rnd(240) == 0 then kind = "rabbit" end
  end
  if not kind then return end
  local dir = rnd(2) == 0 and 1 or -1
  critter = { kind = kind, x = dir > 0 and FX or FX + COLS * PS - 9, y = FY + rnd(ROWS) * PS + 12 + rnd(12),
              dir = dir, t = 0, hop = 0, run = false, ate = {} }
end
-- 每 0.3 秒走一步；有事发生就返回一句话
critter_step = function()
  local a = critter
  if not a then return nil end
  a.t = a.t + 1
  local msg
  local i = plot_at(a.x + 4, a.y + 3)
  if a.kind == "rabbit" then
    if i == S.cur then a.run = true end -- 光标过来就跑
    a.hop = mod(a.t, 2) == 0 and 2 or 0
    if a.hop > 0 then a.x = a.x + a.dir * (a.run and 7 or 3) end
    -- 路过熟了的矮作物，偶尔啃掉一颗
    if i and not a.run and not a.ate[i] and low_ripe(i) then
      a.ate[i] = true
      if rnd(3) == 0 then eat_one(i); msg = "a rabbit nibbled one" end
    end
  elseif a.kind == "frog" then
    a.hop = mod(a.t, 4) == 0 and 3 or 0
    if a.hop > 0 then a.x = a.x + a.dir * 6 end
  elseif a.kind == "hedgehog" then a.x = a.x + a.dir
  else -- 蝴蝶：忽上忽下
    a.x = a.x + a.dir * 2
    a.y = clamp(a.y + rnd(5) - 2, FY + 4, FY + ROWS * PS - 6)
  end
  if a.x < FX or a.x > FX + COLS * PS - 9 then
    -- 走出田：兔子和刺猬身上偶尔沾着一粒种子
    if (a.kind == "rabbit" or a.kind == "hedgehog") and rnd(4) == 0 and wild_seed() then msg = "something left a seed" end
    critter = nil
  end
  return msg
end
end

-- ---------- 画面 ----------
-- 伪 3D：一块有厚度的草地板子，棋盘格草坪上放着凸起的苗床（顶面、侧面、深色描边、地上一道影子）。
-- 作物都由小方块拼成，统一描一圈深色边：先把所有方块的描边画完，再画填色，相邻方块的边就连成一个轮廓。
local draw_all, draw_bag
do
local D = { BAR = 114, TOP = 11, shown = {}, land = { 256, 256, 256 }, sh = {}, pen = { 0, 0, 0 } }
local K = { -- 颜色（画的时候都按当前的光 tint 一下）
  BG = { 190, 232, 124 }, BG2 = { 168, 216, 106 }, OUT = { 58, 40, 54 },
  LAWN1 = { 124, 208, 98 }, LAWN2 = { 96, 182, 88 }, TUFT = { 176, 236, 126 }, SHADE = { 76, 146, 78 },
  SIDE = { 86, 156, 80 }, UNDER = { 156, 82, 96 },
  WOOD = { 232, 174, 104 }, WOODS = { 198, 128, 74 }, WOODD = { 160, 96, 60 },
  SOIL = { 128, 80, 58 }, SOILW = { 94, 58, 48 }, SOILD = { 104, 64, 50 },
  LEAF = { 112, 210, 92 }, LEAF2 = { 60, 164, 82 }, LEAF3 = { 176, 238, 124 }, STEM = { 138, 104, 70 },
  BLOOM = { 255, 248, 228 }, YEL = { 255, 218, 72 }, PINK = { 255, 196, 214 },
  WEED = { 64, 142, 76 }, WEED2 = { 104, 188, 90 },
  CRIT = { -- 小动物的小像素图（朝右）
    rabbit = { c = { 215, 205, 190 }, "......#.", ".....##.", "..#####.", ".######.", "######..", ".#...#.." },
    frog = { c = { 190, 235, 90 }, "#....#", ".####.", "######", "#....#" },
    hedgehog = { c = { 235, 205, 165 }, ".#####..", "#######.", "########", ".#...#.." },
    butterfly = { c = { 245, 190, 220 }, "#...#", "##.##", ".#.#." },
  },
}
local function lit(c) return pack(tint(c, D.land)) end

-- 描边方块：P 选颜色，R 记一块，flush 一起画（先描边、后填色）；RH 是不描边的高光
D.P = function(c) D.pen = c end
D.R = function(x, y, w, h) if w > 0 and h > 0 then D.sh[#D.sh + 1] = { x, y, w, h, D.pen } end end
D.RH = function(x, y, w, h) D.sh[#D.sh + 1] = { x, y, w, h, D.pen, true } end
D.flush = function()
  local sh = D.sh
  fg(lit(K.OUT))
  for _, s in ipairs(sh) do if not s[6] then rect(s[1] - 1, s[2] - 1, s[3] + 2, s[4] + 2) end end
  local last
  for _, s in ipairs(sh) do
    if s[5] ~= last then last = s[5]; fg(lit(last)) end
    rect(s[1], s[2], s[3], s[4])
  end
  D.sh = {}
end

-- 还要多久
D.eta = function(p)
  if p.w <= 0 then return "dry" end
  if p.wd then return "weedy" end
  local left = CROPS[p.c].grow - p.g
  if left <= 0 then return "ripe" end
  if left < 60 then return "ripe soon" end
  if left < 2880 then return "ripe in " .. div(left + 59, 60) .. "h" end
  return "ripe in " .. div(left + 1439, 1440) .. "d"
end
D.new_vars = function()
  local n = 0
  for key in pairs(VAR) do
    local c = tonumber(string.match(key, "^(%d+)"))
    if c and key ~= vkey(c, CROPS[c].col) then n = n + 1 end
  end
  return n
end
D.seen = function(c)
  if BARN[c] > 0 then return true end
  for key in pairs(VAR) do if string.match(key, "^(%d+):") == tostring(c) then return true end end
  return false
end

-- ---------- 地面 ----------
D.lawn = function(x, y, i)
  local odd = mod(mod(i - 1, COLS) + div(i - 1, COLS), 2) == 1
  fg(lit(odd and K.LAWN2 or K.LAWN1)); rect(x, y, PS, PS)
end
D.tufts = function(x, y, i, n)
  local r = Rng(i * 7 + 3)
  fg(lit(K.TUFT))
  for _ = 1, n do
    local tx, ty = x + 3 + r(PS - 8), y + 3 + r(PS - 8)
    rect(tx, ty + 1, 1, 2); rect(tx + 2, ty, 1, 3); rect(tx + 4, ty + 1, 1, 2)
  end
end
-- 长满杂草：几丛描边的灌木
D.weeds = function(x, y, i)
  local r = Rng(i * 13 + 5)
  local P, R = D.P, D.R
  for _ = 1, 4 do
    local bx, by = x + 3 + r(PS - 14), y + 4 + r(PS - 14)
    P(K.WEED); R(bx, by + 2, 10, 6); R(bx + 2, by, 6, 9)
    P(K.WEED2); D.RH(bx + 2, by + 1, 2, 2); D.RH(bx + 6, by + 3, 2, 1)
  end
  D.flush()
end
-- 木头种植箱：浅色的箱沿、里面一层土、正面是带接缝的木板，地上一道影子
D.bed = function(x, y, p, i)
  local wet = p.w > 40
  fg(lit(K.SHADE)); rect(x + 4, y + 30, 26, 2)
  fg(lit(K.OUT)); rect(x + 3, y + 9, 26, 22); rect(x + 2, y + 10, 28, 20)
  fg(lit(K.WOOD)); rect(x + 3, y + 10, 26, 13)
  fg(lit(wet and K.SOILW or K.SOIL)); rect(x + 5, y + 12, 22, 9)
  fg(lit(K.SOILD)); rect(x + 5, y + 12, 22, 1)
  local r = Rng(i * 5 + 1)
  for _ = 1, 4 do rect(x + 6 + r(19), y + 14 + r(6), 2, 1) end
  fg(lit(K.WOODS)); rect(x + 3, y + 23, 26, 7)
  fg(lit(K.WOODD)); rect(x + 3, y + 23, 26, 1)
  for k = 1, 3 do rect(x + 3 + k * 7, y + 24, 1, 6) end -- 木板接缝
  fg(lit({ 250, 206, 140 })); rect(x + 4, y + 10, 24, 1)  -- 箱沿的高光
end

-- ---------- 作物 ----------
-- 地面线 g：苗床顶面中间。所有作物都画在自己这一格（32×32）里面，不越界。
D.low = function(x, y, g, c, st, col) -- 萝卜、胡萝卜、草莓
  local P, R, RH = D.P, D.R, D.RH
  if c == 1 then -- 萝卜：三个圆圆的红头半埋在土里，顶上一对叶子
    for k = 0, 2 do
      local cx, by = x + 9 + k * 7, g + 2
      local s = ({ 2, 3, 4, 4 })[st]
      if st == 4 then P(col); R(cx - 2, by - 2, 5, 3) end
      P(K.LEAF); R(cx - s, by - s - 2, s, s); R(cx + 1, by - s - 2, s, s)
      P(K.LEAF2); R(cx, by - 3, 1, 2)
      if st == 3 then P(K.BLOOM); R(cx, by - s - 5, 1, 2) end
      if st == 4 then P(K.BLOOM); RH(cx - 1, by - 2, 1, 1) end
    end
  elseif c == 5 then -- 胡萝卜：一整丛羽毛一样的叶子，熟了露出三个橙色的头
    local s = ({ 3, 5, 7, 8 })[st]
    if st == 4 then P(col); R(x + 8, g + 1, 3, 2); R(x + 15, g + 2, 3, 2); R(x + 22, g + 1, 3, 2) end
    P(K.LEAF2); R(x + 6, g - s + 2, 20, s - 1)
    P(K.LEAF); R(x + 8, g - s, 16, s - 2)
    P(K.LEAF3); for k = 0, 4 do RH(x + 9 + k * 3, g - s + 1 + mod(k, 2), 1, 1) end
    if st == 3 then P(K.BLOOM); R(x + 10, g - s - 1, 3, 1); R(x + 19, g - s - 1, 3, 1) end
  else -- 草莓：贴地的一片三出叶，熟了的果子垂在箱子前沿上
    local s = ({ 1, 2, 3, 3 })[st]
    P(K.LEAF2); R(x + 6, g - 1, 20, 3)
    P(K.LEAF)
    for k = 0, 2 do
      local cx = x + 9 + k * 7
      R(cx - s, g - 2 - s, s, s); R(cx + 1, g - 2 - s, s, s); R(cx - 1, g - 3 - s, 2, s)
    end
    if st == 3 then P(K.BLOOM); R(x + 11, g - 1, 2, 2); R(x + 19, g - 2, 2, 2) end
    if st == 4 then
      P(col); R(x + 8, y + 22, 3, 4); R(x + 16, y + 23, 3, 4); R(x + 23, y + 22, 3, 3)
      P(K.LEAF2); RH(x + 8, y + 22, 3, 1); RH(x + 16, y + 23, 3, 1); RH(x + 23, y + 22, 3, 1)
      P(K.YEL); RH(x + 9, y + 24, 1, 1); RH(x + 17, y + 25, 1, 1)
    end
  end
end

D.tall = function(x, y, g, c, st, col) -- 麦子、番茄、玉米、向日葵、南瓜、苹果树
  local P, R, RH = D.P, D.R, D.RH
  if c == 2 then -- 麦子：一整片麦浪，顶上一排麦穗
    local h = ({ 3, 6, 9, 10 })[st]
    P(st == 4 and mix(col, K.STEM, 1, 4) or K.LEAF); R(x + 5, g - h + 2, 22, h)
    P(st == 4 and mix(col, K.STEM, 1, 2) or K.LEAF2); for k = 0, 6 do RH(x + 6 + k * 3, g - h + 4, 1, h - 3) end
    if st >= 3 then
      P(st == 4 and mix(col, { 255, 255, 255 }, 1, 4) or { 206, 222, 150 })
      for k = 0, 6 do R(x + 5 + k * 3, g - h - 1 - mod(k, 2), 2, 3) end
    end
  elseif c == 6 then -- 番茄：一丛圆圆的，套着铁丝笼
    local h = ({ 4, 8, 11, 12 })[st]
    local cx = x + 16
    P(K.LEAF2); R(cx - 6, g - h + 2, 13, h - 1)
    P(K.LEAF); R(cx - 5, g - h, 11, h - 3)
    P(K.LEAF3); RH(cx - 3, g - h + 1, 2, 1)
    if st == 3 then P(K.YEL); R(cx - 3, g - h + 4, 1, 1); R(cx + 3, g - h + 6, 1, 1) end
    if st == 4 then
      P(col); R(cx - 5, g - h + 3, 3, 3); R(cx + 2, g - h + 2, 3, 3); R(cx - 1, g - h + 6, 3, 3); R(cx + 3, g - h + 7, 3, 3)
      P(K.BLOOM); RH(cx - 4, g - h + 3, 1, 1); RH(cx + 3, g - h + 2, 1, 1)
    end
    P({ 214, 220, 230 }); RH(cx - 8, g - h + 2, 1, h); RH(cx + 8, g - h + 2, 1, h)
    RH(cx - 8, g - h + 2, 17, 1); RH(cx - 8, g - 1, 17, 1)
  elseif c == 7 then -- 玉米：两棵，长叶子往下垂
    local h = ({ 5, 10, 14, 15 })[st]
    for k = 0, 1 do
      local sx = x + 11 + k * 10
      P(K.LEAF); R(sx, g - h, 2, h)
      P(K.LEAF2); R(sx - 4, g - div(h, 2), 4, 1); R(sx - 5, g - div(h, 2) + 1, 1, 2)
      R(sx + 2, g - div(h * 3, 4), 4, 1); R(sx + 6, g - div(h * 3, 4) + 1, 1, 2)
      if st >= 3 then P({ 232, 212, 150 }); R(sx - 1, g - h - 2, 1, 2); R(sx + 1, g - h - 3, 1, 3); R(sx + 2, g - h - 2, 1, 2) end
      if st == 4 then P(col); R(sx + 2, g - div(h, 2) - 4, 3, 6); P(K.LEAF2); RH(sx + 2, g - div(h, 2) + 1, 3, 1) end
    end
  elseif c == 8 then -- 向日葵：每箱一棵大的
    local h = ({ 3, 5, 7, 7 })[st]
    local cx = x + 15
    P(K.LEAF); R(cx, g - h, 2, h + 1)
    P(K.LEAF2); R(cx - 6, g - div(h, 2) - 1, 6, 3); R(cx + 2, g - h + 1, 6, 3)
    if st == 3 then P(K.LEAF2); R(cx - 2, g - h - 4, 6, 4); P(K.YEL); R(cx - 1, g - h - 5, 4, 1) end
    if st == 4 then
      P(col); R(cx - 5, g - h - 9, 12, 9); R(cx - 4, g - h - 10, 10, 11)
      P(mix(col, { 255, 255, 255 }, 1, 3)); RH(cx - 4, g - h - 9, 2, 1); RH(cx + 5, g - h - 4, 1, 2)
      P({ 110, 70, 40 }); R(cx - 2, g - h - 7, 6, 5)
      P({ 150, 100, 56 }); RH(cx - 1, g - h - 6, 1, 1); RH(cx + 2, g - h - 5, 1, 1); RH(cx, g - h - 4, 1, 1)
    end
  elseif c == 3 then -- 南瓜：藤蔓爬出箱沿，熟了一个大南瓜
    local lw = ({ 3, 4, 5, 5 })[st]
    P(K.LEAF2); R(x + 5, g, 22, 2); R(x + 26, g + 2, 2, 5)
    P(K.LEAF); R(x + 7, g - lw, lw + 1, lw); R(x + 21, g - lw - 1, lw + 1, lw)
    if st >= 2 then R(x + 14, g - lw + 1, lw, lw - 1) end
    if st == 3 then P(K.YEL); R(x + 11, g - 3, 2, 2); R(x + 19, g - 2, 2, 2) end
    if st == 4 then
      P(K.STEM); R(x + 15, g - 9, 2, 2)
      P(col); R(x + 10, g - 6, 12, 8); R(x + 12, g - 7, 8, 10)
      P(mix(col, { 0, 0, 0 }, 1, 4)); RH(x + 13, g - 5, 1, 6); RH(x + 18, g - 5, 1, 6)
      P(mix(col, { 255, 255, 255 }, 1, 2)); RH(x + 11, g - 5, 1, 2)
    end
  else -- 苹果树：圆圆的树冠
    local h = ({ 3, 4, 4, 4 })[st]
    P(K.STEM); R(x + 15, g - h, 2, h + 1)
    if st == 1 then P(K.LEAF); R(x + 13, g - h - 3, 6, 3)
    else
      local big = st >= 3
      local cw, ch = big and 18 or 10, big and 12 or 7
      P(K.LEAF2); R(x + 16 - div(cw, 2), g - h - ch + 1, cw, ch - 1)
      P(K.LEAF); R(x + 16 - div(cw, 2) + 2, g - h - ch, cw - 4, ch - 3)
      P(K.LEAF3); RH(x + 16 - div(cw, 2) + 3, g - h - ch + 1, 3, 1)
      if st == 3 then P(K.PINK); for k = 0, 4 do R(x + 9 + k * 3, g - h - ch + 2 + mod(k, 2) * 4, 1, 1) end end
      if st == 4 then
        P(col); for k = 0, 4 do R(x + 9 + k * 3, g - h - ch + 3 + mod(k * 5, 6), 3, 3) end
        P(K.BLOOM); for k = 0, 4 do RH(x + 9 + k * 3, g - h - ch + 3 + mod(k * 5, 6), 1, 1) end
      end
    end
  end
end

D.crop = function(x, y, p)
  local st, c = stage(p), p.c
  local g = y + 17
  if st == 0 then -- 刚种下：土里几个小坑
    fg(lit({ 70, 44, 34 }))
    for k = 0, 2 do rect(x + 8 + k * 7, g + mod(k, 2), 2, 2) end
    return
  end
  if c == 1 or c == 5 or c == 9 then D.low(x, y, g, c, st, p.col) else D.tall(x, y, g, c, st, p.col) end
  D.flush()
end

-- ---------- 一块地 ----------
D.critter_on = function(i) -- 这块地上有没有小动物（看四个角）
  local a = critter
  if not a then return false end
  for k = 0, 3 do
    if plot_at(a.x + mod(k, 2) * 7, a.y - 3 + div(k, 2) * 9) == i then return true end
  end
  return false
end

D.sig = function(i, bees, rain)
  local p = P[i]
  local s = p.k * 10 + (p.k == CROP and (p.c * 100 + stage(p) * 1000) or 0) + (p.wd and 1 or 0)
  s = s + (p.w > 40 and 7000 or 0) + (i == S.cur and 50000 or 0) + (crow and crow.i == i and 100000 or 0)
  if D.critter_on(i) then s = s .. ":" .. critter.x .. "," .. critter.y .. "," .. critter.hop end
  return s .. ":" .. (bees or 0) .. ":" .. (rain or 0)
end

D.plot = function(i, bees, rain)
  local p = P[i]
  local x, y = FX + mod(i - 1, COLS) * PS, FY + div(i - 1, COLS) * PS
  D.lawn(x, y, i)
  if p.k == WILD then D.tufts(x, y, i, 3)
  elseif p.k == WEEDS then D.weeds(x, y, i)
  else
    D.bed(x, y, p, i)
    if p.k == CROP then
      D.crop(x, y, p)
      if p.wd then -- 苗床里也长了草
        local r = Rng(i * 11)
        local Pn, R = D.P, D.R
        Pn(K.WEED)
        for _ = 1, 3 do local wx = x + 5 + r(20); R(wx, y + 15 + r(6), 3, 3); R(wx + 1, y + 13 + r(2), 1, 3) end
        D.flush()
      end
    end
  end
  if i == S.cur then -- 光标：四个角的白色描边方括号
    local Pn, R = D.P, D.R
    Pn({ 252, 250, 240 })
    R(x + 1, y + 1, 6, 2); R(x + 1, y + 1, 2, 6); R(x + PS - 7, y + 1, 6, 2); R(x + PS - 3, y + 1, 2, 6)
    R(x + 1, y + PS - 3, 6, 2); R(x + 1, y + PS - 7, 2, 6); R(x + PS - 7, y + PS - 3, 6, 2); R(x + PS - 3, y + PS - 7, 2, 6)
    D.flush()
  end
  if crow and crow.i == i then -- 乌鸦站在苗床后面的草地上
    fg(lit({ 22, 20, 28 }))
    rect(x + 12, y + 3, 8, 5); rect(x + 18, y + 1, 4, 4); rect(x + 9, y + 4, 4, 2); rect(x + 14, y + 8, 1, 2); rect(x + 17, y + 8, 1, 2)
    fg(rgb(235, 195, 60)); rect(x + 22, y + 2, 2, 1)
  end
  if bees then -- 蜜蜂
    fg(lit(K.OUT)); rect(x + bees[1] - 1, y + bees[2] - 1, 4, 3)
    fg(rgb(250, 220, 40)); rect(x + bees[1], y + bees[2], 2, 1)
  end
  if rain then -- 这一格上的几滴雨
    fg(rgb(170, 190, 230))
    local r = Rng(rain)
    for _ = 1, 5 do rect(x + r(PS - 1), y + r(PS - 4), 1, 3) end
  end
  if D.critter_on(i) then -- 小动物：先画一层深色的影子，再画本体
    local a = critter
    local sp = K.CRIT[a.kind]
    for pass = 0, 1 do
      fg(lit(pass == 0 and K.OUT or sp.c))
      for r = 1, #sp do
        local row, w = sp[r], #sp[1]
        for cx = 1, w do
          if string.sub(row, cx, cx) == "#" then rect(a.x + (a.dir > 0 and cx - 1 or w - cx) + 1 - pass, a.y - a.hop + r - pass, 1, 1) end
        end
      end
    end
  end
end

-- ---------- 板子、顶栏、底栏 ----------
D.board = function()
  fg(lit(K.BG)); rect(0, D.TOP, W, D.BAR - D.TOP)
  fg(lit(K.BG2))
  for y = D.TOP + 1, D.BAR - 2, 4 do -- 背景的小点（只有两边露出来）
    local o = mod(y, 8) == 0 and 1 or 4
    rect(o, y, 1, 1); rect(W - 1 - o, y, 1, 1)
  end
  fg(lit(K.OUT)); rect(FX - 1, FY - 1, COLS * PS + 2, ROWS * PS + 6)
  fg(lit(K.SIDE)); rect(FX, FY + ROWS * PS, COLS * PS, 3)
  fg(lit(K.UNDER)); rect(FX, FY + ROWS * PS + 3, COLS * PS, 1)
  -- 板子上沿的一圈草
  local r = Rng(17)
  local P, R = D.P, D.R
  P(K.LAWN1)
  for x = FX, FX + COLS * PS - 6, 7 do R(x + r(3), FY - 3, 3 + r(2), 3) end
  D.flush()
end

D.top_bar = function(t)
  local L = D.L
  local w = weather(div(t, 86400))
  fg(pack(L.top)); rect(0, 0, W, 5); fg(pack(L.bot)); rect(0, 5, W, D.TOP - 5)
  local c = civil(t)
  local ink = (L.sun > 200) and rgb(30, 30, 40) or rgb(235, 235, 240)
  text(3, 2, string.format("%02d-%02d %02d:%02d", c.m, c.d, c.hh, c.mm), ink, pack(L.bot))
  local ix = W - 16
  if w.rainy then
    fg(rgb(170, 175, 185)); rect(ix, 2, 10, 4); rect(ix + 2, 0, 6, 2)
    fg(rgb(120, 160, 230)); rect(ix + 1, 7, 1, 2); rect(ix + 4, 7, 1, 2); rect(ix + 7, 7, 1, 2)
  elseif L.night then -- 月牙
    fg(rgb(230, 225, 190)); rect(ix + 2, 2, 6, 5); rect(ix + 3, 1, 4, 7)
    fg(pack(L.bot)); rect(ix + 5, 0, 4, 6)
  else fg(rgb(250, 210, 80)); rect(ix + 2, 2, 6, 6); rect(ix + 4, 0, 2, 10); rect(ix, 4, 10, 2) end
end

D.bottom_bar = function()
  local bg = rgb(36, 30, 34)
  fg(bg); rect(0, D.BAR, W, H - D.BAR)
  local p = P[S.cur]
  local line
  if p.k == CROP then
    line = CROPS[p.c].name .. (is_base(p.c, p.col) and "" or "*") .. "  " .. D.eta(p)
  elseif p.k == WILD then line = "wild grass"
  elseif p.k == WEEDS then line = "weeds"
  else line = "soil" .. (p.w > 40 and ", damp" or "") end
  text(3, D.BAR + 1, line, rgb(240, 232, 215), bg)
  local _, how = next_job(S.cur)
  if rb.current_tick() < S.msg_t then text(3, D.BAR + 10, S.msg, rgb(160, 214, 140), bg)
  else text(3, D.BAR + 10, "> " .. how, rgb(244, 190, 100), bg) end
end

-- 开花的相邻两块之间有没有蜜蜂：返回 { [块] = {x, y} }
D.bees = function(frame)
  local b = {}
  for i = 1, NP do
    local p = P[i]
    if stage(p) == 3 then
      for _, j in ipairs(neighbours(i)) do
        local q = P[j]
        if j > i and stage(q) == 3 and q.c ~= p.c then
          local k = mod(frame, 16)
          local f = k < 8 and k or 15 - k -- 来回飞
          local host = f < 4 and i or j
          b[host] = { clamp(6 + f * 3 + mod(frame * 7, 5), 2, PS - 4), 4 + mod(frame * 3, 9) }
        end
      end
    end
  end
  return b
end

draw_all = function(t, frame, force)
  D.L = light_at(t)
  local l = D.L.land
  D.land = { math.max(l[1], 95), math.max(l[2], 95), math.max(l[3], 105) }
  if force or not D.shown[0] then
    D.shown = { [0] = true }
    D.board()
  end
  D.top_bar(t)
  local bees = D.bees(frame)
  -- 雨：每次只在两块地上落几滴，省得整片重画
  local rain = {}
  if weather(div(t, 86400)).rainy then
    local r = Rng(frame + 1)
    rain[r(NP) + 1] = frame + 1; rain[r(NP) + 1] = frame + 2
  end
  for i = 1, NP do
    local s = D.sig(i, bees[i] and (bees[i][1] * 100 + bees[i][2]), rain[i])
    if D.shown[i] ~= s then D.shown[i] = s; D.plot(i, bees[i], rain[i]) end
  end
  D.bottom_bar()
  rb.lcd_update()
end

draw_bag = function(list, sel, page)
  local bg, ink = rgb(36, 30, 34), rgb(240, 232, 215)
  local bx, by, bw = 14, 16, 148
  local rows = 7
  local top = clamp(sel - 3, 1, math.max(1, #list - rows + 1))
  fg(rgb(40, 38, 48)); rect(bx - 2, by - 2, bw + 4, 100)
  fg(rgb(196, 150, 100)); rect(bx - 1, by - 1, bw + 2, 98)
  fg(bg); rect(bx, by, bw, 96)
  if page == 2 then -- 谷仓：每种作物收过多少；没见过的作物是问号
    text(bx + 4, by + 3, "BARN", rgb(244, 190, 100), bg)
    text_r(bx + bw - 4, by + 3, "new kinds " .. D.new_vars(), rgb(150, 140, 130), bg)
    for c = 1, #CROPS do
      local seen = D.seen(c)
      local yy = by + 13 + (c - 1) * 9
      if seen then fg(pack(CROPS[c].col)); rect(bx + 6, yy + 1, 5, 5) end
      text(bx + 16, yy, seen and CROPS[c].name or "?", seen and ink or rgb(110, 100, 100), bg)
      text_r(bx + bw - 6, yy, tostring(BARN[c]), ink, bg)
    end
    rb.lcd_update()
    return
  end
  text(bx + 4, by + 3, "SEEDS", rgb(244, 190, 100), bg)
  text_r(bx + bw - 4, by + 3, "new " .. D.new_vars(), rgb(150, 140, 130), bg)
  if #list == 0 then text(bx + 4, by + 16, "(none - harvest)", rgb(150, 140, 130), bg) end
  for n = top, math.min(#list, top + rows - 1) do
    local b = list[n]
    local yy = by + 14 + (n - top) * 10
    fg(pack(b.col)); rect(bx + 6, yy + 1, 6, 6)
    local name = CROPS[b.c].name .. (is_base(b.c, b.col) and "" or "*")
    text(bx + 16, yy, (n == sel and "> " or "  ") .. name .. " x" .. b.n, n == sel and rgb(244, 190, 100) or ink, bg)
  end
  text(bx + 4, by + 86, "next: barn", rgb(150, 140, 130), bg)
  rb.lcd_update()
end
end

local function bag_list()
  local list = {}
  for key, b in pairs(BAG) do if b.n > 0 then b.key = key; list[#list + 1] = b end end
  table.sort(list, function(a, b)
    if a.c ~= b.c then return a.c < b.c end
    return a.key < b.key
  end)
  return list
end

-- 蛇形顺序：第 n 步（0..14）对应哪块地
local function snake(n)
  local row, k = div(n, COLS), mod(n, COLS)
  if mod(row, 2) == 1 then k = COLS - 1 - k end
  return row * COLS + k + 1
end

-- ---------- 主循环 ----------
load()
light_start()
do
  -- 补算之前先画一行字：可能要算一会儿
  fg(rgb(28, 24, 20)); rect(0, 0, W, H)
  text(6, 60, "the farm grew while", rgb(230, 225, 210), rgb(28, 24, 20))
  text(6, 70, "you were away...", rgb(230, 225, 210), rgb(28, 24, 20))
  rb.lcd_update()
  local h = catch_up(now())
  if h > 0 then say(h >= 48 and ("away " .. div(h, 24) .. " days") or ("away " .. h .. "h")) end
end
save()

-- 循环里的状态放进一个表：Rockbox 的 Lua 主函数最多 100 个 local
local U = { running = true, bag = false, sel = 1, page = 1, dirty = true, step = 0, frame = 0, check = 0 }
for n = 0, NP - 1 do if snake(n) == S.cur then U.step = n end end

local HELP = {
  "A small farm on real time.",
  "radish 4h, carrot 8h,",
  "wheat a day, tomato and",
  "strawberry 2 days, corn 3,",
  "pumpkin 4, sunflower 5,",
  "apple tree 3 weeks. Apple,",
  "tomato, strawberry fruit",
  "again after picking.",
  "New kinds are not bought:",
  "a passing animal or the",
  "wind brings a seed now and",
  "then. Rain waters",
  "it; dry plots stop growing",
  "but never die. Ripe crops",
  "left alone re-seed. Weeds",
  "creep in. A crow may come;",
  "select its plot to shoo.",
  "Two kinds in bloom side by",
  "side: bees may cross them.",
  "",
  "*Keys",
  "wheel   move (snake order)",
  "select  the next job here",
  "play    seed bag",
  "        (next: barn)",
  "menu    quit",
  "hold menu  this help",
}

local function handle(e)
  local g = select_gesture(e)
  if e.k == "help" then help_screen("FARM", HELP); U.dirty = "force"
  elseif U.bag then
    local list = bag_list()
    if e.k == "menu" or (e.k == "play" and not e.rel and not e.rep) then U.bag = false
    elseif (e.k == "next" or e.k == "prev") and not e.rel then U.page = 3 - U.page
    elseif e.k == "fwd" and not e.rel then U.sel = clamp(U.sel + 1, 1, math.max(1, #list))
    elseif e.k == "back" and not e.rel then U.sel = clamp(U.sel - 1, 1, math.max(1, #list))
    elseif g == "short" then
      if U.page == 1 and list[U.sel] then S.sel = list[U.sel].key end
      U.bag = false
    end
    U.dirty = U.bag or "force"
  elseif e.k == "menu" then U.running = false
  elseif e.k == "fwd" and not e.rel then U.step = mod(U.step + 1, NP); S.cur = snake(U.step); U.dirty = true
  elseif e.k == "back" and not e.rel then U.step = mod(U.step + NP - 1, NP); S.cur = snake(U.step); U.dirty = true
  elseif g == "short" then do_job(S.cur); U.dirty = true; save()
  elseif e.k == "play" and not e.rel and not e.rep then
    U.bag, U.sel, U.page = true, 1, 1
    for n, b in ipairs(bag_list()) do if b.key == S.sel then U.sel = n end end
    U.dirty = true
  end
end

-- 每 10 秒：按真实时间往前走；乌鸦来去
local function tick_world(tk)
  if catch_up(now()) > 0 then save() end
  -- 乌鸦：有熟的作物时，偶尔落在那块地的篱笆上，坐一两分钟；没赶走就叼走一颗
  if crow and tk >= crow.leave then
    if P[crow.i].k == CROP and stage(P[crow.i]) == 4 then eat_one(crow.i); say("the crow took one") end
    crow = nil; save()
  elseif not crow then
    local ripe = {}
    for i = 1, NP do if stage(P[i]) == 4 then ripe[#ripe + 1] = i end end
    if #ripe > 0 and rnd(30) == 0 then crow = { i = ripe[rnd(#ripe) + 1], leave = tk + (60 + rnd(60)) * HZ } end
  end
  local t = now()
  critter_spawn(light_at(t), weather(div(t, 86400)))
  if not U.dirty then U.dirty = true end -- 时钟走了，顶栏要更新
end

while U.running do
  for _, e in ipairs(poll()) do handle(e) end
  local tk = rb.current_tick()
  if tk >= U.check then U.check = tk + 10 * HZ; tick_world(tk) end
  U.frame = U.frame + 1
  if mod(U.frame, 3) == 0 and not U.bag then
    local m = critter_step()
    if m then say(m); save() end
  end
  if U.bag then
    if U.dirty then draw_bag(bag_list(), U.sel, U.page); U.dirty = false end
  elseif U.dirty or mod(U.frame, 3) == 0 then -- 蜜蜂和雨：每秒动几下
    draw_all(now(), div(U.frame, 3), U.dirty == "force")
    U.dirty = false
  end
  keep_light()
  rb.sleep(div(HZ, 10))
end

save()
light_end()
