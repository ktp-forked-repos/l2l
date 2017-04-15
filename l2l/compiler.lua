local utils = require("leftry").utils
local list = require("l2l.list")
local lua = require("l2l.lua")
local reader = require("l2l.reader")
local vector = require("l2l.vector")
local exception = require("l2l.exception")
local symbol = reader.symbol
local len = require("l2l.len")
local loadstring = _G["loadstring"] or _G["load"]
local ipairs = require("l2l.iterator")

local trait = require("leftry.trait")
local destructure = trait("destructure")

local unpack = table.unpack or _G["unpack"]
local pack = table.pack or function(...) return {n=select("#", ...), ...} end
local set_sourcemap_to = reader.set_sourcemap_to

local function validate_functioncall(car)
  assert(
    getmetatable(car) ~= lua.lua_number and (
    utils.hasmetatable(car, list) or
    utils.hasmetatable(car, symbol) or
    lua.lua_ast[getmetatable(car)]),
    "only expressions and symbols can be called.."..tostring(car))
end

local function accessor_functioncall(car, cdr)
  if utils.hasmetatable(car, symbol) then
    local first = string.sub(car.name, 1, 1)
    local second = string.sub(car.name, 2, 2)
    local rest = lua.lua_args.new(lua.lua_explist(vector.sub(cdr, 2)))
    if first == ":"then
      return lua.lua_colon_functioncall.new(
        lua.lua_paren_exp.new(cdr[1]),
        lua.lua_name(car.name:sub(2)),
        rest)
    elseif car.name == "." then
      local exp = cdr[1]
      for i, v in ipairs(cdr) do
        if i > 1 then
          exp = lua.lua_index.new(lua.lua_paren_exp.new(exp), cdr[i])
        end
      end
      return exp
    elseif first == "." and second ~= "." then
      return lua.lua_dot.new(lua.lua_paren_exp.new(cdr[1]),
        lua.lua_name(car.name:sub(2)))
    end
  end
end


--- Return expansion of special form f with arguments ... in a protected
--  manner.
local function transform(f, invariant, data, ...)
  local ok, error_or_data = xpcall(f, function(e)
    return (function()
      if e:match("%% Module") then
        return e
      end
      local position, rest = vector.unpack(invariant.index[data])
      local message = "ERROR: ".. e:gsub("^.*:[0-9]: ", "") ..
          "\n% Module \""..(invariant.mod or "N/A").."\". "..
          exception.formatsource(invariant.source, position, rest-1)
      return message
    end)()
  end, invariant, data, ...)
  if not ok then
    error(error_or_data, 2)
  end
  return error_or_data
end


local expize

--- Convert a compiled lua expression into a Lua statement. Replace all
-- Lisp symbols with Lua names, call the appropriate special form function
-- for all Lua function calls if the caller is a defined special form
-- designed with Lua in mind.
-- @param invariant
-- @param data
-- @param output
-- @return
local function statize_lua(invariant, data, output)
  local stat = data
    :gsub(symbol, function(value) return lua.lua_nameize(value) end)
    :gsub(list, function(value, ...)
      return set_sourcemap_to(invariant, value, expize(invariant, value, output))
    end)
    :gsub(lua.lua_functioncall,
      function(value, parent)
        if parent ~= data then
          return lua.lua_nameize(invariant.lua[tostring(value.exp)].expize(
            invariant,
            list.cast(value.args.explist),
            output))
        else
          return invariant.lua[tostring(value.exp)].statize(
            invariant,
            list.cast(value.args.explist),
            output)
        end
      end, function(value)
        return invariant.lua[tostring(value.exp)] and
          invariant.lua[tostring(value.exp)].in_lua
      end)
  return stat
end


--- If invariant is in debug mode, append each lua expression with a comment
-- to describe which code in the original source code the compiled lua
-- expression corresponds to.
-- @param invariant
-- @param data
-- @param exp
-- @return
local function record(invariant, data, exp)
  if invariant.debug and invariant.index[data]
      and not utils.hasmetatable(data, lua.lua_block) then
    local position, rest = unpack(invariant.index[data])
    return lua.lua_annotated.new(exp,
      lua.lua_long_comment.new(
        "\n% Module \""..(invariant.mod or "N/A").."\". "..
          exception.formatsource(invariant.source, position, rest-1).."\n"))
  end
  return exp
end

