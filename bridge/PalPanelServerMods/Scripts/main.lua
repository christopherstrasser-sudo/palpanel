-- PalPanelServerMods v0.2.5 loader
-- Preserves the proven 0.2.1 raid runtime, the 0.2.3 wild-controller fix and
-- the 0.2.4 first-hit combat AI. Arena v0.2.5 locks immediately when the raid
-- becomes ACTIVE and keeps gameplay enforcement independent from visual VFX.

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

-- Must load before runtime-021. It temporarily swaps the generic NPC controller
-- to BP_MonsterAIController_Wild_C only while the raid spawn task runs.
loadModule("controller-023.lua", "wild raid controller adapter 0.2.3")

local runtimeOk = loadModule("runtime-021.lua", "stable raid runtime 0.2.1")
if not runtimeOk then
    print("[PalPanelServerMods] Combat/arena modules skipped because the stable runtime did not load.\n")
    return
end

loadModule("combat-024.lua", "first-hit raid combat AI 0.2.4")
loadModule("arena-025.lua", "authoritative visible raid arena 0.2.5")
print("[PalPanelServerMods] v0.2.5 loader ready\n")
