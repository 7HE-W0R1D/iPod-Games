-- 播棋（卡拉哈规则）：拿起一坑种子，一颗一颗往下撒
-- 开局界面：转盘选 人对人 / 人对电脑 / 电脑对电脑，Select 开始
-- 转盘：在该走一方的非空坑之间跳   Select：撒种   上一首：悔一步（人对电脑）
-- 观战时 Play：每步至少隔 5 / 10 / 20 秒   长按 Select：回开局界面
-- 短按 Menu 退出，长按 Menu 看说明

local SAVE = "slow_mancala.txt"

-- 坑的编号：0..5 是下方（先手）从左到右，6 是右边的大仓；
-- 7..12 是上方从右到左，13 是左边的大仓。逆时针撒种就是编号加一。
-- 对面的坑：i ↔ 12 - i。side 1 是下方，2 是上方。

-- ================= 规则和电脑 =================
local E = {}
do
local function copy(b)
  local t = {}
  for i = 0, 13 do t[i] = b[i] end
  return t
end
local function store_of(side) return side == 1 and 6 or 13 end
local function low_of(side) return side == 1 and 0 or 7 end

-- 撒一坑（就地改 b）。返回 最后一颗落在哪、是否再走一次、吃了几颗
local function sow(b, side, pit)
  local n = b[pit]
  b[pit] = 0
  local skip = store_of(3 - side)
  local i = pit
  while n > 0 do
    i = i + 1
    if i > 13 then i = 0 end
    if i ~= skip then b[i] = b[i] + 1; n = n - 1 end
  end
  local st = store_of(side)
  if i == st then return i, true, 0 end
  local lo = low_of(side)
  if i >= lo and i <= lo + 5 and b[i] == 1 and b[12 - i] > 0 then
    local cap = b[12 - i] + 1
    b[st] = b[st] + cap
    b[i], b[12 - i] = 0, 0
    return i, false, cap
  end
  return i, false, 0
end

-- 任何一侧空了：剩下的种子归各自的仓。返回是否结束
local function finish(b)
  local a, c = 0, 0
  for i = 0, 5 do a = a + b[i] end
  for i = 7, 12 do c = c + b[i] end
  if a > 0 and c > 0 then return false end
  for i = 0, 5 do b[i] = 0 end
  for i = 7, 12 do b[i] = 0 end
  b[6], b[13] = b[6] + a, b[13] + c
  return true
end

-- 走一步，不改原棋盘。返回 新棋盘、下一个该谁、详情
E.apply = function(b, side, pit)
  local c = copy(b)
  local last, extra, cap = sow(c, side, pit)
  local over = finish(c)
  local nxt = side
  if not extra then nxt = 3 - side end
  return c, nxt, { last = last, extra = extra, cap = cap, over = over }
