-- PalPanelServerMods v0.3.3 loader
-- Arena v2 step 2A: proven technical keep-in remains untouched.
-- Adds only a read-only GUObjectArray discovery scan for vanilla arena/boundary visuals.

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
loadModule("arena-v2-discovery-001.lua", "Arena v2 step 2A GUObject visual discovery 0.2.0")

print("[PalPanelServerMods] v0.3.3 ready; stable keep-in + GUObject visual discovery active\n")