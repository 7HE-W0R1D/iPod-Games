-- 检查 Rockbox Lua 的编译限制：每个函数最多 100 个同时存在的 local、最多 30 个 upvalue。
-- 用桌面 luac 的字节码清单来数（luac -l -l）。_ENV 不算（Rockbox 的 Lua 5.1 没有它）。
-- 桌面 Lua 的 for 循环隐藏变量比 5.1 多一个，所以 local 数会略微高估，偏保守。
-- 用法：lua tools/check_limits.lua dist/golf.lua [更多文件]

local MAXVARS, MAXUP = 100, 30
local WARN_VARS, WARN_UP = 90, 27
local bad = false

for _, path in ipairs(arg) do
  local p = io.popen("luac -l -l -o /dev/null '" .. path .. "' 2>&1")
  local out = p:read("a")
  p:close()
  local funcs, cur, section = {}, nil, nil
  for line in out:gmatch("[^\n]+") do
    local head, l1 = line:match("^(%a+) <[^:]+:(%d+),%d+>")
    if head == "main" or head == "function" then
      cur = { line = tonumber(l1), ranges = {}, ups = 0 }
      funcs[#funcs + 1] = cur
      section = nil
    elseif line:match("^locals %(") then section = "locals"
    elseif line:match("^upvalues %(") then section = "upvalues"
    elseif line:match("^constants %(") then section = nil
    elseif cur and section == "locals" then
      local name, s, e = line:match("^%s+%d+%s+(%S+)%s+(%d+)%s+(%d+)")
      if name then cur.ranges[#cur.ranges + 1] = { tonumber(s), tonumber(e) } end
    elseif cur and section == "upvalues" then
      local name = line:match("^%s+%d+%s+(%S+)")
      if name and name ~= "_ENV" then cur.ups = cur.ups + 1 end
    end
  end
  local worst_v, worst_u = 0, 0
  for _, f in ipairs(funcs) do
    -- 同时存在的 local 数 = 区间重叠的最大值
    local ev = {}
    for _, r in ipairs(f.ranges) do ev[#ev + 1] = { r[1], 1 }; ev[#ev + 1] = { r[2], -1 } end
    table.sort(ev, function(a, b) if a[1] ~= b[1] then return a[1] < b[1] end return a[2] < b[2] end)
    local n, m = 0, 0
    for _, e in ipairs(ev) do n = n + e[2]; if n > m then m = n end end
    f.vars = m
    if m > worst_v then worst_v = m end
    if f.ups > worst_u then worst_u = f.ups end
    local where = f.line == 0 and "主函数" or ("第 " .. f.line .. " 行的函数")
    if m >= MAXVARS or f.ups >= MAXUP then
      print(string.format("!! %s %s：%d 个 local，%d 个 upvalue（上限 %d / %d）", path, where, m, f.ups, MAXVARS - 1, MAXUP - 1))
      bad = true
    elseif m >= WARN_VARS or f.ups >= WARN_UP then
      print(string.format("注意 %s %s：%d 个 local，%d 个 upvalue，接近上限", path, where, m, f.ups))
    end
  end
  print(string.format("%-20s 最多 %d 个 local，%d 个 upvalue", path, worst_v, worst_u))
end
if bad then os.exit(1) end
