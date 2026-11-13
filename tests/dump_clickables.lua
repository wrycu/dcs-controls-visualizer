-- Usage: luajit tests/dump_clickables.lua "<DCS install>/Mods/aircraft/FA-18C/Cockpit/Scripts" [arg=value ...]
-- With arg=value pairs, prints what the overlay would show for that arg moving to that value.
package.path = "mod/Scripts/ControlsVisualizer/?.lua;" .. package.path
local clickables = require("clickables")

local dir = assert(arg[1], "pass the aircraft Cockpit/Scripts directory")
local args, count = clickables.load(dir)
if not args then
    io.stderr:write("FAILED: " .. tostring(count) .. "\n")
    os.exit(1)
end

if arg[2] then
    for i = 2, #arg do
        local a, v = arg[i]:match("^(%d+)=(%-?[%d.]+)$")
        local info = a and args[tonumber(a)]
        print(string.format("%-10s %s", arg[i], info and clickables.describe(info, tonumber(v)) or "(unknown arg)"))
    end
    os.exit(0)
end

local nums = {}
for a in pairs(args) do nums[#nums + 1] = a end
table.sort(nums)
for _, a in ipairs(nums) do
    local info = args[a]
    local extra = ""
    if info.positions then extra = " [" .. table.concat(info.positions, " | ") .. "]" end
    if #info.variants > 1 then
        local vs = {}
        for _, v in ipairs(info.variants) do vs[#vs + 1] = string.format("%.1f=%s", v.value, v.hint) end
        extra = " {" .. table.concat(vs, "; ") .. "}"
    end
    print(string.format("%5d %s %s%s%s", a, info.is_button and "btn" or "sw ",
        info.name, extra, info.commented and "  (commented)" or ""))
end
print(string.format("-- %d elements, %d args", count, #nums))
if clickables.last_warning then print("-- warning: " .. clickables.last_warning) end
