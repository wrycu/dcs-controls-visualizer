-- On-screen list of recent controls (dxgui window, like the SRS overlay).
-- Newest line at the bottom; controls still held are drawn in amber.
-- A line's `box` ({ word =, boxed = }) draws a frame around that word, like
-- the MFD does: solid when the option is boxed, dashed when it isn't.

local M = {}

M.config = {
    x = 20,               -- px from the left edge of the screen
    bottom_margin = 220,  -- px from the bottom edge to the newest line
    width = 460,
    line_h = 26,
    max_lines = 6,
    text_offset = 10,     -- the line skins' horzAlign offset
    box_pad = 3,          -- px between the word and its frame
    box_inset = 3,        -- px from the line's top/bottom to the frame
    border = 1,           -- frame thickness
    dash = 3, gap = 3,    -- dashed frame
}

local window, box, statics, skins
local measure            -- hidden Static for text widths
local edges = {}         -- pool of frame segments (Panels)
local edge_skins
local last_key = nil

--- Create the window (once per DCS session). Returns true, or nil and an error.
-- @param hotkey e.g. "Ctrl+Shift+V" (dxgui format), calls on_hotkey; optional
function M.create(dlg_path, hotkey, on_hotkey)
    if window then M.place(); return true end
    local ok, err = pcall(function()
        local DialogLoader = require("DialogLoader")
        local Static = require("Static")
        window = DialogLoader.spawnDialogFromFile(dlg_path, {})
        -- No title bar: the chat window's minimal skin has headerHeight 0
        -- (the SRS overlay uses it the same way).
        local Skin = require("Skin")
        if Skin and Skin.windowSkinChatMin then window:setSkin(Skin.windowSkinChatMin()) end
        box = window.Box
        skins = { normal = window.LineNormal:getSkin(), held = window.LineHeld:getSkin() }
        edge_skins = { normal = window.EdgeNormal:getSkin(), held = window.EdgeHeld:getSkin() }
        measure = Static.new()
        measure:setSkin(skins.normal)
        edges = {}
        statics = {}
        for i = 1, M.config.max_lines do
            local s = Static.new()
            s:setSkin(skins.normal)
            s:setVisible(false)
            box:insertWidget(s)
            statics[i] = s
        end
        M.place()
        window:setVisible(true) -- keep it visible; hide the box instead
        if hotkey and on_hotkey then window:addHotKeyCallback(hotkey, on_hotkey) end
    end)
    if not ok then window = nil; return nil, err end
    return true
end

--- Position the window from the current screen size.
function M.place()
    local c = M.config
    local _, h = require("dxgui").GetWindowSize()
    local wh = c.line_h * c.max_lines
    window:setBounds(c.x, math.max(0, h - c.bottom_margin - wh), c.width, wh)
    last_key = nil
end

function M.available() return window ~= nil end

local function text_w(s)
    measure:setText(s)
    return (measure:calcSize()) or 0
end

local function last_find(text, word)
    local at, i = nil, 0
    while true do
        i = text:find(word, i + 1, true)
        if not i then return at end
        at = i
    end
end

-- Left edge and width of the last `word` in `text`, as a line Static draws it
-- (differences of measured widths, so the skin's own offsets cancel out).
local function word_span(text, word)
    local i = word and word ~= "" and last_find(text, word)
    if not i then return nil end
    local ref = text_w("X")
    local before = text_w("X" .. text:sub(1, i - 1)) - ref
    local width = text_w("X" .. text:sub(1, i - 1) .. word) - ref - before
    if width <= 0 then return nil end
    return M.config.text_offset + before, width
end

local function segment(n, x, y, w, h, skin)
    local p = edges[n]
    if not p then
        p = require("Panel").new()
        box:insertWidget(p)
        edges[n] = p
    end
    p:setSkin(skin)
    p:setBounds(x, y, math.max(1, w), math.max(1, h))
    p:setVisible(true)
end

-- Frame segments from pool index n + 1 on; returns the last index used.
local function frame(n, x, y, w, h, dashed, skin)
    local c = M.config
    local t = c.border
    local step = dashed and (c.dash + c.gap) or math.huge
    local function run(from, len, draw)
        local o = 0
        while o < len do
            local l = dashed and math.min(c.dash, len - o) or len
            n = n + 1
            draw(from + o, l)
            o = o + step
        end
    end
    run(x, w, function(a, l) segment(n, a, y, l, t, skin) end)
    run(x, w, function(a, l) segment(n, a, y + h - t, l, t, skin) end)
    run(y + t, h - 2 * t, function(a, l) segment(n, x, a, t, l, skin) end)
    run(y + t, h - 2 * t, function(a, l) segment(n, x + w - t, a, t, l, skin) end)
    return n
end

-- Text for a line whose frame can't be drawn.
local function with_box_words(l)
    if not l.box then return l.text end
    return l.text .. (l.box.boxed and " (boxed)" or " (unboxed)")
end

--- Show these lines ({ text=, held= }, oldest first). Cheap when unchanged.
function M.show(lines)
    if not window then return end
    local parts = {}
    for i, l in ipairs(lines) do
        parts[i] = (l.held and "*" or "") .. l.text
            .. (l.box and ("\0" .. l.box.word .. (l.box.boxed and "\1" or "\2")) or "")
    end
    local key = table.concat(parts, "\n")
    if key == last_key then return end
    last_key = key

    local c = M.config
    local n = math.min(#lines, c.max_lines)
    local wh = c.line_h * c.max_lines
    box:setBounds(0, wh - n * c.line_h, c.width, math.max(1, n * c.line_h))
    box:setVisible(n > 0)
    local used = 0
    for i = 1, c.max_lines do
        local s = statics[i]
        local l = lines[#lines - n + i]
        if i <= n and l then
            local text = l.text
            if l.box then
                local ok, x, w = pcall(word_span, l.text, l.box.word)
                local drawn = nil
                if ok and x then
                    local p, y = c.box_pad, (i - 1) * c.line_h
                    local fok, n = pcall(frame, used, x - p, y + c.box_inset, w + 2 * p,
                        c.line_h - 2 * c.box_inset, not l.box.boxed,
                        l.held and edge_skins.held or edge_skins.normal)
                    if fok then used, drawn = n, true end
                end
                if not drawn then
                    text = with_box_words(l)
                end
            end
            s:setSkin(l.held and skins.held or skins.normal)
            s:setBounds(0, (i - 1) * c.line_h, c.width, c.line_h)
            s:setText(text)
            s:setVisible(true)
        else
            s:setText("")
            s:setVisible(false)
        end
    end
    for j = used + 1, #edges do edges[j]:setVisible(false) end
end

M.with_box_words = with_box_words

function M.clear() M.show({}) end

return M
