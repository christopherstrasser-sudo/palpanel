-- PalPanelServerMods v0.3.8 loader
-- Arena v2 step 4: raid boss spawns normally with no arena. The exact first hit
-- on that raid boss arms the arena, returns the boss to the arena center, places
-- players safely well inside the wall, and only then spawns the enlarged barrier.
-- No repeated component visibility/replication mutations are used.

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
    print("[PalPanelServerMods] Remaining modules skipped because raid runtime failed to load.\n")
    return
end

loadModule("combat-025.lua", "raid combat observer")
loadModule("arena-v2-trigger-001.lua", "Arena v2 first-hit boss trigger")
loadModule("arena-v2-004.lua", "Arena v2 step 4 first-hit player placement + keep-in")
loadModule("arena-v2-visual-005.lua", "Arena v2 step 4 first-hit enlarged TowerLockBarrier")

print("[PalPanelServerMods] v0.3.8 ready; first-hit gated enlarged raid arena active\n")
