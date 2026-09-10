-- PalPanelServerMods v0.2.15 loader
-- Server-only visible arena replication test using deferred AlwaysSpawn.
--
-- controller-023 gives the raid Pal the real wild controller while it is spawned.
-- combat-025 is observer-only and performs no forced AI/target calls.
-- arena-027 keeps the proven static authoritative keep-in/keep-out boundary.
-- arena-visual-005 uses BeginDeferredActorSpawnFromClass(AlwaysSpawn), enables
-- replication/relevancy before FinishSpawningActor, and fixes the v0.4 Lua
-- multi-return bug that discarded successful spawned actor references.
--
-- Deliberately NOT loaded anymore:
--   * arena-visual-001.lua (Pal BuildObject wall -> combat-start crash)
--   * arena-visual-002.lua (LegendDeer SkillEffect barrier -> raid-start crash)
--   * arena-visual-003.lua (post-spawn replication experiment)
--   * arena-visual-004.lua (actor-return bug in withBornReplication)

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

loadModule("controller-023.lua", "wild raid controller adapter 0.2.3")

local runtimeOk = loadModule("runtime-021.lua", "stable raid runtime 0.2.1")
if not runtimeOk then
    print("[PalPanelServerMods] Combat/arena modules skipped because the stable runtime did not load.\n")
    return
end

loadModule("combat-025.lua", "safe native-wild-AI observer 0.2.5")
loadModule("arena-027.lua", "static authoritative raid arena 0.2.7")
loadModule("arena-visual-005.lua", "deferred AlwaysSpawn server-only fire arena visual 0.5.0")

print("[PalPanelServerMods] v0.2.15 loader ready; deferred AlwaysSpawn server-only arena visual ENABLED\n")
