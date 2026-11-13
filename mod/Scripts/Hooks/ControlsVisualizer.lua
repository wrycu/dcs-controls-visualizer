-- DCS Controls Visualizer - hook entry point (Phase 0 prototype)
--
-- Shows the name of any cockpit control that moves, regardless of whether it
-- was moved by HOTAS, keyboard, mouse or VR hands.
--
-- Install: copy the contents of mod/ into "Saved Games/DCS/". Output goes to on-screen
-- mission text (single player / when hosting) and to Logs/dcs.log.

local ok_init, init_err = pcall(function()

local CV = {
    poll_every_n_frames = 2,
    change_threshold = 0.01,
    settle_polls = 2,        -- a control counts as "done moving" after this many unchanged polls
    display_seconds = 3,
    -- Diagnostics: log every raw change of the tracked args, plus the extra
    -- range below, to dcs.log ("raw f=<frame> arg=<n> <old> -> <new>"),
    -- muting args that change constantly (gauges, needles). Cheap: only
    -- logs on change, and reads at most debug_extra_args more args per poll.
    debug_raw = false,
    -- Experiment: log what Input.getInputActions() returns during flight.
    input_probe = true,
    -- Experiment step 2: also add a raw-button input layer on top (see input_probe.lua).
    -- If any control stops working in flight, set this to false.
    input_probe_layer = true,
    debug_extra_args = { 470, 500 },
    -- DCS unit type -> cockpit scripts folder, relative to the DCS install dir.
    aircraft = {
        ["FA-18C_hornet"] = "Mods/aircraft/FA-18C/Cockpit/Scripts/",
    },
}

local base = lfs.writedir() .. "Scripts/ControlsVisualizer/"
package.path = base .. "?.lua;" .. package.path
local clickables = require("clickables")

local function log_info(msg) log.write("ControlsVisualizer", log.INFO, msg) end
local function log_err(msg) log.write("ControlsVisualizer", log.ERROR, msg) end

local state = nil -- per-flight state, nil when inactive
local frame = 0

local function show(text)
    log_info("control: " .. text)
    local code = string.format("trigger.action.outText(%q, %d, true)", text, CV.display_seconds)
    net.dostring_in("server", code)
end

-- Hooks can't use net.dostring_in('export', ...) (blocked unless allowed in
-- autoexec.cfg), but they get the export functions on the `Export` table,
-- including GetDevice (confirmed in DCS 2.9 under Wine).
local function find_cockpit_reader()
    if type(Export) == "table" and type(Export.GetDevice) == "function" then
        return function(a) return Export.GetDevice(0):get_argument_value(a) end, "Export.GetDevice"
    end
    if type(GetDevice) == "function" then
        return function(a) return GetDevice(0):get_argument_value(a) end, "GetDevice"
    end
    return nil
end

