-- Unit tests for feed.lua, using event sequences seen in dcs.log.
-- Usage: luajit tests/test_feed.lua
package.path = "mod/Scripts/ControlsVisualizer/?.lua;" .. package.path
local feed = require("feed")

local failures = 0
local function lines_at(t)
    local out = {}
    for _, l in ipairs(feed.visible(t)) do out[#out + 1] = (l.held and "*" or "") .. l.text end
    return table.concat(out, " | ")
end
local function check(name, got, want)
    if got == want then
        print("ok   " .. name)
    else
        failures = failures + 1
        print("FAIL " .. name .. "\n     got:  " .. got .. "\n     want: " .. want)
    end
end

-- Trigger: held entry while down, normal after release
feed.reset()
feed.input_down("c:1", "Gun Trigger", "Gun Trigger - SECOND DETENT", 0.0)
check("trigger held", lines_at(0.2), "*Gun Trigger - SECOND DETENT")
feed.input_up("c:1", 0.7)
check("trigger released", lines_at(0.8), "Gun Trigger - SECOND DETENT")
check("expires", lines_at(0.7 + feed.config.display_s + 0.1), "")

-- Held hat: DCS re-sends down/up every ~0.5 s (Radar Elevation, 06:03:54-56)
feed.reset()
local t = 0
feed.input_down("c:7", "Radar Elevation Control", "Radar Elevation Control - Down", t)
for _ = 1, 4 do
    t = t + 0.5
    feed.input_up("c:7", t)
    feed.input_down("c:7", "Radar Elevation Control", "Radar Elevation Control - Down", t)
end
feed.input_up("c:7", t + 0.4)
check("held hat is one entry", lines_at(t + 0.5), "Radar Elevation Control - Down")

-- Repeated taps count up
feed.reset()
for i = 0, 2 do
    feed.input_down("c:3", "Weapon Release Button", "Weapon Release Button", i * 0.6)
    feed.input_up("c:3", i * 0.6 + 0.2)
    feed.cockpit("Weapon Release Button", "Weapon Release Button", i * 0.6 + 0.25)
end
check("weapon release x3", lines_at(1.6), "Weapon Release Button  x3")

-- Input + cockpit for the same switch merge into the position (lights, 06:04:01)
feed.reset()
feed.input_down("c:9", "Exterior Lights Switch", "Exterior Lights Switch - ON/OFF", 0.0)
feed.input_up("c:9", 0.1)
feed.cockpit("Exterior Lights Switch", "Exterior Lights Switch: ON", 0.12)
feed.input_down("c:9", "Exterior Lights Switch", "Exterior Lights Switch - ON/OFF", 1.0)
feed.input_up("c:9", 1.1)
feed.cockpit("Exterior Lights Switch", "Exterior Lights Switch: OFF", 1.13)
check("lights on then off", lines_at(1.2), "Exterior Lights Switch: ON | Exterior Lights Switch: OFF")

-- Plain command + interlock bounce: only the first position is kept (gear on ground)
feed.reset()
feed.input_tap("p:68", "Landing Gear Control Handle", "Landing Gear Control Handle - UP/DOWN", 0.0)
feed.cockpit("Landing Gear Control Handle", "Landing Gear Control Handle: UP", 0.08)
feed.cockpit("Landing Gear Control Handle", "Landing Gear Control Handle: DOWN", 0.18)
check("gear bounce", lines_at(0.3), "Landing Gear Control Handle: UP")

-- Mouse clicks (cockpit only); same switch toggled stays separate
feed.reset()
feed.cockpit("Master Arm Switch", "Master Arm Switch: ARM", 0.0)
feed.cockpit("Master Arm Switch", "Master Arm Switch: SAFE", 0.6)
feed.cockpit("Master Mode Button", "Master Mode Button, A/A", 1.2)
feed.cockpit("Master Mode Button", "Master Mode Button, A/A", 1.8)
check("mouse clicks", lines_at(2.0), "Master Arm Switch: ARM | Master Arm Switch: SAFE | Master Mode Button, A/A  x2")

-- Spring-loaded switch from input: release spring-back isn't a new line
feed.reset()
feed.input_down("c:5", "Speed Brake Switch", "Speed Brake Switch - EXTEND", 0.0)
feed.cockpit("Speed Brake Switch", "Speed Brake Switch: EXTEND", 0.15)
feed.input_up("c:5", 1.0)
feed.cockpit("Speed Brake Switch", "Speed Brake Switch: OFF", 1.15)
check("spring back", lines_at(1.2), "Speed Brake Switch: EXTEND")

-- Axes (no_count): moving again soon after reuses the line, without "x2"
feed.reset()
feed.input_down("a:TDC", "TDC", "TDC", 0.0, true)
feed.input_up("a:TDC", 0.5)
feed.input_down("a:TDC", "TDC", "TDC", 1.0, true)
check("axis no counter", lines_at(1.1), "*TDC")

-- A bare cockpit name doesn't replace a more specific binding name (JF-17)
feed.reset()
feed.input_tap("p:1", "Master Arm Switch", "Master Arm Switch - ON", 0.0)
feed.cockpit("Master Arm Switch", "Master Arm Switch", 0.1)
check("bare name keeps binding text", lines_at(0.2), "Master Arm Switch - ON")

-- Oldest lines drop off past max_entries
feed.reset()
for i = 1, feed.config.max_entries + 2 do feed.cockpit("S" .. i, "Switch " .. i, i * 0.01) end
local n = select(2, lines_at(0.2):gsub("Switch", ""))
check("max entries", tostring(n), tostring(feed.config.max_entries))

os.exit(failures == 0 and 0 or 1)
