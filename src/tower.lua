-- 瞭望塔：在森林火警塔上 360 度环视。大部分时候什么都没有，你的工作只是看和记录。
-- 转盘：转身   Select：记日志（附时间和方位）   长按 Select：翻日志   Menu：退出

local SAVE = "slow_tower.txt"
local PW = W * 4                -- 一圈全景的宽度
local DEG_PER_CLICK = 3         -- 一格转几度（转盘一圈大约看一圈，上机再调）
local VIEW_DEG = div(360 * W, PW) -- 屏幕一次看到的角度（90°）
local SCAR_DAYS = 35            -- 焦黑的山坡多少天后完全返绿
local BUSY_CLICKS = 1500        -- 一天转身超过这么多格就算“太勤快”

-- ---------- 全景：三层山脊，每列一个高度 ----------
local far, mid, near = {}, {}, {}
local function ridge(arr, seed, spacing, lo, hi, jag)
  local r = Rng(seed)
  local n = div(PW, spacing)
  local pts = {}
  for i = 0, n - 1 do pts[i] = lo + r(hi - lo + 1) end
  for x = 0, PW - 1 do
    local i = div(x, spacing)
    local a, b = pts[i], pts[mod(i + 1, n)]
    arr[x] = lerp(a, b, x - i * spacing, spacing) - (jag > 0 and r(jag) or 0)
  end
end
ridge(far, 11, 44, 36, 66, 0)
ridge(mid, 22, 22, 64, 84, 3)
ridge(near, 33, 11, 96, 112, 6)
local stars = {}
do local r = Rng(5); for i = 1, 70 do stars[i] = { r(PW), r(60) } end end

local C = {
  far = { 150, 165, 185 }, mid = { 70, 100, 80 }, near = { 25, 48, 34 },
  smoke = { 200, 200, 205 }, deer = { 120, 80, 45 }, bird = { 20, 20, 25 }, burnt = { 35, 25, 20 },
}

-- ---------- 状态 ----------
local t_open = now()
local today = civil(t_open).day
local bearing = 0
local log = {}               -- { {t, b, code}, ... }
local scars = {}             -- { {b, t}, ... }
local first_day, resolved_day, smoke_logged = today, today - 1, -1
local smoke_logged_min = 0   -- 记下烟的那一分钟；之后 30 分钟烟就散了
local clicks_day, clicks, busy_noted = today, 0, false

