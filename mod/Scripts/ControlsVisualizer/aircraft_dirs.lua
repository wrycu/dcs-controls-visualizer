-- Finds an aircraft's cockpit scripts folder from its unit type by reading
-- each module's entry.lua, e.g.
--   make_flyable('FA-18C_hornet', current_mod_path..'/Cockpit/Scripts/', ...)
--   local ac_name = 'JF-17' ... make_flyable(ac_name, current_mod_path .. '/Cockpit/Scripts/', ...)
-- Searches <DCS>/Mods/aircraft and <Saved Games>/Mods/aircraft (third-party).

local M = {}

local function read_file(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    return s
end

-- unit type -> scripts folder (relative to the module folder) from entry.lua
local function flyables(src)
    local out = {}
    for args in src:gmatch("make_flyable%s*(%b())") do
        local first, rest = args:match("^%(%s*([^,]+),(.*)$")
        if first then
            local unit = first:match("^['\"]([^'\"]+)['\"]%s*$")
            if not unit then -- a variable: find `local name = 'X'` / `name = "X"`
                local var = first:match("^([%w_]+)%s*$")
                if var then unit = src:match(var .. "%s*=%s*['\"]([^'\"]+)['\"]") end
            end
            local sub = rest:match("^%s*current_mod_path%s*%.%.%s*['\"]([^'\"]+)['\"]")
            if unit and sub then out[unit] = sub end
        end
    end
    return out
end
M._flyables = flyables -- for tests

local cache = nil

--- Scan once per DCS session.
-- @param roots list of "<...>/Mods/aircraft/" folders
-- @param dir_iter function(path) -> iterator of entry names (lfs.dir)
function M.scan(roots, dir_iter)
    cache = {}
    for _, root in ipairs(roots) do
        local ok, iter, state = pcall(dir_iter, root)
        if ok and iter then
            for name in iter, state do
                if name ~= "." and name ~= ".." then
                    local module = root .. name
                    local src = read_file(module .. "/entry.lua")
                    if src then
                        for unit, sub in pairs(flyables(src)) do
                            local dir = module .. sub
                            if not dir:match("[/\\]$") then dir = dir .. "/" end
                            if not cache[unit] and read_file(dir .. "clickabledata.lua") then
                                cache[unit] = dir
                            end
                        end
                    end
                end
            end
        end
    end
    return cache
end

--- Cockpit scripts folder for a unit type, or nil.
function M.find(unit_type)
    return cache and cache[unit_type]
end

return M
