-- PalPanelServerMods Arena v2 visual discovery / v0.2.0
-- SERVER-ONLY / NO CLIENT MOD.
--
-- Read-only discovery pass for Arena v2 step 2A.
-- Uses UE4SS GUObjectArray enumeration instead of AssetRegistry out-parameter calls.
-- No actors/NPCs/effects are spawned and no gameplay/world state is mutated.

local MOD = "PalPanelArenaV2Discovery"
local VERSION = "0.2.0"
local START_DELAY_MS = 1500
local MAX_RESULTS = 120

local KEYWORDS = {
    { text = "arena", weight = 12 },
    { text = "barrier", weight = 12 },
    { text = "boundary", weight = 10 },
    { text = "fence", weight = 7 },
    { text = "wall", weight = 5 },
    { text = "gate", weight = 5 },
    { text = "niagara", weight = 4 },
    { text = "effect", weight = 3 },
    { text = "beam", weight = 3 },
    { text = "pillar", weight = 3 },
    { text = "field", weight = 1 }
}

local DIRECT_PROBES = {
    "BP_LevelGimmick_AreaBarrier_C",
    "BP_LevelGimmick_AreaBarrier_Info_C",
    "BP_LevelGimmick_AreaBarrier_Volume_C",
    "BP_CutsceneActor_LevelGimmick_AreaBarrier_C",
    "BP_ArenaEntrance_C",
    "BP_PalArenaWorldSubsystem_C"
}

