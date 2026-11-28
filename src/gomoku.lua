-- 五子棋：15×15，黑先，连成五子赢
-- 开局界面：转盘选 人对人 / 执黑 / 执白 / 电脑对电脑，Select 开始
-- 跳点（默认）：转盘在已有棋子附近的空位之间跳，从最后一手由近到远；Select 落子
-- Play：切换到自由光标（转盘在一行里左右走，上一首 / 下一首换行）
-- 长按上一首：悔一步（人对电脑）   观战时 Play：每步至少隔 5 / 10 / 20 秒
-- 长按 Select：回开局界面   短按 Menu 退出，长按 Menu 看说明（在说明页按 Play 切换黑方禁手）

local SAVE = "slow_gomoku.txt"
local N = 15

-- ================= 规则和电脑 =================
-- 棋盘 B[r*15+c]：0 空，1 黑，2 白
local A = { B = {} }
do
local B = A.B
for i = 0, N * N - 1 do B[i] = 0 end
local DR, DC = { 0, 1, 1, 1 }, { 1, 0, 1, -1 }
local buf = {}

-- 以 p 为中心、方向 d 上的 11 格：中心当作 who 的子 → "1"，who 的子 "1"，空 "0"，对方或出界 "2"
-- 第二个返回值：中心两边 4 格内 who 自己的子数
local function line(p, d, who)
  local r0, c0 = div(p, N), mod(p, N)
  local dr, dc, own = DR[d], DC[d], 0
  for k = -5, 5 do
    local r, c = r0 + k * dr, c0 + k * dc
    local ch
    if k == 0 then ch = "1"
    elseif r < 0 or r >= N or c < 0 or c >= N then ch = "2"
    else
      local v = B[r * N + c]
      if v == 0 then ch = "0" elseif v == who then
        ch = "1"
        if k >= -4 and k <= 4 then own = own + 1 end
      else ch = "2" end
    end
    buf[k + 6] = ch
  end
  return table.concat(buf), own
end
-- 这个棋形有没有一处盖住中心（第 6 格）
local function covers(s, pat)
  local i = 1
  while true do
    i = string.find(s, pat, i, true)
    if not i then return false end
    if i <= 6 and i + #pat - 1 >= 6 then return true end
    i = i + 1
  end
end
-- 棋形表：{棋形, 分, 子数}，从大到小
local PATS = {
  { "11111", 100000 }, { "011110", 12000 },
  { "11110", 1500 }, { "01111", 1500 }, { "11011", 1500 }, { "10111", 1500 }, { "11101", 1500 },
  { "011100", 900 }, { "001110", 900 }, { "011010", 900 }, { "010110", 900 },
  { "11100", 150 }, { "00111", 150 }, { "11010", 150 }, { "01011", 150 }, { "10110", 150 },
  { "01101", 150 }, { "10011", 150 }, { "11001", 150 }, { "10101", 150 }, { "01110", 150 },
  { "001100", 110 }, { "011000", 90 }, { "000110", 90 }, { "001010", 90 }, { "010100", 90 }, { "010010", 70 },
  { "11000", 20 }, { "00011", 20 }, { "01100", 20 }, { "00110", 20 }, { "01010", 20 }, { "10100", 20 }, { "00101", 20 },
}
for _, pt in ipairs(PATS) do
  local n = 0
  for k = 1, #pt[1] do if string.sub(pt[1], k, k) == "1" then n = n + 1 end end
  pt[3] = n
end
local function pat_score(s, own)
  for _, pt in ipairs(PATS) do
    if pt[3] <= own + 1 and covers(s, pt[1]) then return pt[2] end
  end
  return 1
end

-- 在 p（空位）下 who 的子值多少分：四个方向的棋形加起来，双三、四三再加
local function eval(p, who)
  local sum, n4, n3 = 0, 0, 0
  for d = 1, 4 do
    local s, own = line(p, d, who)
    local v = (own == 0) and 1 or pat_score(s, own)
    sum = sum + v
    if v >= 1500 and v < 100000 then n4 = n4 + 1 elseif v == 900 then n3 = n3 + 1 end
  end
  if n4 >= 2 or (n4 >= 1 and n3 >= 1) then sum = sum + 20000
  elseif n3 >= 2 then sum = sum + 6000 end
  return sum
