-- Watches the player's cockpit arguments and reports controls that moved:
-- catches mouse and VR clicks, and gives switch positions for input presses.
--
-- Each arg is tracked through one "movement": it leaves its resting value,
-- animates, and settles. One report per movement:
--   buttons  -> at the furthest point reached (picks the direction on shared
--               hat args), whether tapped or held; not on release;
--   switches -> at the new resting position.

local clickables = require("clickables")
local overrides = require("overrides")

local M = {}

M.config = {
    change_threshold = 0.01,
    settle_polls = 2, -- "done moving" after this many unchanged polls
}

local state = nil

-- Hooks can't use net.dostring_in('export', ...) (blocked unless allowed in
-- autoexec.cfg), but they get the export functions on the `Export` table.
local function find_cockpit_reader()
    if type(Export) == "table" and type(Export.GetDevice) == "function" then
        return function(a) return Export.GetDevice(0):get_argument_value(a) end
    end
    if type(GetDevice) == "function" then
        return function(a) return GetDevice(0):get_argument_value(a) end
    end
end

local function apply_overrides(args, unit_type)
    for a, o in pairs(overrides[unit_type] or {}) do
        local info = args[a]
        if info then
            info.name = o.name or info.name
            if o.positions == false then info.positions = nil
            elseif o.positions then info.positions = o.positions end
        end
    end
end

--- Start watching. Returns true, or nil and a reason.
-- @param scripts_dir the aircraft's Cockpit/Scripts directory
function M.start(unit_type, scripts_dir)
    state = nil
    local args, count = clickables.load(scripts_dir)
    if not args then return nil, "failed to load clickables: " .. tostring(count) end
    local read_arg = find_cockpit_reader()
    if not read_arg then return nil, "no way to read cockpit arguments from hooks" end
    apply_overrides(args, unit_type)
    local list = {}
    for a in pairs(args) do list[#list + 1] = a end
    table.sort(list)
    state = { args = args, list = list, read_arg = read_arg, tracks = nil }
    return true, string.format("%d controls (%d args)", count, #list)
end

function M.stop() state = nil end

local function track(info, t, v)
    local thr = M.config.change_threshold
    if math.abs(v - t.prev) < thr then t.still = t.still + 1 else t.still = 0 end
    t.prev = v

    local away = math.abs(v - t.rest)
    if away >= thr and (not t.peak or away > math.abs(t.peak - t.rest)) then
        t.peak = v
    end
    if not t.peak or t.still < M.config.settle_polls then return nil end

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

--- Read all args once; calls report(name, text) for each control that moved.
function M.poll(report)
    if not state then return end
    local list, read_arg = state.list, state.read_arg
    if not state.tracks then -- baseline
        state.tracks = {}
        for i = 1, #list do
            local v = read_arg(list[i])
            state.tracks[i] = { rest = v, prev = v, still = 0 }
        end
        return
    end
    for i = 1, #list do
        local info = state.args[list[i]]
        local text = track(info, state.tracks[i], read_arg(list[i]))
        if text then report(info.name, text) end
    end
end

return M
