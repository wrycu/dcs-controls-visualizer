-- What a display pushbutton press did, once the display shows it: the Hornet
-- acts on release, so at the press the display still shows the old state.
--
--   "Left MDI PB 6 (1B)"    -> "Left MDI PB 6 (1B -> 2B)"     label changed
--   "Left MDI PB 11 (WYPT)" -> same text, with box { word = "WYPT", boxed = true }
--
-- Watches the display from `min_s` after the press until the button's label
-- or box changes on the same page, or `max_s` passes (then reports the box
-- state as it is). If the press switched pages, the line is left as it was.
-- While the button shows an option legend or nothing in place of its label
-- (the radar page scripts draw legends like PRF "HI MED INTL" there), it
-- waits up to `legend_s` for the label to come back.

local mfd_labels = require("mfd_labels")

local M = {}

M.config = {
    min_s = 0.05,
    max_s = 1.5,
    legend_s = 8,
    dedupe_s = 0.3, -- the same press reported by input and cockpit
}

local db, get_text = nil, nil
local pending = {}

function M.start(mfd_db, text_getter)
    db, get_text, pending = mfd_db, text_getter, {}
end

function M.stop() db, get_text, pending = nil, nil, {} end

--- A display pushbutton was reported.
-- @param control control name, e.g. "Left MDI PB 6"
-- @param shown   the text the feed shows for it now, e.g. "Left MDI PB 6 (1B)"
-- @param before  optional getter for the display text as it was when the
--                press began (default: the current text)
function M.press(control, shown, now, before)
    if not db then return end
    local id, pb, d = mfd_labels.match(db, control)
    if not id or d.element then return end -- UFC options: nothing to follow
    for _, p in ipairs(pending) do
        if p.control == control and now - p.at <= M.config.dedupe_s then return end
    end
    local text = (before or get_text)(id)
    if not text then return end
    local label, legend = mfd_labels.label(db, text, pb)
    if not label then return end
    pending[#pending + 1] = {
        control = control, shown = shown, id = id, pb = pb, at = now,
        label = label, legend = legend, boxed = mfd_labels.boxed(db, text, pb),
        page = mfd_labels.page_names(db, text, pb),
    }
end

-- Text and box state ({ word =, boxed = } or nil) after the press.
local function final_text(p, label, boxed)
    local l, word = p.label, p.label
    if label and p.legend then
        l, word = label, label -- pressed while a legend showed: just the result
    elseif label and label ~= p.label then
        l, word = p.label .. " -> " .. label, label
    end
    local box = nil
    if boxed ~= nil then box = { word = word, boxed = boxed } end
    return p.control .. " (" .. l .. ")", box
end

--- Call every frame. retext(old, new, now, box) updates a shown line.
function M.frame(now, retext)
    for i = #pending, 1, -1 do
        local p = pending[i]
        local age = now - p.at
        if age >= M.config.min_s then
            local text = get_text(p.id)
            local done, new, box = false, nil, nil
            if not text or not mfd_labels.same_page(p.page, mfd_labels.page_names(db, text, p.pb)) then
                done = true -- switched pages (or display gone): nothing to add
            else
                local label, legend = mfd_labels.label(db, text, p.pb)
                local boxed = mfd_labels.boxed(db, text, p.pb)
                if legend or not label then
                    -- legend (or nothing) in place of the label: wait for it
                    if age >= M.config.legend_s then done = true end
                elseif p.legend or label ~= p.label or boxed ~= p.boxed or age >= M.config.max_s then
                    done = true
                    new, box = final_text(p, label, boxed)
                end
            end
            if done then
                table.remove(pending, i)
                if new and (new ~= p.shown or box) then retext(p.shown, new, now, box) end
            end
        end
    end
end

return M
