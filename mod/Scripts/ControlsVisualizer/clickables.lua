-- Loads an aircraft's Cockpit/Scripts/clickabledata.lua in a sandbox and
-- returns a table mapping cockpit argument number -> control info.
--
-- Also reads elements that are commented out (`--elements[...] = ...`): many
-- modules (e.g. the F/A-18C HOTAS) leave non-clickable controls commented out,
-- but they still animate their cockpit argument.
--
-- Works both inside DCS (hooks environment) and in standalone Lua 5.1/LuaJIT
-- for testing. Pure Lua 5.1, no DCS APIs required.

local M = {}

-- A "proxy" stands in for any DCS global the cockpit scripts reference that we
-- don't provide (class_type.TUMB, devices.X, sounds, get_option_value(...)).
-- It can be indexed, called, compared and used in arithmetic without erroring,
-- and tostring() gives its path, e.g. "class_type.BTN".
local proxy_mt = {}
local function new_proxy(name)
    return setmetatable({ __proxy_name = name }, proxy_mt)
end
proxy_mt.__index = function(t, k)
    local p = new_proxy(tostring(rawget(t, "__proxy_name")) .. "." .. tostring(k))
    rawset(t, k, p)
    return p
end
proxy_mt.__call = function(t) return new_proxy(rawget(t, "__proxy_name") .. "()") end
local function arith() return 0 end
proxy_mt.__add, proxy_mt.__sub, proxy_mt.__mul = arith, arith, arith
proxy_mt.__div, proxy_mt.__unm, proxy_mt.__mod, proxy_mt.__pow = arith, arith, arith, arith
proxy_mt.__concat = function(a, b) return tostring(a) .. tostring(b) end
proxy_mt.__tostring = function(t) return rawget(t, "__proxy_name") end

local function read_file(path)
    local f, err = io.open(path, "rb")
    if not f then return nil, err end
    local src = f:read("*a")
    f:close()
    return src
end

local function make_env(script_path)
    local env = {}
    setmetatable(env, {
        __index = function(t, k)
            local v = _G[k]
            if v ~= nil then return v end
            local p = new_proxy(k)
            rawset(t, k, p)
            return p
        end,
    })

    env.LockOn_Options = new_proxy("LockOn_Options")
    rawset(env.LockOn_Options, "script_path", script_path)
    env.get_option_value = function() return false end
    env._ = function(s) return s end

    env.require = function(name)
        if name == "i_18n" then
            return { translate = function(s) return s end }
        end
        local ok, mod = pcall(require, name)
        if ok then return mod end
        return new_proxy("require(" .. name .. ")")
    end

    env.dofile = function(path)
        local src = read_file(path)
        if not src then return end -- missing helper scripts are not fatal
        local chunk = loadstring(src, "@" .. path)
        if not chunk then return end
        setfenv(chunk, env)
        local ok, err = pcall(chunk)
        if not ok then
            M.last_warning = "error in " .. path .. ": " .. tostring(err)
        end
    end

    return env
end

local function trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end

-- Strip mouse-interaction markers like "(RMB)", "(LMB)", "(MW)" from hints,
-- e.g. "(RMB)CW/(LMB)CCW/ (MW)PULL/STOW" -> "CW/CCW/PULL/STOW".
local function clean_hint(hint)
    hint = tostring(hint)
    hint = hint:gsub("%s*%(%u?MB%)%s*", ""):gsub("%s*%(MW%)%s*", "")
    hint = hint:gsub("%s*/%s*", "/")
    -- usage instructions: "(Press to shoot)", "(MW to pull)", "(hold RMB ...)"
    hint = hint:gsub("%s*%(([^()]*)%)", function(s)
        if s:match("^Press") or s:match("^MW ") or s:match("^[Hh]old ") then return "" end
    end)
    -- unbalanced trailing ')' (typo in some hints)
    local _, opens = hint:gsub("%(", "")
    local _, closes = hint:gsub("%)", "")
    if closes > opens then hint = hint:gsub("%)%s*$", "") end
    return trim(hint)
end
M.clean_hint = clean_hint

