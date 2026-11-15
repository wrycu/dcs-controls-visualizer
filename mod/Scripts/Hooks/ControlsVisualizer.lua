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
    cockpit_watch.stop()
    feed.reset()
    if overlay.available() then pcall(overlay.clear) end
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

    if input_ok then
        local iok, msg = input_watch.start(unit_type, feed, CV.intercept_cockpit_bindings)
        input_running = iok and true or false
        log_info(unit_type .. " input: " .. tostring(msg))
    end

    if not aircraft_dirs.find(unit_type) and not CV.aircraft[unit_type] then
        aircraft_dirs.scan({ lfs.currentdir() .. "Mods/aircraft/", lfs.writedir() .. "Mods/aircraft/" }, lfs.dir)
    end
    local dir = CV.aircraft[unit_type] and (lfs.currentdir() .. CV.aircraft[unit_type]) or aircraft_dirs.find(unit_type)
    if dir then
        local cok, msg = cockpit_watch.start(unit_type, dir)
        cockpit_running = cok and true or false
        log_info(unit_type .. " cockpit: " .. tostring(msg))
    else
        log_info(unit_type .. " cockpit: no clickabledata.lua found, switch positions and mouse clicks not shown")
    end
    active = input_running or cockpit_running
end

local function on_cockpit_report(name, text)
    feed.cockpit(name, text, now())
end

local function update_display(t)
    if hidden then return end
    local lines = feed.visible(t)
    if overlay.available() then
        overlay.show(lines)
    elseif feed.version() ~= shown_version and #lines > 0 then
        out_text(lines[#lines].text)
    end
    if CV.log_controls and feed.version() ~= shown_version and #lines > 0 then
        log_info("control: " .. lines[#lines].text)
    end
    shown_version = feed.version()
end

local function step()
    local t = now()
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
        local ok, err = pcall(cockpit_watch.poll, on_cockpit_report)
        if not ok then
            log_err("cockpit: " .. tostring(err))
            cockpit_running = false
        end
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
