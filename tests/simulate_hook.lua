-- Runs the hook outside DCS with stubbed DCS APIs and scripted cockpit values.
-- Usage: luajit tests/simulate_hook.lua "<DCS install dir>/"
local install = assert(arg[1], "pass the DCS install dir (with trailing slash)")

local values = {}      -- arg -> current value
local shown = {}
local handler

lfs = {
    writedir = function() return "mod/" end,
    currentdir = function() return install end,
}
log = { INFO = "INFO", ERROR = "ERROR", write = function(_, lvl, msg)
    if lvl == "ERROR" then print("LOG ERROR: " .. msg) end
end }
net = { dostring_in = function(_, code)
    shown[#shown + 1] = code:match('outText%((".-")') and loadstring("return " .. code:match('outText%((".-")'))()
end }
DCS = {
    getPlayerUnitType = function() return "FA-18C_hornet" end,
    setUserCallbacks = function(h) handler = h end,
}
local forwarded = {}
Export = { GetDevice = function(id)
    return { get_argument_value = function(_, a) return values[a] or 0 end,
             performClickableAction = function(_, cmd, v)
                 forwarded[#forwarded + 1] = string.format("device %s cmd %s value %s", tostring(id), tostring(cmd), tostring(v))
             end }
end }

local pending_actions = {}
package.loaded["Input"] = {
    getInputActions = function() local a = pending_actions; pending_actions = {}; return a end,
    getLayerStack = function() return { "FA-18C_hornet", "UiLayer" } end,
    getLoadedLayers = function() return { "FA-18C_hornet" } end,
    getDevices = function() return { "Keyboard", "Throttle - HOTAS Warthog {GUID}" } end,
    getDeviceId = function(name) return #name end,
    createLayer = function(n) print("[stub] createLayer " .. n) end,
    deleteLayer = function() end,
    addKeyCombo = function() end,
    addReformer = function() end,
    getUiLayerName = function() return "uiInputLayer" end,
    getIgnoreUiLayer = function() return false end,
    setTopLayer = function(n) print("[stub] setTopLayer " .. n) end,
    setLayerStack = function(s) print("[stub] setLayerStack {" .. table.concat(s, ", ") .. "}") end,
}
package.preload["Input.Utils"] = function()
    return { getDeviceNameById = function(id) return "device#" .. id end,
             getDeviceEventName = function(e) return "JOY_BTN" .. e end,
             getInputActionName = function(a) return "iCommand#" .. a end,
             getDeviceKeysNoModifiers = function() return { { event = 1 }, { event = 2 } } end,
             getDeviceEventsToSkip = function() return {} end,
             getInputEvent = function(k) return tonumber(k:match("%d+$")) end }
end
package.preload["Input.Data"] = function()
    return {
        getProfileNameByUnitName = function(u) return "F/A-18C" end,
        getProfileModifiers = function() return {} end,
        getProfileKeyCommands = function() return {
            { name = "Landing Gear Control Handle - UP/DOWN", down = 68, combos = { Keyboard = { { key = "G", valid = true } } } },
            { name = "Gun Trigger - SECOND DETENT (Press to shoot)", down = 3002, up = 3002, cockpit_device_id = 13,
              value_down = 1, value_up = 0, combos = { ["Throttle - HOTAS Warthog {GUID}"] = { { key = "JOY_BTN2", valid = true } } } },
        } end,
    }
end
package.preload["Input.Loader"] = function()
    return { loadUiLayer = function(p) print("[stub] loadUiLayer " .. p) end }
end
local probe_lines = {}
local real_write = log.write
log.write = function(src, lvl, msg)
    if msg:find("^probe") then probe_lines[#probe_lines + 1] = msg end
    real_write(src, lvl, msg)
end

dofile("mod/Scripts/Hooks/ControlsVisualizer.lua")
handler.onSimulationStart()

-- One "poll" = 2 frames (poll_every_n_frames).
local function polls(n) for _ = 1, n * 2 do handler.onSimulationFrame() end end

local function scenario(name, arg_n, seq)
    shown = {}
    for _, v in ipairs(seq) do values[arg_n] = v; polls(1) end
    polls(4)
    print(string.format("%-34s -> %s", name, #shown > 0 and table.concat(shown, " | ") or "(nothing)"))
end

polls(1) -- baseline
scenario("tap (from dcs.log)", 475, { 0.34, 1, 0.66, 0 })
scenario("hold then release", 475, { 0.34, 1, 1, 1, 1, 1, 0.66, 0 })
scenario("trigger 2nd detent tap", 479, { 0.5, 1, 0.5, 0 })
scenario("trigger 1st detent hold", 479, { 0.25, 0.5, 0.5, 0.5, 0.5, 0.25, 0 })
scenario("sensor ctrl aft (0.4) tap", 476, { 0.1, 0.2, 0.3, 0.4, 0.2, 0 })
scenario("master arm -> SAFE (1)", 49, { 0.5, 1, 1 })
scenario("master arm -> ARM (0)", 49, { 0.5, 0, 0 })
scenario("radar knob OFF -> STBY", 440, { 0.05, 0.1, 0.1 })
scenario("speed brake EXTEND (spring back)", 489, { -0.5, -1, -1, -1, -0.5, 0, 0 })

-- input probe: a sim command and an axis action
pending_actions = { { action = 3002, deviceId = 5, hasValue = false },
                    { action = 200001, deviceId = 31, hasValue = false },
                    { action = -200001, deviceId = 31, hasValue = false },
                    { action = 68, deviceId = 31, hasValue = false },
                    { action = 2001, deviceId = 5, hasValue = true, value = 0.3 } }
polls(1)
handler.onSimulationStop()
print("-- probe log:")
for _, l in ipairs(probe_lines) do print("   " .. l) end
print("-- forwarded:")
for _, l in ipairs(forwarded) do print("   " .. l) end
