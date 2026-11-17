-- Names MFD pushbuttons (OSBs) by what their display shows next to them:
-- "Left MDI PB 12" -> "WYPT up" while the HSI page is up. Also the UFC
-- option buttons: "UFC Option Select Pushbutton 3" -> "BALT".
--
-- How (F/A-18C, found by experiment):
--  * Each display page is built by Lua scripts that create named elements;
--    pushbutton labels come from add_PB_label(n, ...) / add_PB_symbol(n, ...).
--    Element names are "<label>_<i>_<_id:N>", N counting per script file.
--  * We run those scripts in a sandbox (like clickables.lua) and record
--    which pushbutton number each element name belongs to.
--  * At runtime, list_indication(display) lists the elements currently
--    visible, with their text (sent over from Export.lua, see indications.lua).
--    The visible elements recorded for pushbutton n give its label.
--  * The Hornet acts on button release, so at the press the display still
--    shows the page the button was pressed on.
--
-- Pure Lua 5.1, no DCS APIs: works in the hook and in standalone LuaJIT.

local M = {}

-- Per aircraft: page list script, and control name pattern -> indicator id.
-- A display with `element` shows button n's text in one fixed element
-- (element name with %d = n) instead of on pages built from page scripts.
M.aircraft = {
    ["FA-18C_hornet"] = {
        init = "Multipurpose_Display_Group/Common/indicator/Common_init.lua",
        displays = {
            { pattern = "^Left MDI PB (%d+)", id = 2 },
            { pattern = "^Right MDI PB (%d+)", id = 3 },
            { pattern = "^AMPCD PB (%d+)", id = 4 },
            { pattern = "^UFC Option Select Pushbutton (%d+)", id = 6, element = "UFC_OptionDisplay%d" },
        },
    },
}

-- Helpers that place something next to a pushbutton: true = the pushbutton
-- number is their first argument, a number = always that pushbutton (the menu
-- page title "TAC"/"SUPT" is drawn just above PB 18, MENU).
local PB_HELPERS = { add_PB_label = true, add_PB_symbol = true, add_PB_label_RDR = true, addMenuLabel = 18 }

-- Text and symbols drawn this close to a pushbutton's label position (display
-- units; pushbuttons are ~168 apart) belong to it, e.g. the radar range
-- arrows, which are placed at PB_positions[11] directly. Only used for a
-- pushbutton showing no helper-made label: readouts (airspeed, fuel) also sit
-- near some labelled pushbuttons.
local NEAR_PB = 62
local POSITIONED_KINDS = { ceStringSLine = true, ceSMultiLine = true }

local ARROWS = { up = "up", down = "down", left = "left", right = "right" }

---------------------------------------------------------------- sandbox

local proxy_mt = {}
local function new_proxy(name) return setmetatable({ __proxy_name = name }, proxy_mt) end
proxy_mt.__index = function(t, k)
    local p = new_proxy(tostring(rawget(t, "__proxy_name")) .. "." .. tostring(k))
    rawset(t, k, p)
    return p
end
proxy_mt.__call = function(t) return new_proxy(rawget(t, "__proxy_name") .. "()") end
local function zero() return 0 end
proxy_mt.__add, proxy_mt.__sub, proxy_mt.__mul, proxy_mt.__div = zero, zero, zero, zero
proxy_mt.__unm, proxy_mt.__mod, proxy_mt.__pow = zero, zero, zero
proxy_mt.__lt = function() return false end
proxy_mt.__le = function() return false end
proxy_mt.__concat = function(a, b) return tostring(a) .. tostring(b) end
proxy_mt.__tostring = function(t) return rawget(t, "__proxy_name") end

local function is_proxy(v) return type(v) == "table" and getmetatable(v) == proxy_mt end

-- string.format that treats stand-ins as 0 (GetRenderTarget() etc.)
local safe_string = setmetatable({
    format = function(fmt, ...)
        local n, a = select("#", ...), { ... }
        for i = 1, n do if is_proxy(a[i]) then a[i] = 0 end end
        return string.format(fmt, unpack(a, 1, n))
    end,
}, { __index = string })

