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
local FX, FY = 8, 18                -- 田的左上角（上面一条是远景）

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
-- 伪 3D：草地上一块块翻过的田（田垄、垄沟、前面一截土的侧面）；顶上一条远景：天空、远山、树和开着野花的草地。
-- 作物都由小方块拼成，统一描一圈深色边：先把所有方块的描边画完，再画填色，相邻方块的边就连成一个轮廓。
local draw_all, draw_bag
do
local D = { BAR = 115, TOP = 18, shown = {}, rain = {}, land = { 256, 256, 256 }, sh = {}, pen = { 0, 0, 0 } }
local K = { -- 颜色（画的时候都按当前的光 tint 一下）
  BG = { 190, 232, 124 }, BG2 = { 168, 216, 106 }, OUT = { 58, 40, 54 },
  LAWN1 = { 124, 208, 98 }, LAWN2 = { 96, 182, 88 }, TUFT = { 176, 236, 126 }, SHADE = { 76, 146, 78 },
  SOIL = { 166, 108, 68 }, SOILW = { 120, 78, 56 }, RIDGE = { 206, 148, 96 }, RIDGEW = { 156, 106, 74 },
  FURROW = { 120, 74, 52 }, FRONT = { 128, 80, 56 },
  HILL = { 92, 120, 168 }, HILL2 = { 64, 134, 100 }, TREE = { 50, 120, 76 },
  FLOWERS = { { 236, 72, 88 }, { 176, 96, 214 }, { 250, 140, 190 }, { 255, 236, 120 }, { 250, 250, 255 } },
  LEAF = { 112, 210, 92 }, LEAF2 = { 60, 164, 82 }, LEAF3 = { 176, 238, 124 }, STEM = { 138, 104, 70 },
  BLOOM = { 255, 248, 228 }, YEL = { 255, 218, 72 }, PINK = { 255, 196, 214 },
  WEED = { 64, 142, 76 }, WEED2 = { 104, 188, 90 },
  RAIN = { 206, 222, 250 }, BEE = { 250, 220, 40 }, CROW = { 22, 20, 28 }, BEAK = { 235, 195, 60 },
  CRIT = { -- 小动物的小像素图（朝右）
    rabbit = { c = { 215, 205, 190 }, "......#.", ".....##.", "..#####.", ".######.", "######..", ".#...#.." },
    frog = { c = { 190, 235, 90 }, "#....#", ".####.", "######", "#....#" },
    hedgehog = { c = { 235, 205, 165 }, ".#####..", "#######.", "########", ".#...#.." },
    butterfly = { c = { 245, 190, 220 }, "#...#", "##.##", ".#.#." },
  },
}

-- 影子缓冲：记下屏幕 0..BAR-1 行的「背景」每个像素是什么颜色，每行一个字符串，一个字符是调色板下标。
-- 雨点、蜜蜂、小动物这些会动的东西不进影子；擦掉它们时按影子把底下几个像素补回来（一两个 fillrect），
-- 不用重画整块地（一百多个）。下面的 fg / rect 盖过 common.lua 的同名函数：画的同时记进影子，
-- 颜色没变就不再调 lcd_set_foreground。
local SB = { rows = {}, pal = {}, col = { [0] = 0 }, ch = {}, n = 0, cur = -1, c = "\0", off = false }
for i = 0, 255 do SB.ch[i] = string.char(i) end
SB.reset = function()
  SB.pal, SB.col, SB.n, SB.full, SB.cur = {}, { [0] = 0 }, 0, false, -1
  local blank = string.rep("\0", W)
  for y = 0, D.BAR - 1 do SB.rows[y] = blank end
end
local function fg(c)
  if c ~= SB.cur then SB.cur = c; rb.lcd_set_foreground(c) end
  if SB.off then return end
  local i = SB.pal[c]
  if not i then
    if SB.n >= 250 then SB.full = true; i = 0 -- 调色板满了：下一帧整屏重画，换一张新的
    else SB.n = SB.n + 1; i = SB.n; SB.pal[c] = i; SB.col[i] = c end
  end
  SB.c = SB.ch[i]
