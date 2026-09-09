-- PalPanelServerMods v0.2.3 loader
-- Preserves the proven 0.2.1 raid runtime, fixes raid spawns with the real
-- wild-pal combat controller, keeps combat AI isolated and adds an arena lock.

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

-- Must load before runtime-021: it wraps ExecuteInGameThread only while the
-- raid status is SPAWNING, temporarily swapping the NPC manager's generic
-- controller for BP_MonsterAIController_Wild_C and restoring it afterwards.
loadModule("controller-023.lua", "wild raid controller adapter 0.2.3")

local runtimeOk = loadModule("runtime-021.lua", "stable raid runtime 0.2.1")
if not runtimeOk then
    print("[PalPanelServerMods] Combat/arena modules skipped because the stable runtime did not load.\n")
    return
end

loadModule("combat-022.lua", "raid combat AI 0.2.2")
loadModule("arena-023.lua", "raid arena lock 0.2.3")
print("[PalPanelServerMods] v0.2.3 loader ready\n")