--- Compile a embedded Lua expression into a Lua expression, compiling all
-- nested Lisp expressions into Lua expressions too.
-- @param invariant
-- @param data
-- @param output
-- @return
local function expize_lua(invariant, data, output)
  local exp = data:gsub(symbol, function(value)
      return lua.lua_nameize(value)
    end):gsub(list, function(value)
      return expize(invariant, value, output)
    end):gsub(lua.lua_functioncall,
    function(value)
      return lua.lua_nameize(invariant.lua[tostring(value.exp)].expize(
        invariant,
        list.cast(value.args.explist),
        output))
    end, function(value)
      return invariant.lua[tostring(value.exp)] and
        invariant.lua[tostring(value.exp)].in_lua
    end)
  return record(invariant, data, exp)
end

--- Compile a Lisp expression into a Lua expression.
-- @param invariant
-- @param data
-- @param output
-- @return
function expize(invariant, data, output)
  local expanded
  if utils.hasmetatable(data, list) then
    local car = data:car()
    if utils.hasmetatable(car, symbol) and invariant.lua[car[1]] then
      return transform(invariant.lua[car[1]].expize, invariant,
        set_sourcemap_to(invariant, data, data:cdr()), output)
    end
    local _data
    _data, expanded = reader.expand(invariant, data)
    if expanded then
      return expize(invariant, set_sourcemap_to(invariant, data, _data), output)
    end
  end
  if lua.lua_ast[getmetatable(data)] then
    return expize_lua(invariant, data, output)
  end
  if utils.hasmetatable(data, list) then
    local car = data:car()
    local cdr = vector.cast(data:cdr(), function(value)
      return expize(invariant, value, output)
    end)
    validate_functioncall(car)
    local accessor = accessor_functioncall(car, cdr)
    if accessor then
      return accessor
    end
    local func = expize(invariant, car, output)
    if utils.hasmetatable(func, lua.lua_lambda_function) then
      func = lua.lua_paren_exp.new(func)
    end
    return record(invariant, data, lua.lua_functioncall.new(
      func,
      lua.lua_args.new(lua.lua_explist(cdr))))
  elseif utils.hasmetatable(data, symbol) then
    return lua.lua_name(data:mangle())
  elseif data == nil then
    return "nil"
  elseif data == reader.lua_none then
    return
  elseif type(data) == "number" then
    return data
  end
  error("cannot expize.."..tostring(data))
end


--- Convert a compiled lua expression into a statement.
-- @param exp
-- @param name
-- @return
local function to_stat(exp, name)
  -- convert exp to stat
  name = name or lua.lua_name:unique("_var")
  assert(exp)
  return lua.lua_local.new(lua.lua_namelist({name}), lua.lua_explist({exp}))
end


