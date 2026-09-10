-- PalPanelServerMods v0.2.18 loader
-- Stable raid/combat plus one-marker direct PalNetworkTransmitter multicast probe.
--
-- controller-023 gives the raid Pal the real wild controller while it is spawned.
-- combat-025 is observer-only and performs no forced AI/target calls.
-- arena-027 keeps the proven static authoritative keep-in/keep-out boundary.
-- arena-visual-007 performs ONE delayed visual probe through the direct
-- SpawnedNonReliableActor_ToALL NetMulticast RPC. It avoids the crashing
-- SpawnNonReliableActorBroadcast wrapper/delegate path and keeps Owner and
-- NetworkOwner null, matching FNetworkActorSpawnParameters defaults.
--
-- Deliberately NOT loaded:
--   * arena-visual-001.lua (Pal BuildObject wall -> combat-start crash)
--   * arena-visual-002.lua (LegendDeer SkillEffect barrier -> raid-start crash)
--   * arena-visual-003.lua (post-spawn replication invisible)
--   * arena-visual-004.lua (actor-return bug)
--   * arena-visual-005.lua (32/32 server actors, client invisible)
--   * arena-visual-006.lua (SpawnNonReliableActorBroadcast wrapper -> native crash before first return)

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
loadModule("arena-visual-007.lua", "one-marker direct PalNetworkTransmitter multicast probe 0.7.0")

print("[PalPanelServerMods] v0.2.18 loader ready; one-marker direct multicast visual probe ENABLED\n")
