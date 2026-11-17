-- Runs in DCS's export environment (loaded from Scripts/Export.lua), the only
-- place list_indication() is available, and sends cockpit display text to the
-- ControlsVisualizer hook over local UDP (see indications.lua).
--
-- Add this line to Saved Games/DCS/Scripts/Export.lua:
--   pcall(function() local lfs=require('lfs'); dofile(lfs.writedir()..'Scripts/ControlsVisualizer/export_indications.lua') end)
--
-- Datagrams: "CVIND2\n<indicator id>\n<serial>\n<part>/<parts>\n<text chunk>".
-- LuaSocket receives at most 8192 bytes per datagram, and a busy display
-- (the F/A-18C SA page) is bigger, so text is sent in chunks the hook joins.
-- A display is sent when its text changes, and all of them every `resend_s`
-- so a hook that (re)started late catches up.

local CV_PORT = 47833
local CV_MAX_ID = 30
local CV_INTERVAL_S = 0.1
local CV_RESEND_S = 1.0
local CV_MAX_LEN = 200000 -- longer display text is cut
local CV_CHUNK = 7000     -- bytes of text per datagram (receive limit 8192)

local ok_init, init_err = pcall(function()
    package.path = package.path .. ";.\\LuaSocket\\?.lua"
    package.cpath = package.cpath .. ";.\\LuaSocket\\?.dll"
    local socket = require("socket")

    local udp = nil
    local last = {}           -- id -> text last sent
    local serial = 0

    local function send(id, text)
        serial = (serial + 1) % 1000000
        local parts = math.max(1, math.ceil(#text / CV_CHUNK))
        for i = 1, parts do
            udp:sendto("CVIND2\n" .. id .. "\n" .. serial .. "\n" .. i .. "/" .. parts .. "\n"
                .. text:sub((i - 1) * CV_CHUNK + 1, i * CV_CHUNK), "127.0.0.1", CV_PORT)
        end
    end
    local next_poll, next_resend = 0, 0

    local function send_all(force)
        for id = 0, CV_MAX_ID do
            local ok, text = pcall(list_indication, id)
            if ok and type(text) == "string" and (force or text ~= last[id]) then
                -- Empty displays are only sent once they've had text, so the
                -- hook sees a display go blank.
                if text ~= "" or last[id] then
                    last[id] = text
                    if #text > CV_MAX_LEN then text = text:sub(1, CV_MAX_LEN) end
                    send(id, text)
                end
            end
        end
    end

    local function frame()
        local t = socket.gettime()
        if t < next_poll then return end
        next_poll = t + CV_INTERVAL_S
        if not udp then
            udp = socket.udp()
            udp:settimeout(0)
        end
        local force = t >= next_resend
        if force then next_resend = t + CV_RESEND_S end
        send_all(force)
    end

    local prev_after = LuaExportAfterNextFrame
    LuaExportAfterNextFrame = function()
        pcall(frame)
        if prev_after then prev_after() end
    end

    local prev_stop = LuaExportStop
    LuaExportStop = function()
        if udp then pcall(function() udp:close() end) end
        udp, last = nil, {}
        if prev_stop then prev_stop() end
    end
end)

if not ok_init and log and log.write then
    log.write("ControlsVisualizer", log.ERROR, "export_indications: " .. tostring(init_err))
end
