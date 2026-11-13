-- Cross-checks our switch position labels against DCS-BIOS's position lists.
-- Usage: luajit tests/check_dcsbios_positions.lua <DCS-BIOS aircraft module .lua> <aircraft Cockpit/Scripts dir>
-- DCS-BIOS lists positions from the lowest arg value to the highest.
package.path = "mod/Scripts/ControlsVisualizer/?.lua;" .. package.path
local clickables = require("clickables")

local bios_path = assert(arg[1], "pass the DCS-BIOS aircraft module file")
local scripts_dir = assert(arg[2], "pass the aircraft Cockpit/Scripts directory")

-- Load the DCS-BIOS module with everything stubbed, recording define* calls.
local proxy_mt = {}
local function proxy() return setmetatable({}, proxy_mt) end
proxy_mt.__index = function() return proxy() end
proxy_mt.__call = function() return proxy() end

local calls = {}
local recorder = setmetatable({}, {
    __index = function(_, method)
        return function(_, ...) calls[#calls + 1] = { method = method, args = { ... } } end
    end,
    __newindex = function() end, -- ignore the module's own helper definitions
})
local module_stub = { new = function() return recorder end }

local env = setmetatable({
    module = function() end,
    require = function(name)
        if name:match("%.Module$") then return module_stub end
        return proxy()
    end,
}, { __index = _G })
local chunk = assert(loadfile(bios_path))
setfenv(chunk, env)
chunk()

-- arg number and the arg value of each listed position, per define* type
local value_rules = {
    define3PosTumb = function(a) return a[4], function(k) return k - 2 end end,
    defineTumb = function(a) return a[4], function(k) return a[6][1] + a[5] * (k - 1) end end,
    defineMultipositionSwitch = function(a) return a[4], function(k) return a[6] * (k - 1) end end,
    defineRockerSwitch = function(a) return a[7], function(k) return k - 2 end end,
}

local function norm(s) return (s:upper():gsub("[^%w]", "")) end

local args = assert(clickables.load(scripts_dir))
local checked, ok_count, mismatches, skipped = 0, 0, {}, {}
for _, c in ipairs(calls) do
    local positions
    for _, v in ipairs(c.args) do
        if type(v) == "table" and getmetatable(v) ~= proxy_mt and v.positions then positions = v.positions end
    end
    if positions then
        local rule = value_rules[c.method]
        if not rule then
            skipped[#skipped + 1] = c.method .. " " .. tostring(c.args[1])
        else
            local arg_n, value_of = rule(c.args)
            local info = args[arg_n]
            for k, expected in ipairs(positions) do
                checked = checked + 1
                local value = value_of(k)
                local got = info and clickables.describe(info, value) or "(arg not loaded)"
                local label = got:match(":%s*(.+)$") or got
                local a, b = norm(label), norm(expected)
                if a ~= "" and (a:find(b, 1, true) or b:find(a, 1, true)) then
                    ok_count = ok_count + 1
                else
                    mismatches[#mismatches + 1] = string.format("%-22s arg %-4d value %5.2f  DCS-BIOS %-10q ours %q",
                        tostring(c.args[1]), arg_n, value, expected, got)
                end
            end
        end
    end
end

for _, m in ipairs(mismatches) do print("MISMATCH " .. m) end
for _, s in ipairs(skipped) do print("skipped  " .. s) end
print(string.format("-- %d/%d positions match DCS-BIOS", ok_count, checked))
os.exit(#mismatches == 0 and 0 or 1)
