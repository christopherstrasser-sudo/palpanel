-- PalPanelServerMods Arena v2 visual discovery / v0.1.0
-- SERVER-ONLY / NO CLIENT MOD.
--
-- Read-only discovery pass for Arena v2 step 2A.
-- This module does NOT spawn actors, NPCs or effects and performs no gameplay/world mutation.
-- It only inspects already-loaded BlueprintGeneratedClasses and the cooked AssetRegistry
-- for likely arena/boundary visual assets, then writes ranked candidates to IPC.

local MOD = "PalPanelArenaV2Discovery"
local VERSION = "0.1.0"
local START_DELAY_MS = 5000
local MAX_RESULTS = 100

local ROOTS = {
    "/Game/Pal/Blueprint/MapObject",
    "/Game/Pal/Blueprint/LevelObject",
    "/Game/Pal/Blueprint"
}

local KEYWORDS = {
    { text = "arena", weight = 12 },
    { text = "barrier", weight = 12 },
    { text = "boundary", weight = 10 },
    { text = "fence", weight = 7 },
    { text = "wall", weight = 5 },
    { text = "gate", weight = 5 },
    { text = "niagara", weight = 4 },
    { text = "effect", weight = 3 },
    { text = "light", weight = 2 },
    { text = "beam", weight = 3 },
    { text = "pillar", weight = 3 },
    { text = "field", weight = 1 }
}

local function log(msg)
    print(string.format("[%s] %s\n", MOD, tostring(msg)))
end

local function scriptDir()
    local src = debug.getinfo(1, "S").source
    src = src:match("^@(.+)$") or src
    return src:match("^(.+)\\[^\\]+$")
end

