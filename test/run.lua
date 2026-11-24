-- 桌面上跑 dist/*.lua 的假 Rockbox 环境。
-- 用法：lua test/run.lua dist/sandpile.lua [帧数] [时间偏移秒] [按键脚本]
-- 按键脚本：逗号分隔，比如 "fwd*20,select,wait*30,play,longselect"
-- 检查：画图参数必须是整数（Rockbox 的 Lua 没有浮点）、坐标不能离谱地出屏。

local script, frames, shift, keys = arg[1], tonumber(arg[2] or "300"), tonumber(arg[3] or "0"), arg[4] or ""

local tick = 0
local raw_open = io.open
-- 帧缓冲：SNAP=文件名 时在最后一帧把画面存成 PPM
local fb, cur = {}, 0
for i = 0, 176 * 132 - 1 do fb[i] = 0 end
local function px(x, y) if x >= 0 and x < 176 and y >= 0 and y < 132 then fb[y * 176 + x] = cur end end
local function fill(x, y, w, h) for yy = y, y + h - 1 do for xx = x, x + w - 1 do px(xx, yy) end end end
local function snap(path)
  local f = raw_open(path, "wb"); f:write("P6\n176 132\n255\n")
  local t = {}
  for i = 0, 176 * 132 - 1 do local c = fb[i]; t[#t + 1] = string.char(c // 65536, (c // 256) % 256, c % 256) end
  f:write(table.concat(t)); f:close()
end
local snap_at = {}
for n in string.gmatch(os.getenv("SNAPAT") or "", "%d+") do snap_at[tonumber(n)] = true end
local calls = 0
local function isint(v, name)
  if math.type(v) ~= "integer" then
    error(string.format("%s 收到非整数 %s", name, tostring(v)), 3)
  end
end
local function ints(name, ...)
  local n = select("#", ...)
  for i = 1, n do isint((select(i, ...)), name) end
  calls = calls + 1
end

local B = {
  BUTTON_NONE = 0, BUTTON_SELECT = 0x01, BUTTON_MENU = 0x02, BUTTON_LEFT = 0x04,
  BUTTON_RIGHT = 0x08, BUTTON_SCROLL_FWD = 0x10, BUTTON_SCROLL_BACK = 0x20,
  BUTTON_PLAY = 0x40, BUTTON_REL = 0x02000000, BUTTON_REPEAT = 0x04000000,
}

-- 把按键脚本展开成每帧的按键队列
local plan = {}
for tok in string.gmatch(keys, "[^,]+") do
  local name, n = string.match(tok, "^(%a+)%*?(%d*)$")
  n = tonumber(n) or 1
  for _ = 1, n do
    if name == "wait" then plan[#plan + 1] = {}
    elseif name == "fwd" then plan[#plan + 1] = { B.BUTTON_SCROLL_FWD }
    elseif name == "back" then plan[#plan + 1] = { B.BUTTON_SCROLL_BACK }
    elseif name == "flick" then plan[#plan + 1] = { B.BUTTON_SCROLL_FWD, B.BUTTON_SCROLL_FWD, B.BUTTON_SCROLL_FWD, B.BUTTON_SCROLL_FWD, B.BUTTON_SCROLL_FWD, B.BUTTON_SCROLL_FWD }
    elseif name == "longselect" or name == "longmenu" then
      local code = (name == "longmenu") and B.BUTTON_MENU or B.BUTTON_SELECT
      plan[#plan + 1] = { code }
      for _ = 1, 30 do plan[#plan + 1] = { code + B.BUTTON_REPEAT } end
      plan[#plan + 1] = { code + B.BUTTON_REL }
    else
      local alias = { next = "RIGHT", prev = "LEFT" }
      local code = B["BUTTON_" .. (alias[name] or string.upper(name))]
      assert(code, "未知按键 " .. name)
      plan[#plan + 1] = { code }
      plan[#plan + 1] = { code + B.BUTTON_REL }
    end
  end
end

local queue, frame = {}, 0
local wheel_pos = 0 -- 模拟转盘绝对位置：每个转盘事件走 6 格（一圈 96）
local function next_frame()
  frame = frame + 1
  local p = plan[frame]
  if p then for _, b in ipairs(p) do
    queue[#queue + 1] = b
    if b == B.BUTTON_SCROLL_FWD then wheel_pos = (wheel_pos + 6) % 96 end
    if b == B.BUTTON_SCROLL_BACK then wheel_pos = (wheel_pos - 6) % 96 end
  end end
  if snap_at[frame] and os.getenv("SNAP") then snap(os.getenv("SNAP") .. "_" .. frame .. ".ppm") end
  if frame >= frames then queue[#queue + 1] = ((frame - frames) % 2 == 0) and B.BUTTON_MENU or (B.BUTTON_MENU + B.BUTTON_REL) end -- Menu 松开时才退出
  if frame > frames + 30 then error("按了 Menu 之后 30 帧还没退出", 0) end
end

rb = {
  LCD_WIDTH = 176, LCD_HEIGHT = 132, HZ = 100, FONT_SYSFIXED = 0, -- 和真机一样：没有 rb.buttons
  current_tick = function() return tick end,
  sleep = function(t) isint(t, "sleep"); tick = tick + math.max(t, 1); next_frame() end,
  yield = function() end,
  button_get = function(block)
    if #queue == 0 then return 0 end
    return table.remove(queue, 1)
  end,
  wheel_status = function() if os.getenv("NOWHEELPOS") then error("no wheel_status") end return wheel_pos end,
  button_get_w_tmo = function(t) tick = tick + t; next_frame(); if #queue == 0 then return 0 end return table.remove(queue, 1) end,
  lcd_rgbpack = function(r, g, b) ints("lcd_rgbpack", r, g, b)
    assert(r >= 0 and r <= 255 and g >= 0 and g <= 255 and b >= 0 and b <= 255, "颜色越界")
    return r * 65536 + g * 256 + b end,
  lcd_set_foreground = function(c) ints("fg", c); cur = c end,
  lcd_set_background = function(c) ints("bg", c) end,
  lcd_fillrect = function(x, y, w, h) ints("lcd_fillrect", x, y, w, h)
    assert(x > -400 and y > -400 and x < 600 and y < 600, "fillrect 坐标离谱"); fill(x, y, w, h) end,
  lcd_drawpixel = function(x, y) ints("lcd_drawpixel", x, y); px(x, y) end,
  lcd_hline = function(x1, x2, y) ints("lcd_hline", x1, x2, y); if x2 < x1 then x1, x2 = x2, x1 end fill(x1, y, x2 - x1 + 1, 1) end,
  lcd_vline = function(x, y1, y2) ints("lcd_vline", x, y1, y2); if y2 < y1 then y1, y2 = y2, y1 end fill(x, y1, 1, y2 - y1 + 1) end,
  lcd_drawline = function(a, b, c, d) ints("lcd_drawline", a, b, c, d) end,
  lcd_putsxy = function(x, y, s) ints("lcd_putsxy", x, y); assert(type(s) == "string"); fill(x, y, #s * 6, 7)
    if os.getenv("SHOWTEXT") then print("text:", s) end end,
  lcd_getstringsize = function(s) return #s * 6, 8 end,
  lcd_setfont = function() end,
  lcd_clear_display = function() end,
  lcd_update = function() end,
  lcd_update_rect = function() end,
  backlight_on = function() end,
}

-- 和真机一样：require("buttons") 之后才有 rb.buttons。NOBUTTONS=1 时模拟加载失败。
package.preload["buttons"] = function()
  if os.getenv("NOBUTTONS") then error("module 'buttons' not found") end
  rb.buttons = B
end

-- 存档重定向到临时目录
local fsroot = (os.getenv("TMPDIR") or "/tmp/") .. "/rbfs"
os.execute("mkdir -p '" .. fsroot .. "/.rockbox/rocks.data'")
local real_open = io.open
io.open = function(path, mode)
  if string.sub(path, 1, 1) == "/" then path = fsroot .. path end
  return real_open(path, mode)
end
local real_time = os.time
os.time = function(t) if t then return real_time(t) end return real_time() + shift + math.floor(tick / 100) end

local ok, err = pcall(dofile, script)
if not ok then print("FAIL " .. script .. ": " .. tostring(err)); os.exit(1) end
print(string.format("ok   %s  帧=%d  画图调用=%d", script, frame, calls))
