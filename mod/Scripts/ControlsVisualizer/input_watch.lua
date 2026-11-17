-- Names bound key/button presses, including HOTAS controls the cockpit
-- doesn't animate (trigger, sensor control switch, ...).
--
-- How DCS input behaves (found by experiment, F/A-18C, DCS 2.9):
--  * Input.getInputActions() reports plain sim commands (gear = 68) without
--    taking them, but never commands bound to a cockpit device
--    ("d3002...cd13": trigger, SCS, most of the HOTAS).
--  * A layer that maps a key consumes it: the layers below never see it.
--    That holds on top of the stack and in the UI layer alike.
--  * A layer can hold only one action per combo ("Combo already mapped").
--
-- So:
--  * plain commands: read-only, named from the aircraft's input profile by
--    action number;
--  * cockpit-device commands: a layer on top of the stack maps exactly those
--    combos (same key, same modifiers) to marker actions. On a marker we
--    report the command and perform it ourselves with
--    GetDevice(id):performClickableAction(command, value) for down / pressed
--    (every frame while held) / up, which is what the unit layer would have
--    done. Other keys have no combo in our layer and fall through.
--  * cockpit-device axes (TDC, radar elevation, knobs; "a3043cd13") work the
--    same way: our layer maps them to marker actions with the binding's own
--    filter (curve, deadzone, invert), and each value is forwarded with
--    performClickableAction(axis action, value). They're shown while they
--    move. Plain sim axes (pitch, roll, rudder, thrust, brakes, zoom) are
--    left alone and not shown.
-- The layer is removed and the stack restored on stop, and on any error (the
-- hook calls stop()), so those buttons can't stay dead.

local clickables = require("clickables")

local M = {}

local LAYER = "ControlsVisualizer"
local MARKER = 200000
local AXIS_MARKER = 300000
local AXIS_MOVE = 0.02      -- change that counts as movement
local AXIS_DEFLECT = 0.1    -- away from rest that counts as "held" (centred mini-sticks)
local AXIS_SETTLE_S = 1.5   -- unchanged this long -> new rest position (knobs, sliders)
local AXIS_IDLE_S = 0.3     -- no movement this long -> released
local SYS_CONFIG = "./Config/Input/"
local LOCK_KEYS = { NumLock = true, CapsLock = true, ScrollLock = true }

local Input, InputUtils, get_device, log_info
local sink = nil         -- feed-like object: input_down / input_up / input_tap
local saved_stack = nil
local markers = {}       -- marker index -> { cmd=, id=, base=, text= }
local held = {}          -- marker index -> true while held
local plain = {}         -- action number -> { id=, base=, text=, lock_only= }
local axes = {}          -- axis marker index -> { cmd=, id=, base=, value=, rest=, ref=, stable_since= }
local axis_ids = {}      -- shown id -> { active=, last=, base=, text= }

local function safe(f, ...)
    local ok, v = pcall(f, ...)
    if ok then return v end
end

-- "Gun Trigger - SECOND DETENT (Press to shoot)" -> base "Gun Trigger",
-- text "Gun Trigger - SECOND DETENT"
local function names_for(cmd)
    local text = clickables.clean_hint(cmd.name or "?")
    local base = text:match("^(.-)%s+%-%s+") or text
    return base, text
end

function M.init(logger)
    log_info = logger
    -- Not a global in the hooks environment; DCS's own UI scripts require it.
    Input = rawget(_G, "Input") or safe(require, "Input")
    InputUtils = safe(require, "Input.Utils")
    if type(Export) == "table" and type(Export.GetDevice) == "function" then get_device = Export.GetDevice
    elseif type(GetDevice) == "function" then get_device = GetDevice end
    return type(Input) == "table" and type(Input.getInputActions) == "function" and InputUtils ~= nil
end

local function load_profile(unit_type)
    local InputData = require("Input.Data")
    local input_name = safe(DCS.getInputNameByUnitType, unit_type) or unit_type
    local function lookup()
        local profile = InputData.getProfileNameByUnitName(input_name)
        return profile, profile and InputData.getProfileKeyCommands(profile) or {}
    end
    local profile, commands = lookup()
    if #commands == 0 then
        -- Profiles aren't loaded in the hooks' Lua state: load them the way
        -- DCS's InputVisualizerDialog does (loadProfiles_). ~0.6 s.
        local ProfileDatabase = require("Input.ProfileDatabase")
        InputData.initialize(lfs.writedir() .. "Config/Input/", SYS_CONFIG)
        for _, info in ipairs(ProfileDatabase.createDefaultProfilesSet(SYS_CONFIG, DCS.getInputProfiles())) do
            InputData.createProfile(info)
        end
        profile, commands = lookup()
    end
    return profile, commands, profile and InputData.getProfileModifiers(profile) or {},
        profile and InputData.getProfileAxisCommands(profile) or {}