--- Compile a lisp expression into a Lua return statement.
-- @param invariant
-- @param data
-- @param output
-- @return
local function retstatize(invariant, data, output)
  -- Convert stat to retstat.
  if not utils.hasmetatable(data, lua.lua_block) then
    return lua.lua_retstat.new(
      lua.lua_explist({expize(invariant, data, output)}))
  elseif not utils.hasmetatable(data[#data], lua.lua_retstat) then
    if not data[#data]:match(lua.lua_assign) then
      -- TODO: Should ignore all Lua stat asts that are not valid Lua exps, not just lua_assign.
      data[#data] = retstatize(invariant,
        expize_lua(invariant, data[#data], output), output)
    end
    return statize_lua(invariant, data, output)
  elseif not utils.hasmetatable(data, lua.retstat) then
    return statize_lua(invariant, data, output)
  end
  return expize_lua(invariant, data, output)
end


--- Compile a Lisp expression into a Lua statement.
-- @param invariant
-- @param data
-- @param output
-- @param last
-- @return
local function statize(invariant, data, output, last)
  if last then
    return retstatize(invariant, data, output)
  end
  local expanded
  if utils.hasmetatable(data, list) then
    local car = data:car()
    if utils.hasmetatable(car, symbol) and invariant.lua[car[1]] then
      return transform(invariant.lua[car[1]].statize, invariant,
        set_sourcemap_to(invariant, data, data:cdr()), output)
    end
    data, expanded = reader.expand(invariant, data)
    if expanded then
      return statize(invariant, data, output, last)
    end
  end
  if lua.lua_ast[getmetatable(data)] then
    if utils.hasmetatable(data, lua.lua_functioncall) or
        utils.hasmetatable(data, lua.lua_block) then
      return statize_lua(invariant, data, output)
    else
      return to_stat(data)
    end
  end
  if type(data) == "number" then
    return to_stat(data)
  elseif utils.hasmetatable(data, lua.lua_comment)
      or utils.hasmetatable(data, lua.lua_long_comment) then
    return data
  end
  if utils.hasmetatable(data, list) then
    local car = data:car()
    local cdr = vector.cast(data:cdr(), function(value)
      return expize(invariant, value, output)
    end)
    validate_functioncall(car)
    local accessor = accessor_functioncall(car, cdr)
    if accessor then
      return lua.lua_block({accessor, lua.lua_semicolon()})
    end
    return lua.lua_functioncall.new(
      expize(invariant, car),
      lua.lua_args.new(lua.lua_explist(cdr)))
  elseif data == reader.lua_none then
    return
  end
  error("cannot statize.."..tostring(data))
end

local exports

local dependencies

--- This function returns a table that stores the lua statement required
-- to import the lua object named as the key.
-- @return
local function initialize_dependencies()
  if not dependencies then
    dependencies = {
      ["compiler"] = {{'require("l2l.compiler");'}},
      ["reader"] = {{'require("l2l.reader");'}},
      ["list"] = {{'require("l2l.list");', nil}},
      ["vector"] = {{'require("l2l.vector");', nil}},
      ["ipairs"] = {{'require("l2l.iterator");', nil}},
      ["trace"] = {{'require("l2l.trace");', nil}},
      ["len"] = {{'require("l2l.len");', nil}},
      [symbol("%"):mangle()] = {
        "import", {'import("l2l.lib.operators");', "operators"}},
      [symbol(".."):mangle()] = {
        "import", {'import("l2l.lib.operators");', "operators"}},
      [symbol("-"):mangle()] = {
        "import", {'import("l2l.lib.operators");', "operators"}},
      [symbol("+"):mangle()] = {
        "import", {'import("l2l.lib.operators");', "operators"}},
      [symbol("*"):mangle()] = {
        "import", {'import("l2l.lib.operators");', "operators"}},
      [symbol("/"):mangle()] = {
        "import", {'import("l2l.lib.operators");', "operators"}},
      [symbol("<"):mangle()] = {
        "import", {'import("l2l.lib.operators");', "operators"}},
      [symbol("<="):mangle()] = {
        "import", {'import("l2l.lib.operators");', "operators"}},
      [symbol(">"):mangle()] = {
        "import", {'import("l2l.lib.operators");', "operators"}},
      [symbol(">="):mangle()] = {
        "import", {'import("l2l.lib.operators");', "operators"}},
      [symbol("=="):mangle()] = {
        "import", {'import("l2l.lib.operators");', "operators"}},
      [symbol("and"):mangle()] = {
        "import", {'import("l2l.lib.operators");', "operators"}},
      [symbol("or"):mangle()] = {
        "import", {'import("l2l.lib.operators");', "operators"}},
      [symbol("not"):mangle()] = {
        "import", {'import("l2l.lib.operators");', "operators"}},
      ["apply"] = {"import", {'import("l2l.lib.apply");', "apply"}},
      ["unpack"] = {{"table.unpack or unpack;", nil}}
    }
    for name, _ in pairs(lua) do
      dependencies[name] = {{'require("l2l.lua");', "lua"}}
    end

    for name, _ in pairs(reader) do
      dependencies[name] = {{'require("l2l.reader");', "reader"}}
    end

    for name, _ in pairs(exports) do
      dependencies[name] = {{'require("l2l.compiler");', "compiler"}}
    end
  end
  return dependencies
end


--- Given a list of Lua names generate a list of lua statement that imports
-- the referenced Lua object from l2l modules.
-- @param references
-- @param mod
-- @return
local function header(references, mod)
  local deps = initialize_dependencies()
  local names = {}
  for name, dep in pairs(deps) do
    if references[name] then
      for _, v in ipairs(dep) do
        if type(v) == "string" then
          table.insert(names, v)
        end
      end
      table.insert(names, name)
    end
  end

  local output = {}
  local outputed = {}

  for _, name in ipairs(names) do
    for _, dep in ipairs(deps[name]) do
      if type(dep) == "table" then
        local m, label = dep[1], dep[2]
        if not mod or not string.match(m, mod) then
          if m then
            local r = string.format("local %s = %s", label or name, m)
            if not outputed[r] then
              outputed[r] = true
              table.insert(output, r)
            end
          end
          if label then
            local l = label.."."..name
            local r = string.format("local %s = %s", name, l)
            if not outputed[r] then
              outputed[r] = true
              table.insert(output, r)
            end
          end
        end
      end
    end
  end
  return table.concat(output, "\n")
end


--- Analyse a Lua expression and store all Lua name prefixes into the
-- `references` table.
-- @param references
-- @return value
local function analyse_chunk(references, value)
  for match in lua.Chunk:gmatch(value, lua.Var) do
    if utils.hasmetatable(match, lua.lua_dot) then
      references[tostring(match.prefix)] = match.prefix
    elseif utils.hasmetatable(match, lua.lua_index) then
      references[tostring(match.prefix)] = match.prefix
    else
      references[tostring(match)] = match
    end
  end
end

local compile_or_cached

local build_cache = {}

local function build(mod, extends, verbose)
  local prefix = string.gsub(mod, "[.]", "/")
  local path = prefix..".lisp"
  if build_cache[path] then
    return unpack(build_cache[path])
  end
  local file = io.open(path)
  if not file then
    return
  end
  local source = file:read("*a")
  file:close()
  local out = compile_or_cached(source, mod, extends, prefix..".lua", verbose)
  local f, err = loadstring(out)
  if f then
    build_cache[path] = {f, out}
    return f, out
  else
    -- print(out)
    error(err)
  end
end


--- Import an l2l module named `mod`, making sure it's compiled to Lua.
-- @param mod
-- @param extends
-- @param verbose
-- @return
local function import(mod, extends, verbose)
  local f, out = build(mod, extends, verbose)
  local path = mod:gsub("[.]", "/")
  local ok, m
  if f then
    ok, m = pcall(f, mod, path)
    if not m then
      print("missing module", mod, path)
    end
    if not ok then
      -- print(out)
      error(m)
    end
  else
    m = require(mod)
  end
  local s = {}
  for k, v in pairs(m) do
    if utils.hasmetatable(k, symbol) then
      s[k:mangle()] = v
    end
  end
  for k, v in pairs(s) do
    m[k] = v
  end
  return m
end


--- Compile l2l string code into Lua.
-- @param source
-- @param mod
-- @param verbose
-- @param extensions
-- @return
local function compile(source, mod, verbose, extensions)
  local invariant = source

  if type(source) == "string" then
    invariant = reader.environ(source, verbose)
  end

  invariant.mod = mod

  if verbose ~= nil then
    invariant.debug = verbose
  end

  source = invariant.source

  if not extensions then
    if mod and string.match(mod, "^l2l[.]lib") then
      extensions = {}
    else
      extensions = {
        "fn",
        "quasiquote",
        "quote",
        "operators",
        "local",
        "cond",
        "if",
        "do",
        "set",
        "seti",
        "let",
        "boolean"
      }
    end
  end

  for _, e in ipairs(extensions) do
    reader.load_extension(invariant,
      reader.import_extension(invariant, e, false))
  end

  local output = {}
  local ending
  local length = #source
  for rest, values in reader.read, invariant do
    for _, value in ipairs(values) do
      table.insert(output, statize(invariant, value, output, rest > length))
    end
    ending = rest
  end

  if ending < length then
    error("syntax error in module `"..tostring(mod).."`:\n"
      ..source:sub(ending, ending + 100))
  end

  local references = {}
  for i, value in ipairs(output) do
    output[i] = tostring(value)
    analyse_chunk(references, output[i])
  end

  output = table.concat(output, "\n")

  local _references = {}
  analyse_chunk(_references, "return unpack")
  if verbose then
    return header(_references, mod)..("\n"..[[
local pack = table.pack or function(...) return {n=select("#", ...), ...} end
local returns = pack(xpcall(function(...)
%s
%s
end, require("l2l.compiler").error_handler, ...))
local ok = returns[1]
if not ok then
  error(returns[2], 2)
end
return unpack(returns, 2, returns.n)]]):format(header(references, mod), output)
  end
  return header(references, mod).."\n"..output
end


local function error_handler(e)
  local level = 2
  local message = {
    "ERROR: ".. e:gsub("^.*:[0-9]: ", ""),
    "stack traceback:"}
  while true do
    local info = debug.getinfo(level, "Slnf")
    if not info then break end
    if info.what == "C" then
      table.insert(message,
        "\t"..info.short_src..": in "..
          (info.name and "function '"..tostring(info.name).."'" or "?"))
    else   -- a Lua function
      local src = exception.source(info.source)
      local from, to = exception.atlineno(src, info.currentline)
      local line = src:sub(from, to)
      local rest = src:sub(to+3)
      local comment_from, comment_to = lua.Comment:find(rest, lua.Comment)
      if comment_from and comment_from == 1 and
        rest:sub(comment_from, comment_to):sub(6, -4):match("^%% Module") then
        local comment = rest:sub(comment_from, comment_to):sub(6, -4)
        table.insert(message, "\t"..info.short_src..":"..info.currentline)
        table.insert(message, "<=")
        table.insert(message, "\t"..comment:gsub("[\n]", "\n\t"))
      else
        table.insert(message,
          "\t"..info.short_src..":"..info.currentline..": "..
            (info.name and "function '"..
              tostring(info.name).."'" or "in main chunk")..
                ": `"..line:gsub("^%s+", "").."`")
      end
    end
    level = level + 1
  end
  return table.concat(message, "\n")
end


local function call(f, ...)
  local returns = pack(xpcall(f, error_handler, ...))
  local ok = returns[1]
  if not ok then
    error(returns[2], 2)
  end
  return unpack(returns, 2, returns.n)
end


--- Convert a purely functional lua anonymous function definition into a
-- macro definition.
-- @param invariant
-- @param f
-- @param output
-- @return
local function macroize(invariant, f, output)
  assert(utils.hasmetatable(f, lua.lua_lambda_function)
      and len(f.body.block) == 1
      and utils.hasmetatable(f.body.block[1], lua.lua_retstat),
      "only single line return lambda functions can be turned into macros")
  local exp = f.body.block[1].explist
  local names = {}
  for _, name in ipairs(f.body.namelist) do
    names[name.value] = true
  end
  -- Manual quasiquote lua_names so they get compiled.
  exp = exp:gsub(lua.lua_name, function(x)
    if names[x.value] then
      x = expize(invariant, symbol(x.value), output)
      function x.repr()
        return x
      end
      return expize(invariant, x, output)
    end
    return x
  end)
  return lua.lua_lambda_function.new(
    lua.lua_funcbody.new(
      f.body.namelist,
      lua.lua_block({
        lua.lua_retstat.new(exp:repr())
      })
    ))
end


--- Convert a function call into a macro expansion.
-- @param invariant
-- @param f
-- @param output
-- @param ...
-- @return
local function lua_inline_functioncall(invariant, f, output, ...)
  f = expize(invariant, f, output)
  if utils.hasmetatable(f, lua.lua_lambda_function)
      and len(f.body.block) == 1
      and utils.hasmetatable(f.body.block[1], lua.lua_retstat) then
    local src = "return "..tostring(macroize(invariant, f, output))
    local references = {}
    analyse_chunk(references, src)
    local g = loadstring(header(references, nil).."\n"..src)
    if g then
      local ok, h = pcall(g)
      local value
      if ok and h then
        ok, value = pcall(h, ...)
        if ok and value then
          return value
        end
      end
    end
  end
  return lua.lua_functioncall.new(
    lua.lua_paren_exp.new(f),
    lua.lua_args.new(lua.lua_explist{...}))
end


--- Load l2l string code into a function.
-- @param source
-- @return
local function _loadstring(source)
  return loadstring(compile(source))
end


--- Generate a hash from a string
-- @param source
-- @return
local function hash_mod(source)
  local h = #source.."@"..source
  local total = 1

  for i=1, #h do
    total = total + string.byte(h, i) * 0.1 * i
  end

  return "--"..total.."\n"
end

--- Retrieve the compiled result of `source` and if it has not been compiled
-- before, compile it and save it into the cache.
-- @param source
-- @param mod
-- @param extends
-- @param path
-- @param verbose
-- @return
compile_or_cached = function(source, mod, extends, path, verbose)
  local f = io.open(path)
  local h = hash_mod(source)
  if not f then
    local out = compile(source, mod, verbose, extends)
    local g = io.open(path, "w")
    g:write(h..out)
    g:close()
    return out
  end
  local code = f:read("*a")
  f:close()
  if code:sub(1, #h) ~= h then
    local out = compile(source, mod, verbose, extends)
    local g = io.open(path, "w")
    g:write(h..out)
    g:close()
    return out
  end
  return code:sub(#h + 1)
end

exports = {
  lua_inline_functioncall=lua_inline_functioncall,
  loadstring=_loadstring,
  build=build,
  import=import,
  compile=compile,
  mangle = reader.mangle,
  statize = statize,
  expize = expize,
  to_stat = to_stat,
  expand = reader.expand,
  destructure = destructure,
  error_handler = error_handler,
  call = call,
}

return exports