end
A.eval = eval

-- 黑方禁手（规则打开时）：长连、双四、双三。只看一层，不追究“假禁手”
A.forbidden = function(p)
  B[p] = 1
  local five, over, fours, threes = false, false, 0, 0
  for d = 1, 4 do
    local s = line(p, d, 1)
    if covers(s, "11111") then
      if covers(s, "111111") then over = true else five = true end
    else
      local f, t = false, false
      for k = 2, 10 do
        if k ~= 6 and string.sub(s, k, k) == "0" then
          local s2 = string.sub(s, 1, k - 1) .. "1" .. string.sub(s, k + 1)
          if covers(s2, "11111") and not covers(s2, "111111") then f = true
          elseif covers(s2, "011110") then t = true end
        end
      end
      if f then fours = fours + 1 elseif t then threes = threes + 1 end
    end
  end
  B[p] = 0
  if five then return false end
  return over or fours >= 2 or threes >= 2
end

-- p 刚落了子：连成五子（exact：黑方有禁手时要正好五子）就返回那条线上的格子
A.win_line = function(p, exact)
  local who = B[p]
  local r0, c0 = div(p, N), mod(p, N)
  for d = 1, 4 do
    local cells = { p }
    for _, sgn in ipairs({ 1, -1 }) do
      local r, c = r0 + sgn * DR[d], c0 + sgn * DC[d]
      while r >= 0 and r < N and c >= 0 and c < N and B[r * N + c] == who do
        cells[#cells + 1] = r * N + c
        r, c = r + sgn * DR[d], c + sgn * DC[d]
      end
    end
    if #cells == 5 or (#cells > 5 and not exact) then return cells end
  end
  return nil
end

-- 候选点：已有棋子周围两格内的空位；空棋盘只有天元
A.cands = function(moves)
  local seen, list = {}, {}
  for _, m in ipairs(moves) do
    local r0, c0 = div(m, N), mod(m, N)
    for r = math.max(0, r0 - 2), math.min(N - 1, r0 + 2) do
      for c = math.max(0, c0 - 2), math.min(N - 1, c0 + 2) do
        local q = r * N + c
        if B[q] == 0 and not seen[q] then seen[q] = true; list[#list + 1] = q end
      end
    end
  end
  if #moves == 0 then list[1] = 7 * N + 7 end
  return list
end

-- 电脑想一步：先按棋形给每个候选点打分（进攻 + 防守），
-- 再把前几名各试下一下，看对方接下来最好能得多少分，减掉。
-- hook(p)：每试一个点调用一次，界面拿来在棋盘上淡淡地显示它
A.choose = function(moves, who, rule, r, jitter, hook)
  local opp = 3 - who
  local list = A.cands(moves)
  if #moves == 0 then return list[1] end
  local scored = {}
  for _, p in ipairs(list) do
    if not (rule and who == 1 and A.forbidden(p)) then
      local a = eval(p, who)
      if a >= 100000 then return p end -- 能赢就赢
      scored[#scored + 1] = { p, a + div(eval(p, opp) * 85, 100) }
    end
  end
  if #scored == 0 then return list[1] end
  table.sort(scored, function(x, y) return x[2] > y[2] end)
  local best, bv = scored[1][1], -99999999
  for k = 1, math.min(6, #scored) do
    local p, v = scored[k][1], scored[k][2]
    if hook and hook(p) then return nil end
    B[p] = who
    moves[#moves + 1] = p
    local oa = 0
    for _, q in ipairs(A.cands(moves)) do
      local s = eval(q, opp)
      if s > oa then oa = s end
    end
    moves[#moves] = nil
    B[p] = 0
    v = v - div(oa * 6, 10) + r(jitter + 1)
    if v > bv then best, bv = p, v end
  end
  return best
end
end

-- ================= 界面 =================
local main = function()
local B = A.B
local C = {
  wood = rgb(214, 170, 100), grid = rgb(128, 88, 44), black = rgb(26, 26, 30), shine = rgb(110, 110, 118),
  white = rgb(242, 238, 226), wedge = rgb(150, 138, 116), mark = rgb(222, 56, 40), cursor = rgb(28, 86, 220),
  strip = rgb(58, 62, 70), ink = rgb(236, 236, 230), dim = rgb(170, 172, 178), hi = rgb(240, 150, 60),
  bg = rgb(24, 26, 30),
}
C.ghost = { pack(mix({ 214, 170, 100 }, { 26, 26, 30 }, 40, 100)), pack(mix({ 214, 170, 100 }, { 242, 238, 226 }, 55, 100)) }
local BX, BY, SX = 4, 6, 128
local KINDS = { "2 players", "you black", "you white", "cpu vs cpu" }
local PACES = { 5, 10, 20 }
local THINK_T = div(HZ * 3, 2)
local STAR = { [3 * N + 3] = true, [3 * N + 11] = true, [11 * N + 3] = true, [11 * N + 11] = true, [7 * N + 7] = true }
-- 7×7 的圆：每行 {缩进, 宽}
local DISC = { { 2, 3 }, { 1, 5 }, { 0, 7 }, { 0, 7 }, { 0, 7 }, { 1, 5 }, { 2, 3 } }

local G = {
  scr = "menu", kind = 2, sel = 2, moves = {}, cands = {}, ci = 1, free = false, fr = 7, fc = 7,
  rule = false, pace = 2, games = { 0, 0, 0, 0 }, bw = { 0, 0, 0, 0 }, ww = { 0, 0, 0, 0 },
  result = nil, winline = nil, flash_until = 0, ghost = -1, wait_until = 0, over_at = 0,
  shown = {}, full = true, quit = false, note = nil, note_until = 0, rng = Rng(now()),
}

local function turn() return (mod(#G.moves, 2) == 0) and 1 or 2 end
local function human(who)
  return G.kind == 1 or (G.kind == 2 and who == 1) or (G.kind == 3 and who == 2)
end

-- ---------- 存档 ----------
local function save()
  local s = { moves = table.concat(G.moves, ","), kind = G.kind, rule = G.rule and 1 or 0, pace = G.pace,
              scr = G.scr, result = G.result or "" }
  for k = 1, 4 do s["g" .. k] = G.games[k] .. "," .. G.bw[k] .. "," .. G.ww[k] end
  save_kv(SAVE, s)
end

-- 候选点按“好用”排序：要紧的点（堵对方、接自己）先按分数，其余从最后一手由近到远
local function refresh()
  local who = turn()
  local last = G.moves[#G.moves]
  local lr, lc = 7, 7
  if last then lr, lc = div(last, N), mod(last, N) end
  local list = {}
  for _, p in ipairs(A.cands(G.moves)) do
    if not (G.rule and who == 1 and A.forbidden(p)) then
      local v = A.eval(p, who) + A.eval(p, 3 - who)
      local dr, dc = iabs(div(p, N) - lr), iabs(mod(p, N) - lc)
      list[#list + 1] = { p = p, v = v, urgent = v >= 900, d = math.max(dr, dc) * 100 + dr + dc }
    end
  end
  table.sort(list, function(a, b)
    if a.urgent ~= b.urgent then return a.urgent end
    if a.urgent and a.v ~= b.v then return a.v > b.v end
    if a.d ~= b.d then return a.d < b.d end
    if a.v ~= b.v then return a.v > b.v end
    return a.p < b.p
  end)
  G.cands, G.ci = {}, 1
  for i, it in ipairs(list) do G.cands[i] = it.p end
end

local function rebuild(moves)
  for i = 0, N * N - 1 do B[i] = 0 end
  for i, p in ipairs(moves) do B[p] = (mod(i, 2) == 1) and 1 or 2 end
  G.moves, G.result, G.winline = moves, nil, nil
end

local function load()
  local s, found = load_kv(SAVE)
  G.kind = clamp(num(s.kind, 2), 1, 4)
  G.sel, G.rule, G.pace = G.kind, s.rule == "1", clamp(num(s.pace, 2), 1, #PACES)
  for k = 1, 4 do
    local a, b, c = string.match(s["g" .. k] or "", "(%d+),(%d+),(%d+)")
    G.games[k], G.bw[k], G.ww[k] = num(a, 0), num(b, 0), num(c, 0)
  end
  if s.scr == "play" or s.scr == "over" then
    local mv, used = {}, {}
    for v in string.gmatch(s.moves or "", "%d+") do
      local p = num(v, -1)
      if p >= 0 and p < N * N and not used[p] then used[p] = true; mv[#mv + 1] = p end
    end
    rebuild(mv)
    G.scr = s.scr
    if s.result and s.result ~= "" then G.result = s.result end
    local last = mv[#mv]
    if last and G.scr == "over" then G.winline = A.win_line(last, G.rule) end
    G.over_at = rb.current_tick()
    refresh()
  end
  return found
end

-- ---------- 画面 ----------
local function cursor_at()
  if G.scr ~= "play" or not human(turn()) then return -1 end
  if G.free then return G.fr * N + G.fc end
  return G.cands[G.ci] or -1
end
local function disc(x, y, col)
  fg(col)
  for k = 1, 7 do rect(x + DISC[k][1], y + k - 1, DISC[k][2], 1) end
end
local function draw_cell(p, stone, mark, cur, ghost)
  local r, c = div(p, N), mod(p, N)
  local x, y = BX + c * 8, BY + r * 8
  fg(C.wood); rect(x, y, 8, 8)
  fg(C.grid)
  local x0, x1 = (c == 0) and 3 or 0, (c == N - 1) and 3 or 7
  local y0, y1 = (r == 0) and 3 or 0, (r == N - 1) and 3 or 7
  rect(x + x0, y + 3, x1 - x0 + 1, 1)
  rect(x + 3, y + y0, 1, y1 - y0 + 1)
  if STAR[p] then rect(x + 2, y + 2, 3, 3) end
  if stone == 1 then
    disc(x, y, C.black)
    fg(C.shine); rect(x + 2, y + 2, 1, 1)
  elseif stone == 2 then
    disc(x, y, C.wedge)
    fg(C.white)
    rect(x + 2, y + 1, 3, 1); rect(x + 1, y + 2, 5, 3); rect(x + 2, y + 5, 3, 1)
  elseif ghost > 0 then
    disc(x, y, C.ghost[ghost])
  end
  if mark then fg(C.mark); rect(x + 2, y + 2, 3, 3) end
  if cur then
    fg(C.cursor)
    rect(x, y, 3, 1); rect(x, y, 1, 3); rect(x + 5, y, 3, 1); rect(x + 7, y, 1, 3)
    rect(x, y + 7, 3, 1); rect(x, y + 5, 1, 3); rect(x + 5, y + 7, 3, 1); rect(x + 7, y + 5, 1, 3)
  end
end

local function strip_lines()
  local who = turn()
  local t = {}
  if G.scr == "over" then
    t[1] = (G.result == "draw") and "draw" or ((G.result == "b") and "black" or "white")
    t[2] = (G.result == "draw") and "" or "wins"
    t[3] = "sel:new"
  else
    t[1] = (who == 1) and "black" or "white"
    t[2] = human(who) and "" or "thinks"
    t[3] = ""
  end
  t[4] = "#" .. #G.moves
  if G.kind == 4 then t[5], t[6] = "auto", PACES[G.pace] .. "s"
  else t[5] = ({ "2P", "you B", "you W" })[G.kind]; t[6] = G.free and "free" or "jump" end
  t[7] = G.rule and "limits" or ""
  t[8] = G.note or ""
  return t, who
end
local function draw_strip()
  local t, who = strip_lines()
  local key = table.concat(t, "|") .. who
  if G.shown.strip == key then return end
  G.shown.strip = key
  fg(C.strip); rect(SX, 0, W - SX, H)
  if G.scr ~= "over" then
    if who == 1 then disc(SX + 4, 6, C.black) else disc(SX + 4, 6, C.wedge); fg(C.white); rect(SX + 5, 7, 5, 5) end
    text(SX + 14, 6, t[1], C.ink, C.strip)
  else text(SX + 3, 6, t[1], C.hi, C.strip) end
  text(SX + 3, 18, t[2], (G.scr == "over") and C.hi or C.dim, C.strip)
  text(SX + 3, 30, t[3] or "", C.ink, C.strip)
  text(SX + 3, 50, t[4], C.dim, C.strip)
  text(SX + 3, 70, t[5], C.ink, C.strip)
  text(SX + 3, 80, t[6], C.dim, C.strip)
  text(SX + 3, 100, t[7], C.dim, C.strip)
  text(SX + 3, 116, t[8], C.hi, C.strip)
end

local function render()
  if G.full then
    fg(C.wood); rect(0, 0, SX, H)
    G.shown, G.full = {}, false
  end
  local cur, last = cursor_at(), G.moves[#G.moves]
  local hide = {}
  -- 连成五子：那条线闪几下
  if G.winline and rb.current_tick() < G.flash_until and mod(div(rb.current_tick() * 10, HZ * 3), 2) == 1 then
    for _, p in ipairs(G.winline) do hide[p] = true end
  end
  local gw = (G.ghost >= 0) and turn() or 0
  for p = 0, N * N - 1 do
    local st = hide[p] and 0 or B[p]
    local gh = (p == G.ghost and st == 0) and gw or 0
    local key = st * 1000 + gh * 100 + ((p == last) and 10 or 0) + ((p == cur) and 1 or 0)
    if G.shown[p] ~= key then
      G.shown[p] = key
      draw_cell(p, st, p == last and st > 0, p == cur, gh)
    end
  end
  draw_strip()
  rb.lcd_update()
end

local function draw_menu()
  fg(C.bg); rect(0, 0, W, H)
  text(4, 3, "GOMOKU", C.hi, C.bg)
  for k = 1, 4 do
    local y = 18 + (k - 1) * 24
    if k == G.sel then fg(C.hi); rect(2, y - 1, 3, 19) end
    text(10, y, KINDS[k], (k == G.sel) and C.hi or C.ink, C.bg)
    text(10, y + 10, G.games[k] .. " games  B " .. G.bw[k] .. "  W " .. G.ww[k], C.dim, C.bg)
  end
  text(10, 118, G.rule and "rule: black limits" or "rule: free", C.dim, C.bg)
  rb.lcd_update()
  G.full = true
end

-- ---------- 走棋 ----------
local function new_game(kind)
  G.kind, G.scr, G.free, G.ghost, G.wait_until = kind, "play", false, -1, 0
  rebuild({})
  refresh()
  G.full = true
  save()
end
local function finish(result)
  G.result, G.scr, G.over_at = result, "over", rb.current_tick()
  local k = G.kind
  G.games[k] = G.games[k] + 1
  if result == "b" then G.bw[k] = G.bw[k] + 1 elseif result == "w" then G.ww[k] = G.ww[k] + 1 end
  save()
end
local function place(p)
  local who = turn()
  B[p] = who
  G.moves[#G.moves + 1] = p
  local wl = A.win_line(p, G.rule and who == 1)
  if wl then
    G.winline, G.flash_until = wl, rb.current_tick() + 3 * HZ
    finish((who == 1) and "b" or "w")
  elseif #G.moves >= N * N then finish("draw")
  else refresh(); save() end
end
local function say(s) G.note, G.note_until = s, rb.current_tick() + 2 * HZ end

local function think()
  local started, who = rb.current_tick(), turn()
  local hook = function(p)
    G.ghost = p
    render()
    for _, e in ipairs(poll()) do
      if e.k == "menu" then G.quit = true elseif e.k == "help" then G.help_req = true end
    end
    keep_light()
    rb.sleep(div(HZ, 8))
    return G.quit
  end
  local jitter = (G.kind == 4) and 60 or 3
  local p = A.choose(G.moves, who, G.rule, G.rng, jitter, hook)
  if not p or G.quit then G.ghost = -1; return end
  -- 每步有固定的思考时间：想完了也在选中的点上停一会儿
  G.ghost = p
  while not G.quit and rb.current_tick() < started + THINK_T do
    render()
    for _, e in ipairs(poll()) do if e.k == "menu" then G.quit = true end end
    rb.sleep(div(HZ, 10))
  end
  G.ghost = -1
  if G.quit then return end
  if G.kind == 4 then G.wait_until = started + PACES[G.pace] * HZ end
  place(p)
end

local function help()
  local k = help_screen("GOMOKU", {
    "Five in a row wins.",
    "Black plays first.",
    "",
    "*Keys",
    "wheel  jump to spots near",
    "       the stones",
    "select place a stone",
    "play   jump / free cursor",
    "free:  wheel along the row,",
    "       prev / next: row",
    "hold prev    undo (vs cpu)",
    "hold select  back to modes",
    "menu   quit",
    "",
    "*Watching",
    "play   5 / 10 / 20 s a move",
    "select next game",
    "",
    G.rule and "*Black limits: ON" or "*Black limits: OFF",
    "no 3-3, 4-4 or 6+ for black",
    "PLAY here to switch",
  })
  if k == "play" then
    G.rule = not G.rule
    say(G.rule and "limits" or "free")
    if G.scr == "play" then refresh() end
    save()
  end
  G.full = true
  if G.scr == "menu" then draw_menu() end
end

local function undo()
  local me = (G.kind == 3) and 2 or 1
  local mv = G.moves
  while #mv > 0 do
    local n = #mv
    table.remove(mv)
    if ((mod(n, 2) == 1) and 1 or 2) == me then break end -- 退掉了自己的一手就停
  end
  rebuild(mv)
  G.scr = "play"
  refresh()
  save()
end

local function try_place(p)
  if p < 0 or B[p] ~= 0 then return end
  if G.rule and turn() == 1 and A.forbidden(p) then say("no!"); return end
  place(p)
end

local function on_key(e)
  local g = select_gesture(e)
  if e.k == "help" then help(); return end
  if e.k == "menu" then G.quit = true; return end
  local turn_ = (e.k == "fwd" or e.k == "back") and not e.rel
  if G.scr == "menu" then
    if turn_ then G.sel = mod(G.sel - 1 + ((e.k == "fwd") and 1 or -1), 4) + 1; draw_menu()
    elseif g == "short" then new_game(G.sel) end
    return
  end
  if g == "long" then G.sel, G.scr = G.kind, "menu"; save(); draw_menu(); return end
  -- 上一首：短按换行（自由光标），按住悔棋
  if e.k == "prev" then
    if not e.rel and not e.rep then G.prev_down, G.prev_fired = rb.current_tick(), false
    elseif e.rep and G.prev_down and not G.prev_fired and rb.current_tick() - G.prev_down >= div(HZ * 4, 5) then
      G.prev_fired = true
      if G.kind == 2 or G.kind == 3 then undo() end
    elseif e.rel then
      if G.prev_down and not G.prev_fired and G.free then G.fr = mod(G.fr - 1, N) end
      G.prev_down = nil
    end
    return
  end
  if G.scr == "over" then
    if g == "short" then
      if G.kind == 4 then new_game(4) else G.sel, G.scr = G.kind, "menu"; draw_menu() end
    end
    return
  end
  if e.k == "play" and not e.rel and not e.rep then
    if G.kind == 4 then G.pace = mod(G.pace, #PACES) + 1; save()
    else
      G.free = not G.free
      local p = G.cands[G.ci]
      if G.free and p then G.fr, G.fc = div(p, N), mod(p, N) end
    end
    return
  end
  if not human(turn()) then return end
  if turn_ then
    local d = (e.k == "fwd") and 1 or -1
    if G.free then G.fc = mod(G.fc + d, N)
    elseif #G.cands > 0 then G.ci = mod(G.ci - 1 + d, #G.cands) + 1 end
  elseif e.k == "next" and not e.rel and not e.rep and G.free then G.fr = mod(G.fr + 1, N)
  elseif g == "short" then
    if G.free then try_place(G.fr * N + G.fc) else try_place(G.cands[G.ci] or -1) end
  end
end

-- ---------- 主循环 ----------
local found = load()
light_start()
if not found then help() end
if G.scr == "menu" then draw_menu() else render() end

while not G.quit do
  for _, e in ipairs(poll()) do on_key(e) end
  if G.quit then break end
  if G.help_req then G.help_req = nil; help() end
  if G.note and rb.current_tick() > G.note_until then G.note = nil end
  if G.scr == "play" and not human(turn()) and rb.current_tick() >= G.wait_until then
    render()
    think()
  end
  -- 电脑对电脑：终局停一分钟，没人按 Select 就自己开下一局（可以放一整晚）
  if G.scr == "over" and G.kind == 4 and rb.current_tick() > G.over_at + 60 * HZ then new_game(4) end
  if G.scr ~= "menu" and not G.quit then render() end
  keep_light()
  rb.sleep(div(HZ, 20))
end

save()
light_end()
end
main()
