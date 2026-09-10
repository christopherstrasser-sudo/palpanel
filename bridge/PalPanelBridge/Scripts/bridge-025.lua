-- PalPanelBridge v0.2.5
-- Crash-hardened bridge for PalPanel.
-- Important safety rule: no UObject/FProperty wrapper is retained across an
-- ExecuteWithDelay/LoopAsync callback. All command-side UObject work is moved
-- to ExecuteInGameThread. Capture observation is immediate hook-only.

local MOD_NAME = "PalPanelBridge"
local MOD_VERSION = "0.2.5"

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

local function unwrap(value)
    if value == nil then return nil end
    local ok, inner = pcall(function() return value:get() end)
    if ok and inner ~= nil then return inner end
    return value
end

local function member(value, name)
    value = unwrap(value)
    if value == nil then return nil end
    local ok, field = pcall(function() return value[name] end)
    if ok then return unwrap(field) end
    return nil
end

local function valid(object)
    object = unwrap(object)
    if object == nil then return false end
    local addrOk, addr = pcall(function() return object:GetAddress() end)
    if addrOk and tonumber(addr) == 0 then return false end
    local ok, result = pcall(function() return object:IsValid() end)
    return ok and result == true
end

local function toText(value)
    value = unwrap(value)
    if value == nil then return nil end
    if type(value) == "string" then return value end
    local ok, text = pcall(function() return value:ToString() end)
    if ok and type(text) == "string" and text ~= "" then return text end
    return nil
end

local function playerName(ps)
    ps = unwrap(ps)
    if not valid(ps) then return nil end
    return toText(member(ps, "PlayerNamePrivate"))
        or toText(member(ps, "SavedPlayerName"))
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
    ps = unwrap(ps)
    if not valid(ps) then return "" end
    return guidHex(member(ps, "PlayerUId"))
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

local function writeResponse(id, ok, message)
    local body = table.concat({
        "id=" .. urlEncode(id),
        "ok=" .. (ok and "1" or "0"),
        "message=" .. urlEncode(message or "")
    }, "\n") .. "\n"
    writeAll(responseFile, body)
end

-- ---------------------------------------------------------------------------
-- Capture fallback: immediate only.
-- ---------------------------------------------------------------------------
-- PalPanelCapture remains the dedicated sphere observer. This fallback keeps
-- the proven ToClient Paldex event but deliberately does NOT use the old
-- RegisterForPalDex_ServerInternal + 900ms retry path. That path retained
-- short-lived Unreal wrappers after the hook returned and could dereference
-- them after a reward Pal had already been captured/destroyed.

local captureEventCounter = 0
local emitted = {}
local emittedOrder = {}

local function rememberEvent(id)
    if emitted[id] then return false end
    emitted[id] = true
    emittedOrder[#emittedOrder + 1] = id
    if #emittedOrder > 256 then
        emitted[table.remove(emittedOrder, 1)] = nil
    end
    return true
end

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

local function writeCaptureEvent(fields)
    if not rememberEvent(fields.eventId) then return true end

    captureEventCounter = captureEventCounter + 1
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
        "pal_id=",
        "source=PalPlayerState.RegisterForPalDex_ToClient",
        "time=" .. tostring(os.time())
    }, "\n") .. "\n"

    local fileName = string.format("capture_%d_%06d.evt", os.time(), captureEventCounter)
    if writeAll(eventsDir .. "\\" .. fileName, body) then
        log(string.format("capture event: %s -> %s", fields.playerName or fields.uid, fields.species))
        return true
    end

    emitted[fields.eventId] = nil
    log("capture event write failed")
    return false
end

local function onRegisterForPalDex(context, captureInfoParam, _displayHudParam)
    -- Hook callback runs synchronously with the game function. Consume every
    -- UObject/FProperty value now and retain plain Lua values only.
    local ps = unwrap(context)
    local info = unwrap(captureInfoParam)
    if not valid(ps) or info == nil then return end

    local uid = playerUid(ps)
    if uid == "" then return end

    local rawSpecies = toText(member(info, "CharacterID"))
    if not rawSpecies or rawSpecies == "" or rawSpecies == "None" then return end

    local species = normalizeSpecies(rawSpecies)
    local uniqueNpc = toText(member(info, "UniqueNPCID")) or ""
    local captureCount = tonumber(member(info, "CaptureCount")) or 0
    local level = tonumber(member(info, "Level")) or 0
    local rare = member(info, "IsRarePal") == true
    local eventId

    if captureCount > 0 then
        eventId = string.format("capture:%s:%s:%d", uid, species, captureCount)
    else
        eventId = string.format("capture:%s:%s:%d:%d", uid, species, os.time(), captureEventCounter + 1)
    end

    writeCaptureEvent({
        eventId = eventId,
        uid = uid,
        playerName = playerName(ps),
        species = species,
        rawSpecies = rawSpecies,
        captureCount = captureCount,
        level = level,
        uniqueNpc = uniqueNpc,
        rare = rare,
        alpha = looksAlpha(rawSpecies, uniqueNpc)
    })
