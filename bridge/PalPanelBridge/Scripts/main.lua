-- PalPanelBridge v0.2.5 loader
-- Keep the UE4SS entrypoint tiny so the stable implementation can be versioned
-- independently and rolled back without mixing old delayed hook code.

local function scriptDir()
    local src = debug.getinfo(1, "S").source
    src = src:match("^@(.+)$") or src
    return src:match("^(.+)\\[^\\]+$")
end

local scriptsDir = scriptDir()
if not scriptsDir then
    print("[PalPanelBridge] ERROR: Scripts directory unavailable\n")
    return
end

local path = scriptsDir .. "\\bridge-025.lua"
local ok, err = pcall(dofile, path)
if not ok then
    print("[PalPanelBridge] bridge-025.lua FAILED: " .. tostring(err) .. "\n")
end
