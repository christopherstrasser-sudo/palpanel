-- PalPanelServerMods v0.2.9 loader
-- Stability + replicated arena fallback build.
--
-- controller-023 still gives the raid Pal the real wild controller while it is
-- spawned. combat-025 is observer-only and performs no forced AI/target calls.
-- arena-027 keeps the proven static authoritative keep-in/keep-out boundary.
-- arena-visual-001 adds a separate client-visible ring using replicated ordinary
-- Palworld build-wall actors because the native AreaBarrier Niagara does not
-- present on normal clients when spawned by the dedicated server.

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

loadModule("combat-025.lua", "safe native-wild-AI observer 0.2.5")
loadModule("arena-027.lua", "static authoritative raid arena 0.2.7")
loadModule("arena-visual-001.lua", "replicated build-wall arena visual 0.1.0")
print("[PalPanelServerMods] v0.2.9 loader ready\n")
