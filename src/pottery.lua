-- 陶艺转盘：泥在拉坯机上自己转。转盘把双手上下移动，上一首 / 下一首把那一层收窄 / 甩宽。
-- 转盘：手的高度（看架子时横向浏览）   上一首 / 下一首：收窄 / 加宽   Select 或 Play：送进窑
-- 长按 Select：看架子   Menu：退出   长按 Menu：说明
-- 收窄的地方会被拔高，加宽的地方变扁；悬出去太多会歪掉。进窑一小时后才看到成品，窑上的小钟走一圈就好了。

local SAVE = "slow_pottery.txt"
local NL = 30                  -- 层数
local KILN_SECONDS = 3600      -- 烧窑一小时
local RMIN, RMAX = 4, 46       -- 每层半径的范围
local OVERHANG = 10            -- 比下面一层宽出这么多就开始失稳
local CX, BASE = div(W, 2), H - 10

local CLAY = { 168, 112, 80 }
local GLAZES = {
  { 150, 190, 160 }, { 70, 42, 28 }, { 185, 172, 140 }, { 45, 72, 150 },
  { 222, 202, 182 }, { 150, 45, 38 }, { 95, 120, 70 }, { 210, 160, 70 },
}

-- ---------- 存档 ----------
local shelf = {}  -- 每只罐子：{ r = {}, h = {}, off = {}, glaze = {r,g,b}, drip = {r,g,b}, bad = bool }
local kiln = nil  -- 正在烧的：{ pot = ..., ready = unix 秒 }

local function enc(p)
  local r, h, o = {}, {}, {}
  for i = 1, NL do
    r[i] = string.char(48 + p.r[i]); h[i] = string.char(48 + p.h[i]); o[i] = string.char(80 + (p.off[i] or 0))
  end
  local g, d = p.glaze or CLAY, p.drip or CLAY
  return table.concat(r) .. "|" .. table.concat(h) .. "|" .. table.concat(o) .. "|" ..
    g[1] .. "," .. g[2] .. "," .. g[3] .. "|" .. d[1] .. "," .. d[2] .. "," .. d[3] .. "|" .. (p.bad and "1" or "0")
end
local function dec(s)
  local a, b, c, g, d, bad = string.match(s, "^([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)|(%d)$")
  if not a or #a ~= NL then return nil end
  local p = { r = {}, h = {}, off = {}, bad = bad == "1" }
  for i = 1, NL do
    p.r[i] = string.byte(a, i) - 48; p.h[i] = string.byte(b, i) - 48; p.off[i] = string.byte(c, i) - 80
  end
  local function rgb3(x) local r_, g_, b_ = string.match(x, "(%d+),(%d+),(%d+)"); return { tonumber(r_), tonumber(g_), tonumber(b_) } end
  p.glaze, p.drip = rgb3(g), rgb3(d)
  return p
end

