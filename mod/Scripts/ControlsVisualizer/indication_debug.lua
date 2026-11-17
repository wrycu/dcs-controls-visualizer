-- Debug aid for naming MFD pushbuttons (OSBs) by their on-screen label.
--
-- When a control whose name looks like a display pushbutton ("Left MDI PB 12",
-- "OSB 3") is reported, writes the text of every cockpit indicator to dcs.log,
-- right away and again `after_s` later (to see the page it switched to).
-- Display text comes from Export.lua via indications.lua. Dumps go to their
-- own file (dcs.log cuts long messages short); dcs.log gets one line per press.

local indications = require("indications")

local M = {}

M.config = {
    after_s = 1.0,   -- second dump this long after the press
    dedupe_s = 0.5,  -- the same press reported by input and cockpit: dump once
    no_link_warn_s = 10,
}

local running, log_fn, out = false, nil, nil
local pending = {}     -- { at =, label = }
local last_key, last_at = nil, -math.huge
local started_at, warned = nil, false
local seq = 0

--- @param dump_path file to write the dumps to (overwritten)
function M.start(logger, dump_path)
    log_fn = logger
    if out then pcall(out.close, out); out = nil end
    local f, ferr = io.open(dump_path, "w")
    if not f then
        log_fn("indication debug: cannot write " .. tostring(dump_path) .. ": " .. tostring(ferr))
        return false
    end
    out = f
    pending, last_key, last_at, started_at, warned = {}, nil, -math.huge, nil, false
    local ok, err = indications.start(logger)
    if not ok then
        log_fn("indication debug: " .. tostring(err))
        running = false
        return false
    end
    log_fn("indication debug: listening on 127.0.0.1:" .. indications.PORT .. ", dumps go to " .. dump_path)
    running = true
    return true
end

function M.stop()
    running, pending = false, {}
    if out then pcall(out.close, out); out = nil end
    indications.stop()
end

local function is_pushbutton(text)
    text = tostring(text or "")
    return text:find("PB%s*%d+") or text:find("OSB") or text:find("[Pp]ush[Bb]utton")
end

local function write(s)
    out:write(s, "\n")
end

local function dump(label, now)
    log_fn(label)
    write(string.rep("=", 78) .. "\n" .. label)
    local ids = {}
    for id in pairs(indications.all()) do ids[#ids + 1] = id end
    table.sort(ids)
    local found = 0
    for _, id in ipairs(ids) do
        local e = indications.all()[id]
        if e.text ~= "" then
            found = found + 1
            write(string.format("\n### indicator %d (%d chars, received %.2f s ago)\n%s",
                id, #e.text, now - e.at, e.text))
        end
    end
    if found == 0 then
        write("no display text received" ..
            (indications.receiving() and "" or " (nothing from Export.lua yet)"))
    end
end

--- A control was reported (source = "input" or "cockpit").
function M.on_report(source, base, text, now)
    if not running or not is_pushbutton(text) then return end
    local key = tostring(base)
    if key == last_key and now - last_at <= M.config.dedupe_s then return end
    last_key, last_at = key, now
    seq = seq + 1
    local label = string.format("OSB DEBUG #%d [%s] %q", seq, source, tostring(text))
    dump(label .. " AT PRESS", now)
    pending[#pending + 1] = { at = now + M.config.after_s, label = label .. " AFTER" }
end

function M.frame(now)
    if not running then return end
    indications.poll(now)
    started_at = started_at or now
    if not warned and not indications.receiving() and now - started_at > M.config.no_link_warn_s then
        warned = true
        log_fn("indication debug: nothing received from Export.lua after " .. M.config.no_link_warn_s ..
            " s - is export_indications.lua loaded from Scripts/Export.lua?")
    end
    for i = #pending, 1, -1 do
        if now >= pending[i].at then
            local p = table.remove(pending, i)
            dump(p.label, now)
        end
    end
    if out then out:flush() end
end

return M
