-- 高尔夫：一座安静的小球场。慢转瞄准，快拨出杆。一天只开放一个洞。
-- 转盘：慢转调角度，快拨一下出杆（只看那一下的峰值速度）   Select：打完后看一眼杆数   Menu：退出

local SAVE = "slow_golf.txt"
local CW = W * 3                -- 球场宽度
local FP = 16                   -- 定点：位置 ×16
-- 转速单位：每秒转过多少格，一圈 96 格（读转盘的绝对位置算出来的）
local T = {
  -- 上机实测（窗口 0.2 秒时）：慢转 50～100，快拨峰值才 105 左右，所以改用更短的窗口抓快拨
  AIM_MAX = 110,                -- 慢于这个算瞄准
  SHOT_MIN = 170,               -- 快于这个算出杆；中间是死区
  SHOT_FULL = 420,              -- 到这个速度就是满力
  WINDOW = div(HZ, 10),         -- 量转速的时间窗（0.1 秒）：快拨很短，窗口长了会被摊薄
  POWER_MIN = 14,               -- 最轻的一杆（满力是 120）
  GIMME = 8,                    -- 球在果岭上停在离洞这么多像素以内，就算进了
}
-- 按 Play 显示转速读数（now 当前 / peak 最近 3 秒最快），用来上机调上面几个数
local G = 2                     -- 重力（1/16 像素 / tick²）
local CAPTURE = 36              -- 球速低于这个经过洞口才会进

-- cos 表：0°,5°,…,90°，×256
local COS = { 256, 255, 252, 247, 241, 232, 222, 210, 196, 181, 165, 147, 128, 108, 88, 66, 44, 22, 0 }
local function cosd(a)
  a = clamp(a, 0, 90)
  local i = div(a, 5)
  if i >= 18 then return 0 end
  return lerp(COS[i + 1], COS[i + 2], a - i * 5, 5)
end
local function sind(a) return cosd(90 - a) end

-- ---------- 球场：每天一个新地形 ----------
local GRASS, SAND, WATER, GREEN = 0, 1, 2, 3
local ground, kind = {}, {}
local far = {}
local course = {}

local function build(day)
  local r = Rng(hash(day, 3))
  for x = 0, CW - 1 do ground[x] = 100; kind[x] = GRASS end
  -- 缓坡和小丘
  for _ = 1, 6 do
    local cx, w, a = r(CW), 30 + r(90), r(29) - 12
    for x = math.max(0, cx - w), math.min(CW - 1, cx + w) do
      local d = x - cx
      ground[x] = ground[x] - div(a * (w * w - d * d), w * w)
    end
  end
  local tilt = r(21) - 10 -- 整体略微上坡或下坡
  for x = 0, CW - 1 do ground[x] = ground[x] + div(x * tilt, CW) end
  -- 果岭：最后一段压平
  local gx0, gx1 = CW - 90, CW - 10
  local gy = ground[gx0]
  local gslope = r(5) - 2 -- 果岭只有一点点坡
  for x = gx0, CW - 1 do
    ground[x] = lerp(ground[x], gy + div((x - gx0) * gslope, 80), clamp(x - gx0, 0, 20), 20)
    if x <= gx1 then kind[x] = GREEN end
  end
  -- 发球台
  for x = 0, 34 do ground[x] = ground[34] end
  -- 小溪
  local c0 = 120 + r(CW - 300)
  for x = c0, c0 + 15 do ground[x] = ground[x] + 9; kind[x] = WATER end
  -- 沙坑（在溪和果岭之间，或者溪前面）
  local s0 = c0 + 40 + r(math.max(1, gx0 - c0 - 70))
  for x = s0, s0 + 19 do
    if kind[x] == GRASS then ground[x] = ground[x] + clamp(4 - div(iabs(x - s0 - 10), 3), 0, 4); kind[x] = SAND end
  end
  for x = 0, CW - 1 do ground[x] = clamp(ground[x], 66, 122) end
  local rf = Rng(hash(day, 4))
  local h = 84
  for x = 0, W + div(CW, 2) do h = clamp(h + rf(3) - 1, 76, 94); far[x] = h end
  course = { hole = CW - 40, creek = c0, tee = 20, rabbit = r(3) == 0, rx = gx0 - 8 }
  -- 洞
  local hx = course.hole
  for x = hx - 1, hx + 1 do ground[x] = ground[hx - 2] end
end

