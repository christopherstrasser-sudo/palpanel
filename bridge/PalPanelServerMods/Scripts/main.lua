-- PalPanelServerMods v0.3.7 loader
-- Arena v2 step 3: the proven persistent TowerLockBarrier is now centered on
-- the resolved raid boss and enlarged once at spawn. Online players are placed
-- inside the boss-centered arena and the server-side keep-in remains authoritative.
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
loadModule("arena-v2-003.lua", "Arena v2 step 3 boss-centered player keep-in")
loadModule("arena-v2-visual-004.lua", "Arena v2 step 3 boss-centered enlarged TowerLockBarrier")

print("[PalPanelServerMods] v0.3.7 ready; boss-centered enlarged raid arena active\n")