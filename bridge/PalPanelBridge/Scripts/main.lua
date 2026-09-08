-- PalPanelBridge v0.2.3
-- Server-side UE4SS Lua bridge for PalPanel.
-- Commands and gameplay events use local files only; no network listener.

local MOD_NAME = "PalPanelBridge"
local MOD_VERSION = "0.2.3"

local function log(msg)
    print(string.format("[%s] %s\n", MOD_NAME, tostring(msg)))
end

local function scriptDir()
    local src = debug.getinfo(1, "S").source
    src = src:match("^@(.+)$") or src
    return src:match("^(.+)\\[^\\]+$")
end

local function readAll(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local content = f:read("*a")
    f:close()
    return content
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

local scriptsDir = scriptDir()
if not scriptsDir then
    log("ERROR: script directory could not be resolved")
    return
end

local modDir = scriptsDir:match("^(.+)\\Scripts$") or scriptsDir
local pathFile = modDir .. "\\ipc_path.txt"

local function deriveIpcDir()
    local root = scriptsDir:match("^(.-)\\server\\Pal\\Binaries\\Win64\\")
    if root and root ~= "" then return root .. "\\data\\bridge-ipc" end
    return nil
end

local ipcDir = readAll(pathFile)
if ipcDir then ipcDir = ipcDir:gsub("[\r\n]+$", "") end
if not ipcDir or ipcDir == "" then
    ipcDir = deriveIpcDir()
    if not ipcDir then
        log("ERROR: ipc_path.txt missing and IPC path could not be derived")
        return
    end
    pcall(function() writeAll(pathFile, ipcDir .. "\r\n") end)
    log("ipc_path.txt missing; derived IPC path: " .. ipcDir)
end

local commandFile = ipcDir .. "\\command.txt"
local responseFile = ipcDir .. "\\response.txt"
local heartbeatFile = ipcDir .. "\\heartbeat.txt"
local processedDir = ipcDir .. "\\processed"
local eventsDir = ipcDir .. "\\events"

os.execute('mkdir "' .. ipcDir .. '" 2>nul')
os.execute('mkdir "' .. processedDir .. '" 2>nul')
os.execute('mkdir "' .. eventsDir .. '" 2>nul')

local function urlDecode(value)
    value = tostring(value or ""):gsub("%+", " ")
    return (value:gsub("%%(%x%x)", function(hex)
        return string.char(tonumber(hex, 16))
    end))
end

local function urlEncode(value)
    value = tostring(value or "")
    return (value:gsub("([^%w%-%._~])", function(c)
        return string.format("%%%02X", string.byte(c))
    end))
end

local function parseKv(content)
    local out = {}
    for line in tostring(content or ""):gmatch("[^\r\n]+") do
        local key, value = line:match("^([^=]+)=(.*)$")
        if key then out[key] = urlDecode(value) end
    end
    return out
end

local function unwrap(param)
    if param == nil then return nil end
    local ok, value = pcall(function() return param:get() end)
    if ok then return value end
    return param
end

local function member(value, name)
    if value == nil then return nil end
    local ok, field = pcall(function() return value[name] end)
    if ok then return field end
    return nil
end

local function valid(object)
    if object == nil then return false end
    local ok, result = pcall(function() return object:IsValid() end)
    return ok and result == true
end

local function toText(value)
    value = unwrap(value)
    if value == nil then return nil end
    if type(value) == "string" then return value end
    local ok, text = pcall(function() return value:ToString() end)
    if ok and type(text) == "string" and text ~= "" then return text end
    local raw = tostring(value)
    if raw and raw ~= "" and raw ~= "nil" then return raw end
    return nil
end

local function playerName(ps)
    local name = toText(member(ps, "PlayerNamePrivate"))
    if not name or name == "" then name = toText(member(ps, "SavedPlayerName")) end
    return name
end

local ZERO_UID = string.rep("0", 32)
local function hex32(word)
    return string.format("%08X", (tonumber(word) or 0) % 0x100000000)
end

local function guidHex(guid)
    guid = unwrap(guid)
    if guid == nil then return "" end
    local ok, text = pcall(function()
        return hex32(guid.A) .. hex32(guid.B) .. hex32(guid.C) .. hex32(guid.D)
    end)
    if ok and text and text ~= ZERO_UID then return text end
    return ""
end

local function playerUid(ps)
    if not valid(ps) then return "" end
    return guidHex(member(ps, "PlayerUId"))
end

local function allPlayerStates()
    local states = nil
    pcall(function() states = FindAllOf("PalPlayerState") end)
    if type(states) ~= "table" then return {} end
    return states
end

local function findPlayerExact(target)
    local wanted = string.lower(tostring(target or ""))
    for _, ps in ipairs(allPlayerStates()) do
        if valid(ps) then
            local name = playerName(ps)
            if name and string.lower(name) == wanted then return ps, name end
        end
    end
    return nil
end

local function writeResponse(id, ok, message)
    local body = table.concat({
        "id=" .. urlEncode(id),
        "ok=" .. (ok and "1" or "0"),
        "message=" .. urlEncode(message or "")
    }, "\n") .. "\n"
    writeAll(responseFile, body)
end

local function safeId(id)
    return tostring(id or ""):gsub("[^%w%-%_]", "")
end

local function processedPath(id)
    return processedDir .. "\\" .. safeId(id) .. ".ok"
end

local function markProcessed(id, message)
    writeAll(processedPath(id), tostring(message or "ok"))
end

local function alreadyProcessed(id)
    return readAll(processedPath(id)) ~= nil
end

-- ---------------------------------------------------------------------------
-- Live capture events
-- ---------------------------------------------------------------------------

local captureEventCounter = 0
local captureSerial = {}
local captureBaseline = {}
local captureBaselineReady = {}
local captureRecordWarned = {}
local checkerResolveWarned = false
local PalUtility = nil

local function normalizeSpecies(raw)
    return tostring(raw or ""):gsub("^BOSS_", ""):gsub("^Boss_", "")
end

local function looksAlpha(rawSpecies, uniqueNpc, save)
    rawSpecies = tostring(rawSpecies or "")
    uniqueNpc = tostring(uniqueNpc or "")
    if rawSpecies:match("^BOSS_") or rawSpecies:match("^Boss_") then return true end
    if uniqueNpc:match("^BOSS_") or uniqueNpc:match("^Boss_") then return true end
    if save ~= nil and (member(save, "IsBoss") == true or member(save, "IsAlpha") == true) then return true end
    return false
end

local function writeCaptureEvent(fields)
    if not fields or not fields.uid or fields.uid == "" or not fields.species or fields.species == "" then
        return false
    end

    captureEventCounter = captureEventCounter + 1
    captureSerial[fields.uid] = (captureSerial[fields.uid] or 0) + 1

    local body = table.concat({
        "event_id=" .. urlEncode(fields.eventId),
        "type=capture",
        "player_uid=" .. urlEncode(fields.uid),
        "player_name=" .. urlEncode(fields.playerName or ""),
        "species=" .. urlEncode(fields.species),
        "raw_species=" .. urlEncode(fields.rawSpecies or fields.species),
        "capture_count=" .. tostring(math.floor(tonumber(fields.captureCount) or 0)),
        "level=" .. tostring(math.floor(tonumber(fields.level) or 0)),
        "unique_npc=" .. urlEncode(fields.uniqueNpc or ""),
        "rare=" .. (fields.rare and "1" or "0"),
        "alpha=" .. (fields.alpha and "1" or "0"),
        "pal_id=" .. urlEncode(fields.palId or ""),
        "source=" .. urlEncode(fields.source or "capture"),
        "time=" .. tostring(os.time())
    }, "\n") .. "\n"

    local fileName = string.format("capture_%d_%06d.evt", os.time(), captureEventCounter)
    local ok = writeAll(eventsDir .. "\\" .. fileName, body)
    if ok then
        log(string.format(
            "capture event: %s -> %s #%d%s [%s]",
            fields.playerName or fields.uid,
            fields.species,
            math.floor(tonumber(fields.captureCount) or 0),
            fields.alpha and " [ALPHA]" or "",
            fields.source or "capture"
        ))
    else
        log("capture event write failed")
    end
    return ok
end

local function emitCountCapture(ps, rawSpecies, captureCount, source)
    if not valid(ps) then return false end
    local uid = playerUid(ps)
    if uid == "" then return false end

    rawSpecies = tostring(rawSpecies or "")
    if rawSpecies == "" or rawSpecies == "None" then return false end
    local species = normalizeSpecies(rawSpecies)
    local count = math.floor(tonumber(captureCount) or 0)
    if count < 1 then return false end

    return writeCaptureEvent({
        eventId = string.format("capture:%s:%s:%d", uid, species, count),
        uid = uid,
        playerName = playerName(ps),
        species = species,
        rawSpecies = rawSpecies,
        captureCount = count,
        alpha = looksAlpha(rawSpecies, "", nil),
        source = source or "PalCaptureCount"
    })
end

-- Primary low-level state path: read the replicated server-side capture record.
-- Existing values become the baseline; only increases after startup are emitted.
local function readCaptureRecord(ps)
    local record = member(ps, "RecordData")
    if not valid(record) then
        local ok, got = pcall(function() return ps:GetRecordData() end)
        if ok then record = got end
    end
    if not valid(record) then return nil, "RecordData unavailable" end

    local capture = member(record, "PalCaptureCount")
    if capture == nil then return nil, "PalCaptureCount unavailable" end
    capture = unwrap(capture)

    local items = member(capture, "Items")
    if items == nil then return nil, "PalCaptureCount.Items unavailable" end
    items = unwrap(items)

    local counts = {}
    local ok, err = pcall(function()
        for _, rawItem in ipairs(items) do
            local item = unwrap(rawItem)
            local key = toText(member(item, "Key"))
            local value = tonumber(unwrap(member(item, "Value"))) or tonumber(toText(member(item, "Value"))) or 0
            if key and key ~= "" and key ~= "None" then
                counts[key] = math.floor(value)
            end
        end
    end)
    if not ok then return nil, tostring(err) end
    return counts, nil
end

local function scanCaptureRecords()
    for _, ps in ipairs(allPlayerStates()) do
        if valid(ps) then
            local uid = playerUid(ps)
            if uid ~= "" then
                local ok, counts, err = pcall(readCaptureRecord, ps)
                if not ok then
                    err = tostring(counts)
                    counts = nil
                end

                if counts then
                    captureRecordWarned[uid] = nil
                    local baseline = captureBaseline[uid]
                    if not baseline then
                        baseline = {}
                        captureBaseline[uid] = baseline
                    end

                    if not captureBaselineReady[uid] then
                        local speciesCount = 0
                        local total = 0
                        for key, value in pairs(counts) do
                            baseline[key] = value
                            speciesCount = speciesCount + 1
                            total = total + value
                        end
                        captureBaselineReady[uid] = true
                        log(string.format(
                            "capture record baseline: %s -> %d species / %d captures",
                            playerName(ps) or uid,
                            speciesCount,
                            total
                        ))
                    else
                        for rawSpecies, newValue in pairs(counts) do
                            local oldValue = tonumber(baseline[rawSpecies]) or 0
                            if newValue > oldValue then
                                for count = oldValue + 1, newValue do
                                    emitCountCapture(ps, rawSpecies, count, "PalPlayerRecordData.PalCaptureCount")
                                end
                            end
                            baseline[rawSpecies] = newValue
                        end
                    end
                elseif not captureRecordWarned[uid] then
                    captureRecordWarned[uid] = true
                    log("capture record unavailable for " .. tostring(playerName(ps) or uid) .. ": " .. tostring(err or "unknown"))
                end
            end
        end
    end
end

-- Event-driven capture-count callback. It uses the same deterministic event id
-- as the record watcher, so simultaneous paths are harmless and idempotent.
local function sameObject(a, b)
    a = unwrap(a)
    b = unwrap(b)
    if a == nil or b == nil then return false end
    if a == b then return true end
    return tostring(a) == tostring(b)
end

local function playerStateForChecker(checker)
    checker = unwrap(checker)
    if checker == nil then return nil end
    for _, ps in ipairs(allPlayerStates()) do
        if valid(ps) then
            local candidate = member(ps, "UserAchievementChecker")
            if sameObject(candidate, checker) then return ps end
        end
    end
    return nil
end

local function onUpdatePalCaptureCount(context, keyParam, valueParam)
    local checker = unwrap(context)
    local rawSpecies = toText(keyParam)
    local newValue = tonumber(unwrap(valueParam)) or tonumber(toText(valueParam)) or 0
    local ps = playerStateForChecker(checker)

    if not ps then
        if not checkerResolveWarned then
            checkerResolveWarned = true
            log("capture record hook fired, but owning PlayerState could not be resolved")
        end
        return
    end

    checkerResolveWarned = false
    emitCountCapture(ps, rawSpecies, newValue, "PalUserAchievementChecker.OnUpdatePalCaptureCount")
end

-- Rich PalDex callback retained for extra metadata on builds where this RPC is
-- dispatched through UE4SS on the dedicated server.
local function onRegisterForPalDex(context, captureInfoParam, _displayHudParam)
    local ps = unwrap(context)
    local info = unwrap(captureInfoParam)
    if not valid(ps) or info == nil then return end

    local rawSpecies = toText(member(info, "CharacterID"))
    local count = tonumber(unwrap(member(info, "CaptureCount"))) or 0
    if not rawSpecies or count < 1 then return end

    local uid = playerUid(ps)
    if uid == "" then return end
    local species = normalizeSpecies(rawSpecies)
    local uniqueNpc = toText(member(info, "UniqueNPCID")) or ""
    local level = tonumber(unwrap(member(info, "Level"))) or 0
    local rare = member(info, "IsRarePal") == true

    writeCaptureEvent({
        eventId = string.format("capture:%s:%s:%d", uid, species, math.floor(count)),
        uid = uid,
        playerName = playerName(ps),
        species = species,
        rawSpecies = rawSpecies,
        captureCount = count,
        level = level,
        uniqueNpc = uniqueNpc,
        rare = rare,
        alpha = looksAlpha(rawSpecies, uniqueNpc, nil),
        source = "PalPlayerState.RegisterForPalDex_ToClient"
    })
end

local function palUtility()
    if valid(PalUtility) then return PalUtility end
    local ok, found = pcall(function()
        return StaticFindObject("/Script/Pal.Default__PalUtility")
    end)
    if ok and valid(found) then
        PalUtility = found
        return found
    end
    return nil
end

local function resolveParameterFromInstance(instanceId)
    local util = palUtility()
    if instanceId == nil or not valid(util) then return nil end
    local world = nil
    pcall(function() world = FindFirstOf("World") end)
    if not valid(world) then return nil end
    local ok, parameter = pcall(function()
        return util:GetIndividualCharacterParameterByIstanceID(world, instanceId)
    end)
    if ok and valid(parameter) then return parameter end
    return nil
end

-- Dedicated-server fallback. If the count-based paths already emitted during the
-- delay, this does nothing. Otherwise it resolves FPalInstanceID to the Pal.
local function onRegisterForPalDexServer(context, individualIdParam, _displayHudParam)
    local ps = unwrap(context)
    local instanceId = unwrap(individualIdParam)
    if not valid(ps) or instanceId == nil then return end

    local uid = playerUid(ps)
    if uid == "" then return end
    local serialBefore = captureSerial[uid] or 0

    ExecuteWithDelay(1200, function()
        local ok, err = pcall(function()
            if (captureSerial[uid] or 0) ~= serialBefore then return end
            local parameter = resolveParameterFromInstance(instanceId)
            if not valid(parameter) then return end
            local save = member(parameter, "SaveParameter")
            if save == nil then return end
            local rawSpecies = toText(member(save, "CharacterID"))
            if not rawSpecies or rawSpecies == "" or rawSpecies == "None" then return end

            local species = normalizeSpecies(rawSpecies)
            local palId = guidHex(member(instanceId, "InstanceId"))
            local uniqueNpc = toText(member(save, "UniqueNPCID")) or ""
            local level = tonumber(unwrap(member(save, "Level"))) or 0
            local rare = member(save, "IsRarePal") == true

            writeCaptureEvent({
                eventId = palId ~= ""
                    and ("capture:" .. uid .. ":pal:" .. palId)
                    or string.format("capture:%s:%s:%d:%d", uid, species, os.time(), captureEventCounter + 1),
                uid = uid,
                playerName = playerName(ps),
                species = species,
                rawSpecies = rawSpecies,
                captureCount = 0,
                level = level,
                uniqueNpc = uniqueNpc,
                rare = rare,
                alpha = looksAlpha(rawSpecies, uniqueNpc, save),
                palId = palId,
                source = "PalPlayerState.RegisterForPalDex_ServerInternal"
            })
        end)
        if not ok then log("capture server fallback failed: " .. tostring(err)) end
    end)
end

local function registerCaptureHooks()
    local targets = {
        { "/Script/Pal.PalUserAchievementChecker:OnUpdatePalCaptureCount", onUpdatePalCaptureCount },
        { "/Script/Pal.PalPlayerState:RegisterForPalDex_ToClient", onRegisterForPalDex },
        { "/Script/Pal.PalPlayerState:RegisterForPalDex_ServerInternal", onRegisterForPalDexServer }
    }

    local registered = 0
    for _, target in ipairs(targets) do
        local ok, err = pcall(function() RegisterHook(target[1], target[2]) end)
        if ok then
            registered = registered + 1
            log("capture hook registered: " .. target[1])
        else
            log("capture hook unavailable: " .. target[1] .. " -> " .. tostring(err))
        end
    end
    return registered, #targets
end

-- ---------------------------------------------------------------------------
-- Commands
-- ---------------------------------------------------------------------------

local function giveItem(id, params)
    local target = tostring(params.target or "")
    local itemId = tostring(params.item or "")
    local qty = math.tointeger(tonumber(params.count or "0") or 0)

    if target == "" then return writeResponse(id, false, "target missing") end
    if itemId == "" then return writeResponse(id, false, "item missing") end
    if not qty or qty < 1 or qty > 9999 then
        return writeResponse(id, false, "count must be an integer between 1 and 9999")
    end

    local ps, resolvedName = findPlayerExact(target)
    if not ps then return writeResponse(id, false, "player not found: " .. target) end

    local invOk, inventory = pcall(function() return ps:GetInventoryData() end)
    if not invOk or not inventory then
        return writeResponse(id, false, "inventory unavailable")
    end

    ExecuteInGameThread(function()
        local ok, result = pcall(function()
            return inventory:AddItem_ServerInternal(FName(itemId), qty, false, 0.0, true)
        end)
        if not ok then
            log("give_item failed: " .. tostring(result))
            writeResponse(id, false, "AddItem_ServerInternal failed: " .. tostring(result))
            return
        end

        local msg = string.format(
            "gave %d x %s to %s (result=%s)",
            qty,
            itemId,
            resolvedName or target,
            tostring(result)
        )
        markProcessed(id, msg)
        writeResponse(id, true, msg)
        log(msg)
    end)
end

local function processCommand(cmd)
    local id = tostring(cmd.id or "")
    local kind = tostring(cmd.type or "")
    if id == "" then return end

    if alreadyProcessed(id) then
        writeResponse(id, true, "already_processed")
        return
    end

    if kind == "ping" then
        markProcessed(id, "pong")
        return writeResponse(id, true, "pong")
    elseif kind == "give_item" then
        return giveItem(id, cmd)
    end

    writeResponse(id, false, "unknown command: " .. kind)
end

local function pollCommand()
    local content = readAll(commandFile)
    if not content or content == "" then return end
    os.remove(commandFile)
    local ok, cmd = pcall(parseKv, content)
    if not ok or not cmd then
        writeResponse("unknown", false, "invalid command")
        return
    end
    processCommand(cmd)
end

local function writeHeartbeat()
    local body = table.concat({
        "version=" .. urlEncode(MOD_VERSION),
        "time=" .. tostring(os.time()),
        "state=ready",
        "capabilities=heartbeat,give_item,capture_events,capture_record_watch"
    }, "\n") .. "\n"
    writeAll(heartbeatFile, body)
end

os.remove(commandFile)
os.remove(responseFile)
writeHeartbeat()

LoopAsync(500, function()
    local ok, err = pcall(pollCommand)
    if not ok then log("poll error: " .. tostring(err)) end
    return false
end)

LoopAsync(1000, function()
    local ok, err = pcall(scanCaptureRecords)
    if not ok then log("capture record scan failed: " .. tostring(err)) end
    return false
end)

LoopAsync(2000, function()
    pcall(writeHeartbeat)
    return false
end)

local hooks, hookTotal = registerCaptureHooks()
log("v" .. MOD_VERSION .. " loaded")
log("IPC: " .. ipcDir)
log("Capabilities: heartbeat, give_item, capture_events, capture_record_watch")
log("Capture hooks active: " .. tostring(hooks) .. "/" .. tostring(hookTotal))
log("Capture record watcher: active (1s)")
