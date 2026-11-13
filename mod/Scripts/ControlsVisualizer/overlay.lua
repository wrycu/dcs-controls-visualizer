-- On-screen list of recent controls (dxgui window, like the SRS overlay).
-- Newest line at the bottom; controls still held are drawn in amber.

local M = {}

M.config = {
    x = 20,               -- px from the left edge of the screen
    bottom_margin = 220,  -- px from the bottom edge to the newest line
    width = 460,
    line_h = 26,
    max_lines = 6,
}

local window, box, statics, skins
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

--- Show these lines ({ text=, held= }, oldest first). Cheap when unchanged.
function M.show(lines)
    if not window then return end
    local parts = {}
    for i, l in ipairs(lines) do parts[i] = (l.held and "*" or "") .. l.text end
    local key = table.concat(parts, "\n")
    if key == last_key then return end
    last_key = key

    local c = M.config
    local n = math.min(#lines, c.max_lines)
    local wh = c.line_h * c.max_lines
    box:setBounds(0, wh - n * c.line_h, c.width, math.max(1, n * c.line_h))
    box:setVisible(n > 0)
    for i = 1, c.max_lines do
        local s = statics[i]
        local l = lines[#lines - n + i]
        if i <= n and l then
            s:setSkin(l.held and skins.held or skins.normal)
            s:setBounds(0, (i - 1) * c.line_h, c.width, c.line_h)
            s:setText(l.text)
            s:setVisible(true)
        else
            s:setText("")
            s:setVisible(false)
        end
    end
end

function M.clear() M.show({}) end

return M