local function load()
  local s, found = load_kv(SAVE)
  if not found then return end
  bearing = num(s.bearing, 0)
  first_day = num(s.first_day, today)
  resolved_day = num(s.resolved_day, today - 1)
  smoke_logged = num(s.smoke_logged, -1)
  smoke_logged_min = num(s.smoke_logged_min, 0)
  if num(s.clicks_day, -1) == today then clicks = num(s.clicks, 0); busy_noted = s.busy == "1" end
  for t, b, c in string.gmatch(s.log or "", "(%d+),(%d+),(%a)") do log[#log + 1] = { tonumber(t), tonumber(b), c } end
  for b, t in string.gmatch(s.scars or "", "(%d+),(%d+)") do scars[#scars + 1] = { tonumber(b), tonumber(t) } end
end
local function save()
  local lp, sp = {}, {}
  for i, e in ipairs(log) do lp[i] = e[1] .. "," .. e[2] .. "," .. e[3] end
  for i, s in ipairs(scars) do sp[i] = s[1] .. "," .. s[2] end
  save_kv(SAVE, { bearing = bearing, first_day = first_day, resolved_day = resolved_day,
    smoke_logged = smoke_logged, smoke_logged_min = smoke_logged_min, clicks_day = clicks_day, clicks = clicks, busy = busy_noted and "1" or "0",
    log = table.concat(lp, ";"), scars = table.concat(sp, ";") })
end

-- ---------- 每天的事件（同一天算出来总是一样的） ----------
local function smoke_of(day)
  local r = Rng(hash(day, 7))
  if r(100) >= 25 then return nil end -- 大约四天一次
  local start = 600 + r(420)
  return { start = start, stop = start + 180 + r(240), b = r(360) }
end
local function passers_of(day, L) -- 鹿和鸟群
  local r = Rng(hash(day, 8))
  local list = {}
  for i = 1, 2 + r(3) do
    list[i] = { kind = r(2) == 0 and "deer" or "birds", start = L.sr + r(L.ss - L.sr), b = r(360),
                dir = r(2) == 0 and -1 or 1 }
  end
  return list
end

-- 补算：没被发现的烟自己熄掉，或者留下一块焦黑的山坡
local function resolve_smoke(t)
  local c = civil(t)
  while resolved_day < c.day do
    local d = resolved_day + 1
    local ev = smoke_of(d)
    if ev then
      local stop_t = d * 86400 + ev.stop * 60
      if stop_t > t then break end
      if smoke_logged ~= d and mod(hash(d, 99), 2) == 0 then scars[#scars + 1] = { ev.b, stop_t } end
    elseif d == c.day then break end
    resolved_day = d
  end
  for i = #scars, 1, -1 do
    if t - scars[i][2] > SCAR_DAYS * 86400 then table.remove(scars, i) end
  end
end

-- 角度差（-180..179）
local function adiff(a, b) return mod(a - b + 180, 360) - 180 end
local function col_of(b) return div(mod(b, 360) * PW, 360) end

-- 这一刻全景里有哪些东西：返回 { {kind, b, ...} }
local function things(t, L, wx)
  local out = {}
  local m = L.min
  local ev = smoke_of(L.day)
  if ev and m >= ev.start and m < ev.stop then
    local over = smoke_logged == L.day and m >= smoke_logged_min + 30
    if not over then out[#out + 1] = { kind = "smoke", b = ev.b, age = m - ev.start } end
  end
  for _, p in ipairs(passers_of(L.day, L)) do
    local secs = (m - p.start) * 60 + mod(t, 60)
    if secs >= 0 and secs < 180 then
      out[#out + 1] = { kind = p.kind, b = p.b + p.dir * div(secs * 25, 180), secs = secs }
    end
  end
  if wx.rainy and m >= wx.storm_start and m < wx.storm_start + 240 then
    out[#out + 1] = { kind = "rain", b = wx.storm_bearing + wx.storm_dir * div((m - wx.storm_start) * 15, 60) }
  end
  if L.night and mod(div(t, 600) * 7, 5) == 0 and mod(t, 600) < 3 then
    out[#out + 1] = { kind = "light", b = 217 } -- 远处另一座塔
  end
  return out
end

-- ---------- 画面 ----------
-- 画面分两块画：Rockbox 的 Lua 每个函数最多 30 个 upvalue
local function draw_land(t, L, wx, left)
  for y = 0, H - 1, 4 do fg(pack(mix(L.top, L.bot, y, 100))); rect(0, y, W, 4) end
  if L.night then
    fg(rgb(205, 210, 225))
    for _, s in ipairs(stars) do
      local x = mod(s[1] - left, PW)
      if x < W and s[2] < far[mod(s[1], PW)] then rect(x, s[2], 1, 1) end
    end
  end
  -- 焦黑程度：每列查一下附近有没有疤
  local burn = {}
  for _, s in ipairs(scars) do
    local age = div(t - s[2], 86400)
    local k = age < 7 and 256 or clamp(256 - div((age - 7) * 256, SCAR_DAYS - 7), 0, 256)
    local c0 = col_of(s[1])
    for dx = -14, 14 do
      local x = mod(c0 + dx - left, PW)
      if x < W then burn[x] = math.max(burn[x] or 0, div(k * (15 - iabs(dx)), 15)) end
    end
  end
  local fc, mc, nc = pack(mix(tint(C.far, L.land), L.bot, 1, 2)), tint(C.mid, L.land), pack(tint(C.near, L.land))
  local mcp = pack(mc)
  for x = 0, W - 1 do
    local px = mod(left + x, PW)
    fg(fc); rect(x, far[px], 1, H - far[px])
    if burn[x] then fg(pack(mix(mc, tint(C.burnt, L.land), burn[x], 256))) else fg(mcp) end
    rect(x, mid[px], 1, H - mid[px])
    fg(nc); rect(x, near[px], 1, H - near[px])
  end
  -- 晨雾：山谷里一层淡淡的横线
  if wx.fog > 20 and L.min > L.sr - 60 and L.min < L.sr + 150 then
    fg(pack(tint({ 225, 228, 235 }, L.land)))
    local thick = clamp(div(wx.fog, 25), 1, 4)
    for k = 0, thick - 1 do rect(0, 90 + k * 3, W, 1) end
  end
end

local function draw_things(t, L, list, left)
  for _, e in ipairs(list) do
    local x = mod(col_of(e.b) - left, PW)
    if e.kind == "smoke" and x < W then
      local px = mod(left + x, PW)
      local base = mid[px]
      local tall = clamp(div(e.age, 2) + 12, 12, 56)
      fg(pack(mix(tint(C.smoke, L.land), C.smoke, 1, 2)))
      for k = 0, tall - 1, 2 do
        local wob = iabs(mod(div(t, 2) + div(k, 2), 6) - 3) + div(k, 5) -- 风把烟往一边带
        rect(x + wob - 1, base - k, 2 + div(k, 10), 2)
      end
    elseif e.kind == "deer" and x < W - 3 then
      local px = mod(left + x, PW)
      fg(pack(tint(C.deer, L.land))); rect(x, mid[px] - 3, 3, 2); rect(x + 2, mid[px] - 4, 1, 1)
      rect(x, mid[px] - 1, 1, 1); rect(x + 2, mid[px] - 1, 1, 1)
    elseif e.kind == "birds" then
      fg(pack(C.bird))
      local r = Rng(e.secs) -- 群里每只的位置略有抖动
      for k = 0, 6 do
        local bx = x + mod(k * 5, 13) - 6 + r(3)
        local by = 40 + mod(k * 7, 9) + div(iabs(mod(e.secs + k * 3, 20) - 10), 4)
        if bx >= 0 and bx < W then rect(bx, by, 1, 1) end
      end
    elseif e.kind == "rain" then
      local x0 = mod(col_of(e.b - 25) - left, PW)
      local wcol = col_of(50)
      fg(pack(mix(L.bot, { 90, 95, 105 }, 1, 2)))
      for k = 0, wcol - 1, 3 do
        local xx = mod(x0 + k, PW)
        if xx < W then rect(xx, mod(t * 5 + k, 7), 1, H) end
      end
    elseif e.kind == "light" and x < W then
      fg(rgb(255, 230, 150)); rect(x, far[mod(left + x, PW)] - 2, 1, 1)
    end
  end
end

local function draw(t, L, wx, list)
  local left = col_of(bearing) - div(W, 2)
  draw_land(t, L, wx, left)
  draw_things(t, L, list, left)
  text(div(W, 2) - 9, 2, string.format("%03d", bearing), pack(mix(L.top, { 255, 255, 255 }, 2, 3)), pack(L.top))
  rb.lcd_update()
end

local NAMES = { s = "smoke", d = "deer", b = "birds", r = "rain", l = "a light", n = "nothing", x = "looked a lot. nothing." }

local function draw_log(top)
  -- 日志：最新的在上面；没有记录的日子写 nothing
  local lines = {}
  local by_day = {}
  for _, e in ipairs(log) do
    local d = div(e[1], 86400)
    by_day[d] = by_day[d] or {}
    table.insert(by_day[d], e)
  end
  for d = today, first_day, -1 do
    local es = by_day[d]
    if es then
      for i = #es, 1, -1 do
        local e = es[i]
        local c = civil(e[1])
        lines[#lines + 1] = string.format("%02d-%02d %02d:%02d %03d %s", c.m, c.d, c.hh, c.mm, e[2], NAMES[e[3]] or "?")
      end
    else
      local c = civil(d * 86400)
      lines[#lines + 1] = string.format("%02d-%02d       nothing", c.m, c.d)
    end
  end
  fg(rgb(235, 228, 210)); rect(0, 0, W, H)
  local ink = rgb(60, 50, 40)
  for i = 0, 13 do
    local s = lines[top + i]
    if s then text(3, 3 + i * 9, s, ink, rgb(235, 228, 210)) end
  end
  rb.lcd_update()
  return #lines
end

-- ---------- 主循环 ----------
load()
light_start()
resolve_smoke(now())

local mode, log_top, log_len = "look", 1, 0
local running, last_draw = true, -1
while running do
  local t = now()
  local L = light_at(t)
  local wx = weather_of(L.day)
  if L.day ~= today then today = L.day end
  if clicks_day ~= today then clicks_day, clicks, busy_noted = today, 0, false end
  local list = things(t, L, wx)

  for _, e in ipairs(poll()) do
    local g = select_gesture(e)
    if e.k == "menu" and not e.rel then
      if mode == "log" then mode = "look" else running = false end
      last_draw = -1
    elseif mode == "log" then
      if e.k == "fwd" and not e.rel then log_top = clamp(log_top + 1, 1, math.max(1, log_len - 13))
      elseif e.k == "back" and not e.rel then log_top = clamp(log_top - 1, 1, math.max(1, log_len))
      elseif g == "short" or g == "long" then mode = "look" end
      last_draw = -1
    elseif e.k == "fwd" and not e.rel then bearing = mod(bearing + DEG_PER_CLICK, 360); clicks = clicks + 1; last_draw = -1
    elseif e.k == "back" and not e.rel then bearing = mod(bearing - DEG_PER_CLICK, 360); clicks = clicks + 1; last_draw = -1
    elseif g == "short" then
      -- 记下当前视野里能看到的东西
      local code = "n"
      for _, th in ipairs(list) do
        if iabs(adiff(th.b, bearing)) <= div(VIEW_DEG, 2) then
          code = ({ smoke = "s", deer = "d", birds = "b", rain = "r", light = "l" })[th.kind]
          if code == "s" then smoke_logged, smoke_logged_min = L.day, L.min end
          break
        end
      end
      log[#log + 1] = { t, bearing, code }
      if #log > 400 then table.remove(log, 1) end
      fg(rgb(255, 255, 255)); rect(0, 0, W, 2); rb.lcd_update() -- 一闪，表示记下了
      save()
    elseif g == "long" then
      mode, log_top = "log", 1
      last_draw = -1
    end
  end

  -- 转身转得太勤快
  if not busy_noted and clicks > BUSY_CLICKS then
    local any = false
    for _, e in ipairs(log) do if div(e[1], 86400) == today and e[3] ~= "n" then any = true end end
    if not any then log[#log + 1] = { t, bearing, "x" } end
    busy_noted = true
  end

  if mod(t, 60) == 0 then resolve_smoke(t) end
  local stamp = div(rb.current_tick(), div(HZ, 5)) -- 每秒最多 5 帧
  if mode == "log" then
    if last_draw < 0 then log_len = draw_log(log_top); last_draw = stamp end
  elseif stamp ~= last_draw then
    draw(t, L, wx, list)
    last_draw = stamp
  end
  keep_light()
  rb.sleep(div(HZ, 20))
end

save()
light_end()