end
E.copy, E.store_of, E.low_of = copy, store_of, low_of
E.legal = function(b, side)
  local t, lo = {}, low_of(side)
  for i = lo, lo + 5 do if b[i] > 0 then t[#t + 1] = i end end
  return t
end
E.new = function()
  local b = {}
  for i = 0, 13 do b[i] = 4 end
  b[6], b[13] = 0, 0
  return b
end

-- 负极大值搜索：分数 = 自己仓里的种子 - 对方仓里的（终局再加一千）
local S = { nodes = 0, limit = 0, deadline = 0, hook = nil, abort = false }
local function search(b, side, depth, alpha, beta)
  S.nodes = S.nodes + 1
  if mod(S.nodes, 200) == 0 then
    if S.hook then S.hook() end
    if S.nodes > S.limit or rb.current_tick() > S.deadline then S.abort = true end
  end
  local my, op = store_of(side), store_of(3 - side)
  if depth <= 0 then return b[my] - b[op] end
  local lo, best = low_of(side), -99999
  for k = 5, 0, -1 do -- 离仓近的坑先试：更容易“再走一次”，剪枝更多
    local pit = lo + k
    if b[pit] > 0 then
      local c = copy(b)
      local _, extra = sow(c, side, pit)
      local v
      if finish(c) then
        v = c[my] - c[op]
        if v > 0 then v = v + 1000 elseif v < 0 then v = v - 1000 end
      elseif extra then v = search(c, side, depth - 1, alpha, beta)
      else v = -search(c, 3 - side, depth - 1, -beta, -alpha) end
      if v > best then best = v end
      if best > alpha then alpha = best end
      if alpha >= beta or S.abort then break end
    end
  end
  return best
end

-- 想一步。返回 选的坑、想过的坑（按想的顺序）
-- maxd：最深几层；r：随机数（打平时随机挑一个，电脑对电脑每局才不一样）
E.think = function(b, side, maxd, secs, r, hook)
  S.nodes, S.limit, S.abort, S.hook = 0, 40000, false, hook
  S.deadline = rb.current_tick() + secs * HZ
  local moves = E.legal(b, side)
  local best = moves[1]
  local seen = {}
  for d = 1, maxd do
    local bs, ties = -999999, {}
    for _, pit in ipairs(moves) do
      seen[#seen + 1] = pit
      local c, nxt, info = E.apply(b, side, pit)
      local v
      if info.over then
        local my, op = store_of(side), store_of(3 - side)
        v = c[my] - c[op]
        if v > 0 then v = v + 1000 elseif v < 0 then v = v - 1000 end
      elseif nxt == side then v = search(c, side, d - 1, -999999, 999999)
      else v = -search(c, nxt, d - 1, -999999, 999999) end
      if S.abort then break end
      if v > bs then bs, ties = v, { pit } elseif v == bs then ties[#ties + 1] = pit end
    end
    if S.abort then break end
    best = ties[r(#ties) + 1]
    if bs > 900 or bs < -900 then break end -- 胜负已定
  end
  return best, seen
end
end

-- ================= 界面 =================
local main = function()
local C = {
  bg = rgb(34, 30, 28), wood = rgb(168, 112, 62), edge = rgb(120, 78, 42),
  pit = rgb(66, 40, 22), lit = rgb(118, 78, 46), seed = rgb(226, 190, 110), seedhi = rgb(255, 240, 196),
  ring = rgb(240, 150, 60), ink = rgb(232, 226, 214), dim = rgb(150, 140, 128),
}
-- 版面：坑 20 像素圆，间距 22；两头的大仓 14 宽
local L = { px = 23, pitch = 22, rowt = 28, rowb = 70, by = 22, bh = 76, sy = 28, sh = 62, bar = 102 }
local KINDS = { "2 players", "vs cpu", "cpu vs cpu" }
local PACES = { 5, 10, 20 }
local SOW_T, THINK_T = div(HZ * 22, 100), div(HZ * 12, 10)

-- 圆的每一行：{左边缩进, 宽度}
local function spans(d)
  local t = {}
  for y = 0, d - 1 do
    local dy = 2 * y + 1 - d
    local w = 0
    while (2 * w + 2) * (2 * w + 2) + dy * dy <= d * d do w = w + 1 end
    t[y] = { div(d, 2) - w, 2 * w }
  end
  return t
end
local OUT, INN = spans(20), spans(16)
-- 坑里 12 颗种子的位置（相对坑中心），先中间后外圈
local SLOTS = { { -2, -2 }, { 2, 2 }, { 2, -2 }, { -2, 2 }, { -6, -2 }, { 6, 2 }, { -2, -6 }, { 2, 6 },
                { 6, -2 }, { -6, 2 }, { 2, -6 }, { -2, 6 } }

local G = {
  scr = "menu", kind = 2, sel = 2, b = E.new(), side = 1, phase = "pick", cur = 1,
  pace = 2, games = { 0, 0, 0 }, w1 = { 0, 0, 0 }, w2 = { 0, 0, 0 }, best_chain = 0,
  chain = 0, last_side = 0, hist = {}, shown = {}, full = true, quit = false,
  hi = -1, hi2 = -1, t = 0, wait_until = 0, rng = Rng(now()),
}

local function human(side) return G.kind == 1 or (G.kind == 2 and side == 1) end

-- ---------- 存档 ----------
local function save()
  local b, side, over = G.b, G.side, G.scr == "over"
  if G.post then b, side, over = G.post, G.post_side, G.post_over end -- 撒到一半退出：存撒完的样子
  local t = {}
  for i = 0, 13 do t[#t + 1] = b[i] end
  local s = { board = table.concat(t, ","), side = side, kind = G.kind, pace = G.pace,
              scr = (G.scr == "menu") and "menu" or (over and "over" or "play"), best = G.best_chain,
              chain = G.chain, last_side = G.last_side }
  for k = 1, 3 do s["g" .. k] = G.games[k] .. "," .. G.w1[k] .. "," .. G.w2[k] end
  save_kv(SAVE, s)
end
local function load()
  local s, found = load_kv(SAVE)
  G.kind = clamp(num(s.kind, 2), 1, 3)
  G.sel = G.kind
  G.pace = clamp(num(s.pace, 2), 1, #PACES)
  G.best_chain = num(s.best, 0)
  for k = 1, 3 do
    local a, b, c = string.match(s["g" .. k] or "", "(%d+),(%d+),(%d+)")
    G.games[k], G.w1[k], G.w2[k] = num(a, 0), num(b, 0), num(c, 0)
  end
  local b, n = {}, 0
  for v in string.gmatch(s.board or "", "%d+") do b[n] = num(v, 0); n = n + 1 end
  if n == 14 and (s.scr == "play" or s.scr == "over") then
    G.b, G.side, G.scr = b, clamp(num(s.side, 1), 1, 2), s.scr
    G.chain, G.last_side = num(s.chain, 0), num(s.last_side, 0)
  end
  return found
end

-- ---------- 画面 ----------
local function pit_xy(i) -- 坑的左上角
  if i <= 5 then return L.px + i * L.pitch, L.rowb end
  return L.px + (12 - i) * L.pitch, L.rowt
end
local function seed(x, y)
  fg(C.seed); rect(x, y, 2, 2)
  fg(C.seedhi); rect(x, y, 1, 1)
end
local function draw_pit(i, n, ring, lit)
  local x, y = pit_xy(i)
  fg(ring and C.ring or C.pit)
  for r = 0, 19 do rect(x + OUT[r][1], y + r, OUT[r][2], 1) end
  fg(lit and C.lit or C.pit)
  for r = 0, 15 do rect(x + 2 + INN[r][1], y + 2 + r, INN[r][2], 1) end
  for k = 1, math.min(n, 12) do
    local s = SLOTS[k]
    local j = mod(hash(i, k), 3) - 1 -- 每个坑的种子摆得稍微不一样
    seed(x + 9 + s[1] + j, y + 9 + s[2] - j)
  end
  -- 太多了：画一堆，数字写在坑旁边（两排之间的空地）
  local ny = (i <= 5) and (y - 10) or (y + 22)
  fg(C.wood); rect(x - 1, ny, 22, 8)
  if n > 12 then
    seed(x + 9, y + 9)
    local s = tostring(n)
    text(x + 10 - div(#s * 6, 2), ny, s, C.ink, C.wood)
  end
end
local function draw_store(i, n, lit)
  local x = (i == 6) and 157 or 5
  fg(C.edge); rect(x, L.sy, 14, L.sh)
  fg(lit and C.lit or C.pit); rect(x + 1, L.sy + 1, 12, L.sh - 2)
  for k = 0, n - 1 do -- 从下往上堆，一行 3 颗
    local yy = L.sy + L.sh - 5 - div(k, 3) * 3
    if yy > L.sy + 1 then seed(x + 2 + mod(k, 3) * 4, yy) end
  end
end
local function draw_board()
  fg(C.bg); rect(0, 0, W, H)
  fg(C.edge); rect(2, L.by, W - 4, L.bh)
  fg(C.wood); rect(3, L.by + 1, W - 6, L.bh - 2)
end

-- 当前该高亮什么
local function looks()
  local ring, lit = -1, {}
  if G.phase == "pick" and human(G.side) then
    local moves = E.legal(G.b, G.side)
    if #moves > 0 then ring = moves[clamp(G.cur, 1, #moves)] end
  end
  if G.hi >= 0 then lit[G.hi] = true end
  if G.hi2 >= 0 then lit[G.hi2] = true end
  return ring, lit
end
local function bar_text()
  local a, b = G.b[6], G.b[13]
  local left
  if G.scr == "over" then
    if a > b then left = (G.kind == 2) and "you win" or "bottom wins"
    elseif b > a then left = (G.kind == 2) and "cpu wins" or "top wins"
    else left = "draw" end
    left = left .. "  sel:new"
  elseif G.kind == 3 then left = "auto " .. PACES[G.pace] .. "s"
  elseif G.kind == 2 then left = (G.side == 1) and "your move" or "thinking"
  else left = (G.side == 1) and "bottom to move" or "top to move" end
  return left, b .. ":" .. a
end
local function render()
  if G.full then
    draw_board()
    G.shown, G.full = {}, false
  end
  local ring, lit = looks()
  for i = 0, 13 do
    local key = G.b[i] .. (i == ring and "r" or "") .. (lit[i] and "l" or "")
    if G.shown[i] ~= key then
      G.shown[i] = key
      if i == 6 or i == 13 then draw_store(i, G.b[i], lit[i]) else draw_pit(i, G.b[i], i == ring, lit[i]) end
    end
  end
  -- 该走的一侧：一圈橙框正好围住自己那排 6 个坑（离坑 1 像素，圆角）
  local key = "s" .. ((G.scr == "over") and 0 or G.side)
  if G.shown.side ~= key then
    G.shown.side = key
    for side = 1, 2 do
      local y, x, w = ((side == 1) and L.rowb or L.rowt) - 2, L.px - 2, 6 * L.pitch
      fg((G.scr ~= "over" and G.side == side) and C.ring or C.wood)
      rect(x + 1, y, w - 2, 1); rect(x + 1, y + 23, w - 2, 1)
      rect(x, y + 1, 1, 22); rect(x + w - 1, y + 1, 1, 22)
    end
  end
  local left, right = bar_text()
  key = left .. right
  if G.shown.bar ~= key then
    G.shown.bar = key
    fg(C.bg); rect(0, L.bar, W, H - L.bar)
    text(4, L.bar + 8, left, C.ink, C.bg)
    text_r(W - 4, L.bar + 8, right, C.dim, C.bg)
  end
  rb.lcd_update()
end

local function draw_menu()
  fg(C.bg); rect(0, 0, W, H)
  text(4, 4, "MANCALA", C.ring, C.bg)
  for k = 1, 3 do
    local y = 22 + (k - 1) * 30
    if k == G.sel then fg(C.ring); rect(2, y - 2, 3, 22) end
    text(10, y, KINDS[k], (k == G.sel) and C.ring or C.ink, C.bg)
    local who = (k == 2) and "you %d cpu %d" or "bottom %d top %d"
    text(10, y + 11, G.games[k] .. " games  " .. string.format(who, G.w1[k], G.w2[k]), C.dim, C.bg)
  end
  text(10, 116, "most moves in a row: " .. G.best_chain, C.dim, C.bg)
  rb.lcd_update()
  G.full = true
end

-- ---------- 走棋 ----------
local function new_game(kind)
  G.kind, G.b, G.side, G.scr, G.phase = kind, E.new(), 1, "play", "pick"
  G.hist, G.cur, G.chain, G.last_side, G.hi, G.hi2, G.full = {}, 1, 0, 0, -1, -1, true
  G.post = nil
  G.wait_until = 0
  save()
end
local function start_move(pit)
  G.hist[#G.hist + 1] = { b = E.copy(G.b), side = G.side, chain = G.chain, last_side = G.last_side }
  G.post, G.post_side, G.info = E.apply(G.b, G.side, pit)
  G.post_over = G.info.over
  if G.last_side == G.side then G.chain = G.chain + 1 else G.chain = 1 end
  G.last_side = G.side
  if G.chain > G.best_chain then G.best_chain = G.chain end
  G.anim_i, G.anim_n = pit, G.b[pit]
  G.b[pit] = 0
  G.hi, G.hi2 = pit, -1
  G.phase, G.t = "sow", rb.current_tick() + SOW_T
end
local function end_game()
  local a, b, k = G.b[6], G.b[13], G.kind
  G.scr, G.phase = "over", "pick"
  G.games[k] = G.games[k] + 1
  if a > b then G.w1[k] = G.w1[k] + 1 elseif b > a then G.w2[k] = G.w2[k] + 1 end
  save()
end
-- 撒种动画：每一拍落一颗；撒完停一下（吃子、收尾时停久一点），再换成算好的结果
local function step_anim()
  if rb.current_tick() < G.t then return end
  if G.phase == "sow" then
    local skip = E.store_of(3 - G.side)
    local i = G.anim_i
    repeat i = i + 1; if i > 13 then i = 0 end until i ~= skip
    G.b[i] = G.b[i] + 1
    G.anim_i, G.anim_n, G.hi = i, G.anim_n - 1, i
    G.t = rb.current_tick() + SOW_T
    if G.anim_n == 0 then
      G.phase = "settle"
      if G.info.cap > 0 then G.hi2 = 12 - i; G.t = rb.current_tick() + div(HZ * 7, 10)
      elseif G.info.over then G.t = rb.current_tick() + div(HZ * 7, 10) end
    end
  elseif G.phase == "settle" then
    G.b, G.side, G.post = G.post, G.post_side, nil
    G.hi, G.hi2, G.cur = -1, -1, 1
    if G.info.over then end_game()
    else G.phase = "pick"; save() end
  end
end

local function think()
  local started = rb.current_tick()
  local hook = function()
    for _, e in ipairs(poll()) do
      if e.k == "menu" then G.quit = true elseif e.k == "help" then G.help_req = true end
    end
    keep_light()
    if rb.yield then rb.yield() end
    return G.quit
  end
  local maxd = (G.kind == 3) and 7 or 9
  local pit, seen = E.think(G.b, G.side, maxd, 3, G.rng, hook)
  -- 想过的坑轮流亮一下，像手指在棋盘上犹豫
  local n = math.min(#seen, 6)
  local first = #seen - n + 1
  local k = first
  while not G.quit and (rb.current_tick() < started + THINK_T or k <= #seen) do
    G.hi = seen[math.min(k, #seen)]
    render()
    for _, e in ipairs(poll()) do if e.k == "menu" then G.quit = true elseif e.k == "help" then G.help_req = true end end
    keep_light()
    rb.sleep(div(HZ, 5))
    k = k + 1
  end
  G.hi = pit
  -- 观战：每步至少隔几秒
  if G.kind == 3 then G.wait_until = started + PACES[G.pace] * HZ end
  return pit
end

local HELP = {
  "Kalah. Pick up a pit and",
  "sow its seeds one by one,",
  "counterclockwise.",
  "",
  "*Rules",
  "pass your store: drop one",
  "skip the other store",
  "last seed in your store:",
  "  move again",
  "last seed in your empty pit:",
  "  take it and the seeds",
  "  across into your store",
  "one side empty: game over,",
  "  more in the store wins",
  "",
  "*Keys",
  "wheel   choose a pit",
  "select  sow",
  "prev    undo (vs cpu)",
  "play    auto: 5/10/20 s",
  "hold select  back to modes",
  "menu    quit",
  "hold menu  this help",
}

local function undo()
  -- 退回到上一次轮到你的时候
  local h = G.hist
  while #h > 0 do
    local s = table.remove(h)
    if s.side == 1 then
      G.b, G.side, G.chain, G.last_side = s.b, s.side, s.chain, s.last_side
      G.cur, G.scr = 1, "play"
      save()
      return
    end
  end
end

local function on_key(e)
  local g = select_gesture(e)
  if e.k == "help" then help_screen("MANCALA", HELP); G.full = true; if G.scr == "menu" then draw_menu() end; return end
  if e.k == "menu" then G.quit = true; return end
  if G.scr == "menu" then
    if (e.k == "fwd" or e.k == "back") and not e.rel then
      G.sel = mod(G.sel - 1 + ((e.k == "fwd") and 1 or -1), 3) + 1
      draw_menu()
    elseif g == "short" then new_game(G.sel) end
    return
  end
  if g == "long" then G.sel = G.kind; G.scr = "menu"; save(); draw_menu(); return end
  if G.scr == "over" then
    if g == "short" then
      if G.kind == 3 then new_game(3) else G.sel = G.kind; G.scr = "menu"; draw_menu() end
    end
    return
  end
  if e.k == "play" and not e.rel and not e.rep and G.kind == 3 then G.pace = mod(G.pace, #PACES) + 1; save() end
  if G.phase ~= "pick" or not human(G.side) then return end
  local moves = E.legal(G.b, G.side)
  if (e.k == "fwd" or e.k == "back") and not e.rel and #moves > 0 then
    G.cur = mod(clamp(G.cur, 1, #moves) - 1 + ((e.k == "fwd") and 1 or -1), #moves) + 1
  elseif g == "short" and #moves > 0 then start_move(moves[clamp(G.cur, 1, #moves)])
  elseif e.k == "prev" and not e.rel and not e.rep and G.kind == 2 then undo() end
end

-- ---------- 主循环 ----------
local found = load()
light_start()
if G.scr == "menu" then draw_menu() else render() end
if not found then help_screen("MANCALA", HELP); draw_menu() end

while not G.quit do
  for _, e in ipairs(poll()) do on_key(e) end
  if G.quit then break end
  if G.help_req then G.help_req = nil; help_screen("MANCALA", HELP); G.full = true end
  if G.scr == "play" then
    if G.phase == "sow" or G.phase == "settle" then step_anim()
    elseif G.phase == "pick" and not human(G.side) and rb.current_tick() >= G.wait_until then
      render()
      local pit = think()
      if G.quit then break end
      if pit then start_move(pit) end
    end
    if G.scr ~= "menu" then render() end
  elseif G.scr == "over" then render() end
  keep_light()
  rb.sleep(div(HZ, 20))
end

save()
light_end()
end
main()
