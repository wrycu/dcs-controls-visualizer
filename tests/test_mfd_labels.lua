-- Usage: luajit tests/test_mfd_labels.lua "<DCS install dir>/" [ControlsVisualizer-indications.log]
-- Loads the F/A-18C MFD page scripts, checks labels on a recorded HSI page,
-- and with a debug dump file (debug_indications = true), prints the label
-- for every press recorded in it.
package.path = "mod/Scripts/ControlsVisualizer/?.lua;" .. package.path
local mfd = require("mfd_labels")

local install = assert(arg[1], "pass the DCS install dir (with trailing slash)")
local t0 = os.clock()
local db, msg = mfd.load("FA-18C_hornet", install .. "Mods/aircraft/FA-18C/Cockpit/Scripts",
    install .. "Scripts/Aircrafts/_Common/Cockpit/")
assert(db, msg)
print(string.format("loaded: %s (%.2f s)", msg, os.clock() - t0))

local failures = 0
local function check(what, got, want)
    local ok = got == want
    if not ok then failures = failures + 1 end
    print(string.format("%s %-40s %s", ok and "ok  " or "FAIL", what, tostring(got) .. (ok and "" or ("  (want " .. tostring(want) .. ")"))))
end

-- Left MDI on the HSI page, as list_indication returned it (trimmed).
local SEP = "-----------------------------------------\n"
local function page(els)
    local parts = {}
    for _, e in ipairs(els) do parts[#parts + 1] = SEP .. e[1] .. "\n" .. e[2] .. "\n" end
    return table.concat(parts)
end
local hsi = page({
    { "MENU_1__id:1", "2155" },
    { "HSI_Main_Root_PB_1_5", "children are {" },
    { "VEC_1__id:1", "V\nE\nC" },
    { "MODE_1__id:3", "M\nO\nD\nE" },
    { "TCN_1__id:6", "T\nC\nN\n}" },
    { "_1__id:8", "POS/AINS" },
    { "_1__id:10", "SCL/40" },
    { "   _1__id:11", "MK1" },
    { "DATA_1__id:12", "DATA\n}" },
    { "WYPT_1__id:13", "W\nY\nP\nT" },
    { "WYPT_1_box__id:14", "" },
    { "Symbol_124-arrow-up_id:15", "" },
    { "Symbol_124-arrow-down_id:16", "" },
    { "WPDSG_1__id:17", "W\nP\nD\nS\nG" },
    { "AUTO_1__id:20", "AUTO" },
    { "SENSORS_1__id:26", "SENSORS\n}" },
})
check("HSI PB 11", mfd.label(db, hsi, 11), "WYPT")
check("HSI PB 12 (arrow)", mfd.label(db, hsi, 12), "WYPT up")
check("HSI PB 13 (arrow)", mfd.label(db, hsi, 13), "WYPT down")
check("HSI PB 14", mfd.label(db, hsi, 14), "WPDSG")
check("HSI PB 6 (runtime label)", mfd.label(db, hsi, 6), "POS/AINS")
check("HSI PB 9 (runtime label)", mfd.label(db, hsi, 9), "MK1")
check("HSI PB 18 (MENU)", mfd.label(db, hsi, 18), "MENU")
check("HSI PB 1 (nothing there)", mfd.label(db, hsi, 1), nil)
check("match Left MDI", select(2, mfd.match(db, "Left MDI PB 12")), 12)
check("match AMPCD id", (mfd.match(db, "AMPCD PB 3")), 4)
check("match other control", (mfd.match(db, "Master Arm Switch")), nil)

-- Box state: WYPT's box element is drawn in this dump (boxed); without it,
-- unboxed. DATA has no box at all.
local function without(text, part) -- plain-text removal (dashes are pattern characters)
    local i = text:find(part, 1, true)
    return i and (text:sub(1, i - 1) .. text:sub(i + #part)) or text
end
local hsi_unboxed = without(hsi, SEP .. "WYPT_1_box__id:14\n\n")
check("HSI PB 11 boxed", mfd.boxed(db, hsi, 11), true)
check("HSI PB 11 unboxed", mfd.boxed(db, hsi_unboxed, 11), false)
check("HSI PB 10 no box", mfd.boxed(db, hsi, 10), nil)
check("HSI PB 12 arrow no box", mfd.boxed(db, hsi, 12), nil)
check("same page", mfd.same_page(mfd.page_names(db, hsi_unboxed, 11), mfd.page_names(db, hsi, 11)), true)

-- Radar (RWS), trimmed: range arrows and mode are drawn at PB positions
-- directly; airspeed/Mach sit near PB 20 but aren't its label.
local radar = page({
    { "MENU_1__id:1", "2137" },
    { "Radar_mode", "RWS\n}" },
    { "AC_airspeed", "304\n}" },
    { "AC_Mach_symbol", "M" },
    { "AC_Mach_numerics", "0.54\n}" },
    { "PDI_1__id:1", "INTL\nchildren are {" },
    { "Instantaneous_PRF", "HI\n}" },
    { "1B_1__id:3", "1B\nchildren are {" },
    { "Elevation_bar_number", "1\n}\n}" },
    { "RDR_1__id:4", "R\nD\nR" },
    { "PRI_2__id:5", "P\nR\nI" },
    { "MODE_1__id:32", "MODE\n}\n}" },
    { "RangeIncrementArrow", "" },
    { "RangeDecrementArrow", "" },
    { "NCTR_1__id:26", "N\nC\nT\nR" },
})
check("RDR PB 11 (range arrow)", mfd.label(db, radar, 11), "Range up")
check("RDR PB 12 (range arrow)", mfd.label(db, radar, 12), "Range down")
check("RDR PB 5 (mode, by position)", mfd.label(db, radar, 5), "RWS")
check("RDR PB 1 (PRF, by position)", mfd.label(db, radar, 1), "INTL HI")
check("RDR PB 20 (no airspeed)", mfd.label(db, radar, 20), "MODE")
check("RDR PB 6 (no bar number)", mfd.label(db, radar, 6), "1B")
check("RDR PB 6 shows live bars", mfd.label(db, radar:gsub("1B\nchildren", "4B\nchildren"), 6), "4B")
-- Azimuth: each press steps the value in the element named after the default
local az = page({ { "AzimuthScan_Main", "" }, { "140°_1__id:31", " 20°" }, { "MODE_1__id:32", "MODE" } })
check("RDR PB 19 azimuth (live number)", mfd.label(db, az, 19), "20°")
check("RDR vs HSI not same page", mfd.same_page(mfd.page_names(db, radar, 6), mfd.page_names(db, hsi, 6)), false)

-- TAC menu: PB 18 shows the time where MENU was, and the menu title above it.
local tac = page({
    { "MENU_1__id:1", "2148" },
    { "HUD_1__id:2", "HUD" },
    { "SA_1__id:19", "SA" },
    { "TAC_id:23", "TAC" },
})
check("TAC menu PB 18", mfd.label(db, tac, 18), "MENU TAC")
check("TAC menu PB 13", mfd.label(db, tac, 13), "SA")
check("TAC menu PB 18 clock -> MENU", mfd.label(db, tac, 18), "MENU TAC")

-- UFC after A/P: option texts sit in fixed elements.
local ufc = page({
    { "UFC_MainDummy", "children are {" },
    { "UFC_OptionDisplay1", "ATTH" },
    { "UFC_OptionCueing1", "" },
    { "UFC_OptionDisplay3", "BALT" },
    { "UFC_OptionCueing3", ":" },
    { "UFC_OptionDisplay5", "" },
})
local function shown(id) return ({ [2] = hsi, [6] = ufc })[id] end
check("UFC option 3", mfd.label_for(db, "UFC Option Select Pushbutton 3", shown), "BALT")
check("UFC option 1", mfd.label_for(db, "UFC Option Select Pushbutton 1", shown), "ATTH")
check("UFC option 5 (blank)", mfd.label_for(db, "UFC Option Select Pushbutton 5", shown), nil)
check("label_for Left MDI PB 12", mfd.label_for(db, "Left MDI PB 12", shown), "WYPT up")
check("label_for display not seen yet", mfd.label_for(db, "AMPCD PB 3", shown), nil)
check("label_for other control", mfd.label_for(db, "Master Arm Switch", shown), nil)

-- Replay a debug dump: label at each press, from the display's text then.
if arg[2] then
    print("\nreplaying " .. arg[2])
    local src = assert(io.open(arg[2], "rb")):read("*a")
    for block in (src .. string.rep("=", 78)):gmatch("(OSB DEBUG.-)\n" .. string.rep("=", 78)) do
        local label = block:match("^OSB DEBUG [^\n]*")
        if label:find("AT PRESS") then
            local control = label:match('"([^"]+)"')
            if mfd.match(db, control) then
                local function from_dump(id)
                    return block:match("### indicator " .. id .. " %b()\n(.-)\n### ")
                        or block:match("### indicator " .. id .. " %b()\n(.*)$")
                end
                print(string.format("  %-55s -> %s", label:match("^OSB DEBUG (#%d+ %[%a+%] \"[^\"]+\")"),
                    tostring(mfd.label_for(db, control, from_dump))))
            end
        end
    end
end

if failures > 0 then print(failures .. " FAILED"); os.exit(1) end
print("all ok")