local function save()
  local t = { count = #shelf }
  for i, p in ipairs(shelf) do t["pot" .. i] = enc(p) end
  if kiln then t.kiln = enc(kiln.pot); t.kiln_ready = kiln.ready end
  save_kv(SAVE, t)
end
local function load()
  local s = load_kv(SAVE)
  for i = 1, num(s.count, 0) do
    local p = s["pot" .. i] and dec(s["pot" .. i])
    if p then shelf[#shelf + 1] = p end
  end
  if s.kiln then
    local p = dec(s.kiln)
    if p then kiln = { pot = p, ready = num(s.kiln_ready, now()) } end
  end
end

-- ---------- 釉色：同样的形状，每次烧出来都不一样 ----------
local function fire(p, seed)
  local r = Rng(seed)
  local base = GLAZES[r(#GLAZES) + 1]
  local other = GLAZES[r(#GLAZES) + 1]
  p.glaze = { clamp(base[1] + r(41) - 20, 0, 255), clamp(base[2] + r(41) - 20, 0, 255), clamp(base[3] + r(41) - 20, 0, 255) }
  p.drip = mix(p.glaze, other, 40 + r(120), 256)
end

-- ---------- 画罐子 ----------
-- scale：1 原大，2 缩小一半。phase：转动的相位，让横线上的明暗流动。
local function draw_pot(cx, by, p, scale, body, phase, hand_layer)
  local y = by
  local hi = pack(mix(body, { 255, 255, 255 }, 1, 4))
  local lo = pack(mix(body, { 0, 0, 0 }, 1, 3))
  local mid = pack(body)
  local drip = p.drip and pack(p.drip)
  local total_h = 0
  for i = 1, NL do total_h = total_h + p.h[i] end
  local row = 0
  for i = 1, NL do
    if p.r[i] > 0 then
      for _ = 1, p.h[i] do
        row = row + 1
        if scale == 1 or mod(row, 2) == 0 then
          y = y - 1
          local r = div(p.r[i], scale)
          local x0 = cx - r + div(p.off[i], scale)
          local wcol = mid
          if drip and row > total_h - div(total_h, 3) - mod(i * 7, 5) then wcol = drip end -- 上半截挂釉
          fg(wcol); rect(x0, y, r * 2, 1)
          fg(lo); rect(x0, y, math.max(1, div(r, 4)), 1); rect(x0 + r * 2 - math.max(1, div(r, 4)), y, math.max(1, div(r, 4)), 1)
          if r > 3 then
            fg(hi); rect(x0 + div(r, 2), y, 2, 1)
            if phase then
              fg(lo); rect(x0 + mod(phase + row * 5, r * 2), y, 1, 1) -- 转动时流动的暗纹
            end
          end
          if hand_layer == i and scale == 1 then
            fg(rgb(225, 180, 150)); rect(x0 - 4, y - 1, 3, 3); rect(x0 + r * 2 + 1, y - 1, 3, 3)
          end
        end
      end
    end
  end
end

local function new_lump()
  local p = { r = {}, h = {}, off = {} }
  for i = 1, NL do p.r[i] = 24 - div(i * i, 90); p.h[i] = 1; p.off[i] = 0 end
  return p
end

local BG = rgb(38, 32, 30)
local function draw_wheel_scene(p, phase, hand_layer, wob)
  fg(BG); rect(0, 0, W, H)
  fg(rgb(90, 90, 95)); rect(CX - 50, BASE, 100, 4); fg(rgb(60, 60, 64)); rect(CX - 44, BASE + 4, 88, 6)
  local c = { CLAY[1], CLAY[2], CLAY[3] }
  if wob > 20 then -- 失稳时泥颜色发暗、发抖
    c = mix(CLAY, { 110, 70, 50 }, wob, 80)
  end
  draw_pot(CX + (wob > 30 and mod(phase, 3) - 1 or 0), BASE, p, 1, c, phase, hand_layer)
  text_r(W - 2, 2, tostring(#shelf), rgb(120, 105, 95), BG)
  rb.lcd_update()
end

-- 烧窑的小钟：转一圈 = 一小时。走过的部分填上火色，一根指针指着现在
local CLK_R = 10
local CLK_COS = { [0] = 64, 62, 55, 45, 32, 17, 0, -17, -32, -45, -55, -62, -64, -62, -55, -45, -32, -17, 0, 17, 32, 45, 55, 62 }
local CLK_SEC -- 每个点属于哪个扇区（从 12 点顺时针 0..23；圆外是 -1），第一次用时算一次
local function clock_sectors()
  CLK_SEC = {}
  for y = -CLK_R, CLK_R do
    local row = {}
    for x = -CLK_R, CLK_R do
      local bi = -1
      if x * x + y * y <= CLK_R * CLK_R then
        local best = -1000000
        for k = 0, 23 do
          local d = x * CLK_COS[mod(k + 18, 24)] + y * CLK_COS[mod(k + 12, 24)]
          if d > best then best, bi = d, k end
        end
      end
      row[x] = bi
    end
    CLK_SEC[y] = row
  end
end
local function draw_clock(cx, cy, done, fire)
  if not CLK_SEC then clock_sectors() end
  local face, rim, ink = rgb(52, 42, 36), rgb(120, 96, 80), rgb(235, 225, 200)
  local hot = pack(fire)
  local filled = div(done * 24, KILN_SECONDS) -- 24 个扇区里走过了几个
  for y = -CLK_R, CLK_R do
    local row = CLK_SEC[y]
    local x = -CLK_R
    while x <= CLK_R and row[x] < 0 do x = x + 1 end
    if x <= CLK_R then
      fg(rim); rect(cx + x - 1, cy + y, 1, 1); rect(cx - x + 1, cy + y, 1, 1)
      -- 按连续的同色段画，一行最多三四段
      while x <= CLK_R and row[x] >= 0 do
        local on = row[x] < filled
        local x0 = x
        while x <= CLK_R and row[x] >= 0 and (row[x] < filled) == on do x = x + 1 end
        fg(on and hot or face); rect(cx + x0, cy + y, x - x0, 1)
      end
    end
  end
  fg(rim); rect(cx - 1, cy - CLK_R - 1, 3, 1); rect(cx - 1, cy + CLK_R + 1, 3, 1)
  -- 刻度：12、3、6、9 点
  fg(rim); rect(cx, cy - CLK_R + 1, 1, 2); rect(cx, cy + CLK_R - 2, 1, 2); rect(cx - CLK_R + 1, cy, 2, 1); rect(cx + CLK_R - 2, cy, 2, 1)
  -- 指针
  local a = div(done * 24, KILN_SECONDS)
  local dx, dy = CLK_COS[mod(a + 18, 24)], CLK_COS[mod(a + 12, 24)]
  fg(ink)
  for k = 0, CLK_R - 2 do rect(cx + div(dx * k, 64), cy + div(dy * k, 64), 1, 1) end
  rect(cx, cy, 1, 1)
end

local function draw_kiln(t)
  local tk = rb.current_tick()
  local night = rgb(20, 16, 15)
  fg(night); rect(0, 0, W, H)
  -- 火候：刚进窑暗红，快烧好时橘黄
  local left = clamp(kiln.ready - t, 0, KILN_SECONDS)
  local p = KILN_SECONDS - left
  local fire = mix({ 150, 45, 20 }, { 255, 185, 80 }, p, KILN_SECONDS)
  local flame = mix(fire, { 255, 240, 170 }, 1, 2)
  -- 地面和门前的火光
  fg(rgb(34, 28, 25)); rect(0, 112, W, H - 112)
  for k = 0, 2 do
    fg(pack(mix({ 34, 28, 25 }, fire, 3 - k, 6)))
    rect(CX - 22 - k * 10, 112 + k * 5, 44 + k * 20, 5)
  end
  -- 烟囱和烟
  local brick, mortar = { 92, 60, 46 }, rgb(58, 40, 32)
  fg(pack(brick)); rect(CX + 22, 14, 12, 34)
  fg(mortar); for y = 20, 44, 6 do rect(CX + 22, y, 12, 1) end
  fg(rgb(85, 80, 78))
  for k = 0, 5 do
    local y = 12 - k * 3 - mod(div(tk, 8), 3)
    local x = CX + 26 + iabs(mod(div(tk, 6) + k * 2, 8) - 4) + k
    if y >= 0 then rect(x, y, 2 + div(k, 2), 2) end
  end
  -- 窑身：圆拱形砖窑
  local top = 40
  for y = top, 111 do
    local d = y - top
    local inset = d < 14 and div((14 - d) * (14 - d), 7) or 0
    local hw = 46 - inset
    fg(pack(brick)); rect(CX - hw, y, hw * 2, 1)
    if mod(d, 6) == 5 then fg(mortar); rect(CX - hw, y, hw * 2, 1)
    else
      fg(mortar)
      local off = mod(div(d, 6), 2) * 6
      for x = CX - hw + off, CX + hw - 1, 12 do rect(x, y, 1, 1) end
    end
  end
  -- 窑门：拱形开口，里面的火苗在跳
  for y = 76, 111 do
    local d = y - 76
    local hw = d < 6 and 16 - div((6 - d) * (6 - d), 3) or 16
    fg(pack(fire)); rect(CX - hw, y, hw * 2, 1)
  end
  local r = Rng(div(tk, 6))
  fg(pack(flame))
  for x = CX - 14, CX + 13, 3 do
    local h = 6 + r(10) + div(p * 8, KILN_SECONDS)
    rect(x, 112 - h, 2, h)
  end
  fg(mortar); rect(CX - 18, 74, 36, 2)
  draw_clock(24, 20, p, fire)
  text_r(W - 2, 2, tostring(#shelf), rgb(120, 105, 95), night)
  rb.lcd_update()
end

local function pot_width(p)
  local m = 0
  for i = 1, NL do m = math.max(m, p.r[i] + iabs(p.off[i])) end
  return m + 6
end
local function draw_shelf(scroll)
  fg(rgb(48, 40, 34)); rect(0, 0, W, H)
  local wood, wood2 = rgb(130, 92, 58), rgb(95, 66, 42)
  local rows = { { y = 62, bad = false }, { y = H - 6, bad = true } }
  for _, row in ipairs(rows) do
    fg(wood); rect(0, row.y, W, 3); fg(wood2); rect(0, row.y + 3, W, 2)
    local x = 6 - scroll
    for _, p in ipairs(shelf) do
      if p.bad == row.bad then
        local w = pot_width(p)
        if x + w > 0 and x - w < W then draw_pot(x + w, row.y, p, 2, p.glaze or CLAY) end
        x = x + w + 4
      end
    end
  end
  text(3, 68, "seconds", rgb(150, 130, 110), rgb(48, 40, 34))
  text_r(W - 2, 2, tostring(#shelf), rgb(150, 130, 110), rgb(48, 40, 34))
  rb.lcd_update()
end

-- ---------- 主循环 ----------
load()
light_start()
local mode = "wheel"           -- wheel / kiln / shelf
local pot = new_lump()
local hand = 1                 -- 手在第几层：开局在最宽的底层
local shaped = false           -- 动过泥才能送窑，免得误触
local wob, phase, bad = 0, 0, false
local scroll = 0
local running = true

-- 收窄 / 加宽手所在的那一层（上下各一层跟着动一半）
local function shape(dr)
  shaped = true
  for i = math.max(1, hand - 1), math.min(NL, hand + 1) do
    local d = (i == hand) and dr or div(dr, 2)
    pot.r[i] = clamp(pot.r[i] + d, RMIN, RMAX)
  end
  -- 收窄的地方被拔高，加宽的地方变扁
  local h = pot.h[hand]
  if dr < 0 and pot.r[hand] < 16 then h = h + 1 elseif dr > 0 and pot.r[hand] > 20 then h = h - 1 end
  pot.h[hand] = clamp(h, 1, 4)
  -- 泥是连着的：相邻两层粗细差得不能太多
  for i = 2, NL do pot.r[i] = clamp(pot.r[i], pot.r[i - 1] - 3, pot.r[i - 1] + 3) end
  for i = NL - 1, 1, -1 do pot.r[i] = clamp(pot.r[i], pot.r[i + 1] - 3, pot.r[i + 1] + 3) end
end

-- 悬出去太多就失稳：上面一层比下面宽出很多
local function overhang()
  local m, lo = 0, pot.r[1]
  for i = 2, NL do
    if pot.r[i] - lo > m then m = pot.r[i] - lo end
    if pot.r[i] < lo then lo = pot.r[i] end
  end
  return m
end

local function finish_throw()
  local p = pot
  p.bad = bad
  kiln = { pot = p, ready = now() + KILN_SECONDS }
  save()
  mode = "kiln"
  pot, hand, shaped, wob, bad = new_lump(), 1, false, 0, false
end

local function check_kiln()
  if kiln and now() >= kiln.ready then
    fire(kiln.pot, kiln.ready)
    shelf[#shelf + 1] = kiln.pot
    kiln = nil
    save()
    mode = "shelf"
    scroll = 0
  end
end

local function back_from_shelf() mode = kiln and "kiln" or "wheel" end

if kiln then mode = "kiln" end
check_kiln()

while running do
  for _, e in ipairs(poll()) do
    local g = select_gesture(e)
    if e.k == "menu" and not e.rel then running = false
    elseif e.k == "help" then
      help_screen("POTTERY", {
        "The clay spins on the",
        "wheel. Move your hands up",
        "and down and shape each",
        "layer. Narrow = taller,",
        "wide = flatter. Lean out",
        "too far and it wobbles.",
        "The kiln takes an hour;",
        "the little clock shows",
        "how far along it is.",
        "",
        "*Keys",
        "wheel   hands up / down",
        "        (shelf: scroll)",
        "next    widen",
        "prev    narrow",
        "select  fire it",
        "play    fire it",
        "hold select  shelf",
        "menu    quit",
        "hold menu  this help",
      })
    elseif g == "long" then
      if mode == "shelf" then back_from_shelf() else mode = "shelf" end
    elseif mode == "shelf" then
      if (e.k == "fwd" or e.k == "back") and not e.rel then scroll = math.max(0, scroll + (e.k == "fwd" and 4 or -4))
      elseif g == "short" or (e.k == "play" and not e.rel and not e.rep) then back_from_shelf() end
    elseif mode == "kiln" then
      if e.k == "play" and not e.rel and not e.rep then mode = "shelf" end
    else -- wheel
      if e.k == "fwd" and not e.rel then hand = clamp(hand + 1, 1, NL)
      elseif e.k == "back" and not e.rel then hand = clamp(hand - 1, 1, NL)
      elseif e.k == "next" and not e.rel then shape(2)
      elseif e.k == "prev" and not e.rel then shape(-2)
      elseif (g == "short" or (e.k == "play" and not e.rel and not e.rep)) and shaped then finish_throw() end
    end
  end

  if mode == "wheel" then
    phase = phase + 3
    -- 悬出去太多：慢慢歪掉
    if overhang() > OVERHANG then wob = wob + 2 elseif wob > 0 and not bad then wob = wob - 1 end
    if wob > 70 and not bad then
      bad = true
      for i = hand, NL do pot.off[i] = clamp(div((i - hand) * (i - hand), 6), 0, 40) end
    end
    draw_wheel_scene(pot, phase, hand, wob)
  elseif mode == "kiln" then
    check_kiln()
    if mode == "kiln" then draw_kiln(now()) end
  else
    draw_shelf(scroll)
  end
  keep_light()
  rb.sleep(div(HZ, 20))
end

save()
light_end()