end
local function rect(x, y, w, h)
  if w <= 0 or h <= 0 then return end
  rb.lcd_fillrect(x, y, w, h)
  if SB.off then return end
  if x < 0 then w = w + x; x = 0 end
  if x + w > W then w = W - x end
  if y < 0 then h = h + y; y = 0 end
  if y + h > D.BAR then h = D.BAR - y end
  if w <= 0 or h <= 0 then return end
  local rows = SB.rows
  local seg = (w == 1) and SB.c or string.rep(SB.c, w)
  if w == W then for yy = y, y + h - 1 do rows[yy] = seg end return end
  for yy = y, y + h - 1 do
    local r = rows[yy]
    rows[yy] = string.sub(r, 1, x) .. seg .. string.sub(r, x + w + 1)
  end
end
-- 按影子把一块补回来：一行里同色的连成一段；一像素宽的竖条按列连。
-- 先按颜色分组记在 q 里，flushq 时每种颜色只设一次前景色。
D.q = {}
D.put = function(c, x, y, w, h)
  local a = D.q[c]
  if not a then a = {}; D.q[c] = a end
  local n = #a
  a[n + 1], a[n + 2], a[n + 3], a[n + 4] = x, y, w, h
end
D.flushq = function()
  for c, a in pairs(D.q) do
    SB.cur = c; rb.lcd_set_foreground(c)
    for k = 1, #a, 4 do rb.lcd_fillrect(a[k], a[k + 1], a[k + 2], a[k + 3]) end
  end
  D.q = {}
end
D.restore = function(x, y, w, h)
  if x < 0 then w = w + x; x = 0 end
  if x + w > W then w = W - x end
  if y < 0 then h = h + y; y = 0 end
  if y + h > D.BAR then h = D.BAR - y end
  if w <= 0 or h <= 0 then return end
  local rows, col, byte, put = SB.rows, SB.col, string.byte, D.put
  if w == 1 then
    local yy = y
    while yy < y + h do
      local b = byte(rows[yy], x + 1)
      local e = yy + 1
      while e < y + h and byte(rows[e], x + 1) == b do e = e + 1 end
      put(col[b], x, yy, 1, e - yy)
      yy = e
    end
    return
  end
  for yy = y, y + h - 1 do
    local r = rows[yy]
    local xx = x
    while xx < x + w do
      local b = byte(r, xx + 1)
      local e = xx + 1
      while e < x + w and byte(r, e + 1) == b do e = e + 1 end
      put(col[b], xx, yy, e - xx, 1)
      xx = e
    end
  end
end
-- 按当前的光调色；同一张颜色表的结果记下来，光变了才清空（弱键：临时算出来的颜色表会被回收）
D.lc = setmetatable({}, { __mode = "k" })
local function lit(c)
  local v = D.lc[c]
  if not v then v = pack(tint(c, D.land)); D.lc[c] = v end
  return v