end

local function reformers_for(names, modifiers)
    if not names then return nil end
    local out = {}
    for _, n in ipairs(names) do
        local m = modifiers[n]
        if m then out[#out + 1] = { key = m.event, deviceId = m.deviceId } end
    end
    return out
end

local function only_lock_keys(cmd)
    local any = false
    for device, list in pairs(cmd.combos or {}) do
        for _, combo in ipairs(list) do
            if not (device == "Keyboard" and LOCK_KEYS[combo.key]) then return false end
            any = true
        end
    end
    return any
end

function M.stop()
    if saved_stack then
        safe(Input.setLayerStack, saved_stack)
        saved_stack = nil
    end
    if Input then safe(Input.deleteLayer, LAYER) end
    markers, held, plain, axes, axis_ids, sink = {}, {}, {}, {}, {}, nil
end

-- Cockpit-device axes go into our layer; an axis also bound to a plain sim
-- axis is skipped so that one keeps working (we'd consume it).
local function add_axes(axis_commands, modifiers)
    local plain_keys = {}
    for _, cmd in ipairs(axis_commands) do
        if not cmd.cockpit_device_id then
            for device, list in pairs(cmd.combos or {}) do
                for _, combo in ipairs(list) do plain_keys[device .. ":" .. tostring(combo.key)] = true end
            end
        end
    end
    for _, cmd in ipairs(axis_commands) do
        if cmd.cockpit_device_id and type(cmd.action) == "number" then
            local base = names_for(cmd) -- "TDC - Vertical Axis" and "- Horizontal Axis" share one line
            for device, list in pairs(cmd.combos or {}) do
                local id = Input.getDeviceId(device)
                for _, combo in ipairs(list) do
                    if combo.valid and id and not plain_keys[device .. ":" .. tostring(combo.key)] then
                        axes[#axes + 1] = { cmd = cmd, id = "a:" .. base, base = base }
                        Input.addAxisCombo(LAYER, InputUtils.getInputEvent(combo.key), id,
                            reformers_for(combo.reformers, modifiers), AXIS_MARKER + #axes, combo.filter)
                    end
                end
            end
        end
    end
end

--- Start for the player's aircraft. Returns true and a summary, or nil and a reason.
-- @param intercept also take over cockpit-device bindings (see top of file)
local profile_commands = {}

--- Key commands of the input profile loaded by the last start().
function M.commands() return profile_commands end

function M.start(unit_type, feed_sink, intercept)
    M.stop()
    local profile, commands, modifiers, axis_commands = load_profile(unit_type)
    profile_commands = commands
    if #commands == 0 then return nil, "no input profile for " .. tostring(unit_type) end

    local cockpit_cmds = {}
    for _, cmd in ipairs(commands) do
        if cmd.cockpit_device_id then
            cockpit_cmds[#cockpit_cmds + 1] = cmd
        else
            local base, text = names_for(cmd)
            local entry = { id = "p:" .. tostring(cmd.down or cmd.pressed), base = base, text = text,
                            lock_only = only_lock_keys(cmd) }
            -- only the actions that start a press; `up` numbers are ignored
            for _, a in ipairs({ cmd.down, cmd.pressed }) do
                if type(a) == "number" and not plain[a] then plain[a] = entry end
            end
        end
    end
    sink = feed_sink

    if intercept and get_device then
        saved_stack = safe(Input.getLayerStack)
        if type(saved_stack) ~= "table" then
            saved_stack = nil
        else
            Input.deleteLayer(LAYER)
            Input.createLayer(LAYER)
            for _, m in pairs(modifiers) do
                Input.addReformer(LAYER, m.event, m.deviceId, m.switch)
            end
            local seen = {}
            for _, cmd in ipairs(cockpit_cmds) do
                local base, text = names_for(cmd)
                for device, list in pairs(cmd.combos or {}) do
                    local id = Input.getDeviceId(device)
                    for _, combo in ipairs(list) do
                        local key = tostring(id) .. ":" .. tostring(combo.key) .. ":" .. table.concat(combo.reformers or {}, "+")
                        if combo.valid and id and not seen[key] then
                            seen[key] = true
                            markers[#markers + 1] = { cmd = cmd, id = "c:" .. #markers + 1, base = base, text = text }
                            local marker = MARKER + #markers
                            Input.addKeyCombo(LAYER, InputUtils.getInputEvent(combo.key), id,
                                reformers_for(combo.reformers, modifiers), marker, nil, -marker)
                        end
                    end
                end
            end
            add_axes(axis_commands, modifiers)
            Input.setTopLayer(LAYER)
        end
    end
    return true, string.format("profile %s: %d HOTAS/cockpit buttons and %d axes forwarded, %d commands total",
        tostring(profile), #markers, #axes, #commands)
end

-- Perform a cockpit command the way the unit layer would have.
local forward_errors = {}
local function forward(cmd, which)
    local action = cmd[which]
    if type(action) ~= "number" then return end
    local value = cmd["value_" .. which]
    if value == nil then value = (which == "up") and 0 or 1 end
    local ok, err = pcall(function()
        get_device(cmd.cockpit_device_id):performClickableAction(action, value)
    end)
    if not ok and not forward_errors[cmd] then
        forward_errors[cmd] = true
        log_info("could not forward " .. tostring(cmd.name) .. ": " .. tostring(err))
    end
end

local function axis_active(ax, now)
    local s = axis_ids[ax.id]
    if not s then s = {}; axis_ids[ax.id] = s end
    if not s.active then
        s.active = true
        sink.input_down(ax.id, ax.base, ax.base, now, true)
    end
    s.last = now
end

local function axis_value(ax, v, now)
    local ok, err = pcall(function()
        get_device(ax.cmd.cockpit_device_id):performClickableAction(ax.cmd.action, v)
    end)
    if not ok and not forward_errors[ax.cmd] then
        forward_errors[ax.cmd] = true
        log_info("could not forward " .. tostring(ax.cmd.name) .. ": " .. tostring(err))
    end
    if ax.value == nil then -- first value is the resting position
        ax.value, ax.rest, ax.ref, ax.stable_since = v, v, v, now
        return
    end
    ax.value = v
    if math.abs(v - ax.ref) > AXIS_MOVE then
        ax.ref, ax.stable_since = v, now
        axis_active(ax, now)
    end
end

-- Per frame: deflected mini-sticks stay shown while held; knobs and sliders
-- settle at their new position; idle axes are released.
local function update_axes(now)
    for _, ax in ipairs(axes) do
        if ax.value ~= nil then
            if now - ax.stable_since >= AXIS_SETTLE_S then
                ax.rest = ax.value
            elseif math.abs(ax.value - ax.rest) > AXIS_DEFLECT then
                axis_active(ax, now)
            end
        end
    end
    for id, s in pairs(axis_ids) do
        if s.active and now - s.last > AXIS_IDLE_S then
            s.active = false
            sink.input_up(id, now)
        end
    end
end

function M.frame(now)
    if not sink then return end
    local actions = Input.getInputActions()
    if type(actions) ~= "table" then actions = {} end

    for _, a in ipairs(actions) do
        if a.hasValue then
            local ax = axes[(tonumber(a.action) or 0) - AXIS_MARKER]
            if ax and type(a.value) == "number" then axis_value(ax, a.value, now) end
        else
            local action = tonumber(a.action) or 0
            local idx = math.abs(action) - MARKER
            local m = markers[idx]
            if m then
                if action > 0 then
                    held[idx] = true
                    forward(m.cmd, "down")
                    sink.input_down(m.id, m.base, m.text, now)
                else
                    held[idx] = nil
                    forward(m.cmd, "up")
                    sink.input_up(m.id, now)
                end
            else
                local p = plain[action]
                -- Wine sends stray NumLock events (also alongside unbound keys,
                -- which we can't see), so commands bound only to lock keys
                -- (default: NumLock = "Unlock view") are never shown.
                if p and not p.lock_only then
                    sink.input_tap(p.id, p.base, p.text, now)
                end
            end
        end
    end
    update_axes(now)
    for idx in pairs(held) do
        local m = markers[idx]
        if m and m.cmd.pressed then forward(m.cmd, "pressed") end
    end
end

return M
