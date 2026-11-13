-- Experiment: name HOTAS/keyboard presses that don't animate the cockpit.
--
-- Findings so far (F/A-18C, DCS 2.9):
--  1. Input.getInputActions() (read-only) reports plain sim commands
--     (iCommandPlaneGear = 68, iCommandQuit = 51) but never commands bound
--     to a cockpit device ("d3002...cd13": trigger, SCS, most of the HOTAS).
--  2. A layer with raw combos (event + 99999, like DCS's InputVisualizerDialog)
--     sees every press, but a combo matched by a layer is consumed: the sim
--     never gets it. True on top of the stack and in the UI layer alike.
--  3. Two actions on one combo in the same layer are rejected ("Combo already
--     mapped to action"), so a layer can't both listen and pass through.
--
-- Step 5 (opts.layer = true), "intercept and forward":
--  * plain commands: read-only, named from the profile by action number;
--  * cockpit-device commands: a top layer maps exactly those combos (same key,
--    same modifiers) to markers. On a marker the hook names the command and
--    performs it itself with GetDevice(id):performClickableAction(cmd, value)
--    for down / pressed (every frame while held) / up. Every other button and
--    all axes have no combo in our layer and fall through untouched.
-- The layer is removed and the stack restored on stop.

local M = {}

local MAX_LINES = 400        -- per flight, so a flood can't hurt
local SUMMARY_EVERY_S = 10
local LAYER = "ControlsVisualizerProbe"
local MARKER = 200000
local SYS_CONFIG = "./Config/Input/"

local log_info, Input, InputUtils, opts
local lines, axis_count, last_summary, started = 0, 0, 0, false
local saved_stack, layer_check_at = nil, nil
local markers = {}      -- marker index -> command (with cockpit_device_id)
local held = {}         -- marker index -> true while held (for `pressed`)
local plain_names = {}  -- action number -> command name (plain commands)
local get_device = nil

local function safe(f, ...)
    local ok, v = pcall(f, ...)
    if ok then return v end
    return nil
end

local function list_text(t)
    if type(t) ~= "table" then return tostring(t) end
    local out = {}
    for i, v in ipairs(t) do out[i] = tostring(v) end
    return "{" .. table.concat(out, ", ") .. "}"
end

local function log_line(msg)
    if lines < MAX_LINES then
        lines = lines + 1
        log_info(msg)
    end
end

function M.init(logger, options)
    log_info = logger
    opts = options or {}
    -- Not a global in the hooks environment; DCS's own UI scripts require it.
    Input = rawget(_G, "Input") or safe(require, "Input")
    InputUtils = safe(require, "Input.Utils")
    if type(Export) == "table" and type(Export.GetDevice) == "function" then get_device = Export.GetDevice
    elseif type(GetDevice) == "function" then get_device = GetDevice end
    log_info(string.format("probe: Input=%s getInputActions=%s Input.Utils=%s GetDevice=%s",
        type(Input), Input and type(Input.getInputActions) or "-", type(InputUtils), type(get_device)))
    return type(Input) == "table" and type(Input.getInputActions) == "function"
end

local function remove_layer()
    if saved_stack then
        safe(Input.setLayerStack, saved_stack)
        saved_stack = nil
    end
    safe(Input.deleteLayer, LAYER)
    markers, held = {}, {}
end

local function load_profile()
    local InputData = require("Input.Data")
    local unit = DCS.getPlayerUnitType()
    local input_name = unit and (safe(DCS.getInputNameByUnitType, unit) or unit)
    local function lookup()
        local profile = input_name and InputData.getProfileNameByUnitName(input_name)
        return profile, profile and InputData.getProfileKeyCommands(profile) or {}
    end
    local profile, commands = lookup()
    if #commands == 0 then
        -- Profiles not loaded in this Lua state: load them the way DCS's
        -- InputVisualizerDialog does (loadProfiles_).
        local t0 = os.clock()
        local ProfileDatabase = require("Input.ProfileDatabase")
        InputData.initialize(lfs.writedir() .. "Config/Input/", SYS_CONFIG)
        for _, info in ipairs(ProfileDatabase.createDefaultProfilesSet(SYS_CONFIG, DCS.getInputProfiles())) do
            InputData.createProfile(info)
        end
        profile, commands = lookup()
        log_info(string.format("probe: loaded profiles in %.2fs", os.clock() - t0))
    end
    local modifiers = profile and InputData.getProfileModifiers(profile) or {}
    log_info(string.format("probe: unit=%s profile=%s commands=%d", tostring(unit), tostring(profile), #commands))
    return commands, modifiers
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

local function add_layer()
    remove_layer()
    local commands, modifiers = load_profile()
    plain_names = {}
    local cockpit_cmds = {}
    for _, cmd in ipairs(commands) do
        if cmd.cockpit_device_id then
            cockpit_cmds[#cockpit_cmds + 1] = cmd
        else
            for _, a in ipairs({ cmd.down, cmd.pressed, cmd.up }) do
                if type(a) == "number" and not plain_names[a] then plain_names[a] = cmd.name end
            end
        end
    end
    if not opts.layer or not get_device then return end

    saved_stack = safe(Input.getLayerStack)
    if type(saved_stack) ~= "table" then saved_stack = nil; return end
    Input.createLayer(LAYER)
    for _, m in pairs(modifiers) do
        Input.addReformer(LAYER, m.event, m.deviceId, m.switch)
    end
    local seen = {}
    for _, cmd in ipairs(cockpit_cmds) do
        for device, list in pairs(cmd.combos or {}) do
            local id = Input.getDeviceId(device)
            for _, combo in ipairs(list) do
                local key = tostring(id) .. ":" .. tostring(combo.key) .. ":" .. table.concat(combo.reformers or {}, "+")
                if combo.valid and id and not seen[key] then
                    seen[key] = true
                    markers[#markers + 1] = cmd
                    local marker = MARKER + #markers
                    Input.addKeyCombo(LAYER, InputUtils.getInputEvent(combo.key), id,
                        reformers_for(combo.reformers, modifiers), marker, nil, -marker)
                end
            end
        end
    end
    Input.setTopLayer(LAYER)
    log_info(string.format("probe: intercepting %d cockpit-command combos (%d plain commands named read-only); stack = %s",
        #markers, #commands - #cockpit_cmds, list_text(safe(Input.getLayerStack))))
    layer_check_at = os.clock() + 5
end

function M.start_flight()
    lines, axis_count, last_summary, started = 0, 0, os.clock(), true
    log_info("probe: layer stack (as returned) = " .. list_text(safe(Input.getLayerStack)))
    local ok, err = pcall(add_layer)
    if not ok then
        log_info("probe: setup failed: " .. tostring(err))
        remove_layer()
    end
end

-- Perform a cockpit command the way the unit layer would have.
local function forward(cmd, which)
    local action = cmd[which]
    if type(action) ~= "number" then return end
    local value = cmd["value_" .. which]
    if value == nil then value = (which == "up") and 0 or 1 end
    local dev = get_device(cmd.cockpit_device_id)
    if dev then
        local ok, err = pcall(dev.performClickableAction, dev, action, value)
        if not ok then log_line("probe: forward failed " .. tostring(cmd.name) .. ": " .. tostring(err)) end
    end
end

local function describe_action(a)
    local action = math.abs(tonumber(a.action) or 0)
    local device = InputUtils and safe(InputUtils.getDeviceNameById, a.deviceId) or "?"
    device = device and (tostring(device):match("^(.-)%s*{") or device)
    return string.format("action=%s (%s) %s", tostring(a.action), tostring(device),
        tostring(plain_names[action] or (InputUtils and safe(InputUtils.getInputActionName, action)) or "?"))
end

function M.frame()
    if not started then return end
    local actions = Input.getInputActions()
    if type(actions) == "table" then
        for _, a in ipairs(actions) do
            local action = tonumber(a.action) or 0
            local idx = math.abs(action) - MARKER
            local cmd = markers[idx]
            if cmd then
                if action > 0 then
                    held[idx] = true
                    forward(cmd, "down")
                    log_line("probe: COCKPIT down " .. tostring(cmd.name))
                else
                    held[idx] = nil
                    forward(cmd, "up")
                    log_line("probe: COCKPIT up   " .. tostring(cmd.name))
                end
            elseif a.hasValue then
                axis_count = axis_count + 1
            else
                log_line("probe: PLAIN " .. (action < 0 and "up   " or "down ") .. describe_action(a))
            end
        end
    end
    for idx in pairs(held) do
        local cmd = markers[idx]
        if cmd and cmd.pressed then forward(cmd, "pressed") end
    end
    local now = os.clock()
    if layer_check_at and now >= layer_check_at then
        layer_check_at = nil
        log_info("probe: stack 5s later = " .. list_text(safe(Input.getLayerStack)))
    end
    if now - last_summary >= SUMMARY_EVERY_S then
        if axis_count > 0 then log_info("probe: axis actions in last period: " .. axis_count) end
        axis_count, last_summary = 0, now
    end
end

function M.stop()
    started = false
    remove_layer()
end

return M