end

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
-- 野花：一根茎，顶上一点颜色（参考图里草地上的红、紫、粉色小花）
D.flower = function(x, y, r)
  fg(lit(K.LEAF2)); rect(x, y + 1, 1, 2)
  fg(lit(K.FLOWERS[r(#K.FLOWERS) + 1])); rect(x - 1 + r(2), y, 2, 1)
end
D.tufts = function(x, y, i, n)
  local r = Rng(i * 7 + 3)
  fg(lit(K.TUFT))
  for _ = 1, n do
    local tx, ty = x + 3 + r(PS - 8), y + 3 + r(PS - 8)
    rect(tx, ty + 1, 1, 2); rect(tx + 2, ty, 1, 3); rect(tx + 4, ty + 1, 1, 2)
  end
  for _ = 1, n + 1 do D.flower(x + 3 + r(PS - 6), y + 3 + r(PS - 7), r); fg(lit(K.TUFT)) end
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
-- 一块翻过的田：四道田垄（亮的垄背、暗的垄沟），前面露出一截土的侧面，像是比草地低一点点又高一点点
D.field = function(x, y, p, i)
  local wet = p.w > 40
  fg(lit(K.OUT)); rect(x + 2, y + 3, 28, 28)
  fg(lit(wet and K.SOILW or K.SOIL)); rect(x + 3, y + 4, 26, 24)
  fg(lit(K.FRONT)); rect(x + 3, y + 28, 26, 2)
  for k = 0, 3 do
    local ry = y + 5 + k * 6
    fg(lit(wet and K.RIDGEW or K.RIDGE)); rect(x + 4, ry, 24, 2)
    fg(lit(K.FURROW)); rect(x + 3, ry + 3, 26, 1)
  end
  local r = Rng(i * 5 + 1)
  fg(lit(K.FURROW))
  for _ = 1, 3 do rect(x + 5 + r(20), y + 5 + r(4) * 6, 2, 1) end -- 土块
end

-- ---------- 作物 ----------
-- 田是方的，作物要把它铺满：矮的（萝卜、胡萝卜、草莓）和麦子、南瓜种前后两行；
-- 番茄一大丛、苹果一棵大树；玉米和向日葵是 2×2。都画在自己这一格（32×32）里，不越界。
-- 先画后排、flush，再画前排：前排的描边压在后排上，看得出前后。
D.low = function(x, g, c, st, col) -- 萝卜、胡萝卜、草莓；g 是这一行的地面线
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
    if st == 4 then P(col); R(x + 7, g, 4, 3); R(x + 14, g + 1, 4, 3); R(x + 21, g, 4, 3) end
    P(K.LEAF2); R(x + 6, g - s + 1, 20, s - 1)
    P(K.LEAF); R(x + 8, g - s, 16, s - 2)
    P(K.LEAF3); for k = 0, 4 do RH(x + 9 + k * 3, g - s + 1 + mod(k, 2), 1, 1) end
    if st == 3 then P(K.BLOOM); R(x + 10, g - s - 1, 3, 1); R(x + 19, g - s - 1, 3, 1) end
  else -- 草莓：贴地的一片三出叶，熟了的果子垂在垄上
    local s = ({ 1, 2, 3, 3 })[st]
    P(K.LEAF2); R(x + 6, g - 1, 20, 3)
    P(K.LEAF)
    for k = 0, 2 do
      local cx = x + 9 + k * 7
      R(cx - s, g - 2 - s, s, s); R(cx + 1, g - 2 - s, s, s); R(cx - 1, g - 3 - s, 2, s)
    end
    if st == 3 then P(K.BLOOM); R(x + 11, g - 1, 2, 2); R(x + 19, g - 2, 2, 2) end
    if st == 4 then
      P(col); R(x + 8, g + 1, 3, 3); R(x + 16, g + 2, 3, 3); R(x + 23, g + 1, 3, 3)
      P(K.LEAF2); RH(x + 8, g + 1, 3, 1); RH(x + 16, g + 2, 3, 1); RH(x + 23, g + 1, 3, 1)
      P(K.YEL); RH(x + 9, g + 2, 1, 1); RH(x + 17, g + 3, 1, 1)
    end
  end
end

D.row = function(x, g, c, st, col) -- 麦子、南瓜的一行
  local P, R, RH = D.P, D.R, D.RH
  if c == 2 then -- 麦子：一片麦浪，顶上一排麦穗
    local h = ({ 3, 6, 9, 10 })[st]
    P(st == 4 and mix(col, K.STEM, 1, 4) or K.LEAF); R(x + 5, g - h + 2, 22, h)
    P(st == 4 and mix(col, K.STEM, 1, 2) or K.LEAF2); for k = 0, 6 do RH(x + 6 + k * 3, g - h + 4, 1, h - 3) end
    if st >= 3 then
      P(st == 4 and mix(col, { 255, 255, 255 }, 1, 4) or { 206, 222, 150 })
      for k = 0, 6 do R(x + 5 + k * 3, g - h - 1 - mod(k, 2), 2, 3) end
    end
  else -- 南瓜：一道藤，熟了一个大南瓜
    local lw = ({ 3, 4, 5, 5 })[st]
    P(K.LEAF2); R(x + 5, g, 22, 2)
    P(K.LEAF); R(x + 7, g - lw, lw + 1, lw); R(x + 21, g - lw - 1, lw + 1, lw)
    if st >= 2 then R(x + 14, g - lw + 1, lw, lw - 1) end
    if st == 3 then P(K.YEL); R(x + 11, g - 3, 2, 2); R(x + 19, g - 2, 2, 2) end
    if st == 4 then
      P(K.STEM); R(x + 15, g - 9, 2, 2)
      P(col); R(x + 10, g - 6, 12, 8); R(x + 12, g - 7, 8, 10)
      P(mix(col, { 0, 0, 0 }, 1, 4)); RH(x + 13, g - 5, 1, 6); RH(x + 18, g - 5, 1, 6)
      P(mix(col, { 255, 255, 255 }, 1, 2)); RH(x + 11, g - 5, 1, 2)
    end
  end
end

D.stalk = function(sx, g, c, st, col) -- 一棵玉米或一棵向日葵
  local P, R, RH = D.P, D.R, D.RH
  if c == 7 then
    local h = ({ 4, 8, 12, 13 })[st]
    P(K.LEAF); R(sx, g - h, 2, h)
    P(K.LEAF2); R(sx - 4, g - div(h, 2), 4, 1); R(sx - 5, g - div(h, 2) + 1, 1, 2)
    R(sx + 2, g - div(h * 3, 4), 4, 1); R(sx + 6, g - div(h * 3, 4) + 1, 1, 2)
    if st >= 3 then P({ 232, 212, 150 }); R(sx - 1, g - h - 2, 1, 2); R(sx + 1, g - h - 3, 1, 3); R(sx + 2, g - h - 2, 1, 2) end
    if st == 4 then P(col); R(sx + 2, g - div(h, 2) - 4, 3, 5); P(K.LEAF2); RH(sx + 2, g - div(h, 2), 3, 1) end
  else
    local h = ({ 2, 4, 5, 5 })[st]
    P(K.LEAF); R(sx, g - h, 2, h + 1)
    P(K.LEAF2); R(sx - 4, g - 2, 4, 2); R(sx + 2, g - h + 1, 4, 2)
    if st == 3 then P(K.LEAF2); R(sx - 1, g - h - 3, 4, 3); P(K.YEL); R(sx, g - h - 4, 2, 1) end
    if st == 4 then
      P(col); R(sx - 4, g - h - 8, 10, 8); R(sx - 3, g - h - 9, 8, 10)
      P(mix(col, { 255, 255, 255 }, 1, 3)); RH(sx - 3, g - h - 8, 2, 1)
      P({ 110, 70, 40 }); R(sx - 1, g - h - 6, 4, 4)
      P({ 150, 100, 56 }); RH(sx, g - h - 5, 1, 1); RH(sx + 2, g - h - 4, 1, 1)
    end
  end
end

D.big = function(x, y, c, st, col) -- 番茄一大丛、苹果一棵大树
  local P, R, RH = D.P, D.R, D.RH
  local g, cx = y + 27, x + 16
  if c == 6 then
    local h = ({ 6, 12, 18, 20 })[st]
    P(K.LEAF2); R(cx - 8, g - h + 2, 17, h - 1)
    P(K.LEAF); R(cx - 7, g - h, 15, h - 3)
    P(K.LEAF3); RH(cx - 5, g - h + 1, 3, 1); RH(cx + 2, g - h + 5, 2, 1)
    if st == 3 then P(K.YEL); for k = 0, 3 do R(cx - 5 + k * 3, g - h + 4 + mod(k, 2) * 5, 1, 1) end end
    if st == 4 then
      local spots = { { -6, 3 }, { 1, 2 }, { -2, 8 }, { 4, 9 }, { -6, 13 }, { 2, 15 } }
      P(col); for _, d in ipairs(spots) do R(cx + d[1], g - h + d[2], 3, 3) end
      P(K.BLOOM); for _, d in ipairs(spots) do RH(cx + d[1], g - h + d[2], 1, 1) end
    end
    P({ 214, 220, 230 }); RH(cx - 10, g - h + 2, 1, h); RH(cx + 10, g - h + 2, 1, h)
    RH(cx - 10, g - h + 2, 21, 1); RH(cx - 10, g - div(h, 2), 21, 1); RH(cx - 10, g - 1, 21, 1)
  else -- 苹果树
    local h = ({ 3, 5, 6, 6 })[st]
    P(K.STEM); R(cx - 1, g - h, 3, h + 1)
    if st == 1 then P(K.LEAF); R(cx - 3, g - h - 3, 6, 3)
    else
      local cw, ch = (st >= 3) and 24 or 14, (st >= 3) and 17 or 10
      local top, lx = g - h - ch, cx - div(cw, 2)
      P(K.LEAF2); R(lx, top + 2, cw, ch - 2)
      P(K.LEAF); R(lx + 2, top, cw - 4, ch - 4)
      P(K.LEAF3); RH(lx + 4, top + 1, 4, 1); RH(lx + 3, top + 2, 1, 2)
      if st == 3 then P(K.PINK); for k = 0, 7 do R(lx + 2 + k * 3, top + 3 + mod(k * 5, 10), 1, 1) end end
      if st == 4 then
        P(col); for k = 0, 6 do R(lx + 2 + k * 3, top + 3 + mod(k * 5, 10), 3, 3) end
        P(K.BLOOM); for k = 0, 6 do RH(lx + 2 + k * 3, top + 3 + mod(k * 5, 10), 1, 1) end
      end
    end
  end
end

D.crop = function(x, y, p)
  local st, c, col = stage(p), p.c, p.col
  if st == 0 then -- 刚种下：两行小坑
    fg(lit({ 70, 44, 34 }))
    for k = 0, 5 do rect(x + 8 + mod(k, 3) * 7, y + 12 + div(k, 3) * 12 + mod(k, 2), 2, 2) end
    return
  end
  if c == 1 or c == 5 or c == 9 then
    D.low(x - 1, y + 12, c, st, col); D.flush(); D.low(x + 1, y + 24, c, st, col)
  elseif c == 2 then D.row(x - 1, y + 13, c, st, col); D.flush(); D.row(x + 1, y + 25, c, st, col)
  elseif c == 3 then D.row(x - 3, y + 14, c, st, col); D.flush(); D.row(x + 3, y + 26, c, st, col)
  elseif c == 7 or c == 8 then
    D.stalk(x + 9, y + 17, c, st, col); D.stalk(x + 21, y + 17, c, st, col); D.flush()
    D.stalk(x + 13, y + 28, c, st, col); D.stalk(x + 24, y + 28, c, st, col)
  else D.big(x, y, c, st, col) end
  D.flush()
end

-- ---------- 一块地 ----------
-- 一块地的「样子」：变了才重画。光的档位单独比，见 draw_all
D.sig = function(i)
  local p = P[i]
  local s = p.k * 10 + (p.k == CROP and (p.c * 100 + stage(p) * 1000) or 0) + (p.wd and 1 or 0)
  return s + (p.w > 40 and 7000 or 0) + (i == S.cur and 50000 or 0) + (crow and crow.i == i and 100000 or 0)
end

D.plot = function(i)
  local p = P[i]
  local x, y = FX + mod(i - 1, COLS) * PS, FY + div(i - 1, COLS) * PS
  D.lawn(x, y, i)
  if p.k == WILD then D.tufts(x, y, i, 3)
  elseif p.k == WEEDS then D.weeds(x, y, i)
  else
    D.field(x, y, p, i)
    if p.k == CROP then
      D.crop(x, y, p)
      if p.wd then -- 田里也长了草
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
  if crow and crow.i == i then -- 乌鸦站在田的后沿
    fg(lit(K.CROW))
    rect(x + 12, y + 3, 8, 5); rect(x + 18, y + 1, 4, 4); rect(x + 9, y + 4, 4, 2); rect(x + 14, y + 8, 1, 2); rect(x + 17, y + 8, 1, 2)
    fg(lit(K.BEAK)); rect(x + 22, y + 2, 2, 1)
  end
end

-- ---------- 会动的东西：雨、蜜蜂、小动物 ----------
-- 不进影子。每帧先按影子擦掉上一帧画的，重画变了的地块，再画这一帧的。
D.drops = {}
D.crit_runs = {} -- 小动物像素图按行连成段，朝左朝右各一份
D.runs_of = function(kind, dir)
  local key = kind .. dir
  local rr = D.crit_runs[key]
  if rr then return rr end
  rr = {}
  local sp = K.CRIT[kind]
  local w = #sp[1]
  for r = 1, #sp do
    local row = sp[r]
    if dir < 0 then row = string.reverse(row) end
    local c = 1
    while c <= w do
      if string.sub(row, c, c) == "#" then
        local e = c
        while e < w and string.sub(row, e + 1, e + 1) == "#" do e = e + 1 end
        rr[#rr + 1] = { c - 1, r - 1, e - c + 1 }
        c = e + 1
      else c = c + 1 end
    end
  end
  D.crit_runs[key] = rr
  return rr
end
-- 画这一帧会动的东西，返回它们占的方块（下一帧要擦）
D.sprites = function(frame, wet)
  local out = {}
  SB.off = true
  if wet then
    local dr = D.drops
    if #dr == 0 then for k = 1, 32 do dr[k] = { rnd(W), rnd(D.BAR - 4), 6 + rnd(3) } end end
    fg(lit(K.RAIN))
    for _, d in ipairs(dr) do
      d[2] = d[2] + d[3]
      if d[2] > D.BAR - 4 then d[1], d[2] = rnd(W), rnd(6) end
      rb.lcd_fillrect(d[1], d[2], 1, 3)
      out[#out + 1] = { d[1], d[2], 1, 3 }
    end
  elseif #D.drops > 0 then D.drops = {} end
  for i, b in pairs(D.bees(div(frame, 2))) do
    local x, y = FX + mod(i - 1, COLS) * PS + b[1], FY + div(i - 1, COLS) * PS + b[2]
    fg(lit(K.OUT)); rb.lcd_fillrect(x - 1, y - 1, 4, 3)
    fg(lit(K.BEE)); rb.lcd_fillrect(x, y, 2, 1)
    out[#out + 1] = { x - 1, y - 1, 4, 3 }
  end
  local a = critter
  if a then -- 小动物：先画一层错开一格的深色影子，再画本体
    local sp = K.CRIT[a.kind]
    local rr = D.runs_of(a.kind, a.dir)
    local x, y = a.x, a.y - a.hop
    fg(lit(K.OUT)); for _, r in ipairs(rr) do rb.lcd_fillrect(x + 1 + r[1], y + 1 + r[2], r[3], 1) end
    fg(lit(sp.c)); for _, r in ipairs(rr) do rb.lcd_fillrect(x + r[1], y + r[2], r[3], 1) end
    out[#out + 1] = { x, y, #sp[1] + 1, #sp + 1 }
  end
  SB.off = false
  return out
end

-- ---------- 板子、顶栏、底栏 ----------
D.board = function()
  -- 田四周是草地：两边和下沿各一条，开着野花
  fg(lit(K.LAWN1)); rect(0, D.TOP, FX, D.BAR - D.TOP); rect(FX + COLS * PS, D.TOP, W - FX - COLS * PS, D.BAR - D.TOP)
  rect(0, FY + ROWS * PS, W, D.BAR - FY - ROWS * PS)
  local r = Rng(31)
  for y = D.TOP + 2, D.BAR - 5, 5 do
    D.flower(1 + r(5), y + r(3), r); D.flower(W - 7 + r(5), y + r(3), r)
  end
end
-- 顶上的远景：天空（跟着时间和天气变色）、远山、一棵树和几丛灌木，前面一条开花的草地。每分钟画一次。
D.top_bar = function(t)
  local L = D.L
  local w = weather(div(t, 86400))
  local c = civil(t)
  local sig = c.hh * 60 + c.mm .. (w.rainy and "r" or "")
  if D.shown.top == sig then return end
  D.shown.top = sig
  local top, bot = L.top, L.bot
  if w.rainy then top, bot = mix(top, { 120, 124, 134 }, 1, 2), mix(bot, { 150, 152, 160 }, 1, 2) end
  fg(pack(top)); rect(0, 0, W, 4)
  for k = 0, 4 do fg(pack(mix(top, bot, k + 1, 5))); rect(0, 4 + k * 2, W, 2) end
  if L.night and not w.rainy then -- 星星
    local r = Rng(7)
    fg(rgb(220, 220, 240))
    for _ = 1, 14 do rect(r(W - 24), r(8), 1, 1) end
  end
  -- 远山：两层，远的那层跟天空混一半
  local far, near = pack(mix(tint(K.HILL, D.land), bot, 1, 3)), lit(K.HILL2)
  for x = 0, W - 1, 4 do
    local h1 = 2 + div(math.abs(mod(x * 3 + 20, 96) - 48), 7) + div(math.abs(mod(x + 40, 128) - 64), 16)
    local h2 = 1 + div(math.abs(mod(x * 2 + 70, 80) - 40), 9)
    fg(far); rect(x, 15 - h1, 4, h1)
    fg(near); rect(x, 16 - h2, 4, h2)
  end
  -- 一棵树、几丛灌木
  fg(lit(K.STEM)); rect(140, 10, 2, 6)
  fg(lit(K.OUT)); rect(134, 2, 14, 10); rect(135, 1, 12, 12)
  fg(lit(K.TREE)); rect(135, 2, 12, 9); rect(136, 1, 10, 11)
  fg(lit(K.LEAF2)); rect(137, 2, 3, 2)
  for _, bx in ipairs({ 18, 26, 96, 132 }) do
    fg(lit(K.OUT)); rect(bx - 1, 11, 9, 5)
    fg(lit(K.TREE)); rect(bx, 12, 7, 4); fg(lit(K.LEAF2)); rect(bx + 1, 12, 2, 1)
  end
  -- 田前面的一条草地和野花
  fg(lit(K.LAWN1)); rect(0, 16, W, D.TOP - 16)
  local r = Rng(23)
  for x = 0, W - 3, 3 do rect(x + r(2), 15, 1, 1) end
  for x = 1, W - 6, 6 do D.flower(x + r(4), 14 + r(2), r) end
  -- 天气图标挂在天上（日期和时间在底栏）
  local ix = W - 16
  if w.rainy then
    fg(rgb(170, 175, 185)); rect(ix, 2, 10, 4); rect(ix + 2, 0, 6, 2)
    fg(rgb(120, 160, 230)); rect(ix + 1, 7, 1, 2); rect(ix + 4, 7, 1, 2); rect(ix + 7, 7, 1, 2)
  elseif L.night then -- 月牙
    fg(rgb(230, 225, 190)); rect(ix + 2, 2, 6, 5); rect(ix + 3, 1, 4, 7)
    fg(pack(top)); rect(ix + 5, 0, 4, 6)
  elseif L.sun > 120 then fg(rgb(250, 210, 80)); rect(ix + 2, 2, 6, 6); rect(ix + 4, 1, 2, 8); rect(ix + 1, 4, 8, 2) end
end

D.bottom_bar = function()
  local p = P[S.cur]
  local line
  if p.k == CROP then
    line = CROPS[p.c].name .. (is_base(p.c, p.col) and "" or "*") .. "  " .. D.eta(p)
  elseif p.k == WILD then line = "wild grass"
  elseif p.k == WEEDS then line = "weeds"
  else line = "soil" .. (p.w > 40 and ", damp" or "") end
  local c = civil(now())
  local clock = string.format("%02d:%02d", c.hh, c.mm)
  local msg = rb.current_tick() < S.msg_t
  local _, how = next_job(S.cur)
  local two = msg and S.msg or ("> " .. how)
  local sig = line .. "|" .. clock .. "|" .. two .. (msg and "!" or "")
  if D.shown.bar == sig then return end -- 字没变就不画（写字很贵）
  D.shown.bar = sig
  local bg = rgb(36, 30, 34)
  fg(bg); rect(0, D.BAR, W, H - D.BAR)
  text(3, D.BAR + 1, line, rgb(240, 232, 215), bg)
  text_r(W - 3, D.BAR + 10, clock, rgb(150, 140, 130), bg)
  text(3, D.BAR + 10, two, msg and rgb(160, 214, 140) or rgb(244, 190, 100), bg)
  SB.cur = -1 -- 写字的时候换过前景色
end

-- 开花的相邻两块之间有没有蜜蜂：返回 { [块] = {x, y} }
D.bees = function(frame) -- frame 每两帧加一
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

-- 画一帧。返回 true 表示画面上有会动的东西，下一帧还要接着画。
draw_all = function(t, frame, force)
  SB.cur = -1
  D.L = light_at(t)
  local l = D.L.land
  -- 光分成 8 级一档：同一档里颜色不变，地块不用为了光重画
  local land = { div(math.max(l[1], 95), 8) * 8, div(math.max(l[2], 95), 8) * 8, div(math.max(l[3], 105), 8) * 8 }
  local lk = land[1] * 65536 + land[2] * 256 + land[3]
  if lk ~= D.lk then D.lk, D.land = lk, land; D.lc = setmetatable({}, { __mode = "k" }) end
  if SB.full then force = true end
  local fresh = force or not D.old
  if fresh then -- 整屏重画：新的影子和调色板
    SB.reset(); D.shown = {}; D.old = {}; D.plk = {}
  end
  -- 1. 擦掉上一帧会动的东西
  for _, b in ipairs(D.old) do D.restore(b[1], b[2], b[3], b[4]) end
  D.flushq()
  if rb.__check and not fresh then rb.__check(SB.rows, SB.col, D.BAR) end -- 只有桌面测试有：屏幕应该和影子一样
  -- 2. 背景：两边的草地、顶上的远景、变了的地块
  if D.shown[0] ~= lk then D.shown[0] = lk; D.board() end
  D.top_bar(t)
  local budget = 2 -- 只是光换了一档的地块，每帧最多重画两块，慢慢刷过去
  for i = 1, NP do
    local s = D.sig(i)
    if D.shown[i] ~= s then D.shown[i] = s; D.plk[i] = lk; D.plot(i)
    elseif D.plk[i] ~= lk and budget > 0 then budget = budget - 1; D.plk[i] = lk; D.plot(i) end
  end
  -- 3. 这一帧会动的东西
  D.old = D.sprites(frame, weather(div(t, 86400)).rainy)
  D.bottom_bar()
  rb.lcd_update()
  return #D.old > 0 or budget < 2
end

draw_bag = function(list, sel, page)
  local function fg(c) SB.cur = -1; rb.lcd_set_foreground(c) end -- 和写字交替着画，不用颜色缓存
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
    SB.cur = -1
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
  SB.cur = -1
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
local U = { running = true, bag = false, sel = 1, page = 1, dirty = true, step = 0, frame = 0, check = 0, anim = false }
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
  local tk = rb.current_tick()
  for _, e in ipairs(poll()) do handle(e) end
  if tk >= U.check then U.check = tk + 10 * HZ; tick_world(tk) end
  if S.msg_t > 0 and tk >= S.msg_t then S.msg_t = 0; U.dirty = U.dirty or true end -- 提示到时间了，换回下一件事
  U.frame = U.frame + 1
  if mod(U.frame, 3) == 0 and not U.bag then
    local m = critter_step()
    if m then say(m); save() end
  end
  if U.bag then
    if U.dirty then draw_bag(bag_list(), U.sel, U.page); U.dirty = false end
  elseif U.dirty or U.anim then -- 雨、蜜蜂、小动物：每帧都动；什么都不动的时候不画
    U.anim = draw_all(now(), U.frame, U.dirty == "force")
    U.dirty = false
  end
  keep_light()
  -- 一帧 1/10 秒：画图花掉的时间从睡眠里扣
  rb.sleep(math.max(1, div(HZ, 10) - (rb.current_tick() - tk)))
end

save()
light_end()
