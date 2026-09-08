-- PalPanelBridge v0.2.1
-- Server-side UE4SS Lua bridge for PalPanel.
-- Commands and live gameplay events use local files only; no network listener.

local MOD_NAME = "PalPanelBridge"
local MOD_VERSION = "0.2.1"

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
    if value == nil then return nil end
    if type(value) == "string" then return value end
    local ok, text = pcall(function() return value:ToString() end)
    if ok and type(text) == "string" and text ~= "" then return text end
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

local function writeResponse(id, ok, message)
    local body = table.concat({
        "id=" .. urlEncode(id),
        "ok=" .. (ok and "1" or "0"),
        "message=" .. urlEncode(message or "")
    }, "\n") .. "\n"
    writeAll(responseFile, body)
end

local function findPlayerExact(target)
    local states = nil
    pcall(function() states = FindAllOf("PalPlayerState") end)
    if type(states) ~= "table" then return nil end
    local wanted = string.lower(tostring(target or ""))
    for _, ps in ipairs(states) do
        if valid(ps) then
            local name = playerName(ps)
            if name and string.lower(name) == wanted then return ps, name end
        end
    end
    return nil
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
--
-- PalPlayerState:RegisterForPalDex_ToClient is called for a completed PalDex
-- registration and carries FPalUIPalCaptureInfo. Unlike the old multicast
-- delegate hooks, this is a real reflected /Script/Pal UFunction and gives us
-- the owning PlayerState plus CharacterID and CaptureCount directly.
-- ---------------------------------------------------------------------------

local captureEventCounter = 0

local function normalizeSpecies(raw)
    return tostring(raw or ""):gsub("^BOSS_", ""):gsub("^Boss_", "")
end

local function looksAlpha(rawSpecies, uniqueNpc)
    rawSpecies = tostring(rawSpecies or "")
    uniqueNpc = tostring(uniqueNpc or "")
    return rawSpecies:match("^BOSS_") ~= nil
        or rawSpecies:match("^Boss_") ~= nil
        or uniqueNpc:match("^BOSS_") ~= nil
        or uniqueNpc:match("^Boss_") ~= nil
end

local function emitCaptureInfo(ps, info, source)
    if not valid(ps) or info == nil then return false end

    local uid = playerUid(ps)
    if uid == "" then
        log("capture ignored: PlayerUId unavailable")
        return false
    end

    local rawSpecies = toText(member(info, "CharacterID"))
    if not rawSpecies or rawSpecies == "" or rawSpecies == "None" then
        log("capture ignored: CharacterID unavailable")
        return false
    end

    local species = normalizeSpecies(rawSpecies)
    local uniqueNpc = toText(member(info, "UniqueNPCID")) or ""
    local captureCount = tonumber(member(info, "CaptureCount")) or 0
    local level = tonumber(member(info, "Level")) or 0
    local rare = member(info, "IsRarePal") == true
    local alpha = looksAlpha(rawSpecies, uniqueNpc)

    captureEventCounter = captureEventCounter + 1
    local eventId
    if captureCount > 0 then
        -- Stable across both retries and duplicate hook delivery.
        eventId = string.format("capture:%s:%s:%d", uid, species, captureCount)
    else
        eventId = string.format("capture:%s:%s:%d:%d", uid, species, os.time(), captureEventCounter)
    end

    local body = table.concat({
        "event_id=" .. urlEncode(eventId),
        "type=capture",
        "player_uid=" .. urlEncode(uid),
        "player_name=" .. urlEncode(playerName(ps) or ""),
        "species=" .. urlEncode(species),
        "raw_species=" .. urlEncode(rawSpecies),
        "capture_count=" .. tostring(math.floor(captureCount)),
        "level=" .. tostring(math.floor(level)),
        "unique_npc=" .. urlEncode(uniqueNpc),
        "rare=" .. (rare and "1" or "0"),
        "alpha=" .. (alpha and "1" or "0"),
        "source=" .. urlEncode(source or "paldex"),
        "time=" .. tostring(os.time())
    }, "\n") .. "\n"

    local fileName = string.format("capture_%d_%06d.evt", os.time(), captureEventCounter)
    local ok = writeAll(eventsDir .. "\\" .. fileName, body)
    if ok then
        log(string.format(
            "capture event: %s -> %s #%d%s",
            playerName(ps) or uid,
            species,
            captureCount,
            alpha and " [ALPHA]" or ""
        ))
    else
        log("capture event write failed")
    end
    return ok
end

local function onRegisterForPalDex(context, captureInfoParam, _displayHudParam)
    local ps = unwrap(context)
    local info = unwrap(captureInfoParam)
    local ok, err = pcall(emitCaptureInfo, ps, info, "PalPlayerState.RegisterForPalDex_ToClient")
    if not ok then log("capture hook failed: " .. tostring(err)) end
end

-- Diagnostic fallback signal. We intentionally do not award from it because it
-- carries only an IndividualId, not the species. If the primary hook ever moves
-- in a game update this log tells us the server-side capture path still fired.
local function onRegisterForPalDexServer(context, _individualIdParam, _displayHudParam)
    local ps = unwrap(context)
    if valid(ps) then
        log("server capture signal: " .. tostring(playerName(ps) or playerUid(ps)))
    end
end

local function registerCaptureHooks()
    local targets = {
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
    return registered
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
        "capabilities=heartbeat,give_item,capture_events"
    }, "\n") .. "\n"
    writeAll(heartbeatFile, body)
end

-- Remove transient command files only. Event queue and processed markers survive.
os.remove(commandFile)
os.remove(responseFile)
writeHeartbeat()

LoopAsync(500, function()
    local ok, err = pcall(pollCommand)
    if not ok then log("poll error: " .. tostring(err)) end
    return false
end)

LoopAsync(2000, function()
    pcall(writeHeartbeat)
    return false
end)

local hooks = registerCaptureHooks()
log("v" .. MOD_VERSION .. " loaded")
log("IPC: " .. ipcDir)
log("Capabilities: heartbeat, give_item, capture_events")
log("Capture hooks active: " .. tostring(hooks) .. "/2")