local NATIVE_PROBES = {
    "/Script/Pal.PalLevelGimmick_AreaBarrier",
    "/Script/Pal.PalLevelGimmick_AreaBarrier_Info",
    "/Script/Pal.PalLevelGimmick_AreaBarrier_Lock",
    "/Script/Pal.PalLevelObjectItemRequiredWarpBarrier",
    "/Script/Pal.PalArenaLevelInstance",
    "/Script/Pal.PalArenaEntrance"
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

local function fNameText(obj)
    obj = unwrap(obj)
    if not valid(obj) then return "" end
    local value = nil
    local ok = pcall(function() value = obj:GetFName() end)
    if not ok or value == nil then return "" end
    local text = ""
    pcall(function() text = value:ToString() end)
    if type(text) == "string" and text ~= "" then return text end
    local ok2, fallback = pcall(tostring, value)
    return ok2 and tostring(fallback or "") or ""
end

local function fullName(obj)
    obj = unwrap(obj)
    if not valid(obj) then return "" end
    local text = ""
    pcall(function() text = obj:GetFullName() end)
    return type(text) == "string" and text or ""
end

local function isClass(obj)
    obj = unwrap(obj)
    if not valid(obj) then return false end
    local ok, result = pcall(function() return obj:IsClass() end)
    return ok and result == true
end

local scriptsDir = scriptDir()
if not scriptsDir then log("Scripts directory unavailable; discovery disabled"); return end
local modDir = scriptsDir:match("^(.+)\\Scripts$") or scriptsDir
local ipcDir = readAll(modDir .. "\\ipc_path.txt")
if ipcDir then ipcDir = ipcDir:gsub("[\r\n]+$", "") end
if not ipcDir or ipcDir == "" then log("ipc_path.txt unavailable; discovery disabled"); return end

local outputFile = ipcDir .. "\\raid-arena-v2-visual-discovery.txt"
local candidates = {}
local seen = {}
local scanComplete = false
local callbackEntered = false
local scanAttempt = 0
local uobjectsSeen = 0
local keywordObjectsSeen = 0
local classesSeen = 0
local directProbeHits = 0
local nativeProbeHits = 0
local lastError = ""

local function scoreText(text)
    local hay = string.lower(tostring(text or ""))
    local score, matched = 0, {}
    for _, kw in ipairs(KEYWORDS) do
        if hay:find(kw.text, 1, true) then
            score = score + kw.weight
            matched[#matched + 1] = kw.text
        end
    end
    return score, table.concat(matched, ",")
end

local function addCandidate(source, shortName, objectFullName, classFlag)
    shortName = tostring(shortName or "")
    objectFullName = tostring(objectFullName or "")
    local score, matched = scoreText(shortName .. " " .. objectFullName)
    if score <= 0 then return end

    local key = string.lower(objectFullName ~= "" and objectFullName or shortName)
    if key == "" then return end
    local existing = seen[key]
    if existing then
        if existing.source ~= source and not existing.source:find(source, 1, true) then
            existing.source = existing.source .. "+" .. source
        end
        if score > existing.score then
            existing.score = score
            existing.matches = matched
        end
        return
    end

    local row = {
        source = source,
        name = shortName,
        full_name = objectFullName,
        is_class = classFlag and 1 or 0,
        score = score,
        matches = matched
    }
    seen[key] = row
    candidates[#candidates + 1] = row
end

local function writeResults()
    table.sort(candidates, function(a, b)
        if a.score == b.score then return tostring(a.full_name) < tostring(b.full_name) end
        return a.score > b.score
    end)

    local lines = {
        "version=" .. VERSION,
        "time=" .. tostring(os.time()),
        "scan_attempt=" .. tostring(scanAttempt),
        "callback_entered=" .. (callbackEntered and "1" or "0"),
        "scan_complete=" .. (scanComplete and "1" or "0"),
        "read_only=1",
        "world_mutation=0",
        "actor_spawn=0",
        "npc_spawn=0",
        "rpc_calls=0",
        "client_install_required=0",
        "backend=guobjectarray_read_only_scan",
        "uobjects_seen=" .. tostring(uobjectsSeen),
        "keyword_objects_seen=" .. tostring(keywordObjectsSeen),
        "classes_seen=" .. tostring(classesSeen),
        "direct_probes_requested=" .. tostring(#DIRECT_PROBES),
        "direct_probe_hits=" .. tostring(directProbeHits),
        "native_probes_requested=" .. tostring(#NATIVE_PROBES),
        "native_probe_hits=" .. tostring(nativeProbeHits),
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
        lines[#lines + 1] = string.format("candidate_%d_full_name=%s", i, urlEncode(c.full_name))
        lines[#lines + 1] = string.format("candidate_%d_is_class=%d", i, c.is_class)
        lines[#lines + 1] = string.format("candidate_%d_matches=%s", i, urlEncode(c.matches))
    end
    writeAll(outputFile, table.concat(lines, "\n") .. "\n")
end

local function directProbes()
    for _, name in ipairs(DIRECT_PROBES) do
        local obj = nil
        local ok = pcall(function()
            if FindObject ~= nil then obj = FindObject(nil, name) end
        end)
        obj = unwrap(obj)
        if ok and valid(obj) then
            directProbeHits = directProbeHits + 1
            addCandidate("direct_findobject", fNameText(obj), fullName(obj), isClass(obj))
        end
    end

    for _, path in ipairs(NATIVE_PROBES) do
        local obj = nil
        local ok = pcall(function() obj = StaticFindObject(path) end)
        obj = unwrap(obj)
        if ok and valid(obj) then
            nativeProbeHits = nativeProbeHits + 1
            addCandidate("native_staticfind", fNameText(obj), fullName(obj), isClass(obj))
        end
    end
end

local function scanGUObjectArray()
    if ForEachUObject == nil then
        error("ForEachUObject is unavailable in this UE4SS build")
    end

    ForEachUObject(function(raw)
        local obj = unwrap(raw)
        if not valid(obj) then return end
        uobjectsSeen = uobjectsSeen + 1

        local name = fNameText(obj)
        if name == "" then return end
        local score = scoreText(name)
        if score <= 0 then return end

        keywordObjectsSeen = keywordObjectsSeen + 1
        local classFlag = isClass(obj)
        if classFlag then classesSeen = classesSeen + 1 end
        addCandidate("guobject", name, fullName(obj), classFlag)
    end)
end

local function runScan()
    scanAttempt = scanAttempt + 1
    callbackEntered = true
    scanComplete = false
    lastError = ""
    writeResults()

    local ok, err = xpcall(function()
        directProbes()
        scanGUObjectArray()
    end, debug.traceback)

    if not ok then lastError = tostring(err) end
    scanComplete = true
    writeResults()
    log(string.format("discovery attempt %d complete: %d candidates, %d objects, %d direct hits, %d native hits%s",
        scanAttempt, #candidates, uobjectsSeen, directProbeHits, nativeProbeHits,
        lastError ~= "" and ("; error=" .. lastError) or ""))
end

writeResults()
ExecuteWithDelay(START_DELAY_MS, function()
    ExecuteInGameThread(function()
        runScan()
    end)
end)

log("v" .. VERSION .. " loaded; GUObject read-only Arena v2 discovery scheduled")