-- ---------- 状态 ----------
local today = civil(now()).day
local wx = weather_of(today)
local bx, by, vx, vy = 20 * FP, 0, 0, 0
local state = "aim"           -- aim / fly / roll / splash / holed
local angle, strokes = 35, 0
local show_strokes = false
local rabbit_x, rabbit_run = 0, 0
local splash_until, flag_wiggle = 0, 0
local cam = 0

local function load()
  local s = load_kv(SAVE)
  build(today)
  bx = course.tee * FP
  if num(s.day, -1) == today then
    strokes = num(s.strokes, 0)
    bx = num(s.bx, bx)
    angle = num(s.angle, 35)
    if s.holed == "1" then state = "holed" end
  end
  by = ground[div(bx, FP)] * FP
  rabbit_x = course.rx
end
local function save()
  save_kv(SAVE, { day = today, strokes = strokes, bx = bx, angle = angle, holed = state == "holed" and "1" or "0" })
end

local function facing() return bx <= course.hole * FP and 1 or -1 end

local function shoot(power)
  local f = facing()
  if kind[clamp(div(bx, FP), 0, CW - 1)] == GREEN then power = div(power, 2) end -- 果岭上推杆，力度减半
  vx = div(f * power * cosd(angle), 256)
  vy = -div(power * sind(angle), 256)
  state = "fly"
  strokes = strokes + 1
end

local function gnd(x) return ground[clamp(x, 0, CW - 1)] end

-- 进洞：球落进洞里，旗子晃一下
local function sink(tk)
  local hx = course.hole
  bx, by, vx, vy, state = hx * FP, (gnd(hx) + 3) * FP, 0, 0, "holed"
  flag_wiggle = tk + 2 * HZ
  save()
end

-- 一步物理
local function physics(tk)
  local px = div(bx, FP)
  if state == "fly" then
    vy = vy + G
    if mod(tk, 6) == 0 then vx = vx + wx.wind end -- 一点风
    bx, by = bx + vx, by + vy
    if bx < 0 then bx, vx = 0, -div(vx, 2) elseif bx >= (CW - 1) * FP then bx, vx = (CW - 1) * FP, -div(vx, 2) end
    px = div(bx, FP)
    local gy = gnd(px) * FP
    if by >= gy then
      local k = kind[px]
      if k == WATER then
        state, splash_until = "splash", tk + HZ
        return
      end
      by = gy
      if vy > 18 then
        local rest = k == SAND and 8 or (k == GREEN and 3 or 2)
        vy = -div(vy, rest + 1)
        vx = div(vx * (k == SAND and 1 or 4), 5)
      else
        vy, state = 0, "roll"
      end
    end
  elseif state == "roll" then
    local slope = gnd(px + 1) - gnd(px - 1) -- 往右下坡为正
    vx = vx + clamp(slope, -3, 3)
    local k = kind[px]
    local f = k == SAND and 3 or (k == GREEN and 40 or 16)
    vx = vx - div(vx, f) - (vx > 0 and 1 or (vx < 0 and -1 or 0))
    local nx = bx + vx
    local npx = div(nx, FP)
    -- 经过洞口，够慢就进
    local hx = course.hole
    if (px - hx) * (npx - hx) <= 0 and px ~= npx or npx == hx then
      if iabs(vx) < CAPTURE then sink(tk); return end
    end
    bx = nx
    px = clamp(div(bx, FP), 0, CW - 1)
    if kind[px] == WATER then state, splash_until = "splash", tk + HZ; return end
    local gy = gnd(px) * FP
    if gy - by > 2 * FP then state, vy = "fly", 0 -- 滚下了坎
    else by = gy end
    if bx < 0 or bx >= (CW - 1) * FP then bx, vx = clamp(bx, 0, (CW - 1) * FP), 0 end
    if iabs(vx) < 2 and iabs(slope) <= 1 then
      vx = 0
      -- 停在果岭上、离洞足够近，就算进了
      if kind[px] == GREEN and iabs(px - course.hole) <= T.GIMME then sink(tk)
      else state = "aim"; save() end
    end
  elseif state == "splash" then
    if tk >= splash_until then
      -- 不罚杆，在岸边重新放好
      bx = (course.creek - 6) * FP
      by, vx, vy, state = gnd(course.creek - 6) * FP, 0, 0, "aim"
      save()
    end
  end
end

