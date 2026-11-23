-- 国际象棋：和机器里的对手下棋。它思考时，正在考虑的走法会在棋盘上淡淡闪过
-- 选子：转盘在能动的棋子之间跳，落点提示跟着显示；Select 选中
-- 落子：转盘在合法落点之间跳；Select 落子；Menu 退回选子
-- 上一首：悔一步   Play：思考时间 3 / 10 / 30 秒   Menu（选子时）：退出

local SAVE = "slow_chess.txt"

-- ================= 引擎 =================
-- 10×12 信箱棋盘：a8 = 21，h8 = 28，a1 = 91，h1 = 98；外圈是 OFF
-- 棋子：兵 1 马 2 象 3 车 4 后 5 王 6，白正黑负
local E = (function()
local OFF = 99
local B, K, CR = {}, {}, {}          -- 棋盘；王的位置 K[1]/K[-1]；易位权 CR[1..4]：白短 白长 黑短 黑长
local SQ, ROW, COL = {}, {}, {}
local PSQ = {}                       -- PSQ[棋子][格] = 子力 + 位置分（白正黑负）
local MF, MT, MP, MX, MS = {}, {}, {}, {}, {} -- 走法栈：起点 终点 升变 标记 排序分
local U = { cap = {}, ep = {}, cr = {}, ev = {}, m = {} } -- 每层的撤销信息
local st = { side = 1, ep = 0, ev = 0, ply = 0, top = 0, nodes = 0, abort = false }
local KN = { -21, -19, -12, -8, 8, 12, 19, 21 }
local DIAG = { -11, -9, 9, 11 }
local ORTH = { -10, -1, 1, 10 }
local ALL8 = { -11, -10, -9, -1, 1, 9, 10, 11 }
local VAL = { 100, 320, 330, 500, 900, 0 }
local MATE = 30000
-- 每格的危险：动了这些格子（王或车）就失去对应的易位权
local CR_LOSE = { [95] = { 1, 2 }, [98] = { 1 }, [91] = { 2 }, [25] = { 3, 4 }, [28] = { 3 }, [21] = { 4 } }

-- 位置分（白方视角，a8 → h1）
local T = {
  { 0, 0, 0, 0, 0, 0, 0, 0, 50, 50, 50, 50, 50, 50, 50, 50, 10, 10, 20, 30, 30, 20, 10, 10, 5, 5, 10, 25, 25, 10, 5, 5,
    0, 0, 0, 20, 20, 0, 0, 0, 5, -5, -10, 0, 0, -10, -5, 5, 5, 10, 10, -20, -20, 10, 10, 5, 0, 0, 0, 0, 0, 0, 0, 0 },
  { -50, -40, -30, -30, -30, -30, -40, -50, -40, -20, 0, 0, 0, 0, -20, -40, -30, 0, 10, 15, 15, 10, 0, -30, -30, 5, 15, 20, 20, 15, 5, -30,
    -30, 0, 15, 20, 20, 15, 0, -30, -30, 5, 10, 15, 15, 10, 5, -30, -40, -20, 0, 5, 5, 0, -20, -40, -50, -40, -30, -30, -30, -30, -40, -50 },
  { -20, -10, -10, -10, -10, -10, -10, -20, -10, 0, 0, 0, 0, 0, 0, -10, -10, 0, 5, 10, 10, 5, 0, -10, -10, 5, 5, 10, 10, 5, 5, -10,
    -10, 0, 10, 10, 10, 10, 0, -10, -10, 10, 10, 10, 10, 10, 10, -10, -10, 5, 0, 0, 0, 0, 5, -10, -20, -10, -10, -10, -10, -10, -10, -20 },
  { 0, 0, 0, 0, 0, 0, 0, 0, 5, 10, 10, 10, 10, 10, 10, 5, -5, 0, 0, 0, 0, 0, 0, -5, -5, 0, 0, 0, 0, 0, 0, -5,
    -5, 0, 0, 0, 0, 0, 0, -5, -5, 0, 0, 0, 0, 0, 0, -5, -5, 0, 0, 0, 0, 0, 0, -5, 0, 0, 0, 5, 5, 0, 0, 0 },
  { -20, -10, -10, -5, -5, -10, -10, -20, -10, 0, 0, 0, 0, 0, 0, -10, -10, 0, 5, 5, 5, 5, 0, -10, -5, 0, 5, 5, 5, 5, 0, -5,
    0, 0, 5, 5, 5, 5, 0, -5, -10, 5, 5, 5, 5, 5, 0, -10, -10, 0, 5, 0, 0, 0, 0, -10, -20, -10, -10, -5, -5, -10, -10, -20 },
  { -30, -40, -40, -50, -50, -40, -40, -30, -30, -40, -40, -50, -50, -40, -40, -30, -30, -40, -40, -50, -50, -40, -40, -30, -30, -40, -40, -50, -50, -40, -40, -30,
    -20, -30, -30, -40, -40, -30, -30, -20, -10, -20, -20, -20, -20, -20, -20, -10, 20, 20, 0, 0, 0, 0, 20, 20, 20, 30, 10, 0, 0, 10, 30, 20 },
}
for k = 1, 64 do
  local r, f = div(k - 1, 8), mod(k - 1, 8)
  local sq = (r + 2) * 10 + f + 1
  SQ[k], ROW[sq], COL[sq] = sq, r + 2, f + 1
end
PSQ[0] = {}
for t = 1, 6 do
  PSQ[t], PSQ[-t] = {}, {}
  for k = 1, 64 do
    local sq = SQ[k]
    local r, f = div(k - 1, 8), mod(k - 1, 8)
    PSQ[t][sq] = VAL[t] + T[t][k]
    PSQ[-t][sq] = -(VAL[t] + T[t][(7 - r) * 8 + f + 1])
  end
end
for i = 0, 119 do PSQ[0][i] = 0 end

local function attacked(sq, by) -- by 方有没有子攻击 sq
  if by == 1 then
    if B[sq + 9] == 1 or B[sq + 11] == 1 then return true end
  elseif B[sq - 9] == -1 or B[sq - 11] == -1 then return true end
  for i = 1, 8 do
    if B[sq + KN[i]] == 2 * by then return true end
    if B[sq + ALL8[i]] == 6 * by then return true end
  end
  for i = 1, 4 do
    local o = DIAG[i]
    local t = sq + o
    while B[t] == 0 do t = t + o end
    if B[t] == 3 * by or B[t] == 5 * by then return true end
    o = ORTH[i]
    t = sq + o
    while B[t] == 0 do t = t + o end
    if B[t] == 4 * by or B[t] == 5 * by then return true end
  end
  return false
end

local function add(from, to, pr, fl, score)
  local n = st.top + 1
  st.top = n
  MF[n], MT[n], MP[n], MX[n], MS[n] = from, to, pr, fl, score
end
local function add_pawn(from, to, cap_score, promo_row)
  if ROW[to] == promo_row then
    add(from, to, 5, 0, 900 + cap_score); add(from, to, 2, 0, 300 + cap_score)
    add(from, to, 4, 0, 1 + cap_score); add(from, to, 3, 0, 1 + cap_score)
  else
    add(from, to, 0, 0, cap_score)
  end
end

-- 生成当前一方的伪合法走法，放在栈顶；caps：只要吃子（静态搜索用）
local function gen(caps)
  local s = st.side
  local fwd = -10 * s
  local promo_row = (s == 1) and 2 or 9
  local start_row = (s == 1) and 8 or 3
  for k = 1, 64 do
    local sq = SQ[k]
    local p = B[sq] * s
    if p > 0 and p ~= OFF and p ~= -OFF then
      if p == 1 then
        local to = sq + fwd
        if not caps and B[to] == 0 then
          add_pawn(sq, to, 0, promo_row)
          if ROW[sq] == start_row and B[to + fwd] == 0 then add(sq, to + fwd, 0, 1, 0) end
        end
        for d = -1, 1, 2 do
          local t2 = to + d
          local q = B[t2]
          if q ~= OFF and q * s < 0 then add_pawn(sq, t2, -q * s * 10, promo_row)
          elseif t2 == st.ep then add(sq, t2, 0, 2, 9) end
        end
      else
        local dirs, slide = ALL8, false
        if p == 2 then dirs = KN elseif p == 3 then dirs, slide = DIAG, true
        elseif p == 4 then dirs, slide = ORTH, true elseif p == 5 then slide = true end
        for i = 1, #dirs do
          local o = dirs[i]
          local to = sq + o
          local q = B[to]
          while q ~= OFF do
            if q == 0 then
              if not caps then add(sq, to, 0, 0, 0) end
            else
              if q * s < 0 then add(sq, to, 0, 0, -q * s * 10 - p) end
              break
            end
            if not slide then break end
            to = to + o
            q = B[to]
          end
        end
        if p == 6 and not caps then -- 王车易位
          local home = (s == 1) and 95 or 25
          local ks, qs = (s == 1) and 1 or 3, (s == 1) and 2 or 4
          if sq == home and not attacked(home, -s) then
            if CR[ks] and B[home + 1] == 0 and B[home + 2] == 0 and B[home + 3] == 4 * s
              and not attacked(home + 1, -s) and not attacked(home + 2, -s) then add(home, home + 2, 0, 3, 0) end
            if CR[qs] and B[home - 1] == 0 and B[home - 2] == 0 and B[home - 3] == 0 and B[home - 4] == 4 * s
              and not attacked(home - 1, -s) and not attacked(home - 2, -s) then add(home, home - 2, 0, 3, 0) end
          end
        end
      end
    end
  end
end

local function unmake()
  local ply = st.ply
  local i = U.m[ply]
  st.ply = ply - 1
  st.side = -st.side
  local s = st.side
  local from, to, fl = MF[i], MT[i], MX[i]
  local p = B[to]
  if MP[i] > 0 then p = s end -- 升变：退回成兵
  B[from] = p
  B[to] = U.cap[ply]
  if fl == 2 then B[to] = 0; B[to + 10 * s] = -s end
  if fl == 3 then
    if to > from then B[from + 3] = B[from + 1]; B[from + 1] = 0
    else B[from - 4] = B[from - 1]; B[from - 1] = 0 end
  end
  if p == 6 * s then K[s] = from end
  st.ep, st.ev = U.ep[ply], U.ev[ply]
  local c = U.cr[ply]
  CR[1], CR[2], CR[3], CR[4] = c[1], c[2], c[3], c[4]
end

-- 走第 i 步；不合法（走完自己的王被将）就退回并返回 false
local function make(i)
  local s = st.side
  local from, to, pr, fl = MF[i], MT[i], MP[i], MX[i]
  local p, cap = B[from], B[to]
  local ply = st.ply + 1
  st.ply = ply
  U.m[ply], U.cap[ply], U.ep[ply], U.ev[ply] = i, cap, st.ep, st.ev
  local c = U.cr[ply]
  if not c then c = {}; U.cr[ply] = c end
  c[1], c[2], c[3], c[4] = CR[1], CR[2], CR[3], CR[4]
  local ev = st.ev - PSQ[p][from] - PSQ[cap][to]
  local np = p
  if pr > 0 then np = pr * s end
  B[to], B[from] = np, 0
  ev = ev + PSQ[np][to]
  if fl == 2 then -- 吃过路兵
    local cs = to + 10 * s
    ev = ev - PSQ[-s][cs]
    B[cs] = 0
  elseif fl == 3 then -- 易位：车跟着走
    local rf, rt = from + 3, from + 1
    if to < from then rf, rt = from - 4, from - 1 end
    local r = B[rf]
    ev = ev - PSQ[r][rf] + PSQ[r][rt]
    B[rt], B[rf] = r, 0
  end
  st.ev = ev
  if p == 6 * s then K[s] = to end
  st.ep = (fl == 1) and (from - 10 * s) or 0
  local l = CR_LOSE[from]
  if l then for _, k in ipairs(l) do CR[k] = false end end
  l = CR_LOSE[to]
  if l then for _, k in ipairs(l) do CR[k] = false end end
  st.side = -s
  if attacked(K[s], -s) then unmake(); return false end
  return true
end

local function pick_best(i, last) -- 把 i..last 里排序分最高的换到 i；都是 0 就不排了
  local best, bi = MS[i], i
  for j = i + 1, last do if MS[j] > best then best, bi = MS[j], j end end
  if bi ~= i then
    MF[i], MF[bi] = MF[bi], MF[i]; MT[i], MT[bi] = MT[bi], MT[i]
    MP[i], MP[bi] = MP[bi], MP[i]; MX[i], MX[bi] = MX[bi], MX[i]; MS[i], MS[bi] = MS[bi], MS[i]
  end
  return best > 0
end

local deadline, node_cap = 0, 0
local function tick_check()
  st.nodes = st.nodes + 1
  if mod(st.nodes, 64) == 0 and (rb.current_tick() > deadline or st.nodes > node_cap) then st.abort = true end
end

local function qsearch(alpha, beta, depth)
  tick_check()
  local stand = st.ev * st.side
  if stand >= beta then return stand end
  if stand > alpha then alpha = stand end
  if depth <= 0 or st.abort then return alpha end
  local base = st.top
  gen(true)
  local last = st.top
  for i = base + 1, last do
    pick_best(i, last)
    if make(i) then
      local sc = -qsearch(-beta, -alpha, depth - 1)
      unmake()
      if sc > alpha then alpha = sc end
      if alpha >= beta or st.abort then break end
    end
  end
  st.top = base
  return alpha
end

local function negamax(depth, alpha, beta, root_ply)
  if depth <= 0 then return qsearch(alpha, beta, 4) end
  tick_check()
  local base = st.top
  gen(false)
  local last = st.top
  local legal, sorting = 0, true
  for i = base + 1, last do
    if sorting then sorting = pick_best(i, last) end
    if make(i) then
      legal = legal + 1
      local sc = -negamax(depth - 1, -beta, -alpha, root_ply)
      unmake()
      if sc > alpha then alpha = sc end
      if alpha >= beta or st.abort then break end
    end
  end
  st.top = base
  if legal == 0 and not st.abort then
    if attacked(K[st.side], -st.side) then return -MATE + (st.ply - root_ply) end
    return 0
  end
  return alpha
end

local api = { B = B }
-- 测试用：数走法（perft），和摆 FEN 局面
local function perft(d)
  if d == 0 then return 1 end
  local base = st.top
  gen(false)
  local last, n = st.top, 0
  for i = base + 1, last do
    if make(i) then n = n + perft(d - 1); unmake() end
  end
  st.top = base
  return n
end
api.perft = perft
api.fen = function(f)
  local board, side, cast, ep = string.match(f, "^(%S+) (%S) (%S+) (%S+)")
  for i = 0, 119 do B[i] = OFF end
  local r, c = 2, 1
  local CODE = { p = 1, n = 2, b = 3, r = 4, q = 5, k = 6 }
  for k = 1, #board do
    local ch = string.sub(board, k, k)
    if ch == "/" then r, c = r + 1, 1
    elseif tonumber(ch) then for _ = 1, tonumber(ch) do B[r * 10 + c] = 0; c = c + 1 end
    else
      local lo = string.lower(ch)
      local v = (lo == ch) and -CODE[lo] or CODE[lo]
      B[r * 10 + c] = v
      if v == 6 then K[1] = r * 10 + c elseif v == -6 then K[-1] = r * 10 + c end
      c = c + 1
    end
  end
  st.side = (side == "w") and 1 or -1
  CR[1], CR[2] = string.find(cast, "K") ~= nil, string.find(cast, "Q") ~= nil
  CR[3], CR[4] = string.find(cast, "k") ~= nil, string.find(cast, "q") ~= nil
  st.ep = 0
  if ep ~= "-" then st.ep = (10 - tonumber(string.sub(ep, 2, 2))) * 10 + string.byte(ep, 1) - 96 end
  st.ply, st.top = 0, 0
  local ev = 0
  for k = 1, 64 do local sq = SQ[k]; ev = ev + PSQ[B[sq]][sq] end
  st.ev = ev
end
api.side = function() return st.side end
api.in_check = function() return attacked(K[st.side], -st.side) end
api.new_game = function()
  for i = 0, 119 do B[i] = OFF end
  local back = { 4, 2, 3, 5, 6, 3, 2, 4 }
  for f = 1, 8 do
    B[20 + f], B[30 + f] = -back[f], -1
    B[80 + f], B[90 + f] = 1, back[f]
    for r = 4, 7 do B[r * 10 + f] = 0 end
  end
  K[1], K[-1] = 95, 25
  CR[1], CR[2], CR[3], CR[4] = true, true, true, true
  st.side, st.ep, st.ply, st.top = 1, 0, 0, 0
  local ev = 0
  for k = 1, 64 do local sq = SQ[k]; ev = ev + PSQ[B[sq]][sq] end
  st.ev = ev
end
-- 当前一方的全部合法走法：{ {f=, t=, p=}, ... }
api.legal = function()
  st.top = 0
  gen(false)
  local out = {}
  for i = 1, st.top do
    if make(i) then
      unmake()
      out[#out + 1] = { f = MF[i], t = MT[i], p = MP[i] }
    end
  end
  st.top = 0
  return out
end
-- 走一步棋（对局里真正走的）。找不到返回 false
api.play = function(f, t, p)
  st.top = 0
  gen(false)
  for i = 1, st.top do
    if MF[i] == f and MT[i] == t and MP[i] == p and make(i) then
      st.ply, st.top = 0, 0
      return true
    end
  end
  st.top = 0
  return false
end
-- 局面结束了没有："mate" / "stalemate" / "draw"（只剩王，或王加一个轻子） / nil
api.status = function()
  local minors, others = 0, 0
  for k = 1, 64 do
    local a = B[SQ[k]]
    if a < 0 then a = -a end
    if a == 2 or a == 3 then minors = minors + 1 elseif a == 1 or a == 4 or a == 5 then others = others + 1 end
  end
  if others == 0 and minors <= 1 then return "draw" end
  if #api.legal() > 0 then return nil end
  if api.in_check() then return "mate" end
  return "stalemate"
end
-- 逐步加深搜索。hook(from, to) 在根节点每换一个候选走法时调用（画“看得见的思考”，也读按键）
api.search = function(secs, hook)
  st.top, st.ply, st.nodes, st.abort = 0, 0, 0, false
  deadline = rb.current_tick() + secs * HZ
  node_cap = secs * 3000
  gen(false)
  local n = 0
  for i = 1, st.top do -- 只留合法的，挪到前面
    if make(i) then
      unmake()
      n = n + 1
      MF[n], MT[n], MP[n], MX[n], MS[n] = MF[i], MT[i], MP[i], MX[i], MS[i]
    end
  end
  st.top = n
  if n == 0 then return nil end
  for i = 1, n do pick_best(i, n) end
  local best_i, best_sc = 1, -MATE
  for depth = 1, 6 do
    local alpha, cur_i, done = -MATE - 1, 1, true
    for i = 1, n do
      if hook then hook(MF[i], MT[i]) end
      make(i)
      local sc = -negamax(depth - 1, -MATE - 1, -alpha, 0)
      unmake()
      if st.abort and depth > 1 then done = false; break end
      if sc > alpha then alpha, cur_i = sc, i end
    end
    if not done then break end
    best_i, best_sc = cur_i, alpha
    -- 最好的一步挪到最前面，下一层先搜它
    MF[1], MF[best_i] = MF[best_i], MF[1]; MT[1], MT[best_i] = MT[best_i], MT[1]
    MP[1], MP[best_i] = MP[best_i], MP[1]; MX[1], MX[best_i] = MX[best_i], MX[1]
    best_i = 1
    if best_sc >= MATE - 50 or st.abort then break end
  end
  local f, t, p = MF[best_i], MT[best_i], MP[best_i]
  st.top = 0
  return f, t, p, best_sc, st.nodes
end
return api
end)()

-- ================= 界面 =================
local main = function()
local SQS, BX, BY = 16, 0, 2         -- 每格 16 像素；棋盘左上角
local SX = 128                       -- 右边的窄条
local LIGHT, DARK = { 214, 202, 172 }, { 122, 146, 112 }
local C = {
  wfill = rgb(246, 243, 232), wline = rgb(40, 36, 32),
  bfill = rgb(46, 42, 40), bline = rgb(10, 8, 8),
  hint = rgb(240, 196, 70), cursor = rgb(250, 220, 90),
  strip = rgb(30, 32, 36), ink = rgb(190, 192, 196), dim = rgb(110, 114, 120),
}
-- 每格的底色：普通 / 上一步 / 被将 / 选中 / 思考中
local TINT = { last = { 236, 214, 120 }, check = { 230, 90, 80 }, sel = { 150, 200, 120 }, think = { 120, 150, 230 } }
local SQC = {}
for _, base in ipairs({ LIGHT, DARK }) do
  local t = { plain = pack(base) }
  for k, v in pairs(TINT) do t[k] = pack(mix(base, v, (k == "think") and 45 or 55, 100)) end
  SQC[#SQC + 1] = t
end

-- 棋子点阵：o 是轮廓，x 是填充；12 宽，底部对齐
local ART = {
  { "....oooo....", "...oxxxxo...", "...oxxxxo...", "....oxxo....", "...oxxxxo...", "....oxxo....",
    "....oxxo....", "...oxxxxo...", "..oxxxxxxo..", ".oxxxxxxxxo.", ".oooooooooo." },
  { "....oo......", "...oxxoo....", "..oxxxxxoo..", ".oxxoxxxxxo.", ".oxxxxxxxxo.", "..ooooxxxxo.",
    "....oxxxxo..", "...oxxxxxo..", "...oxxxxxo..", "..oxxxxxxxo.", ".oxxxxxxxxo.", ".oooooooooo." },
  { ".....oo.....", "....oxxo....", "...oxxoxo...", "...oxoxxo...", "...oxxxxo...", "....oxxo....",
    "...oooooo...", "....oxxo....", "...oxxxxo...", "..oxxxxxxo..", ".oxxxxxxxxo.", ".oooooooooo." },
  { ".oo.oooo.oo.", ".oxooxxooxo.", ".oxxxxxxxxo.", ".oooxxxxooo.", "...oxxxxo...", "...oxxxxo...",
    "...oxxxxo...", "...oxxxxo...", "..oxxxxxxo..", ".oxxxxxxxxo.", ".oooooooooo." },
  { "o...o..o...o", "ox.oxooxo.xo", "oxxoxxxxoxxo", ".oxxxxxxxxo.", "..oxxxxxxo..", "...oxxxxo...",
    "...oxxxxo...", "..oooooooo..", "...oxxxxo...", "..oxxxxxxo..", ".oxxxxxxxxo.", ".oooooooooo." },
  { ".....oo.....", "...ooxxoo...", "...ooxxoo...", ".oooooooooo.", ".oxxxxxxxxo.", "..oxxxxxxo..",
    "...oxxxxo...", "..oooooooo..", "...oxxxxo...", "..oxxxxxxo..", ".oxxxxxxxxo.", ".oooooooooo." },
}
-- 预先转成游程：{ 是否轮廓, x, y, 长度 }；small 是缩小一半的版本（窄条里用）
local RUNS, SMALL = {}, {}
for t = 1, 6 do
  local rows, runs, small = ART[t], {}, {}
  local top = 15 - #rows
  for y, row in ipairs(rows) do
    local x = 1
    while x <= 12 do
      local ch = string.sub(row, x, x)
      if ch ~= "." then
        local x2 = x
        while x2 < 12 and string.sub(row, x2 + 1, x2 + 1) == ch do x2 = x2 + 1 end
        runs[#runs + 1] = { ch == "o", x + 1, top + y - 1, x2 - x + 1 }
        x = x2
      end
      x = x + 1
    end
    if mod(y, 2) == 1 then
      for sx = 1, 12, 2 do
        local ch = string.sub(row, sx, sx)
        if ch ~= "." then small[#small + 1] = { ch == "o", div(sx - 1, 2), div(y - 1, 2) } end
      end
    end
  end
  RUNS[t], SMALL[t] = runs, small
end

local function sq_xy(sq) -- 信箱格 → 屏幕左上角
  local r = div(sq, 10) - 2
  return BX + (sq - (r + 2) * 10 - 1) * SQS, BY + r * SQS
end
local function draw_piece(p, x, y)
  if p == 0 then return end
  local t, white = p, true
  if p < 0 then t, white = -p, false end
  for _, r in ipairs(RUNS[t]) do
    if r[1] then fg(white and C.wline or C.bline) else fg(white and C.wfill or C.bfill) end
    rect(x + r[2], y + r[3], r[4], 1)
  end
end

-- ---------- 状态 ----------
local LEVELS = { 3, 10, 30 }
local G = {
  mode = "pick", level = 1, hist = {}, legal = {}, pieces = {}, targets = {},
  cur = 1, tcur = 1, pcur = 1, sel = 0, last_f = 0, last_t = 0, think_f = 0, think_t = 0,
  games = 0, wins = 0, undos = 0, last_undos = 0, result = nil, note = nil, note_until = 0,
  quit = false, shown = {}, strip_key = "",
}
local PROMOS = { 5, 4, 3, 2 }

local function save()
  local h = {}
  for i, m in ipairs(G.hist) do h[i] = m.f .. "," .. m.t .. "," .. m.p end
  save_kv(SAVE, { moves = table.concat(h, ";"), level = G.level, games = G.games, wins = G.wins,
                  undos = G.undos, last_undos = G.last_undos, result = G.result or "" })
end

-- 轮到玩家：算出能动的棋子和各自的落点
local function refresh_turn()
  G.legal = E.legal()
  local seen, list = {}, {}
  for _, m in ipairs(G.legal) do
    if not seen[m.f] then seen[m.f] = true; list[#list + 1] = m.f end
  end
  -- 从左到右、从下到上排，转盘转起来像扫过棋盘
  table.sort(list, function(a, b)
    local ca, cb = mod(a, 10), mod(b, 10)
    if ca ~= cb then return ca < cb end
    return a > b
  end)
  G.pieces = list
  if G.cur > #list then G.cur = 1 end
end
local function targets_of(f)
  local seen, list = {}, {}
  for _, m in ipairs(G.legal) do
    if m.f == f and not seen[m.t] then seen[m.t] = true; list[#list + 1] = m.t end
  end
  table.sort(list, function(a, b)
    local ca, cb = mod(a, 10), mod(b, 10)
    if ca ~= cb then return ca < cb end
    return a > b
  end)
  return list
end

local function finish_game(result)
  G.result = result
  G.mode = "over"
  G.games = G.games + 1
  if result == "1-0" then G.wins = G.wins + 1 end
  G.last_undos = G.undos
  save()
end
local function check_over()
  local s = E.status()
  if not s then return false end
  if s == "mate" then finish_game((E.side() == 1) and "0-1" or "1-0") else finish_game("1/2") end
  return true
end

local function new_game()
  E.new_game()
  G.hist, G.result, G.undos = {}, nil, 0
  G.last_f, G.last_t, G.cur = 0, 0, 1
  G.mode = "pick"
  if G.last_undos > 0 then G.note, G.note_until = "undo " .. G.last_undos, rb.current_tick() + 6 * HZ end
  refresh_turn()
end

-- 从走法记录重新摆出局面（读档、悔棋都用它）
local function replay(hist)
  E.new_game()
  local ok = {}
  for _, m in ipairs(hist) do
    if not E.play(m.f, m.t, m.p) then break end
    ok[#ok + 1] = m
  end
  G.hist = ok
  local l = ok[#ok]
  G.last_f, G.last_t = l and l.f or 0, l and l.t or 0
end

local function load()
  local s, found = load_kv(SAVE)
  G.level = clamp(num(s.level, 1), 1, #LEVELS)
  G.games, G.wins = num(s.games, 0), num(s.wins, 0)
  G.last_undos = num(s.last_undos, 0)
  new_game()
  G.note = nil
  if not found then return end
  local hist = {}
  for f, t, p in string.gmatch(s.moves or "", "(%d+),(%d+),(%d+)") do
    hist[#hist + 1] = { f = num(f, 0), t = num(t, 0), p = num(p, 0) }
  end
  replay(hist)
  G.undos = num(s.undos, 0)
  if s.result and s.result ~= "" then G.result, G.mode = s.result, "over"
  elseif E.side() == -1 then G.mode = "think"
  else refresh_turn() end
end

-- ---------- 画面 ----------
-- 每格算一个“该长什么样”的键，和上次画的不一样才重画
local function square_look(sq)
  local look = "plain"
  if sq == G.think_f or sq == G.think_t then look = "think"
  elseif G.mode == "target" and sq == G.sel then look = "sel"
  elseif sq == G.last_f or sq == G.last_t then look = "last" end
  if G.check_sq == sq then look = "check" end
  local p = E.B[sq]
  if G.mode == "promo" and sq == G.targets[G.tcur] then p = PROMOS[G.pcur] end
  -- 落点提示：选子时预览光标那颗子的落点，落子时显示选中那颗子的落点
  local hint = G.hint_set[sq] and ((E.B[sq] ~= 0) and "cap" or "dot") or ""
  local cursor = (sq == G.cursor_sq)
  return look, p, hint, cursor
end
local function draw_square(sq, look, p, hint, cursor)
  local x, y = sq_xy(sq)
  local r = div(sq, 10)
  local light = mod(r + sq, 2) == 1
  fg(SQC[light and 1 or 2][look])
  rect(x, y, SQS, SQS)
  draw_piece(p, x, y)
  if hint == "dot" then
    fg(C.hint); rect(x + 6, y + 6, 4, 4)
  elseif hint == "cap" then -- 能吃的子：四个角
    fg(C.hint)
    rect(x, y, 4, 2); rect(x, y, 2, 4); rect(x + 12, y, 4, 2); rect(x + 14, y, 2, 4)
    rect(x, y + 14, 4, 2); rect(x, y + 12, 2, 4); rect(x + 12, y + 14, 4, 2); rect(x + 14, y + 12, 2, 4)
  end
  if cursor then
    fg(C.cursor)
    rect(x, y, SQS, 1); rect(x, y + SQS - 1, SQS, 1); rect(x, y, 1, SQS); rect(x + SQS - 1, y, 1, SQS)
    rect(x + 1, y + 1, SQS - 2, 1); rect(x + 1, y + SQS - 2, SQS - 2, 1); rect(x + 1, y + 1, 1, SQS - 2); rect(x + SQS - 2, y + 1, 1, SQS - 2)
  end
end

local function draw_strip()
  -- 被吃掉的子：上面是你吃掉的（黑子），下面是它吃掉的（白子）
  local count = { [1] = {}, [-1] = {} }
  for t = 1, 6 do count[1][t], count[-1][t] = 0, 0 end
  for r = 2, 9 do for f = 1, 8 do
    local p = E.B[r * 10 + f]
    if p > 0 then count[1][p] = count[1][p] + 1 elseif p < 0 then count[-1][-p] = count[-1][-p] + 1 end
  end end
  local START = { 8, 2, 2, 2, 1, 1 }
  local lost = { [1] = {}, [-1] = {} }
  local key = G.mode .. (G.result or "") .. G.level .. (G.note or "")
  for _, s in ipairs({ 1, -1 }) do
    for _, t in ipairs({ 5, 4, 3, 2, 1 }) do
      local n = START[t] - count[s][t]
      for _ = 1, n do lost[s][#lost[s] + 1] = t end
      key = key .. n
    end
  end
  if key == G.strip_key then return end
  G.strip_key = key
  fg(C.strip); rect(SX, 0, W - SX, H)
  for side, y0 in pairs({ [-1] = 4, [1] = 40 }) do
    for k, t in ipairs(lost[side]) do
      local x = SX + 3 + mod(k - 1, 7) * 6
      local y = y0 + div(k - 1, 7) * 8
      for _, d in ipairs(SMALL[t]) do
        if d[1] then fg(side == 1 and C.wline or C.ink) else fg(side == 1 and C.wfill or C.bfill) end
        rect(x + d[2], y + d[3], 1, 1)
      end
    end
  end
  if G.result then
    text(SX + 4, H - 40, G.result, C.cursor, C.strip)
    text(SX + 4, H - 28, G.wins .. "/" .. G.games, C.ink, C.strip)
  elseif G.note then
    text(SX + 4, H - 28, G.note, C.ink, C.strip)
  end
  text(SX + 4, H - 14, LEVELS[G.level] .. "s", C.dim, C.strip)
end

local function render()
  G.hint_set = {}
  G.cursor_sq = 0
  if G.mode == "pick" and #G.pieces > 0 then
    G.cursor_sq = G.pieces[G.cur]
    for _, t in ipairs(targets_of(G.cursor_sq)) do G.hint_set[t] = true end
  elseif G.mode == "target" or G.mode == "promo" then
    for _, t in ipairs(G.targets) do G.hint_set[t] = true end
    G.cursor_sq = G.targets[G.tcur]
  end
  G.check_sq = 0
  if G.mode ~= "over" or G.result ~= "1/2" then
    if E.in_check() then
      for r = 2, 9 do for f = 1, 8 do if E.B[r * 10 + f] == 6 * E.side() then G.check_sq = r * 10 + f end end end
    end
  end
  for r = 2, 9 do
    for f = 1, 8 do
      local sq = r * 10 + f
      local look, p, hint, cursor = square_look(sq)
      local key = look .. p .. hint .. (cursor and "c" or "")
      if G.shown[sq] ~= key then
        G.shown[sq] = key
        draw_square(sq, look, p, hint, cursor)
      end
    end
  end
  draw_strip()
  rb.lcd_update()
end

-- ---------- 对手 ----------
local function think_hook(f, t)
  G.think_f, G.think_t = f, t
  render()
  for _, e in ipairs(poll()) do
    if e.k == "menu" and not e.rel then G.quit = true end
  end
  if G.quit then return end
  keep_light()
  if rb.yield then rb.yield() end
end
local function engine_move()
  local secs = LEVELS[G.level]
  -- 它输了不认输，只是想得越来越久
  local ev = 0
  if G.last_eval and G.last_eval < -300 then ev = clamp(div(-G.last_eval - 300, 150), 0, 4) end
  secs = secs + div(secs * ev, 2)
  local f, t, p, sc = E.search(secs, function(a, b)
    think_hook(a, b)
    if G.quit then error("quit") end
  end)
  G.think_f, G.think_t = 0, 0
  if not f then return end
  G.last_eval = sc
  E.play(f, t, p)
  G.hist[#G.hist + 1] = { f = f, t = t, p = p }
  G.last_f, G.last_t = f, t
  if not check_over() then
    G.mode = "pick"
    refresh_turn()
  end
end

-- ---------- 主循环 ----------
load()
light_start()
fg(C.strip); rect(0, 0, W, H)
render()

while not G.quit do
  for _, e in ipairs(poll()) do
    if not e.rel then
      local k = e.k
      if k == "menu" then
        if G.mode == "target" then G.mode = "pick"
        elseif G.mode == "promo" then G.mode = "target"
        else G.quit = true end
      elseif k == "fwd" or k == "back" then
        local d = (k == "fwd") and 1 or -1
        if G.mode == "pick" and #G.pieces > 0 then G.cur = mod(G.cur - 1 + d, #G.pieces) + 1
        elseif G.mode == "target" then G.tcur = mod(G.tcur - 1 + d, #G.targets) + 1
        elseif G.mode == "promo" then G.pcur = mod(G.pcur - 1 + d, #PROMOS) + 1 end
      elseif k == "play" and not e.rep then
        G.level = mod(G.level, #LEVELS) + 1
      elseif k == "prev" and not e.rep and (G.mode == "pick" or G.mode == "target") then
        -- 悔棋：退回到上一次轮到你的时候
        local h = G.hist
        local n = #h
        if n > 0 then
          n = n - 1
          if mod(n, 2) == 1 then n = n - 1 end
          local keep = {}
          for i = 1, n do keep[i] = h[i] end
          replay(keep)
          G.undos = G.undos + 1
          G.result, G.mode = nil, "pick"
          refresh_turn()
          save()
        end
      elseif k == "select" and not e.rep then
        if G.mode == "pick" and #G.pieces > 0 then
          G.sel = G.pieces[G.cur]
          G.targets = targets_of(G.sel)
          G.tcur, G.mode = 1, "target"
        elseif G.mode == "target" then
          local t = G.targets[G.tcur]
          local promo = false
          for _, m in ipairs(G.legal) do if m.f == G.sel and m.t == t and m.p > 0 then promo = true end end
          if promo then G.pcur, G.mode = 1, "promo"
          else G.pending = { f = G.sel, t = t, p = 0 } end
        elseif G.mode == "promo" then
          G.pending = { f = G.sel, t = G.targets[G.tcur], p = PROMOS[G.pcur] }
        elseif G.mode == "over" then
          new_game()
        end
      end
    end
  end

  if G.pending then
    local m = G.pending
    G.pending = nil
    if E.play(m.f, m.t, m.p) then
      G.hist[#G.hist + 1] = m
      G.last_f, G.last_t = m.f, m.t
      if not check_over() then G.mode = "think" end
      save()
    end
  end

  if G.note and rb.current_tick() > G.note_until then G.note = nil end
  render()

  if G.mode == "think" then
    local ok = pcall(engine_move)
    if not ok then G.quit = true end
    if not G.quit then save() end
  end

  keep_light()
  rb.sleep(div(HZ, 20))
end

save()
light_end()
end
main()
