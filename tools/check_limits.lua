-- 检查 Rockbox Lua 的编译限制：每个函数最多 100 个同时存在的 local、最多 30 个 upvalue。
--
-- local 数：按 Lua 5.1 解析器（lparser.c）的规则直接扫源码来数，不看桌面 luac 的字节码。
--   桌面 Lua 5.4/5.5 的数字 for 只有 2 个隐藏变量，5.1 有 3 个（index、limit、step），
--   每层嵌套的数字 for 都会少数一个；以前用字节码数，dungeon 和 gravity 报 96，真机报超过 100。
--   5.1 的规则：
--     local a, b = ...      声明时就检查 已有个数 + 新名字个数 > 100
--     local function f      +1
--     for i = a, b do       +4（3 个隐藏 + i）
--     for k, v in e do      +3 + 名字个数
--     function(a, b)        新函数，参数从 0 开始数；方法 a:b() 多一个 self；... 多一个 arg
--     块（do/then/else/循环体/函数体）结束时恢复到块开始时的个数
-- upvalue 数：仍用桌面 luac -l -l 的清单数（_ENV 不算，Rockbox 的 Lua 5.1 没有它）。
-- 用法：lua tools/check_limits.lua dist/golf.lua [更多文件]

local MAXVARS, MAXUP = 100, 30
local WARN_VARS, WARN_UP = 95, 27
local bad = false

-- 把源码切成 token：{ t = "name"|"kw"|"sym"|"other", v = 文本, line = 行号 }
local KW = {}
for w in ([[and break do else elseif end false for function if in local nil not or
  repeat return then true until while]]):gmatch("%a+") do KW[w] = true end

