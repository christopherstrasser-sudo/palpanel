-- PalPanelServerMods v0.3.5 loader
-- Arena v2 step 2C: proven 3500-unit technical keep-in remains untouched.
-- The replicated TowerLockBarrier probe is retained, but its BarrierMesh is now
-- explicitly replicated/unhidden and reasserted while the raid is ACTIVE.
-- A targeted LockedObstacle/TowerLockBarrier UFunction scan is written into the
-- visual status file for state-level follow-up without changing raid gameplay.

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
loadModule("arena-v2-002.lua", "Arena v2 step 1 minimal keep-in")
loadModule("arena-v2-visual-002.lua", "Arena v2 step 2C TowerLockBarrier visibility retention")

print("[PalPanelServerMods] v0.3.5 ready; stable keep-in + TowerLockBarrier visibility retention active\n")