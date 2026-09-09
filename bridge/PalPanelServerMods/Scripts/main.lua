-- PalPanelServerMods v0.2.2 loader
-- Keeps the proven 0.2.1 raid runtime isolated and adds combat AI as a separate module.

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

local runtimeOk = loadModule("runtime-021.lua", "stable runtime 0.2.1")
if not runtimeOk then
    print("[PalPanelServerMods] Combat module skipped because the stable runtime did not load.\n")
    return
end

loadModule("combat-022.lua", "raid combat AI 0.2.2")
print("[PalPanelServerMods] v0.2.2 loader ready\n")