end

local captureHookOk, captureHookErr = pcall(function()
    RegisterHook("/Script/Pal.PalPlayerState:RegisterForPalDex_ToClient", function(...)
        local args = { ... }
        local ok, err = xpcall(function()
            onRegisterForPalDex(table.unpack(args))
        end, debug.traceback)
        if not ok then log("capture hook failed: " .. tostring(err)) end
    end)
end)

if captureHookOk then
    log("safe immediate capture hook registered")
else
    log("capture hook unavailable: " .. tostring(captureHookErr))
end

-- ---------------------------------------------------------------------------
-- Commands. File polling may run asynchronously; UObject work never does.
-- ---------------------------------------------------------------------------

local function findPlayerExact(target)
    local states = nil
    pcall(function() states = FindAllOf("PalPlayerState") end)
    if type(states) ~= "table" then return nil end

    local wanted = string.lower(tostring(target or ""))
    for _, ps in ipairs(states) do
        ps = unwrap(ps)
        if valid(ps) then
            local name = playerName(ps)
            if name and string.lower(name) == wanted then
                return ps, name
            end
        end
    end
    return nil
end

local function giveItem(id, params)
    local target = tostring(params.target or "")
    local itemId = tostring(params.item or "")
    local qty = math.tointeger(tonumber(params.count or "0") or 0)

    if target == "" then return writeResponse(id, false, "target missing") end
    if itemId == "" then return writeResponse(id, false, "item missing") end
    if not itemId:match("^[%w_]+$") then return writeResponse(id, false, "invalid item id") end
    if not qty or qty < 1 or qty > 9999 then
        return writeResponse(id, false, "count must be an integer between 1 and 9999")
    end

    -- Do not resolve PlayerState or Inventory on the LoopAsync polling thread.
    ExecuteInGameThread(function()
        local ok, err = xpcall(function()
            local ps, resolvedName = findPlayerExact(target)
            if not valid(ps) then
                return writeResponse(id, false, "player not found: " .. target)
            end

            local inventory = nil
            local invOk, invResult = pcall(function() return ps:GetInventoryData() end)
            if invOk then inventory = unwrap(invResult) end
            if not inventory then
                return writeResponse(id, false, "inventory unavailable")
            end

            local addOk, result = pcall(function()
                return inventory:AddItem_ServerInternal(FName(itemId), qty, false, 0.0, true)
            end)
            if not addOk then
                log("give_item failed: " .. tostring(result))
                return writeResponse(id, false, "AddItem_ServerInternal failed: " .. tostring(result))
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
        end, debug.traceback)

        if not ok then
            log("give_item game-thread error: " .. tostring(err))
            writeResponse(id, false, "give_item game-thread error")
        end
    end)
end

local function processCommand(cmd)
    local id = tostring(cmd.id or "")
    local kind = tostring(cmd.type or "")
    if id == "" then return end

    if alreadyProcessed(id) then
        return writeResponse(id, true, "already_processed")
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
        return writeResponse("unknown", false, "invalid command")
    end
    processCommand(cmd)
end

local function writeHeartbeat()
    local body = table.concat({
        "version=" .. urlEncode(MOD_VERSION),
        "time=" .. tostring(os.time()),
        "state=ready",
        "capabilities=heartbeat,give_item,capture_events",
        "capture_mode=immediate_hook_only",
        "delayed_uobject_access=0"
    }, "\n") .. "\n"
    writeAll(heartbeatFile, body)
end

os.remove(commandFile)
os.remove(responseFile)
writeHeartbeat()

LoopAsync(500, function()
    local ok, err = xpcall(pollCommand, debug.traceback)
    if not ok then log("poll error: " .. tostring(err)) end
    return false
end)

LoopAsync(2000, function()
    local ok, err = pcall(writeHeartbeat)
    if not ok then log("heartbeat error: " .. tostring(err)) end
    return false
end)

log("v" .. MOD_VERSION .. " loaded")
log("IPC: " .. ipcDir)
log("Safety: delayed RegisterForPalDex_ServerInternal UObject retry REMOVED")
log("Safety: give_item UObject work runs exclusively on the game thread")