local function readAll(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    return s
end

local function writeAll(path, content)
    local tmp = path .. ".tmp"
    local f = io.open(tmp, "wb")
    if not f then return false end
    f:write(content)
    f:close()
    os.remove(path)
    return os.rename(tmp, path) ~= nil
end

local function urlEncode(value)
    value = tostring(value or "")
    return (value:gsub("([^%w%-%._~])", function(c)
        return string.format("%%%02X", string.byte(c))
    end))
end

local function unwrap(value)
    if value == nil then return nil end
    local ok, inner = pcall(function() return value:get() end)
    if ok and inner ~= nil then return inner end
    return value
end

local function valid(obj)
    obj = unwrap(obj)
    if obj == nil then return false end
    local addrOk, addr = pcall(function() return obj:GetAddress() end)
    if addrOk and tonumber(addr) == 0 then return false end
    local ok, result = pcall(function() return obj:IsValid() end)
    return ok and result == true
end

local function member(obj, name)
    obj = unwrap(obj)
    if obj == nil then return nil end
    local ok, value = pcall(function() return obj[name] end)
    if not ok then return nil end
    return unwrap(value)
end

local function toText(value)
    value = unwrap(value)
    if value == nil then return "" end
    if type(value) == "string" then return value end
    local ok, text = pcall(function() return value:ToString() end)
    if ok and type(text) == "string" and text ~= "" then return text end
    local ok2, text2 = pcall(tostring, value)
    if ok2 and type(text2) == "string" then return text2 end
    return ""
end

local function objectPath(obj)
    obj = unwrap(obj)
    if not valid(obj) then return "" end
    local value = ""
    pcall(function() value = obj:GetPathName() end)
    if type(value) == "string" and value ~= "" then return value end
    pcall(function() value = obj:GetFullName() end)
    return type(value) == "string" and value or ""
end

local scriptsDir = scriptDir()
if not scriptsDir then
    log("Scripts directory unavailable; discovery disabled")
    return
end
local modDir = scriptsDir:match("^(.+)\\Scripts$") or scriptsDir
local ipcDir = readAll(modDir .. "\\ipc_path.txt")
if ipcDir then ipcDir = ipcDir:gsub("[\r\n]+$", "") end
if not ipcDir or ipcDir == "" then
    log("ipc_path.txt unavailable; discovery disabled")
    return
end

local outputFile = ipcDir .. "\\raid-arena-v2-visual-discovery.txt"
local candidates = {}
local seen = {}
local assetsSeen = 0
local loadedClassesSeen = 0
local registryReady = false
local scanComplete = false
local rootsScanned = 0
local lastError = ""

local function scoreCandidate(name, packageName, classText)
    local hay = string.lower(table.concat({ tostring(name or ""), tostring(packageName or ""), tostring(classText or "") }, " "))
    local score = 0
    local matched = {}
    for _, kw in ipairs(KEYWORDS) do
        if hay:find(kw.text, 1, true) then
            score = score + kw.weight
            matched[#matched + 1] = kw.text
        end
    end
    return score, table.concat(matched, ",")
end

local function addCandidate(source, name, packageName, classText)
    name = tostring(name or "")
    packageName = tostring(packageName or "")
    classText = tostring(classText or "")
    local score, matched = scoreCandidate(name, packageName, classText)
    if score <= 0 then return end
    local key = string.lower(packageName ~= "" and packageName or (classText ~= "" and classText or name))
    if key == "" then return end

    local existing = seen[key]
    if existing then
        if score > existing.score then
            existing.score = score
            existing.matched = matched
        end
        if existing.source ~= source and not existing.source:find(source, 1, true) then
            existing.source = existing.source .. "+" .. source
        end
        return
    end

    local row = {
        source = source,
        name = name,
        package = packageName,
        class = classText,
        score = score,
        matched = matched
    }
    seen[key] = row
    candidates[#candidates + 1] = row
end

local function inspectLoadedClasses()
    local classes = nil
    local ok, result = pcall(function() return FindAllOf("BlueprintGeneratedClass") end)
    if ok then classes = result end
    if type(classes) ~= "table" then return end

    for _, raw in ipairs(classes) do
        local class = unwrap(raw)
        if valid(class) then
            loadedClassesSeen = loadedClassesSeen + 1
            local name = toText(member(class, "ClassGeneratedBy"))
            local fname = ""
            pcall(function() fname = toText(class:GetFName()) end)
            local path = objectPath(class)
            addCandidate("loaded_class", fname ~= "" and fname or name, path, fname)
        end
    end
end

local function getRegistry()
    local helpers = nil
    pcall(function()
        helpers = StaticFindObject("/Script/AssetRegistry.Default__AssetRegistryHelpers")
    end)
    helpers = unwrap(helpers)
    if not valid(helpers) then return nil, nil, "AssetRegistryHelpers unavailable" end

    local registry = nil
    local ok, result = pcall(function() return helpers:GetAssetRegistry() end)
    if ok then registry = unwrap(result) end
    if not valid(registry) then return helpers, nil, "AssetRegistry unavailable" end
    return helpers, registry, nil
end

local function inspectAssetRegistry()
    local helpers, registry, err = getRegistry()
    if not valid(registry) then
        lastError = err or "AssetRegistry unavailable"
        return
    end
    registryReady = true

    for _, root in ipairs(ROOTS) do
        local assets = {}
        local ok, callErr = pcall(function()
            registry:GetAssetsByPath(FName(root), assets, true, true)
        end)
        if ok then
            rootsScanned = rootsScanned + 1
            local count = 0
            pcall(function() count = #assets end)
            log(string.format("AssetRegistry %s -> %d assets", root, count))
            for i = 1, count do
                local data = unwrap(assets[i])
                if data ~= nil then
                    assetsSeen = assetsSeen + 1
                    local assetName = toText(member(data, "AssetName"))
                    local packageName = toText(member(data, "PackageName"))
                    local classText = toText(member(data, "AssetClassPath"))
                    if classText == "" then classText = toText(member(data, "AssetClass")) end
                    addCandidate("asset_registry", assetName, packageName, classText)
                end
            end
        else
            lastError = "GetAssetsByPath failed for " .. root .. ": " .. tostring(callErr)
            log(lastError)
        end
    end
end

local function writeResults()
    table.sort(candidates, function(a, b)
        if a.score == b.score then return tostring(a.package) < tostring(b.package) end
        return a.score > b.score
    end)

    local lines = {
        "version=" .. VERSION,
        "time=" .. tostring(os.time()),
        "scan_complete=" .. (scanComplete and "1" or "0"),
        "read_only=1",
        "world_mutation=0",
        "actor_spawn=0",
        "npc_spawn=0",
        "rpc_calls=0",
        "client_install_required=0",
        "registry_ready=" .. (registryReady and "1" or "0"),
        "roots_requested=" .. tostring(#ROOTS),
        "roots_scanned=" .. tostring(rootsScanned),
        "assets_seen=" .. tostring(assetsSeen),
        "loaded_classes_seen=" .. tostring(loadedClassesSeen),
        "candidates_found=" .. tostring(#candidates),
        "candidates_written=" .. tostring(math.min(#candidates, MAX_RESULTS)),
        "last_error=" .. urlEncode(lastError)
    }

    local limit = math.min(#candidates, MAX_RESULTS)
    for i = 1, limit do
        local c = candidates[i]
        lines[#lines + 1] = string.format("candidate_%d_score=%d", i, c.score)
        lines[#lines + 1] = string.format("candidate_%d_source=%s", i, urlEncode(c.source))
        lines[#lines + 1] = string.format("candidate_%d_name=%s", i, urlEncode(c.name))
        lines[#lines + 1] = string.format("candidate_%d_package=%s", i, urlEncode(c.package))
        lines[#lines + 1] = string.format("candidate_%d_class=%s", i, urlEncode(c.class))
        lines[#lines + 1] = string.format("candidate_%d_matches=%s", i, urlEncode(c.matched))
    end

    writeAll(outputFile, table.concat(lines, "\n") .. "\n")
end

writeResults()
ExecuteWithDelay(START_DELAY_MS, function()
    local ok, err = xpcall(function()
        inspectLoadedClasses()
        inspectAssetRegistry()
        scanComplete = true
        writeResults()
        log(string.format("discovery complete: %d candidates from %d assets / %d loaded classes", #candidates, assetsSeen, loadedClassesSeen))
    end, debug.traceback)
    if not ok then
        lastError = tostring(err)
        scanComplete = true
        writeResults()
        log("discovery failed: " .. lastError)
    end
end)

log("v" .. VERSION .. " loaded; read-only Arena v2 visual discovery scheduled")