-- "Battery Switch, ON/OFF/ORIDE" -> "Battery Switch", {"ON","OFF","ORIDE"}
local function split_positions(hint)
    local name, positions = hint:match("^(.-),%s*([^,]+)$")
    if not name or not positions:find("/") then return hint, nil end
    local list = {}
    for p in positions:gmatch("[^/]+") do list[#list + 1] = trim(p) end
    return name, list
end

local function is_button_class(el, i)
    local cls = type(el.class) == "table" and el.class[i] or el.class
    return tostring(cls):find("BTN") ~= nil
end

-- Add one element (active or commented out) to the args table.
local function add_element(args, element_name, el, commented)
    if type(el) ~= "table" or type(el.hint) ~= "string" then return false end
    local hint = clean_hint(el.hint)
    local arg_list = el.arg
    if type(arg_list) == "number" then arg_list = { arg_list } end
    if type(arg_list) ~= "table" then return false end

    -- An element can drive the same arg from several parts (e.g. External
    -- Power: a -1..0 switch part and a 0..1 button part). Combine them per arg.
    local per_arg, order = {}, {}
    for i, a in ipairs(arg_list) do
        if type(a) == "number" then
            local p = per_arg[a]
            if not p then
                p = { all_buttons = true, step = 0 }
                per_arg[a] = p
                order[#order + 1] = a
            end
            local is_button = is_button_class(el, i)
            p.all_buttons = p.all_buttons and is_button
            local value = type(el.arg_value) == "table" and tonumber(el.arg_value[i]) or nil
            if value then
                p.step = math.max(p.step, math.abs(value))
                if is_button then p.button_values = p.button_values or {}; table.insert(p.button_values, value) end
            end
            local lim = type(el.arg_lim) == "table" and el.arg_lim[i]
            if type(lim) == "table" and type(lim[1]) == "number" and type(lim[2]) == "number" then
                local lo, hi = math.min(lim[1], lim[2]), math.max(lim[1], lim[2])
                p.lo = p.lo and math.min(p.lo, lo) or lo
                p.hi = p.hi and math.max(p.hi, hi) or hi
            end
        end
    end

    for _, a in ipairs(order) do
        local p = per_arg[a]
        local is_button = p.all_buttons
        local info = args[a]
        if not info or (info.commented and not commented) then
            local name, positions = hint, nil
            local lo, hi = p.lo or 0, p.hi or 1
            if not is_button then
                name, positions = split_positions(hint)
                -- More labels than the switch has positions means some labels
                -- are combined ("ECS Mode Switch, AUTO/MAN/ OFF/RAM"): merge
                -- the extras into the last position.
                if positions and p.step > 0 then
                    local count = math.floor((hi - lo) / p.step + 0.5) + 1
                    if count >= 2 and #positions > count then
                        local merged = {}
                        for k = 1, count - 1 do merged[k] = positions[k] end
                        local rest = {}
                        for k = count, #positions do rest[#rest + 1] = positions[k] end
                        merged[count] = table.concat(rest, "/")
                        positions = merged
                    end
                end
            end
            info = {
                name = name,
                hint = hint,
                element = element_name,
                is_button = is_button,
                positions = positions,
                lim = { lo, hi },
                commented = commented,
                variants = info and info.variants or {},
            }
            args[a] = info
        end
        -- Every button pressing toward a specific value is a variant, so
        -- shared args (4-way hats: 0.1/0.2/0.3/0.4) can be told apart.
        if is_button and p.button_values then
            for _, v in ipairs(p.button_values) do
                info.variants[#info.variants + 1] = { value = v, hint = hint }
            end
        end
    end
    return true
end

-- Pull `fn(...)` calls out of `--elements["x"] = fn(...)` lines. Takes the
-- rest of the line rather than matching parentheses, since hints can contain
-- stray ones (F/A-18C: `_('Gun Trigger, FIRST DETENT)')`).
local function commented_elements(src)
    local out = {}
    for line in src:gmatch("[^\r\n]+") do
        local key, call = line:match("^%s*%-%-%s*elements%s*%[%s*[\"']([^\"']+)[\"']%s*%]%s*=%s*([%w_]+%s*%(.*)$")
        if key then
            call = call:gsub("%)[^)]*$", ")") -- drop anything after the last ')'
            out[#out + 1] = { key = key, call = call }
        end
    end
    return out
end

--- Load clickables for one aircraft.
-- @param scripts_dir path to <DCS>/Mods/aircraft/<X>/Cockpit/Scripts/ (trailing slash optional)
-- @return args table { [arg] = { name, hint, element, is_button, positions, lim, variants } },
--         element count (active + commented)
function M.load(scripts_dir)
    if not scripts_dir:match("[/\\]$") then scripts_dir = scripts_dir .. "/" end
    local path = scripts_dir .. "clickabledata.lua"
    local src, err = read_file(path)
    if not src then return nil, "cannot read " .. path .. ": " .. tostring(err) end

    local chunk, cerr = loadstring(src, "@" .. path)
    if not chunk then return nil, cerr end

    local env = make_env(scripts_dir)
    setfenv(chunk, env)
    local ok, rerr = pcall(chunk)
    if not ok then M.last_warning = tostring(rerr) end
    local elements = rawget(env, "elements")
    if type(elements) ~= "table" or getmetatable(elements) == proxy_mt then
        return nil, "no elements table (" .. tostring(rerr) .. ")"
    end

    local args, count = {}, 0
    for element_name, el in pairs(elements) do
        if add_element(args, element_name, el, false) then count = count + 1 end
    end

    -- Commented-out elements, evaluated with the module's own helper functions.
    for _, c in ipairs(commented_elements(src)) do
        local fn = loadstring("return " .. c.call, "=" .. c.key)
        if fn then
            setfenv(fn, env)
            local fok, el = pcall(fn)
            if fok and add_element(args, c.key, el, true) then count = count + 1 end
        end
    end

    return args, count
end

--- Display text for an arg that moved to `value` (a button's peak value, or
--- a switch's new resting value).
function M.describe(info, value)
    if info.is_button then
        if #info.variants > 1 then
            local best, best_d = nil, math.huge
            for _, v in ipairs(info.variants) do
                local d = math.abs(v.value - value)
                if d < best_d then best, best_d = v, d end
            end
            return best.hint
        end
        return info.hint
    end
    local p = info.positions
    if p and #p > 1 then
        -- Hints list positions from the lowest arg value to the highest
        -- ("Battery Switch, ON/OFF/ORIDE": ON = -1, ORIDE = 1; "RADAR Switch,
        -- OFF/STBY/OPR/EMERG": OFF = 0, STBY = 0.1). Verified against all of
        -- DCS-BIOS's F/A-18C position lists (tests/check_dcsbios_positions.lua).
        local lo, hi = info.lim[1], info.lim[2]
        if hi < lo then lo, hi = hi, lo end
        if hi > lo then
            local frac = (value - lo) / (hi - lo)
            local idx = math.floor(frac * (#p - 1) + 0.5) + 1
            if idx >= 1 and idx <= #p then return info.name .. ": " .. p[idx] end
        end
    end
    return info.name
end

return M
