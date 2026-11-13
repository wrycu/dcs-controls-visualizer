-- Runs the hook outside DCS with stubbed DCS APIs: scripted cockpit values,
-- scripted input actions, and a stub dxgui overlay whose text we can read.
-- Usage: luajit tests/simulate_hook.lua "<DCS install dir>/"
local install = assert(arg[1], "pass the DCS install dir (with trailing slash)")

local values = {}          -- cockpit arg -> value
local pending_actions = {} -- returned by the next Input.getInputActions()
local forwarded = {}       -- performClickableAction calls
local stack = { "Debug", "Unit FA-18C_hornet" }
local clock = 0
local handler
local errors = {}

-- lfs.dir via ls (standalone LuaJIT has no lfs)
local function dir_iter(path)
    local p = io.popen('ls -1 "' .. path .. '" 2>/dev/null')
    local names = {}
    for l in p:lines() do names[#names + 1] = l end
    p:close()
    local i = 0
    return function() i = i + 1; return names[i] end
end
lfs = { writedir = function() return "mod/" end, currentdir = function() return install end, dir = dir_iter }
log = { INFO = "INFO", ERROR = "ERROR", write = function(_, lvl, msg)
    if lvl == "ERROR" then errors[#errors + 1] = msg; print("LOG ERROR: " .. msg) end
end }
net = { dostring_in = function() end, get_my_player_id = function() return 1 end }
DCS = {
    getPlayerUnitType = function() return "FA-18C_hornet" end,
    setUserCallbacks = function(h) handler = h end,
    getRealTime = function() return clock end,
    getInputNameByUnitType = function(u) return u end,
}
Export = { GetDevice = function(id)
    return {
        get_argument_value = function(_, a) return values[a] or 0 end,
        performClickableAction = function(_, cmd, v)
            forwarded[#forwarded + 1] = string.format("dev %s cmd %s = %s", tostring(id), tostring(cmd), tostring(v))
        end,
    }
end }

local DEVICES = { Keyboard = 1, ["VPC Stick {GUID}"] = 2, ["Throttle {GUID}"] = 3 }
package.loaded["Input"] = {
    getInputActions = function() local a = pending_actions; pending_actions = {}; return a end,
    getLayerStack = function() local c = {}; for i, v in ipairs(stack) do c[i] = v end; return c end,
    setLayerStack = function(s) stack = s end,
    setTopLayer = function(n) table.insert(stack, 1, n) end,
    createLayer = function() end,
    deleteLayer = function() end,
    addReformer = function() end,
    addKeyCombo = function() end,
    addAxisCombo = function() end,
    getDeviceId = function(name) return DEVICES[name] end,
}
package.preload["Input.Utils"] = function()
    return {
        getDeviceNameById = function(id) for n, i in pairs(DEVICES) do if i == id then return n end end end,
        getInputEvent = function(k) return k end,
    }
end
package.preload["Input.Data"] = function()
    local function key(name, k, down, extra)
        local c = { name = name, combos = { [k[1]] = { { key = k[2], valid = true } } } }
        for f, v in pairs(extra or {}) do c[f] = v end
        c.down = down
        return c
    end
    return {
        getProfileNameByUnitName = function() return "F/A-18C" end,
        getProfileModifiers = function() return {} end,
        getProfileAxisCommands = function() return {
            -- cockpit-device axes -> markers 300001.. in this order
            { name = "Throttle Designator Controller - VERTICAL AXIS", action = 3043, cockpit_device_id = 13,
              combos = { ["Throttle {GUID}"] = { { key = "JOY_Y", valid = true } } } },
            { name = "Throttle Designator Controller - HORIZONTAL AXIS", action = 3044, cockpit_device_id = 13,
              combos = { ["Throttle {GUID}"] = { { key = "JOY_X", valid = true } } } },
            -- plain axis: not intercepted, not shown
            { name = "Pitch", action = 2001, combos = { ["VPC Stick {GUID}"] = { { key = "JOY_Y", valid = true } } } },
        } end,
        getProfileKeyCommands = function() return {
            -- cockpit-device commands -> markers 200001.. in this order
            key("Gun Trigger - SECOND DETENT (Press to shoot)", { "VPC Stick {GUID}", "JOY_BTN2" }, 3002,
                { up = 3002, cockpit_device_id = 13, value_down = 1, value_up = 0 }),
            key("Sensor Control Switch - Fwd", { "Throttle {GUID}", "JOY_BTN9" }, 3020,
                { up = 3020, cockpit_device_id = 13, value_down = 1, value_up = 0 }),
            key("Exterior Lights Switch - ON/OFF", { "Keyboard", "L" }, 3256,
                { cockpit_device_id = 8, value_down = 1 }),
            -- plain commands
            key("Landing Gear Control Handle - UP/DOWN", { "Throttle {GUID}", "JOY_BTN40" }, 68),
            key("Unlock view (stop padlock)", { "Keyboard", "NumLock" }, 20),
        } end,
    }
end

-- stub dxgui
local overlay_lines = {}
local hotkeys = {}
local function widget()
    local w = { visible = true, text = "" }
    function w:setVisible(v) self.visible = v end
    function w:setText(t) self.text = t end
    function w:setSkin() end
    function w:getSkin() return {} end
    function w:setBounds() end
    function w:insertWidget(c) overlay_lines[#overlay_lines + 1] = c end
    function w:addHotKeyCallback(k, f) hotkeys[k] = f end
    return w
end
package.preload["DialogLoader"] = function()
    return { spawnDialogFromFile = function(path)
        assert(loadfile(path), "overlay.dlg must be valid Lua")
        local win = widget()
        win.Box, win.LineNormal, win.LineHeld = widget(), widget(), widget()
        return win
    end }
end
package.preload["Static"] = function() return { new = widget } end
package.preload["Skin"] = function() return { windowSkinChatMin = function() return {} end } end
package.preload["dxgui"] = function() return { GetWindowSize = function() return 1920, 1080 end } end

local function screen()
    local out = {}
    for _, s in ipairs(overlay_lines) do if s.visible and s.text ~= "" then out[#out + 1] = s.text end end
    return #out > 0 and table.concat(out, " | ") or "(nothing)"
end

dofile("mod/Scripts/Hooks/ControlsVisualizer.lua")
handler.onSimulationStart()
print("stack in flight: {" .. table.concat(stack, ", ") .. "}")

local function frames(n) for _ = 1, n do clock = clock + 0.02; handler.onSimulationFrame() end end
local function idle() frames(400) end -- 8 s: everything expires

local function scenario(name, fn)
    idle()
    forwarded = {}
    fn()
    print(string.format("%-34s -> %s", name, screen()))
    if #forwarded > 0 then print(string.rep(" ", 38) .. "forwarded: " .. table.concat(forwarded, "; ")) end
end

local function arg_seq(a, seq) for _, v in ipairs(seq) do values[a] = v; frames(2) end; frames(8) end

values[49] = 1 -- master arm starts SAFE
frames(4) -- cockpit baseline
scenario("mouse: master arm -> ARM", function() arg_seq(49, { 0.5, 0, 0 }) end)
scenario("mouse: master arm -> SAFE", function() arg_seq(49, { 0.5, 1, 1 }) end)
scenario("mouse: radar knob OFF -> STBY", function() arg_seq(440, { 0.05, 0.1, 0.1 }) end)
scenario("weapon release (anim) x3", function()
    for _ = 1, 3 do arg_seq(475, { 0.34, 1, 0.66, 0 }) end
end)
scenario("trigger 2nd detent, held", function()
    pending_actions = { { action = 200001, deviceId = 2 } }; frames(30)
end)
scenario("... then released", function()
    pending_actions = { { action = -200001, deviceId = 2 } }; frames(5)
end)
scenario("SCS fwd tapped twice", function()
    for _ = 1, 2 do
        pending_actions = { { action = 200002, deviceId = 3 } }; frames(10)
        pending_actions = { { action = -200002, deviceId = 3 } }; frames(10)
    end
end)
scenario("L key + Wine NumLock ghost", function()
    pending_actions = { { action = 200003, deviceId = 1 }, { action = 20, deviceId = 1 } }; frames(2)
    pending_actions = { { action = -200003, deviceId = 1 } }
    arg_seq(494, { 0.5, 1, 1 }) -- exterior lights arg animates
end)
scenario("gear (plain) + ground bounce", function()
    pending_actions = { { action = 68, deviceId = 3 } }
    arg_seq(226, { 0.5, 1, 1, 1, 0.5, 0, 0 })
end)
scenario("plain axis (pitch) not shown", function()
    for i = 1, 20 do pending_actions = { { action = 2001, deviceId = 2, hasValue = true, value = i / 20 } }; frames(1) end
end)
local function tdc(v, h)
    pending_actions = { { action = 300001, deviceId = 3, hasValue = true, value = v },
                        { action = 300002, deviceId = 3, hasValue = true, value = h } }
    frames(1)
end
tdc(0, 0) -- resting values at start
scenario("TDC slewing (held)", function()
    for i = 1, 10 do tdc(i / 10, 0) end
    for _ = 1, 30 do tdc(1, 0) end -- held at full deflection
end)
scenario("TDC released", function() tdc(0, 0); frames(30) end)
scenario("TDC nudged twice", function()
    for _, v in ipairs({ 0.5, 0, 0 }) do tdc(0, v); frames(30) end
    for _, v in ipairs({ 0.5, 0, 0 }) do tdc(0, v); frames(30) end
end)
scenario("hotkey hides overlay", function()
    hotkeys["Ctrl+Shift+V"]()
    pending_actions = { { action = 200001, deviceId = 2 } }; frames(5)
end)
scenario("hotkey shows it again", function()
    pending_actions = { { action = -200001, deviceId = 2 } }; frames(2)
    hotkeys["Ctrl+Shift+V"](); frames(2)
end)

handler.onSimulationStop()
print("stack after stop: {" .. table.concat(stack, ", ") .. "}")
os.exit(#errors == 0 and 0 or 1)
