-- Switch position names from input bindings (clickables.apply_bindings).
-- Usage: luajit tests/test_switch_positions.lua "<DCS install dir>/" [list]
-- Loads the F/A-18C clickables and keyboard bindings, checks switches whose
-- hints list positions in the wrong order, and with "list" prints every
-- switch whose labels the bindings change.
package.path = "mod/Scripts/ControlsVisualizer/?.lua;" .. package.path
local clickables = require("clickables")

local install = assert(arg[1], "pass the DCS install dir (with trailing slash)")
local aircraft = install .. "Mods/aircraft/FA-18C/"

-- Load an input profile file the way DCS does (only what it needs here).
local function load_bindings(path, folder)
    local env = setmetatable({}, { __index = _G })
    env.folder = folder
    env._ = function(s) return s end
    env.external_profile = function() return { keyCommands = {}, axisCommands = {} } end
    env.defaultDeviceAssignmentFor = function() return nil end
    env.join = function(a, b) for _, v in ipairs(b) do a[#a + 1] = v end; return a end
    env.dofile = function(p) local f = assert(loadfile(p)); setfenv(f, env); return f() end
    local f = assert(loadfile(path))
    setfenv(f, env)
    return f().keyCommands
end

local commands = load_bindings(aircraft .. "Input/FA-18C/keyboard/default.lua", aircraft .. "Input/FA-18C/keyboard/")
local args = assert(clickables.load(aircraft .. "Cockpit/Scripts"))

local before = {}
for a, info in pairs(args) do
    if not info.is_button then
        before[a] = {}
        for k = 0, 20 do
            local v = info.lim[1] + (info.lim[2] - info.lim[1]) * k / 20
            before[a][k] = clickables.describe(info, v)
        end
    end
end
local n = clickables.apply_bindings(args, commands)
print(string.format("%d commands, %d switches named from bindings", #commands, n))

local failures = 0
local function check(what, got, want)
    local ok = got == want
    if not ok then failures = failures + 1 end
    print(string.format("%s %-34s %s", ok and "ok  " or "FAIL", what, tostring(got) .. (ok and "" or ("  (want " .. tostring(want) .. ")"))))
end
local function at(a, v) return clickables.describe(args[a], v) end

check("ECM 0.0", at(248, 0.0), "ECM Mode Switch: OFF")
check("ECM 0.1", at(248, 0.1), "ECM Mode Switch: STBY")
check("ECM 0.4", at(248, 0.4), "ECM Mode Switch: XMIT")
check("DISPENSER 0.0", at(517, 0.0), "DISPENSER Switch: OFF")
check("DISPENSER 0.2", at(517, 0.2), "DISPENSER Switch: BYPASS")
check("Hook 0", at(293, 0), "Arresting Hook Handle: DOWN")
check("Hook 1", at(293, 1), "Arresting Hook Handle: UP")
check("Master Arm 1", at(49, 1), "Master Arm Switch: ARM")
check("Master Arm 0", at(49, 0), "Master Arm Switch: SAFE")
check("RADAR 0 (hint order was right)", at(440, 0), "RADAR Switch: OFF")
check("Battery -1", at(404, -1), "Battery Switch: ORIDE")
check("External Power 0 (hint name kept)", at(336, 0), "External Power Switch: NORM")
-- the overrides, as cockpit_watch applies them
local o = require("overrides")["FA-18C_hornet"]
for a, ov in pairs(o) do if ov.positions ~= nil then args[a].values = nil; args[a].positions = ov.positions or nil end end
check("IFF Mode 4 -1 (override)", at(355, -1), "IFF Mode 4 Switch: OFF")
check("IFF Mode 4 1 (override)", at(355, 1), "IFF Mode 4 Switch: DIS/AUD")
check("HMD/LDDI/RDDI -1 (override)", at(175, -1), "Selector Switch: RDDI")
check("HMD/LDDI/RDDI 1 (override)", at(175, 1), "Selector Switch: HMD")
check("HUD/LDIR/RDDI 1 (override)", at(176, 1), "Selector Switch: HUD")
check("Gear 1 (override)", at(226, 1), "Landing Gear Control Handle: UP")

if arg[2] == "list" then
    print("\nswitches whose labels changed:")
    local list = {}
    for a in pairs(before) do list[#list + 1] = a end
    table.sort(list)
    for _, a in ipairs(list) do
        local info = args[a]
        local changed = false
        for k = 0, 20 do
            local v = info.lim[1] + (info.lim[2] - info.lim[1]) * k / 20
            if clickables.describe(info, v) ~= before[a][k] then changed = true end
        end
        if changed and info.values then
            local parts = {}
            for _, e in ipairs(info.values) do parts[#parts + 1] = string.format("%g=%s", e.value, e.label) end
            print(string.format("  %4d %-40s %s", a, info.name, table.concat(parts, " ")))
        end
    end
end

if failures > 0 then print(failures .. " FAILED"); os.exit(1) end
print("all ok")
