-- Checks cockpit folder discovery against a real DCS install.
-- Usage: luajit tests/test_aircraft_dirs.lua "<DCS install dir>/"
package.path = "mod/Scripts/ControlsVisualizer/?.lua;" .. package.path
local aircraft_dirs = require("aircraft_dirs")
local install = assert(arg[1], "pass the DCS install dir (with trailing slash)")
local function dir_iter(path)
    local p = io.popen('ls -1 "' .. path .. '" 2>/dev/null')
    local names = {}
    for l in p:lines() do names[#names + 1] = l end
    p:close()
    local i = 0
    return function() i = i + 1; return names[i] end
end
local found = aircraft_dirs.scan({ install .. "Mods/aircraft/" }, dir_iter)
local units = {}
for u in pairs(found) do units[#units + 1] = u end
table.sort(units)
for _, u in ipairs(units) do print(string.format("%-24s %s", u, found[u]:sub(#install + 1))) end
print("-- " .. #units .. " flyable aircraft with clickabledata.lua")
local ok = found["FA-18C_hornet"] and found["JF-17"]
os.exit(ok and 0 or 1)
