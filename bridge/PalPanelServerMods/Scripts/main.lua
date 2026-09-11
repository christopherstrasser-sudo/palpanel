-- PalPanelServerMods v0.3.9 loader
-- Arena v2 step 5: the exact first hit on the raid boss captures the boss's LIVE
-- position as arena center. Players are placed on a compact safe ring first; the
-- enlarged TowerLockBarrier appears one second later with actor collision disabled.
-- The server-side keep-in remains the authoritative boundary.

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
loadModule("arena-v2-005.lua", "Arena v2 safe first-hit player placement + keep-in")
loadModule("arena-v2-visual-006.lua", "Arena v2 delayed nonblocking enlarged TowerLockBarrier")

print("[PalPanelServerMods] v0.3.9 ready; live-boss centered nonblocking first-hit arena active\n")
