-- Exercise the real updater's private release parser without networking or UI.
package.path = "./?.lua;" .. package.path
local object = { new = function(_, opts) return opts end }
package.preload["ui/uimanager"] = function() return {} end
package.preload["ui/widget/infomessage"] = function() return object end
package.preload["ui/widget/confirmbox"] = function() return object end
package.preload.logger = function() return {} end
package.preload.gettext = function() return function(s) return s end end

local source_path = os.getenv("UPDATER_NATIVE_SOURCE") or "grimmory_updater.lua"
local f = assert(io.open(source_path, "r"))
local source = f:read("*a"); f:close()
local load_source = loadstring or load
local function upvalue(fn, wanted, seen)
    seen = seen or {}
    if seen[fn] then return end
    seen[fn] = true
    for i = 1, 100 do
        local name, value = debug.getupvalue(fn, i)
        if not name then break end
        if name == wanted then return value end
        if type(value) == "function" then
            local found = upvalue(value, wanted, seen)
            if found then return found end
        end
    end
end

local known_old_failures = 0
for _, folder in ipairs({ "library-sync.koplugin", "grimmory-sync.koplugin" }) do
    -- The real updater uses its source path to choose its installation's asset.
    -- This is a chunk name only; no file is created in this fictitious directory.
    local updater = assert(load_source(source, "@/tmp/updater-fixture/plugins/" .. folder .. "/grimmory_updater.lua"))()
    local parse = assert(upvalue(updater._checkNow, "parseRelease"))
    local greater = assert(upvalue(updater._checkNow, "versionGreaterThan"))
    assert(greater("0.7.6", "0.7.5") and not greater("0.7.6", "0.7.6"))
    local expected = "https://example.invalid/" .. folder .. ".zip"
    local data = { tag_name = "v0.7.6", body = "**New release**", assets = {
        { name = "library-sync.koplugin.zip.sha256", browser_download_url = "https://example.invalid/library-sync.koplugin.zip.sha256" },
        { name = "grimmory-sync.koplugin.zip", browser_download_url = "https://example.invalid/grimmory-sync.koplugin.zip" },
        { name = "library-sync.koplugin.zip", browser_download_url = "https://example.invalid/library-sync.koplugin.zip" },
    } }
    package.loaded.json = nil
    package.preload.json = function() return { decode = function() return data end } end
    local decoded = assert(parse("{}"))
    assert(decoded.version == "0.7.6" and decoded.download_url == expected)

    package.loaded.json = nil
    package.preload.json = function() error("JSON intentionally unavailable in fallback contract") end
    for _, order in ipairs({ {1, 2, 3}, {1, 3, 2} }) do
        local entries = {}
        for _, index in ipairs(order) do
            entries[#entries + 1] = '{"browser_download_url":"' .. data.assets[index].browser_download_url .. '"}'
        end
        local payload = '{"tag_name":"v0.7.6","assets":[' .. table.concat(entries, ",") .. ']}'
        local fallback = assert(parse(payload))
        if os.getenv("UPDATER_EXPECT_OLD_FAILURE") then
            if fallback.download_url ~= expected then known_old_failures = known_old_failures + 1 end
        else
            assert(fallback.download_url == expected, folder .. " selected " .. tostring(fallback.download_url))
            local escaped = assert(parse(payload:gsub("/", "\\/")))
            assert(escaped.download_url == expected, "escaped URL was not decoded")
        end
    end
end
if os.getenv("UPDATER_EXPECT_OLD_FAILURE") then
    assert(known_old_failures > 0, "previous updater defect was not reproduced")
    print("Previous updater: JSON path passes; expected fallback asset-selection defect reproduced")
else
    print("Updater release contracts passed: canonical/legacy, JSON/fallback, both asset orders, checksum exclusion, escaped URLs")
end
