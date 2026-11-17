-- Runs the hook outside DCS with stubbed DCS APIs: scripted cockpit values,
-- scripted input actions, and a stub dxgui overlay whose text we can read.
-- Usage: luajit tests/simulate_hook.lua "<DCS install dir>/"
local install = assert(arg[1], "pass the DCS install dir (with trailing slash)")

local values = {}          -- cockpit arg -> value
local pending_actions = {} -- returned by the next Input.getInputActions()
local forwarded = {}       -- performClickableAction calls
local stack = { "Debug", "Unit FA-18C_hornet" }
local clock = 0
local player_unit = nil    -- single player: no unit yet at onSimulationStart
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
    getPlayerUnitType = function() return player_unit end,
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
            -- unbound position commands: name the Master Arm positions
            -- (the hint "ARM/SAFE" lists them high to low)
            { name = "Master Arm Switch - ARM", down = 3003, cockpit_device_id = 23, value_down = 1, combos = {} },
            { name = "Master Arm Switch - SAFE", down = 3003, cockpit_device_id = 23, value_down = 0, combos = {} },
            { name = "ALQ-165 ECM Mode Switch - REC", down = 3001, cockpit_device_id = 66, value_down = 0.3, combos = {} },
            { name = "ALQ-165 ECM Mode Switch - BIT", down = 3001, cockpit_device_id = 66, value_down = 0.2, combos = {} },
            { name = "Arresting Hook Handle - Up", down = 3009, cockpit_device_id = 5, value_down = 1, combos = {} },
            { name = "Arresting Hook Handle - Down", down = 3009, cockpit_device_id = 5, value_down = 0, combos = {} },
            -- plain commands
            key("Landing Gear Control Handle - UP/DOWN", { "Throttle {GUID}", "JOY_BTN40" }, 68),
            key("Unlock view (stop padlock)", { "Keyboard", "NumLock" }, 20),
        } end,
    }
end