local function start_flight()
    state = nil
    local unit_type = DCS.getPlayerUnitType()
    if not unit_type then return end
    local rel = CV.aircraft[unit_type]
    if not rel then
        log_info("aircraft not supported yet: " .. tostring(unit_type))
        return
    end
    local args, count = clickables.load(lfs.currentdir() .. rel)
    if not args then
        log_err("failed to load clickables for " .. unit_type .. ": " .. tostring(count))
        return
    end
    local read_arg, via = find_cockpit_reader()
    if not read_arg then
        log_err("no way to read cockpit arguments from hooks")
        return
    end
    local arg_list = {}
    for a in pairs(args) do arg_list[#arg_list + 1] = a end
    table.sort(arg_list)
    state = {
        unit_type = unit_type,
        args = args,
        arg_list = arg_list,
        read_arg = read_arg,
        tracks = nil, -- per-arg movement tracking, created on first poll
    }
    log_info(string.format("loaded %d controls (%d args) for %s; reading via %s",
        count, #arg_list, unit_type, via))
end

-- Each arg is tracked through one "movement": it leaves its resting value,
-- animates, and settles. We report once per movement:
--   buttons  -> at the furthest point reached (picks the right direction on
--               shared hat args), whether tapped or held; not on release.
--   switches -> at the new resting position.
local function track(info, t, v)
    local thr = CV.change_threshold
    if math.abs(v - t.prev) < thr then t.still = t.still + 1 else t.still = 0 end
    t.prev = v

    local away = math.abs(v - t.rest)
    if away >= thr and (not t.peak or away > math.abs(t.peak - t.rest)) then
        t.peak = v
    end
    if not t.peak or t.still < CV.settle_polls then return nil end

    -- movement finished
    if info.is_button then
        local text = nil
        if not t.reported then text = clickables.describe(info, t.peak) end
        if math.abs(v - t.rest) < thr then
            t.peak, t.reported = nil, false -- released: ready for the next press
        else
            t.reported = true               -- still held: wait for release
        end
        return text
    end

    local text = nil
    if math.abs(v - t.rest) >= thr then text = clickables.describe(info, v) end
    t.rest, t.peak = v, nil
    return text
end

local function debug_scan()
    local raw = state.raw
    if not raw then
        raw = { last = {}, changes = {}, muted = {}, window_start = frame, list = {} }
        state.raw = raw
        local seen = {}
        for _, a in ipairs(state.arg_list) do seen[a] = true; raw.list[#raw.list + 1] = a end
        for a = CV.debug_extra_args[1], CV.debug_extra_args[2] do
            if not seen[a] then raw.list[#raw.list + 1] = a end
        end
        for _, a in ipairs(raw.list) do raw.last[a] = state.read_arg(a) end
        log_info("raw: baseline taken for " .. #raw.list .. " args")
        return
    end
    if frame - raw.window_start > 120 then -- reset change counts every ~120 frames
        raw.changes, raw.window_start = {}, frame
    end
    for _, a in ipairs(raw.list) do
        local v = state.read_arg(a)
        local old = raw.last[a]
        if math.abs(v - old) >= 0.001 then
            raw.last[a] = v
            if not raw.muted[a] then
                local n = (raw.changes[a] or 0) + 1
                raw.changes[a] = n
                if n > 30 then
                    raw.muted[a] = true
                    log_info(string.format("raw arg=%d changes constantly, muted", a))
                else
                    local info = state.args[a]
                    log_info(string.format("raw f=%d arg=%d %.3f -> %.3f%s", frame, a, old, v,
                        info and ("  (" .. info.hint .. ")") or ""))
                end
            end
        end
    end
end

local function poll()
    if CV.debug_raw then debug_scan() end
    local list, read_arg = state.arg_list, state.read_arg
    if not state.tracks then
        state.tracks = {}
        for idx = 1, #list do
            local v = read_arg(list[idx])
            state.tracks[idx] = { rest = v, prev = v, still = 0 }
        end
        return
    end

    for idx = 1, #list do
        local info = state.args[list[idx]]
        local t = state.tracks[idx]
        local text = track(info, t, read_arg(list[idx]))
        if text then
            if CV.debug_raw then
                log_info(string.format("report f=%d arg=%d rest=%.3f peak=%s reported=%s",
                    frame, list[idx], t.rest, tostring(t.peak), tostring(t.reported)))
            end
            show(text)
        end
    end
end

local handler = {}

-- Input-action experiment (read-only), see ControlsVisualizer/input_probe.lua
local probe = nil
if CV.input_probe then
    local ok, mod = pcall(require, "input_probe")
    if ok and mod.init(log_info, { layer = CV.input_probe_layer }) then probe = mod
    else log_err("probe unavailable: " .. tostring(mod)) end
end

local function probe_call(name)
    if not probe then return end
    local ok, err = pcall(probe[name])
    if not ok then
        log_err("probe " .. name .. ": " .. tostring(err))
        -- The probe may own an input layer that HOTAS buttons now depend on:
        -- remove it so those buttons go back to the sim.
        pcall(probe.stop)
        probe = nil
    end
end

function handler.onSimulationStart()
    local ok, err = pcall(start_flight)
    if not ok then log_err("start: " .. tostring(err)) end
    probe_call("start_flight")
end

function handler.onPlayerChangeSlot()
    local ok, err = pcall(start_flight)
    if not ok then log_err("slot change: " .. tostring(err)) end
end

function handler.onSimulationStop()
    state = nil
    probe_call("stop")
end

function handler.onSimulationFrame()
    probe_call("frame")
    if not state then return end
    frame = frame + 1
    if frame % CV.poll_every_n_frames ~= 0 then return end
    local ok, err = pcall(poll)
    if not ok then
        log_err("poll: " .. tostring(err))
        state = nil -- stop spamming the log
    end
end

DCS.setUserCallbacks(handler)
log_info("hook loaded")

end)

if not ok_init then
    log.write("ControlsVisualizer", log.ERROR, "init failed: " .. tostring(init_err))
end