-- ---------- 画面 ----------
local COL = {
  [GRASS] = { 70, 130, 60 }, [SAND] = { 215, 195, 140 }, [WATER] = { 60, 110, 170 }, [GREEN] = { 95, 165, 75 },
}
-- 画面分成几块画：Rockbox 的 Lua 每个函数最多 30 个 upvalue
local function draw_land(L)
  for y = 0, H - 1, 4 do fg(pack(mix(L.top, L.bot, y, 110))); rect(0, y, W, 4) end
  -- 远山（视差，一半速度），淡一些，靠近天边的颜色
  fg(pack(mix(tint({ 90, 110, 120 }, L.land), L.bot, 2, 3)))
  local fo = div(cam, 2)
  for x = 0, W - 1 do local h = far[x + fo] or 84; rect(x, h, 1, H - h) end
  local cols = {}
  for k, c in pairs(COL) do cols[k] = pack(tint(c, L.land)) end
  local dirt = pack(tint({ 90, 70, 45 }, L.land))
  for x = 0, W - 1 do
    local cx = x + cam
    local gy = ground[cx]
    local k = kind[cx]
    if k == WATER then
      fg(dirt); rect(x, gy, 1, H - gy)
      fg(cols[WATER]); rect(x, gy - 6, 1, 6)
    else
      fg(cols[k]); rect(x, gy, 1, 3); fg(dirt); rect(x, gy + 3, 1, H - gy - 3)
    end
  end
end

-- 影子：太阳越低越长；早上往左，傍晚往右
local function shadow_of(L)
  local len = 0
  if L.sun > 0 then len = clamp(div(1000 - L.sun, 45), 1, 24) end
  return len, L.min < div(L.sr + L.ss, 2) and -1 or 1, pack(tint({ 35, 60, 30 }, L.land))
end

local function draw_flag_rabbit(L, tk, shadow, sdir, shc)
  local hx = course.hole - cam
  if hx > -30 and hx < W + 30 then
    local hy = ground[course.hole]
    fg(rgb(10, 10, 10)); rect(hx - 1, hy, 3, 3)
    if shadow > 0 then fg(shc); rect(sdir > 0 and hx or hx - shadow * 2, hy, shadow * 2, 1) end
    fg(rgb(230, 230, 230)); rect(hx, hy - 16, 1, 16)
    local wig = tk < flag_wiggle and (mod(div(tk, 3), 3) - 1) or 0
    fg(pack(tint({ 230, 60, 50 }, L.land)))
    rect(hx + 1, hy - 16 + wig, 6, 2); rect(hx + 1, hy - 14 + wig, 4, 2); rect(hx + 1, hy - 12 + wig, 2, 1)
  end
  if course.rabbit and rabbit_x > -10 and rabbit_x < CW + 10 then
    local rx = rabbit_x - cam
    local ry = ground[clamp(rabbit_x, 0, CW - 1)]
    fg(pack(tint({ 150, 130, 110 }, L.land)))
    rect(rx, ry - 3, 4, 3); rect(rx + 3, ry - 6, 1, 3); rect(rx + 4, ry - 5, 1, 2)
  end
end

local function draw_ball(shadow, sdir, shc)
  local px, py = div(bx, FP) - cam, div(by, FP)
  if state ~= "holed" then
    if shadow > 0 then
      local gy = ground[clamp(div(bx, FP), 0, CW - 1)]
      fg(shc); rect(sdir > 0 and px or px - shadow, gy, shadow, 1)
    end
    fg(rgb(250, 250, 250)); rect(px - 1, py - 2, 2, 2)
  end
  if state == "aim" then
    local f = facing()
    fg(rgb(250, 250, 250))
    for k = 2, 4 do
      rect(px + div(f * k * 4 * cosd(angle), 256), py - 2 - div(k * 4 * sind(angle), 256), 1, 1)
    end
  end
end

local function draw_extras(L, tk)
  if state == "splash" then
    fg(pack(tint({ 200, 225, 250 }, L.land)))
    local cxw = course.creek + 8 - cam
    local age = HZ - (splash_until - tk)
    for k = -3, 3 do rect(cxw + k * 2, ground[course.creek] - 6 - div(age * (4 - iabs(k)), 25), 1, 1) end
  end
  if state == "holed" then
    -- 左上角一个小日历：今天的洞打完了，明天再来
    fg(rgb(235, 235, 230)); rect(3, 3, 9, 8)
    fg(rgb(200, 60, 50)); rect(3, 3, 9, 2)
    fg(rgb(90, 90, 90)); rect(5, 7, 1, 1); rect(7, 7, 1, 1); rect(9, 7, 1, 1)
    if show_strokes then text_r(W - 2, 2, tostring(strokes), rgb(255, 255, 255), pack(L.top)) end
  end
