-- Merges control events from both sources into one short list of entries
-- for display. Pure Lua; times are seconds (any monotonic clock).
--
-- Sources:
--   input   - a bound key/button was pressed (input_watch.lua). Has an id per
--             command, a down and (usually) an up.
--   cockpit - a cockpit argument moved and settled (cockpit_watch.lua): mouse
--             and VR clicks, and the visible result of input presses.
--
-- Rules:
--   * a press of a command that is still held, or was released within
--     `continuation_s`, continues its entry (DCS re-sends held hats as
--     down/up pairs every ~0.5 s; pressed-type commands repeat every frame);
--   * a cockpit report for the same control as a recent input entry (held,
--     or released within `absorb_s`) is merged into it once: the switch
--     position replaces the command name ("Exterior Lights Switch - ON/OFF"
--     -> "Exterior Lights Switch: ON"); later reports for it (spring-back,
--     interlocks) are dropped;
--   * the same text again within `repeat_s` bumps a counter ("x3") instead
--     of adding a line, so repeated presses are visible.

local M = {}

M.config = {
    continuation_s = 0.15,
    absorb_s = 1.0,
    repeat_s = 1.5,
    display_s = 4,
    max_entries = 6,
}

local entries = {} -- oldest first
local version = 0

local function norm(s) return (tostring(s or ""):lower():gsub("[^%w]", "")) end

-- Same control? Names from bindings and from cockpit hints differ in
-- punctuation and detail, so compare normalized prefixes.
local function related(a, b)
    a, b = norm(a), norm(b)
    if a == "" or b == "" then return false end
    return a == b or a:sub(1, #b) == b or b:sub(1, #a) == a
end

local function changed() version = version + 1 end

local function push(e)
    entries[#entries + 1] = e
    while #entries > M.config.max_entries do table.remove(entries, 1) end
    changed()
end

function M.reset()
    entries = {}
    changed()
end

function M.version() return version end

--- A bound input command went down.
-- @param id   unique id of the command binding
-- @param base control name without the action detail, for matching cockpit reports
-- @param text display text
-- @param no_count reuse a recent identical line without counting (axes)
function M.input_down(id, base, text, now, no_count)
    local cfg = M.config
    for i = #entries, 1, -1 do
        local e = entries[i]
        if e.id == id and (e.held or now - (e.released_at or -math.huge) <= cfg.continuation_s) then
            e.held, e.updated = true, now
            return
        end
    end
    local last = entries[#entries]
    if last and last.source == "input" and not last.held and last.text == text and not last.box
        and now - last.updated <= cfg.repeat_s then
        -- axes (no_count) just light the same line up again
        if not no_count then last.count = last.count + 1 end
        last.id, last.held, last.updated, last.absorbed = id, true, now, false
        changed()
        return
    end
    push({ source = "input", id = id, base = base, text = text, count = 1, held = true, updated = now })
end

--- A bound input command was released.
function M.input_up(id, now)
    for i = #entries, 1, -1 do
        local e = entries[i]
        if e.id == id and e.held then
            e.held, e.released_at, e.updated = false, now, now
            return
        end
    end
end

--- A command that has no release event (plain sim commands).
function M.input_tap(id, base, text, now)
    M.input_down(id, base, text, now)
    M.input_up(id, now)
end

--- A cockpit control moved to a new position (or a button was pressed).
-- @param base control name (clickables info.name)
-- @param text display text, e.g. "Master Arm Switch: ARM"
function M.cockpit(base, text, now)
    local cfg = M.config
    for i = #entries, 1, -1 do
        local e = entries[i]
        if e.source == "input" and related(e.base, base)
            and (e.held or now - (e.released_at or -math.huge) <= cfg.absorb_s) then
            if not e.absorbed then
                e.absorbed = true
                -- Only a position is news: a bare name ("Master Arm Switch",
                -- modules without position labels) would hide a more specific
                -- binding name ("Master Arm Switch - ON").
                if e.text ~= text and text ~= base then e.text = text; changed() end
            end
            e.updated = math.max(e.updated, now)
            return
        end
    end
    local last = entries[#entries]
    if last and last.source == "cockpit" and last.text == text and not last.box
        and now - last.updated <= cfg.repeat_s then
        last.count = last.count + 1
        last.updated = now
        changed()
        return
    end
    push({ source = "cockpit", base = base, text = text, count = 1, updated = now })
end

--- Replace the text of the newest entry showing `old_text` (what a control
--- did, known only after the press: "... (1B)" -> "... (1B -> 2B)").
-- @param box optional { word =, boxed = }: a word in the text the display
--            boxes (boxed = true) or could box (false); drawn as a frame
-- @return true if an entry was updated
function M.retext(old_text, new_text, now, box)
    for i = #entries, 1, -1 do
        local e = entries[i]
        if e.text == old_text and not e.box then
            e.text, e.box = new_text, box
            e.count = 1 -- a different line now; don't carry "x3" over
            e.updated = math.max(e.updated, now)
            changed()
            return true
        end
    end
    return false
end

--- Lines to show now, oldest first. Each is { text = ..., held = bool, box = nil|{word=, boxed=} }.
function M.visible(now)
    local out = {}
    for _, e in ipairs(entries) do
        if e.held or now - e.updated <= M.config.display_s then
            local text = e.text
            if e.count > 1 then text = text .. "  x" .. e.count end
            out[#out + 1] = { text = text, held = e.held or false, box = e.box }
        end
    end
    return out
end

return M