local function tokens(src)
  local out, i, line, n = {}, 1, 1, #src
  local function long_bracket(at)            -- at 指向 '['，返回结束位置或 nil
    local eq = src:match("^%[(=*)%[", at)
    if not eq then return nil end
    local close = "]" .. eq .. "]"
    local s, e = src:find(close, at, true)
    if not s then error("没闭合的长括号，第 " .. line .. " 行") end
    return e
  end
  while i <= n do
    local c = src:sub(i, i)
    if c == "\n" then line = line + 1; i = i + 1
    elseif c:match("%s") then i = i + 1
    elseif src:sub(i, i + 1) == "--" then
      local e = src:sub(i + 2, i + 2) == "[" and long_bracket(i + 2)
      if not e then e = (src:find("\n", i, true) or n + 1) - 1 end
      local _, nl = src:sub(i, e):gsub("\n", "")
      line = line + nl; i = e + 1
    elseif c == "[" and long_bracket(i) then
      local e = long_bracket(i)
      local _, nl = src:sub(i, e):gsub("\n", "")
      out[#out + 1] = { t = "other", v = "str", line = line }
      line = line + nl; i = e + 1
    elseif c == '"' or c == "'" then
      local j = i + 1
      while true do
        local d = src:sub(j, j)
        if d == "\\" then
          if src:sub(j + 1, j + 1) == "\n" then line = line + 1 end
          j = j + 2
        elseif d == c then break
        elseif d == "" or d == "\n" then error("没闭合的字符串，第 " .. line .. " 行")
        else j = j + 1 end
      end
      out[#out + 1] = { t = "other", v = "str", line = line }
      i = j + 1
    elseif c:match("[%a_]") then
      local w = src:match("^[%w_]+", i)
      out[#out + 1] = { t = KW[w] and "kw" or "name", v = w, line = line }
      i = i + #w
    elseif c:match("%d") or (c == "." and src:sub(i + 1, i + 1):match("%d")) then
      local w = src:match("^0[xX]%x+", i) or src:match("^[%d%.]+[eE][%+%-]?%d+", i) or src:match("^[%d%.]+", i)
      out[#out + 1] = { t = "other", v = "num", line = line }
      i = i + #w
    else
      local w = src:match("^%.%.%.", i) or src:match("^%.%.", i) or src:match("^[=~<>]=", i) or c
      out[#out + 1] = { t = "sym", v = w, line = line }
      i = i + #w
    end
  end
  return out
end

-- 按 5.1 的作用域规则数每个函数同时存在的 local 的峰值
local function count_locals(src)
  local tk = tokens(src)
  local funcs = {}
  local fs = { line = 0, n = 0, max = 0, max_line = 0 }   -- 主函数
  funcs[1] = fs
  -- 结构栈：每项 { kind = "block"|"func"|"loop"（还没遇到 do 的 while/for）|"repeat", save = 进块时的个数, fs = 外层函数 }
  local stack = {}
  local function add(k, line)
    fs.n = fs.n + k
    if fs.n > fs.max then fs.max = fs.n; fs.max_line = line end
  end
  local i = 1
  local function at(j) return tk[j] or { t = "eof", v = "" } end
  -- 从第 j 个 token（function 后面）开始，跳过函数名，读参数表，开一个新函数
  local function open_function(j, line)
    local method = false
    while at(j).v ~= "(" do
      if at(j).v == ":" then method = true end
      j = j + 1
    end
    j = j + 1
    local np = method and 1 or 0
    while at(j).v ~= ")" do
      if at(j).t == "name" then np = np + 1
      elseif at(j).v == "..." then np = np + 1 end   -- LUA_COMPAT_VARARG 的 arg
      j = j + 1
    end
    stack[#stack + 1] = { kind = "func", fs = fs }
    fs = { line = line, n = 0, max = 0, max_line = line }
    funcs[#funcs + 1] = fs
    add(np, line)
    return j + 1
  end
  while i <= #tk do
    local t = tk[i]
    local v = t.v
    if t.t == "kw" then
      if v == "local" then
        if at(i + 1).v == "function" then
          add(1, t.line)
          i = open_function(i + 2, at(i + 1).line)
        else
          local j, k = i + 1, 0
          while at(j).t == "name" do
            k = k + 1
            if at(j + 1).v == "," then j = j + 2 else j = j + 1; break end
          end
          add(k, t.line)
          i = j
        end
      elseif v == "function" then
        i = open_function(i + 1, t.line)
      elseif v == "for" then
        local j, k = i + 1, 0
        while at(j).t == "name" do
          k = k + 1
          if at(j + 1).v == "," then j = j + 2 else j = j + 1; break end
        end
        local numeric = at(j).v == "="
        stack[#stack + 1] = { kind = "loop", save = fs.n, add = numeric and 4 or 3 + k, line = t.line }
        i = j
      elseif v == "while" then
        stack[#stack + 1] = { kind = "loop", save = fs.n, add = 0, line = t.line }
        i = i + 1
      elseif v == "do" then
        local top = stack[#stack]
        if top and top.kind == "loop" then
          top.kind = "block"
          add(top.add, top.line)
        else
          stack[#stack + 1] = { kind = "block", save = fs.n }
        end
        i = i + 1
      elseif v == "if" then
        stack[#stack + 1] = { kind = "block", save = fs.n }
        i = i + 1
      elseif v == "elseif" or v == "else" then
        fs.n = stack[#stack].save
        i = i + 1
      elseif v == "repeat" then
        stack[#stack + 1] = { kind = "repeat", save = fs.n }
        i = i + 1
      elseif v == "until" then
        -- until 的条件还能看到块里的 local；条件里只可能有表达式，直接收块
        local top = table.remove(stack)
        fs.n = top.save
        i = i + 1
      elseif v == "end" then
        local top = table.remove(stack)
        if not top then error("多余的 end，第 " .. t.line .. " 行") end
        if top.kind == "func" then fs = top.fs else fs.n = top.save end
        i = i + 1
      else
        i = i + 1
      end
    else
      i = i + 1
    end
  end
  if #stack > 0 then error("块没闭合") end
  return funcs
end

-- 桌面 luac 的清单里数 upvalue，按函数起始行对应
local function count_upvalues(path)
  local p = io.popen("luac -l -l -o /dev/null '" .. path .. "' 2>&1")
  local out = p:read("a")
  p:close()
  local ups, cur, section = {}, nil, nil
  for line in out:gmatch("[^\n]+") do
    local head, l1 = line:match("^(%a+) <[^:]+:(%d+),%d+>")
    if head == "main" or head == "function" then
      cur = { line = tonumber(l1), n = 0 }
      ups[#ups + 1] = cur
      section = nil
    elseif line:match("^upvalues %(") then section = "upvalues"
    elseif line:match("^%a+ %(") then section = nil
    elseif cur and section == "upvalues" then
      local name = line:match("^%s+%d+%s+(%S+)")
      if name and name ~= "_ENV" then cur.n = cur.n + 1 end
    end
  end
  return ups
end

for _, path in ipairs(arg) do
  local f = assert(io.open(path, "rb"))
  local src = f:read("a")
  f:close()
  local worst_v, worst_u = 0, 0
  for _, fn in ipairs(count_locals(src)) do
    local where = fn.line == 0 and "主函数" or ("第 " .. fn.line .. " 行的函数")
    if fn.max > MAXVARS then
      print(string.format("!! %s %s：%d 个 local（上限 %d），峰值在第 %d 行", path, where, fn.max, MAXVARS, fn.max_line))
      bad = true
    elseif fn.max >= WARN_VARS then
      print(string.format("注意 %s %s：%d 个 local，接近上限，峰值在第 %d 行", path, where, fn.max, fn.max_line))
    end
    if fn.max > worst_v then worst_v = fn.max end
  end
  for _, u in ipairs(count_upvalues(path)) do
    local where = u.line == 0 and "主函数" or ("第 " .. u.line .. " 行的函数")
    if u.n > MAXUP then
      print(string.format("!! %s %s：%d 个 upvalue（上限 %d）", path, where, u.n, MAXUP))
      bad = true
    elseif u.n >= WARN_UP then
      print(string.format("注意 %s %s：%d 个 upvalue，接近上限", path, where, u.n))
    end
    if u.n > worst_u then worst_u = u.n end
  end
  print(string.format("%-20s 最多 %d 个 local，%d 个 upvalue", path, worst_v, worst_u))
end
if bad then os.exit(1) end