local function read_file(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    return s
end

local function num(v) return type(v) == "number" and v or 0 end

-- Option legends ("Layout" elements: the radar's azimuth widths "140 80 60
-- 40 20", PRF "HI\n\nMED\n\nINTL") are drawn beside the pushbutton that
-- steps through them, in place of its label, a little further out than labels.
local NEAR_PB_LEGEND = 150

-- Pushbutton nearest to each element, from its position (own init_pos plus
-- its parents'; controllers that move things at runtime are ignored).
local function assign_by_position(added, pb_positions)
    if type(pb_positions) ~= "table" then return end
    local by_name = {}
    for _, a in ipairs(added) do by_name[a.obj.name] = a.obj end
    local function abs_pos(o, depth)
        local p = type(o.init_pos) == "table" and o.init_pos or {}
        local x, y = num(p[1]), num(p[2])
        local parent = by_name[o.parent_element]
        if parent and parent ~= o and depth < 20 then
            local px, py = abs_pos(parent, depth + 1)
            x, y = x + px, y + py
        end
        return x, y
    end
    for _, a in ipairs(added) do
        if not a.pb and POSITIONED_KINDS[a.obj.kind] then
            local x, y = abs_pos(a.obj, 0)
            local legend = a.obj.name:find("Layout") ~= nil
            local best, best_d = nil, legend and NEAR_PB_LEGEND or NEAR_PB
            for n = 1, 20 do
                local q = pb_positions[n]
                if type(q) == "table" and type(q[1]) == "number" and type(q[2]) == "number" then
                    local d = math.sqrt((x - q[1]) ^ 2 + (y - q[2]) ^ 2)
                    if d < best_d then best, best_d = n, d end
                end
            end
            a.pb, a.layout = best, legend and best ~= nil or nil
        end
    end
end

-- Run one script (and what it dofile()s) in a fresh environment.
-- on_element(name, pb, by_position, legend) is called for every element
-- added, after the script has run; pb is the pushbutton it belongs to (placed
-- by a PB helper, or drawn at a pushbutton's position: by_position), else
-- nil; legend: an option legend shown in place of that pushbutton's label.
local function run(path, scripts_dir, common_dir, on_element, preset)
    local shadow = {} -- PB helpers live here so every (re)definition is wrapped
    local current_pb = nil
    local added = {}
    local env
    env = setmetatable({}, {
        __index = function(t, k)
            if shadow[k] then return shadow[k] end
            local v = _G[k]
            if v ~= nil then return v end
            local p = new_proxy(k)
            rawset(t, k, p)
            return p
        end,
        __newindex = function(t, k, v)
            if PB_HELPERS[k] and type(v) == "function" then
                local f, fixed = v, type(PB_HELPERS[k]) == "number" and PB_HELPERS[k] or nil
                shadow[k] = function(...)
                    local prev = current_pb
                    current_pb = fixed or (...)
                    local r = { pcall(f, ...) }
                    current_pb = prev
                    if r[1] then return unpack(r, 2) end
                end
                return
            end
            rawset(t, k, v)
        end,
    })
    env.LockOn_Options = { script_path = scripts_dir, common_script_path = common_dir }
    env.CreateElement = function(kind) return { kind = kind } end
    env.Copy = function(o) -- engine function: copy of an element
        local c = {}
        for key, val in pairs(type(o) == "table" and o or {}) do
            if type(val) == "table" and not is_proxy(val) then
                local t = {}
                for i, x in pairs(val) do t[i] = x end
                val = t
            end
            c[key] = val
        end
        return c
    end
    env.Add = function(o)
        if type(o) == "table" and type(o.name) == "string" then
            added[#added + 1] = { obj = o, pb = current_pb, helper = current_pb ~= nil }
        end
    end
    env.AddRender = function() end
    env.readParameter = function() return nil end
    env.print = function() end
    env.string = safe_string
    env._ = function(s) return s end
    env.require = function(name)
        if name == "i_18n" then return { translate = function(s) return s end } end
        local ok, mod = pcall(require, name)
        if ok then return mod end
        return new_proxy("require(" .. name .. ")")
    end
    env.dofile = function(p)
        local src = read_file(tostring(p))
        if not src then return end
        -- Lua 5.0-style varargs: these scripts read the implicit `arg` table
        -- (add_PB_label and others), which only some Lua 5.1 builds provide
        -- and LuaJIT doesn't. Define it in every vararg function.
        src = src:gsub("(function[%s%w_%.:]*%([^%)]*%.%.%.%s*%))", "%1 local arg = { n = select('#', ...), ... };")
        local chunk = loadstring(src, "@" .. tostring(p))
        if not chunk then return end
        setfenv(chunk, env)
        pcall(chunk)
    end
    for k, v in pairs(preset or {}) do env[k] = v end
    env.dofile(path)
    assign_by_position(added, rawget(env, "PB_positions"))
    for _, a in ipairs(added) do on_element(a.obj.name, a.pb, not a.helper, a.layout) end
    return env
end

---------------------------------------------------------------- loading

--- Build the element name -> pushbutton table for one aircraft.
-- @param unit_type DCS unit type
-- @param scripts_dir the aircraft's Cockpit/Scripts directory
-- @param common_dir <DCS>/Scripts/Aircrafts/_Common/Cockpit/
-- @return db, summary  or nil, reason
function M.load(unit_type, scripts_dir, common_dir)
    local ac = M.aircraft[unit_type]
    if not ac then return nil, "no MFD support for " .. tostring(unit_type) end
    if not scripts_dir:match("[/\\]$") then scripts_dir = scripts_dir .. "/" end

    -- Page script list: the page_subsets table Common_init.lua fills in
    -- (it errors further down, after that table is complete).
    local init_env = run(scripts_dir .. ac.init, scripts_dir, common_dir, function() end,
        { isHUD = false, isAMPCD = false })
    local subsets = rawget(init_env, "page_subsets")
    if type(subsets) ~= "table" then return nil, "no page list in " .. ac.init end
    local files, seen = {}, {}
    for _, p in pairs(subsets) do
        if type(p) == "string" and not seen[p] then seen[p] = true; files[#files + 1] = p end
    end
    table.sort(files)

    -- names[element name] = { [file index] = { pb =, by_position = } }
    local names, count = {}, 0
    for fi, f in ipairs(files) do
        run(f, scripts_dir, common_dir, function(name, pb, by_position, layout)
            if pb then
                local e = names[name]
                if not e then e = {}; names[name] = e end
                if e[fi] == nil then count = count + 1 end
                e[fi] = { pb = pb, by_position = by_position, layout = layout }
            end
        end, { isHUD = false, isAMPCD = false })
    end
    if count == 0 then return nil, "no pushbutton labels found in " .. #files .. " page scripts" end
    return { names = names, files = files, displays = ac.displays },
        string.format("%d pushbutton elements in %d page scripts", count, #files)
end

---------------------------------------------------------------- runtime

local SEP = "-----------------------------------------"

--- list_indication text -> { { name =, text = }, ... } in display order.
function M.parse_indication(text)
    local out, blocks = {}, {}
    text = tostring(text or "")
    local pos = 1
    while true do
        local s, e = text:find(SEP, pos, true)
        if not s then blocks[#blocks + 1] = text:sub(pos); break end
        blocks[#blocks + 1] = text:sub(pos, s - 1)
        pos = e + 1
    end
    table.remove(blocks, 1) -- before the first separator
    for _, block in ipairs(blocks) do
        local name, rest = block:gsub("^\n", ""):match("^([^\n]*)\n?(.*)$")
        if name and name ~= "" then
            local lines = {}
            for line in rest:gmatch("[^\n]+") do
                -- structure lines, not text
                if line ~= "}" and line ~= "children are {" then lines[#lines + 1] = line end
            end
            out[#out + 1] = { name = name, text = table.concat(lines, "\n") }
        end
    end
    return out
end

-- "WYPT_1__id:13" -> "WYPT"; "   _1__id:11" -> "" (label set at runtime)
local function static_label(name)
    if name:match("^Symbol_") then return nil end -- arrows etc.: see arrow_of
    if name:match("^(.-)_%d+_box__id:%d+$") then return nil end -- the box around a label
    local raw
    raw = name:match("^(.-)_%d+__id:%d+$") or name:match("^(.-)_id:%d+$")
    if not raw then return nil end
    return (raw:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Vertical labels come as one letter per line: "W\nY\nP\nT" -> "WYPT".
local function flatten(text)
    local lines = {}
    for l in text:gmatch("[^\n]+") do lines[#lines + 1] = l end
    local vertical = #lines > 1
    for _, l in ipairs(lines) do if #l > 1 then vertical = false end end
    local s = table.concat(lines, vertical and "" or " ")
    return (s:gsub("%s+", " "):gsub("^ ", ""):gsub(" $", ""))
end

-- Arrow elements: "Symbol_124-arrow-up_id:15" -> nil, "up" (generic: named
-- after a neighbouring label); "RangeIncrementArrow" -> "Range up", "up";
-- "MemoryInspectArrowDn" -> "Memory Inspect down", "down".
local ARROW_SUFFIXES = {
    { "IncrementArrow$", "up" }, { "DecrementArrow$", "down" },
    { "ArrowUp$", "up" }, { "ArrowDn$", "down" }, { "ArrowDown$", "down" },
}
local function arrow_info(name)
    local dir = name:match("^Symbol_.-arrow%-(%a+)_id:%d+$")
    if dir then return nil, ARROWS[dir] end
    for _, suf in ipairs(ARROW_SUFFIXES) do
        local stem = name:gsub(suf[1], "")
        if stem ~= name then
            stem = stem:gsub("_", " "):gsub("(%l)(%u)", "%1 %2"):gsub("^%s+", ""):gsub("%s+$", "")
            if stem == "" then return nil, suf[2] end
            return stem .. " " .. suf[2], suf[2]
        end
    end
end

-- Elements whose text is never a pushbutton label: boxes, lines, symbols,
-- cautions/advisories, own-aircraft readouts, ADI pitch ladder.
local NOT_LABELS = { "^Symbol_", "_box__id:%d+$", "[Aa]rrow", "[Bb]ox", "[Ll]ine", "[Dd]evider",
                     "^Caution", "^Advisor", "^AC_", "^ADI_" }
local function is_text_candidate(name)
    for _, pat in ipairs(NOT_LABELS) do if name:find(pat) then return false end end
    return true
end

-- Numbers alone ("0.54", "-6", "140°") next to a pushbutton are readouts.
local function is_readout(text)
    return text:match("^[%d%s%.%-+:/°]*$") ~= nil
end

-- Pushbuttons on the same display edge: 1-5, 6-10, 11-15, 16-20.
local function same_edge(a, b)
    return a >= 1 and b >= 1 and math.floor((a - 1) / 5) == math.floor((b - 1) / 5)
end

-- Visible elements per pushbutton: { [pb] = { { name, text, by_position, fi }, ... } }
local function group_by_pb(db, indication_text)
    local elements = M.parse_indication(indication_text)

    -- Which script files make up the current page: count visible elements.
    local score = {}
    for _, el in ipairs(elements) do
        local e = db.names[el.name]
        if e then for fi in pairs(e) do score[fi] = (score[fi] or 0) + 1 end end
    end

    -- Visible elements per pushbutton, each from the best-scoring file that
    -- has an element of that name.
    local by_pb = {}
    for _, el in ipairs(elements) do
        local e = db.names[el.name]
        if e then
            local best_fi, best_s = nil, -1
            for fi in pairs(e) do
                if score[fi] > best_s then best_fi, best_s = fi, score[fi] end
            end
            local entry = e[best_fi]
            local n = entry.pb
            by_pb[n] = by_pb[n] or {}
            table.insert(by_pb[n], { name = el.name, text = el.text, by_position = entry.by_position,
                                     layout = entry.layout, fi = best_fi })
        end
    end
    return by_pb
end

-- The box element that goes with a label element, if the page scripts made
-- one: "WYPT_1__id:13" -> "WYPT_1_box__id:14" (the next id in that file);
-- "TWS_AUTO_Label" -> "TWS_AUTO_Label_box".
local function box_name_for(name)
    local raw, i, id = name:match("^(.-)_(%d+)__id:(%d+)$")
    if raw then return raw .. "_" .. i .. "_box__id:" .. (tonumber(id) + 1) end
    return name .. "_box"
end

--- Names of the visible pushbutton elements, except pushbutton `except_pb`'s:
--- compare two of these with M.same_page.
function M.page_names(db, indication_text, except_pb)
    local set = {}
    for n, els in pairs(group_by_pb(db, indication_text)) do
        if n ~= except_pb then
            for _, el in ipairs(els) do set[el.name] = true end
        end
    end
    return set
end

--- Two page_names sets from the same page (labels on the other pushbuttons
--- mostly the same; a few may come and go, like box outlines).
function M.same_page(a, b)
    local na, nb, both = 0, 0, 0
    for k in pairs(a) do na = na + 1; if b[k] then both = both + 1 end end
    for _ in pairs(b) do nb = nb + 1 end
    local most = math.max(na, nb)
    return most == 0 or both / most >= 0.6
end

--- Whether pushbutton `pb`'s label is boxed (selected) on the display now.
-- @return true (boxed), false (has a box, not shown), nil (no box: can't tell)
function M.boxed(db, indication_text, pb)
    local mine = group_by_pb(db, indication_text)[pb] or {}
    local visible = {}
    for _, el in ipairs(mine) do visible[el.name] = true end
    local can_box = false
    for _, el in ipairs(mine) do
        if not el.name:find("[Bb]ox") then
            local box = box_name_for(el.name)
            local e = db.names[box]
            local entry = e and e[el.fi]
            if entry and entry.pb == pb then
                if visible[box] then return true end
                can_box = true
            end
        end
    end
    if can_box then return false end
    return nil
end

--- Label of pushbutton `pb` given one display's list_indication text.
-- @return e.g. "WYPT", "WYPT up", "POS/AINS", or nil; and true when it is an
--         option legend shown in place of the label ("140 80 60 40 20")
function M.label(db, indication_text, pb)
    local by_pb = group_by_pb(db, indication_text)

    local function text_of(n)
        -- an option legend is shown in place of the label
        for _, el in ipairs(by_pb[n] or {}) do
            if el.layout then
                local t = flatten(el.text)
                return t ~= "" and t or nil, true
            end
        end
        local parts = {}
        local has_helper_label = false
        for _, el in ipairs(by_pb[n] or {}) do
            if not el.by_position and static_label(el.name) then has_helper_label = true end
        end
        for _, el in ipairs(by_pb[n] or {}) do
          if not (el.by_position and has_helper_label) then
            local s = static_label(el.name)
            local t
            if el.by_position then
                -- drawn at the pushbutton: what it shows now, if it's a label
                if is_text_candidate(el.name) then
                    t = flatten(el.text)
                    if is_readout(t) then t = nil end
                end
            elseif s and s ~= "" then
                -- What's shown now ("2B" for the element named "1B_1__id:3",
                -- " 20°" for "140°_1__id:31"), unless that's a number where the
                -- name is a word: MENU shows the clock on menu pages.
                local live = flatten(el.text)
                local use_live = live ~= "" and (not is_readout(live) or is_readout(s))
                t = use_live and live or s
            elseif s == "" then
                t = flatten(el.text) -- label written at runtime
            end
            if t and t ~= "" then
                -- "TGT_2__id:22": line 2 of the label
                parts[#parts + 1] = { line = tonumber(el.name:match("_(%d+)__id:%d+$")) or 1, text = t }
            end
          end
        end
        if #parts == 0 then return nil end
        -- Bottom-edge labels (16-20) stack upward: line 2 is above line 1.
        local up = n >= 16 and n <= 20
        table.sort(parts, function(a, b)
            if up then return a.line > b.line end
            return a.line < b.line
        end)
        local out = {}
        for i, p in ipairs(parts) do out[i] = p.text end
        return table.concat(out, " ")
    end

    -- direction, and a full description when the element name gives one;
    -- nothing when arrows point both ways (a drawing, not a button arrow)
    local function arrow_of(n)
        local found_dir, found_phrase
        for _, el in ipairs(by_pb[n] or {}) do
            local phrase, dir = arrow_info(el.name)
            if dir then
                if found_dir and found_dir ~= dir then return nil end
                found_dir, found_phrase = dir, found_phrase or phrase
            end
        end
        return found_dir, found_phrase
    end

    local text, from_layout = text_of(pb)
    if from_layout then return text, true end
    local dir, phrase = arrow_of(pb)
    if phrase then return phrase end -- "Range up"
    if text then return text end
    if not dir then return nil end
    -- An arrow steps the nearest label on the same edge ("WYPT" next to
    -- the up/down arrows): look before it first, then after.
    for _, d in ipairs({ -1, -2, -3, 1, 2, 3 }) do
        local n = pb + d
        if same_edge(pb, n) and not arrow_of(n) then
            local t = text_of(n)
            if t then return t .. " " .. dir end
        end
    end
    return dir .. " arrow"
end

--- For a control name like "Left MDI PB 12": indicator id, pushbutton, display entry.
function M.match(db, control_name)
    for _, d in ipairs(db.displays) do
        local pb = tostring(control_name or ""):match(d.pattern)
        if pb then return d.id, tonumber(pb), d end
    end
end

--- Text of one named element in a list_indication dump, or nil.
function M.element_text(indication_text, name)
    for _, el in ipairs(M.parse_indication(indication_text)) do
        if el.name == name then
            local t = flatten(el.text)
            if t ~= "" then return t end
            return nil
        end
    end
end

--- What a control does right now, or nil if it's not a display button or
--- shows nothing.
-- @param get_text function(indicator id) -> current list_indication text or nil
function M.label_for(db, control_name, get_text)
    local id, pb, d = M.match(db, control_name)
    if not id then return nil end
    local shown = get_text(id)
    if not shown then return nil end
    if d.element then return M.element_text(shown, string.format(d.element, pb)) end
    return M.label(db, shown, pb)
end

--- Whether a display pushbutton's label is boxed right now: true, false, or
--- nil (not a page pushbutton, or its label has no box).
function M.boxed_for(db, control_name, get_text)
    local id, pb, d = M.match(db, control_name)
    if not id or d.element then return nil end
    local shown = get_text(id)
    if not shown then return nil end
    return M.boxed(db, shown, pb)
end

return M
