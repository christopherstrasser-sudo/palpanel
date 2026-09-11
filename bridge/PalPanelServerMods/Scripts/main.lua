-- PalPanelServerMods v0.4.0 loader
-- Arena v2 step 6: exact first hit captures the live boss position as arena center.
-- Players already near the boss stay exactly where they are; only distant players
-- are moved, with a safe Z lift to avoid terrain embedding. The enlarged
-- TowerLockBarrier is spawned after a delay and its BarrierMesh + InteractableBox
-- collision are neutralized after bLocked=true. Server keep-in is authoritative.

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
loadModule("arena-v2-trigger-002.lua", "Arena v2 live-boss first-hit trigger")
loadModule("arena-v2-006.lua", "Arena v2 safe-ground conditional player placement + keep-in")
loadModule("arena-v2-visual-007.lua", "Arena v2 component-collision-neutralized TowerLockBarrier")

print("[PalPanelServerMods] v0.4.0 ready; first-hit safe-ground nonblocking raid arena active\n")