-- stub dxgui
local overlay_lines = {}
local hotkeys = {}
local function widget(kind)
    local w = { visible = true, text = "", kind = kind }
    function w:setVisible(v) self.visible = v end
    function w:setText(t) self.text = t end
    function w:setSkin() end
    function w:getSkin() return {} end
    function w:setBounds(x, y, bw, bh) self.x, self.y, self.w, self.h = x, y, bw, bh end
    function w:calcSize() return 10 + 8 * #self.text, 20 end -- 8 px per character
    function w:insertWidget(c) overlay_lines[#overlay_lines + 1] = c end
    function w:addHotKeyCallback(k, f) hotkeys[k] = f end
    return w
end
package.preload["DialogLoader"] = function()
    return { spawnDialogFromFile = function(path)
        assert(loadfile(path), "overlay.dlg must be valid Lua")
        local win = widget()
        win.Box, win.LineNormal, win.LineHeld = widget(), widget(), widget()
        win.EdgeNormal, win.EdgeHeld = widget(), widget()
        return win
    end }
end
package.preload["Static"] = function() return { new = widget } end
package.preload["Panel"] = function() return { new = function() return widget("panel") end } end
package.preload["Skin"] = function() return { windowSkinChatMin = function() return {} end } end
package.preload["dxgui"] = function() return { GetWindowSize = function() return 1920, 1080 end } end

-- Lines as text; a framed word is shown as [WORD] (solid) or [:WORD:] (dashed),
-- found from where the frame's segments are (8 px per character, offset 10).
local function screen()
    local out = {}
    for _, s in ipairs(overlay_lines) do
        if s.kind ~= "panel" and s.visible and s.text ~= "" then
            local text = s.text
            local x0, x1, n = math.huge, -math.huge, 0
            for _, p in ipairs(overlay_lines) do
                if p.kind == "panel" and p.visible and p.y >= s.y and p.y < s.y + s.h then
                    x0, x1, n = math.min(x0, p.x), math.max(x1, p.x + p.w), n + 1
                end
            end
            if n > 0 then
                local a = math.floor((x0 + 3 - 10) / 8) + 1          -- box_pad 3
                local b = math.floor((x1 - 3 - 10) / 8)
                local o, c = n == 4 and "[" or "[:", n == 4 and "]" or ":]"
                text = text:sub(1, a - 1) .. o .. text:sub(a, b) .. c .. text:sub(b + 1)
            end
            out[#out + 1] = text
        end
    end
    return #out > 0 and table.concat(out, " | ") or "(nothing)"
end

-- LuaSocket stand-in: one in-memory UDP queue shared by Export.lua and the hook.
local udp_queue = {}
package.loaded.socket = {
    gettime = function() return clock end,
    udp = function()
        return {
            settimeout = function() end,
            setsockname = function() return 1 end,
            sendto = function(_, d) udp_queue[#udp_queue + 1] = d; return #d end,
            -- like LuaSocket on Windows: a datagram bigger than the
            -- receive size is an error, and dropped
            receive = function(_, size)
                local d = table.remove(udp_queue, 1)
                if d and #d > (size or 8192) then return nil, "message too large" end
                return d
            end,
            close = function() end,
        }
    end,
}
-- Export environment: display text for list_indication (2 = left MDI, 6 = UFC).
local SEP = "-----------------------------------------\n"
local displays = {
    [2] = SEP .. "MENU_1__id:1\n2155\n" .. SEP .. "WYPT_1__id:13\nW\nY\nP\nT\n"
        .. SEP .. "Symbol_124-arrow-up_id:15\n\n" .. SEP .. "Symbol_124-arrow-down_id:16\n\n"
        .. SEP .. "WPDSG_1__id:17\nW\nP\nD\nS\nG\n",
    [6] = SEP .. "UFC_OptionDisplay1\nATTH\n" .. SEP .. "UFC_OptionDisplay3\nBALT\n",
}
list_indication = function(id) return displays[id] or "" end
dofile("mod/Scripts/ControlsVisualizer/export_indications.lua")

dofile("mod/Scripts/Hooks/ControlsVisualizer.lua")
local function frames(n)
    for _ = 1, n do clock = clock + 0.02; LuaExportAfterNextFrame(); handler.onSimulationFrame() end
end
handler.onSimulationStart()
frames(100) -- 2 s with no player unit
assert(stack[1] == "Debug", "started without a player unit")
player_unit = "FA-18C_hornet"
frames(100) -- unit appears: picked up by the retry
assert(stack[1] ~= "Debug", "did not start once the player unit appeared")
print("stack in flight: {" .. table.concat(stack, ", ") .. "}")

local function idle() frames(400) end -- 8 s: everything expires

local function scenario(name, fn)
    idle()
    forwarded = {}
    fn()
    print(string.format("%-34s -> %s", name, screen()))
    if #forwarded > 0 then print(string.rep(" ", 38) .. "forwarded: " .. table.concat(forwarded, "; ")) end
end

local function arg_seq(a, seq) for _, v in ipairs(seq) do values[a] = v; frames(2) end; frames(8) end

values[49] = 0 -- master arm starts SAFE
frames(4) -- cockpit baseline
scenario("mouse: master arm -> ARM", function() arg_seq(49, { 0.5, 1, 1 }) end)
scenario("mouse: master arm -> SAFE", function() arg_seq(49, { 0.5, 0, 0 }) end)
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
-- The ECM knob turns slowly (anim_speed_default * 0.1): less than the change
-- threshold per poll. One report, at the new position.
values[248] = 0.2
frames(4)
scenario("mouse: ECM knob BIT -> REC (slow)", function()
    local seq = {}
    for k = 1, 20 do seq[k] = 0.2 + 0.1 * k / 20 end
    for _, v in ipairs(seq) do values[248] = v; frames(1) end
    frames(10)
end)
values[293] = 1 -- hook handle up
frames(10)
scenario("mouse: hook handle down", function() arg_seq(293, { 0.5, 0, 0 }) end)
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
scenario("mouse: Left MDI PB 12 on HSI", function() arg_seq(65, { 0.5, 1, 1, 1, 0, 0 }) end)
scenario("mouse: UFC option 3 (A/P)", function() arg_seq(102, { 0.5, 1, 1, 1, 0, 0 }) end)

-- The display changes on release; the line then shows what the press did.
local function press_then(a, after)
    for _, v in ipairs({ 0.5, 1, 1, 1 }) do values[a] = v; frames(2) end
    after() -- released: the display updates
    for _, v in ipairs({ 0, 0 }) do values[a] = v; frames(2) end
    frames(20)
end
local function radar(bars)
    return SEP .. "MENU_1__id:1\n2137\n" .. SEP .. "Radar_mode\nRWS\n" .. SEP .. bars .. "_1__id:3\n" .. bars .. "\n"
        .. SEP .. "RDR_1__id:4\nR\nD\nR\n" .. SEP .. "PRI_2__id:5\nP\nR\nI\n" .. SEP .. "SURF_1__id:6\nS\nU\nR\nF\n"
        .. SEP .. "MODE_1__id:32\nMODE\n" .. SEP .. "NCTR_1__id:26\nN\nC\nT\nR\n" .. SEP .. "RangeIncrementArrow\n\n"
end
displays[3] = radar("1B")
scenario("mouse: radar bars 1B -> 2B", function()
    press_then(84, function() displays[3] = radar("2B"):gsub("2B_1__id:3", "1B_1__id:3") end)
end)
scenario("mouse: WYPT gets boxed", function()
    press_then(64, function() displays[2] = displays[2] .. SEP .. "WYPT_1_box__id:14\n\n" end)
end)
scenario("mouse: WYPT unboxed again", function()
    press_then(64, function() displays[2] = displays[2]:gsub("%-+\nWYPT_1_box__id:14\n\n$", "") end)
end)
-- A quick click: the button is back at rest (and the display changed) before
-- the press is reported; the label still comes from before the press.
local function click_then(a, after)
    values[a] = 1; frames(2)
    values[a] = 0; after(); frames(2)
    frames(20)
end
local function sa(scale)
    return SEP .. "MENU_1__id:1\n2137\n" .. SEP .. "TopLevelPBs_6_10_Root\nchildren are {\n"
        .. SEP .. "SENSR_1__id:9\nS\nE\nN\nS\nR\n" .. SEP .. "MAP_1__id:10\nM\nA\nP\n"
        .. SEP .. "DCLTR_1__id:12\nD\nC\nL\nT\nR\n" .. SEP .. "_1__id:14\nSCL/" .. scale .. "\n"
        .. SEP .. "DCNTR_1__id:16\nD\nC\nN\nT\nR\n}\n" .. SEP .. "STEP_1__id:40\nSTEP\n"
end
scenario("mouse: quick click on SA scale", function()
    displays[3] = sa("40"); frames(20)
    click_then(86, function() displays[3] = sa("80") end)
end)
-- A busy display (the SA page) is bigger than one datagram.
local function sa_busy(scale)
    local filler = {}
    for k = 1, 400 do filler[k] = SEP .. "SA_Track_" .. k .. "\nTRACK " .. k .. "\n" end
    return sa(scale) .. table.concat(filler)
end
scenario("mouse: SA scale on a busy SA page", function()
    displays[2] = sa_busy("40"); frames(20)
    assert(#displays[2] > 8192, "fixture should exceed one datagram")
    click_then(61, function() displays[2] = sa_busy("80") end)
end)
scenario("mouse: page change left alone", function()
    displays[3] = radar("2B"):gsub("2B_1__id:3", "1B_1__id:3"); frames(20)
    press_then(84, function() displays[3] = SEP .. "MENU_1__id:1\n2137\n" .. SEP .. "HUD_1__id:2\nHUD\n" .. SEP .. "TAC_id:23\nTAC\n" end)
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
