-- Receives cockpit display text from export_indications.lua (which runs in
-- the export environment: hooks can't call list_indication themselves).

local M = {}

M.PORT = 47833

local socket, udp, log_fn
local texts = {}  -- indicator id -> { text =, at = }
local history = {} -- indicator id -> { {text =, at =}, ... } changes, oldest first
local chunks = {}  -- indicator id -> datagram parts of the text being received

M.history_s = 5
local link_up = false

--- Bind the local UDP port. Returns true, or nil and a reason.
function M.start(logger)
    log_fn = logger
    if udp then return true end -- kept bound across flights
    local ok, s = pcall(function()
        package.path = package.path .. ";.\\LuaSocket\\?.lua"
        package.cpath = package.cpath .. ";.\\LuaSocket\\?.dll"
        return require("socket")
    end)
    if not ok then return nil, "LuaSocket unavailable: " .. tostring(s) end
    socket = s
    local u = socket.udp()
    local bok, berr = u:setsockname("127.0.0.1", M.PORT)
    if not bok then
        u:close()
        return nil, "cannot bind 127.0.0.1:" .. M.PORT .. ": " .. tostring(berr)
    end
    u:settimeout(0)
    udp = u
    return true
end

function M.stop()
    texts, history, chunks, link_up = {}, {}, {}, false
end

--- Read all pending datagrams. Call every frame.
function M.poll(now)
    if not udp then return end
    for _ = 1, 200 do
        local data = udp:receive(8192)
        if not data then break end
        local id, text = data:match("^CVIND1\n(%d+)\n(.*)$") -- older export script
        if not id then
            local cid, serial, part, parts, chunk = data:match("^CVIND2\n(%d+)\n(%d+)\n(%d+)/(%d+)\n(.*)$")
            if cid then
                part, parts = tonumber(part), tonumber(parts)
                local c = chunks[cid]
                if not c or c.serial ~= serial then
                    c = { serial = serial, parts = parts, got = 0, list = {} }
                    chunks[cid] = c
                end
                if not c.list[part] then c.list[part], c.got = chunk, c.got + 1 end
                if c.got == c.parts then
                    id, text = cid, table.concat(c.list, "", 1, c.parts)
                    chunks[cid] = nil
                end
            end
        end
        if id then
            if not link_up then
                link_up = true
                if log_fn then log_fn("indications: receiving display text from Export.lua") end
            end
            id = tonumber(id)
            texts[id] = { text = text, at = now }
            local h = history[id]
            if not h then h = {}; history[id] = h end
            if not h[#h] or h[#h].text ~= text then h[#h + 1] = { text = text, at = now } end
            while #h > 1 and now - h[2].at > M.history_s do table.remove(h, 1) end
        end
    end
end

function M.receiving() return link_up end

--- Latest text per indicator id: { [id] = { text =, at = } }.
function M.all() return texts end

function M.get(id)
    local t = texts[id]
    return t and t.text
end

--- Text indicator `id` showed at time `t` (as received): the newest change
--- at or before t, or the oldest known if t is older than the history.
function M.get_at(id, t)
    local h = history[id]
    if not h or #h == 0 then return M.get(id) end
    for i = #h, 1, -1 do
        if h[i].at <= t then return h[i].text end
    end
    return h[1].text
end

return M