end

local function draw(L, tk)
  draw_land(L)
  local shadow, sdir, shc = shadow_of(L)
  draw_flag_rabbit(L, tk, shadow, sdir, shc)
  draw_ball(shadow, sdir, shc)
  draw_extras(L, tk)
  rb.lcd_update()
end

-- ---------- 主循环 ----------
load()
light_start()
local running = true
local fl = { on = false, peak = 0 } -- 正在快拨、这一下的峰值
local meter = { on = false, peak = 0, t = 0 } -- 转速读数
local view = { pan = nil } -- 打完以后用转盘左右看球场：镜头位置
local angle_hist = {}
local tk = 0

while running do
  tk = rb.current_tick()
  local clicks = 0
  for _, e in ipairs(poll()) do
    if e.k == "menu" and not e.rel then running = false
    elseif (e.k == "fwd" or e.k == "back") and not e.rel then clicks = clicks + (e.k == "fwd" and 1 or -1)
    elseif e.k == "play" and not e.rel and not e.rep then meter.on = not meter.on
    elseif select_gesture(e) == "short" and state == "holed" then show_strokes = not show_strokes end
  end

  -- 跨天：换一个新地形
  local d = civil(now()).day
  if d ~= today then
    today, wx, strokes, state, angle = d, weather_of(d), 0, "aim", 35
    build(today); bx = course.tee * FP; by = ground[course.tee] * FP; rabbit_x = course.rx
  end

  if state == "aim" then
    -- 记下最近 1/4 秒的角度，快拨时退回到拨之前
    angle_hist[#angle_hist + 1] = { tk, angle }
    while #angle_hist > 1 and tk - angle_hist[2][1] >= div(HZ, 4) do table.remove(angle_hist, 1) end
    local rate = wheel_speed(T.WINDOW)
    if rate >= T.SHOT_MIN then
      if not fl.on then
        fl.on, fl.peak = true, rate
        angle = angle_hist[1][2] -- 快拨开头那几格不算瞄准，退回去
      end
      fl.peak = math.max(fl.peak, rate)
    elseif fl.on then
      fl.on = false
      shoot(T.POWER_MIN + div(clamp(fl.peak - T.SHOT_MIN, 0, T.SHOT_FULL - T.SHOT_MIN) * (120 - T.POWER_MIN), T.SHOT_FULL - T.SHOT_MIN)) -- 越快力度越大
    elseif rate <= T.AIM_MAX and clicks ~= 0 then
      angle = clamp(angle + clicks, 5, 80)
    end
  end
  physics(tk)
  physics(tk) -- 每帧两步，动作更顺

  -- 兔子：球滚近了就跑开
  if course.rabbit then
    if rabbit_run == 0 and iabs(div(bx, FP) - rabbit_x) < 30 and state ~= "aim" then rabbit_run = rabbit_x < div(bx, FP) and -3 or 3 end
    rabbit_x = rabbit_x + rabbit_run
  end

  -- 镜头跟着球；打完以后改由转盘左右看整个球场，像打完球散步回头看一眼
  local target = clamp(div(bx, FP) - div(W, 3), 0, CW - W)
  if facing() < 0 then target = clamp(div(bx, FP) - div(W * 2, 3), 0, CW - W) end
  if state == "holed" then
    if not view.pan then view.pan = target end -- 从镜头要去的地方（球洞那边）开始
    view.pan = clamp(view.pan + clicks * 6, 0, CW - W)
    target = view.pan
  else
    view.pan = nil
  end
  cam = cam + div(target - cam, 6)
  if iabs(target - cam) < 6 then cam = target end

  draw(light_at(now()), tk)
  if meter.on then
    local r, src = wheel_speed(T.WINDOW)
    if r >= meter.peak or tk - meter.t > 3 * HZ then meter.peak, meter.t = r, tk end
    text(2, 2, string.format("now %d  peak %d  %s", r, meter.peak, src), rgb(255, 255, 255), rgb(0, 0, 0))
    rb.lcd_update()
  end
  keep_light()
  rb.sleep(div(HZ, 30))
end

save()
light_end()
