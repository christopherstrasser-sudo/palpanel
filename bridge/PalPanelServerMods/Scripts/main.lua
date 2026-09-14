-- PalPanelServerMods v0.4.2 loader
-- Core raid modules + live UE4SS player-avatar data probe.

local function scriptDir()
    local src = debug.getinfo(1, "S").source
    src = src:match("^@(.+)$") or src
    return src:match("^(.+)\\[^\\]+$")
end

local scriptsDir = scriptDir()
if not scriptsDir then
    print("[PalPanelServerMods] ERROR: Scripts directory unavailable\n")
    return
end

local function loadModule(file, label)
    local path = scriptsDir .. "\\" .. file
    local ok, err = pcall(dofile, path)
    if ok then
        print(string.format("[PalPanelServerMods] %s loaded\n", label))
        return true
    end
    print(string.format("[PalPanelServerMods] %s FAILED: %s\n", label, tostring(err)))
    return false
end

loadModule("controller-023.lua", "raid controller adapter")

local runtimeOk = loadModule("runtime-021.lua", "raid runtime")
if not runtimeOk then
    print("[PalPanelServerMods] Raid combat module skipped because raid runtime failed to load.\n")
else
    loadModule("combat-025.lua", "raid combat observer")
end

-- Independent observer: reads live character creation data only. No save parser,
-- no player mutation and no portrait render invocation in this first probe.
loadModule("avatar-001.lua", "live player avatar data probe")

print("[PalPanelServerMods] v0.4.2 ready\n")
