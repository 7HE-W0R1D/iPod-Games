-- 桌面上验证象棋引擎的走法生成：perft 数和标准答案比
-- 用法：lua test/chess_perft.lua
local f = assert(io.open("src/chess.lua")); local src = f:read("a"); f:close()
local a = src:find("local E = (function()", 1, true)
local b = src:find("\nend)()\n", a, true)
local body = src:sub(a + #"local E = (function()", b)
local stub = "local rb = { current_tick = function() return 0 end }; local HZ = 100\n" ..
  "local function div(x, y) return x // y end; local function mod(x, y) return x % y end\n" ..
  "return (function()" .. body .. " end)()"
local E = assert(load(stub))()
local cases = {
  { "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq -", { 20, 400, 8902, 197281 } },
  { "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq -", { 48, 2039, 97862 } },
  { "8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - -", { 14, 191, 2812, 43238 } },
  { "r3k2r/Pppp1ppp/1b3nbN/nP6/BBP1P3/q4N2/Pp1P2PP/R2Q1RK1 w kq -", { 6, 264, 9467 } },
  { "rnbq1k1r/pp1Pbppp/2p5/8/2B5/8/PPP1NnPP/RNBQK2R w KQ -", { 44, 1486, 62379 } },
}
local bad = 0
for _, c in ipairs(cases) do
  for d, want in ipairs(c[2]) do
    E.fen(c[1])
    local got = E.perft(d)
    local ok = got == want
    if not ok then bad = bad + 1 end
    print(string.format("%s d=%d %d %s", ok and "ok  " or "FAIL", d, got, ok and "" or ("want " .. want)), c[1]:sub(1, 30))
  end
end
-- 搜索：几个一眼就该看出来的局面
local function sq(name) return (10 - tonumber(name:sub(2, 2))) * 10 + name:byte(1) - 96 end
local tactics = {
  { "6k1/5ppp/8/8/8/8/8/R5K1 w - -", "a1", "a8", "一步杀（底线）" },
  { "r1bqkb1r/pppp1ppp/2n2n2/4p2Q/2B1P3/8/PPPP1PPP/RNB1K1NR w KQkq -", "h5", "f7", "一步杀（f7）" },
  { "4k3/8/8/3q4/8/8/3R4/3K4 w - -", "d2", "d5", "白吃没保护的后" },
  { "3qk3/8/8/8/8/8/3Q4/4K3 b - -", "d8", "d2", "黑吃没保护的后" },
}
for _, c in ipairs(tactics) do
  E.fen(c[1])
  local f, t, _, sc, nodes = E.search(3)
  local ok = f == sq(c[2]) and t == sq(c[3])
  if not ok then bad = bad + 1 end
  print(string.format("%s %s  走了 %d→%d 分 %d 节点 %d", ok and "ok  " or "FAIL", c[4], f, t, sc, nodes))
end
os.exit(bad == 0 and 0 or 1)
