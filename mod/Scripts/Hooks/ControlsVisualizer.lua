-- DCS Controls Visualizer - hook entry point
--
-- Shows the name of each cockpit control you use, e.g. "Gun Trigger - SECOND
-- DETENT" or "Master Arm Switch: ARM", however you operated it: HOTAS,
-- keyboard, mouse or VR hands.
--
-- Install: copy the contents of mod/ into "Saved Games/DCS/".
--
-- Two sources, merged by feed.lua:
--   input_watch.lua   - bound key/button presses, named from your control
--                       bindings (catches HOTAS controls the cockpit doesn't
--                       animate, like the trigger);
--   cockpit_watch.lua - cockpit switches that moved (mouse/VR clicks, and
--                       switch positions for input presses).

local ok_init, init_err = pcall(function()

local CV = {
    -- Take over bound HOTAS/cockpit-device buttons so they can be named, and
    -- pass each one on to the aircraft (see input_watch.lua). With false,
    -- those buttons are only seen when the cockpit animates them.
    intercept_cockpit_bindings = true,
    -- Show/hide the overlay (dxgui hotkey format, e.g. "Ctrl+Shift+V").
    toggle_hotkey = "Ctrl+Shift+V",
    poll_every_n_frames = 2,  -- cockpit switch reads
    log_controls = false,     -- also write each shown control to dcs.log
    -- Add what an MFD pushbutton does on the page it was pressed on:
    -- "Left MDI PB 12 (WYPT up)", "UFC Option Select Pushbutton 3 (BALT)".
    -- F/A-18C only. Needs export_indications.lua
    -- loaded from Scripts/Export.lua (see README).
    name_mfd_buttons = true,
    -- Write every cockpit display's text to Logs/ControlsVisualizer-indications.log
    -- when an MFD pushbutton (OSB) is pressed, at the press and 1 s later
    -- (see indication_debug.lua).
    -- Needs export_indications.lua loaded from Scripts/Export.lua.
    debug_indications = false,
    -- Cockpit scripts folders are found from each module's entry.lua; add
    -- "unit type" = "folder relative to the DCS install dir" here only if that fails.
    aircraft = {},
}

local base = lfs.writedir() .. "Scripts/ControlsVisualizer/"
package.path = base .. "?.lua;" .. package.path
local feed = require("feed")
local cockpit_watch = require("cockpit_watch")
local input_watch = require("input_watch")
local overlay = require("overlay")
local aircraft_dirs = require("aircraft_dirs")
local indication_debug = require("indication_debug")
local indications = require("indications")
local mfd_labels = require("mfd_labels")
local button_followup = require("button_followup")

local function log_info(msg) log.write("ControlsVisualizer", log.INFO, msg) end
local function log_err(msg) log.write("ControlsVisualizer", log.ERROR, msg) end

local function now()
    if type(DCS.getRealTime) == "function" then return DCS.getRealTime() end
    return os.clock()
end

local input_ok = input_watch.init(log_info)
if not input_ok then log_err("DCS input API not available; showing cockpit switches only") end

local active = false   -- in an aircraft
local waiting = false  -- sim running, no player unit yet (single player: it can
                       -- appear after onSimulationStart); retried from frames
local last_try = -math.huge
local waiting_logged = false
local input_running, cockpit_running = false, false
local debug_running = false
local mfd_db = nil          -- mfd_labels database for this flight
local indications_running = false
local frame = 0
local shown_version = -1
local hidden = false   -- toggled with CV.toggle_hotkey; kept for the DCS session

-- Fallback display when the overlay can't be created: mission text
-- (single player / when hosting only).
local function out_text(text)
    local code = string.format("trigger.action.outText(%q, 3, true)", text)
    pcall(net.dostring_in, "server", code)
end

local function stop_all()
    active = false
    waiting = false
    if input_ok then pcall(input_watch.stop) end -- also cleans up a half-finished start
    input_running, cockpit_running = false, false
    debug_running = false
    pcall(indication_debug.stop)
    mfd_db, indications_running = nil, false
    pcall(indications.stop)
    pcall(button_followup.stop)
    cockpit_watch.stop()
    feed.reset()
    if overlay.available() then pcall(overlay.clear) end
end

-- "Left MDI PB 12" -> "Left MDI PB 12 (WYPT up)", "UFC Option Select
-- Pushbutton 3" -> "... (BALT)", from what that display
-- shows right now (the Hornet acts on release, so that's the page the button
-- was pressed on). Anything else, or no label: unchanged.
local function decorate(text, get_text)
    if not mfd_db then return text end
    local ok, result = pcall(function()
        local label = mfd_labels.label_for(mfd_db, text, get_text)
        if not label then return text end
        return text .. " (" .. label .. ")"
    end)
    return ok and result or text
end

-- Report a control: shown with its MFD label from when the press began
-- (`since`; a mouse click is reported only after the button is back up, when
-- the display may already show the result), and updated with what the press
-- did once the display shows it (button_followup.lua).
local function shown_text(text, t, since)
    local get_text = indications.get
    if since then get_text = function(id) return indications.get_at(id, since) end end
    local shown = decorate(text, get_text)
    if shown ~= text then pcall(button_followup.press, text, shown, t, get_text) end
    return shown
end

local function start_flight()
    stop_all()
    local unit_type = DCS.getPlayerUnitType()
    if not unit_type or unit_type == "" then
        -- spectator / not in a slot yet: try again from onSimulationFrame
        waiting = true
        if not waiting_logged then
            log_info("no player unit yet, waiting for one")
            waiting_logged = true
        end
        return
    end
    waiting_logged = false
    log_info("starting for " .. unit_type)

    local ok, err = overlay.create(base .. "overlay.dlg", CV.toggle_hotkey, function()
        hidden = not hidden
        if hidden then
            pcall(overlay.clear)
        else
            feed.cockpit("Controls Visualizer", "Controls Visualizer shown", now())
        end
        log_info(hidden and "overlay hidden" or "overlay shown")
    end)
    if not ok then log_err("overlay unavailable, using mission text: " .. tostring(err)) end

    if not aircraft_dirs.find(unit_type) and not CV.aircraft[unit_type] then
        aircraft_dirs.scan({ lfs.currentdir() .. "Mods/aircraft/", lfs.writedir() .. "Mods/aircraft/" }, lfs.dir)
    end
    local dir = CV.aircraft[unit_type] and (lfs.currentdir() .. CV.aircraft[unit_type]) or aircraft_dirs.find(unit_type)

    if CV.name_mfd_buttons and dir and mfd_labels.aircraft[unit_type] then
        local lok, db, msg = pcall(mfd_labels.load, unit_type, dir, lfs.currentdir() .. "Scripts/Aircrafts/_Common/Cockpit/")
        if lok and db then
            local iok, ierr = indications.start(log_info)
            if iok then
                mfd_db, indications_running = db, true
                button_followup.start(db, indications.get)
                log_info(unit_type .. " MFD buttons: " .. tostring(msg))
            else
                log_err("MFD buttons off: " .. tostring(ierr))
            end
        else
            log_err("MFD buttons off: " .. tostring(lok and msg or db))
        end
    end

    if CV.debug_indications then
        local dok, derr = pcall(indication_debug.start, log_info,
            lfs.writedir() .. "Logs/ControlsVisualizer-indications.log")
        debug_running = dok and derr or false
        if not dok then log_err("indication debug: " .. tostring(derr)) end
        indications_running = indications_running or debug_running
    end

    -- Input reports get MFD button labels added, and go past the debug dump.
    local sink = feed
    if mfd_db or debug_running then
        sink = setmetatable({
            input_down = function(id, base, text, t, no_count)
                if debug_running then pcall(indication_debug.on_report, "input", base, text, t) end
                feed.input_down(id, base, shown_text(text, t), t, no_count)
            end,
            input_tap = function(id, base, text, t)
                if debug_running then pcall(indication_debug.on_report, "input", base, text, t) end
                feed.input_tap(id, base, shown_text(text, t), t)
            end,
        }, { __index = feed })
    end

    if input_ok then
        local iok, msg = input_watch.start(unit_type, sink, CV.intercept_cockpit_bindings)
        input_running = iok and true or false
        log_info(unit_type .. " input: " .. tostring(msg))
    end

    if dir then
        local commands = input_running and input_watch.commands() or nil
        local cok, msg = cockpit_watch.start(unit_type, dir, commands)
        cockpit_running = cok and true or false
        log_info(unit_type .. " cockpit: " .. tostring(msg))
    else
        log_info(unit_type .. " cockpit: no clickabledata.lua found, switch positions and mouse clicks not shown")
    end
    active = input_running or cockpit_running
end

local function on_cockpit_report(name, text, since)
    local t = now()
    if debug_running then pcall(indication_debug.on_report, "cockpit", name, text, t) end
    feed.cockpit(name, shown_text(text, t, since), t)
end

local function update_display(t)
    if hidden then return end
    local lines = feed.visible(t)
    if overlay.available() then
        overlay.show(lines)
    elseif feed.version() ~= shown_version and #lines > 0 then
        out_text(overlay.with_box_words(lines[#lines]))
    end
    if CV.log_controls and feed.version() ~= shown_version and #lines > 0 then
        log_info("control: " .. overlay.with_box_words(lines[#lines]))
    end
    shown_version = feed.version()
end

local function step()
    local t = now()
    if indications_running then
        local ok, err = pcall(indications.poll, t) -- before anything reads display text
        if not ok then log_err("indications: " .. tostring(err)); indications_running = false end
    end
    if mfd_db then
        local ok, err = pcall(button_followup.frame, t, feed.retext)
        if not ok then log_err("button follow-up: " .. tostring(err)); button_followup.stop() end
    end
    if input_running then
        local ok, err = pcall(input_watch.frame, t)
        if not ok then
            -- The input layer owns HOTAS buttons: remove it so they go back to the sim.
            log_err("input: " .. tostring(err) .. " - input naming switched off for this flight")
            pcall(input_watch.stop)
            input_running = false
        end
    end
    frame = frame + 1
    if cockpit_running and frame % CV.poll_every_n_frames == 0 then
        local ok, err = pcall(cockpit_watch.poll, on_cockpit_report, t)
        if not ok then
            log_err("cockpit: " .. tostring(err))
            cockpit_running = false
        end
    end
    if debug_running then
        local ok, err = pcall(indication_debug.frame, t)
        if not ok then log_err("indication debug: " .. tostring(err)); debug_running = false end
    end
    update_display(t)
end

local handler = {}

function handler.onSimulationStart()
    local ok, err = pcall(start_flight)
    if not ok then log_err("start: " .. tostring(err)); pcall(stop_all) end
end

function handler.onPlayerChangeSlot(id)
    -- fires for every player in multiplayer; only react to our own
    local me = type(net.get_my_player_id) == "function" and net.get_my_player_id() or id
    if id ~= me then return end
    local ok, err = pcall(start_flight)
    if not ok then log_err("slot change: " .. tostring(err)); pcall(stop_all) end
end

function handler.onSimulationStop()
    pcall(stop_all)
    waiting_logged = false
end

function handler.onSimulationFrame()
    if waiting then
        local t = now()
        if t - last_try >= 1 then
            last_try = t
            local ok, err = pcall(start_flight)
            if not ok then log_err("start: " .. tostring(err)); pcall(stop_all) end
        end
        return
    end
    if not active then return end
    local ok, err = pcall(step)
    if not ok then
        log_err("frame: " .. tostring(err))
        pcall(stop_all)
    end
end

DCS.setUserCallbacks(handler)
log_info("hook loaded")

end)

if not ok_init then
    log.write("ControlsVisualizer", log.ERROR, "init failed: " .. tostring(init_err))
end
