-- PalPanelServerMods v0.4.3 loader
-- Core raid modules + game-thread-only live UE4SS player-avatar data probe.

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

-- Independent read-only observer. All Unreal UObject access is explicitly
-- marshalled back onto the game thread; no save parser and no renderer invocation.
loadModule("avatar-001.lua", "game-thread-only live player avatar data probe")

print("[PalPanelServerMods] v0.4.3 ready\n")
