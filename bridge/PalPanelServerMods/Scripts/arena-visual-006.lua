-- PalPanelServerMods raid arena visual v0.6.0
-- SERVER-ONLY / NO CLIENT MOD.
-- Uses Palworld's own APalNetworkTransmitter::SpawnNonReliableActorBroadcast
-- so the visual actor spawn is distributed through Palworld's NetMulticast path
-- instead of relying on ordinary replicated server actors.

local MOD = "PalPanelRaidArenaVisual"
local VERSION = "0.6.0"
local TICK_MS = 250
local RADIUS = 6000.0
local MARKERS = 16
local SPAWN_BATCH = 2
local GROUND_OFFSET = 70.0
local MARKER_SCALE = 2.0
local ALWAYS_SPAWN = 1
local VISUAL_CLASS_NAME = "BP_pal_b00_building_Lordenfel_Brazier_Lit_01_C"

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

local function urlDecode(value)
    value = tostring(value or ""):gsub("%+", " ")
    return (value:gsub("%%(%x%x)", function(h)
        return string.char(tonumber(h, 16))
    end))
end

local function urlEncode(value)
    value = tostring(value or "")
    return (value:gsub("([^%w%-%._~])", function(c)
        return string.format("%%%02X", string.byte(c))
    end))
end

local function parseKv(raw)
    local out = {}
    for line in tostring(raw or ""):gmatch("[^\r\n]+") do
        local k, v = line:match("^([^=]+)=(.*)$")
        if k then out[k] = urlDecode(v) end
    end
    return out
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
    return ok and unwrap(value) or nil
end

local function toText(value)
    value = unwrap(value)
    if value == nil then return nil end
    if type(value) == "string" then return value end
    local ok, text = pcall(function() return value:ToString() end)
    if ok and type(text) == "string" and text ~= "" then return text end
    local ok2, text2 = pcall(tostring, value)
    if ok2 and type(text2) == "string" and text2 ~= "" then return text2 end
    return nil
end

local function shortName(obj)
    obj = unwrap(obj)
    if not valid(obj) then return "" end
    local name = nil
    pcall(function() name = obj:GetFName() end)
    return toText(name) or ""
end

local function exactVisualClass(obj)
    obj = unwrap(obj)
    return valid(obj) and shortName(obj) == VISUAL_CLASS_NAME
end

local function playerName(ps)
    return toText(member(ps, "PlayerNamePrivate"))
        or toText(member(ps, "SavedPlayerName"))
        or "Unbekannt"
end

local function playerPawn(ps)
    if not valid(ps) then return nil end
    local pc = nil
    pcall(function() pc = ps:GetPlayerController() end)
    pc = unwrap(pc)
    if not valid(pc) then pc = member(ps, "Owner") end
    if not valid(pc) then return nil end
    local pawn = member(pc, "Pawn")
    if valid(pawn) then return pawn end
    pcall(function() pawn = pc:GetPawn() end)
    pawn = unwrap(pawn)
    return valid(pawn) and pawn or nil
end

local function actorLocation(actor)
    actor = unwrap(actor)
    if not valid(actor) then return nil end
    local at = nil
    pcall(function() at = actor:K2_GetActorLocation() end)
    if not at then return nil end
    return { X = tonumber(at.X) or 0, Y = tonumber(at.Y) or 0, Z = tonumber(at.Z) or 0 }
end

local function onlinePlayers()
    local states = nil
    pcall(function() states = FindAllOf("PalPlayerState") end)
    if type(states) ~= "table" then return {} end
    local out = {}
    for _, ps in ipairs(states) do
        ps = unwrap(ps)
        if valid(ps) then
            local pawn = playerPawn(ps)
            local at = actorLocation(pawn)
            if valid(pawn) and at then
                out[#out + 1] = { pawn = pawn, name = playerName(ps), at = at }
            end
        end
    end
    return out
end

local scriptsDir = scriptDir()
if not scriptsDir then log("Scripts directory unavailable"); return end
local modDir = scriptsDir:match("^(.+)\\Scripts$") or scriptsDir
local ipcDir = readAll(modDir .. "\\ipc_path.txt")
if ipcDir then ipcDir = ipcDir:gsub("[\r\n]+$", "") end
if not ipcDir or ipcDir == "" then log("ipc_path.txt unavailable"); return end

local raidStatusFile = ipcDir .. "\\raid-status.txt"
local visualStatusFile = ipcDir .. "\\raid-arena-fire-status.txt"

local currentRaidId = ""
local center = nil
local visualZ = 0
local visualZSource = "none"
local nextIndex = 0
local visualStatus = "idle"
local lastError = ""
local scheduled = false
local cachedClass = nil
local palUtility = nil
local transmitter = nil
local transmitterSource = "none"
local broadcastOk = 0
local broadcastFailed = 0
local lastGuid = ""

local lastActive = {
    valid = 0,
    sent = 0,
    failed = 0,
    nextIndex = 0,
    status = "",
    error = "",
    transmitterSource = "",
    lastGuid = "",
    centerX = 0,
    centerY = 0,
    centerZ = 0,
    visualZ = 0
}

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

local function snapshotActive()
    if not center then return end
    lastActive.valid = 1
    lastActive.sent = broadcastOk
    lastActive.failed = broadcastFailed
    lastActive.nextIndex = nextIndex
    lastActive.status = visualStatus
    lastActive.error = lastError
    lastActive.transmitterSource = transmitterSource
    lastActive.lastGuid = lastGuid
    lastActive.centerX = center.X or 0
    lastActive.centerY = center.Y or 0
    lastActive.centerZ = center.Z or 0
    lastActive.visualZ = visualZ or 0
end

local function writeStatus(raid)
    local c = center or { X = 0, Y = 0, Z = 0 }
    local activeRaid = raid and raid.active == "1" and raid.state == "ACTIVE"
    local lines = {
        "version=" .. VERSION,
        "time=" .. tostring(os.time()),
        "raid_id=" .. urlEncode(currentRaidId),
        "raid_state=" .. urlEncode(raid and raid.state or "IDLE"),
        "backend=pal_network_transmitter_nonreliable_broadcast",
        "client_install_required=0",
        "active=" .. (activeRaid and "1" or "0"),
        "center_frozen=" .. (center and "1" or "0"),
        "center_x=" .. tostring(c.X or 0),
        "center_y=" .. tostring(c.Y or 0),
        "raid_center_z=" .. tostring(c.Z or 0),
        "visual_z=" .. tostring(visualZ or 0),
        "visual_z_source=" .. urlEncode(visualZSource),
        "radius=" .. tostring(math.floor(RADIUS)),
        "markers_requested=" .. tostring(MARKERS),
        "broadcast_ok=" .. tostring(broadcastOk),
        "broadcast_failed=" .. tostring(broadcastFailed),
        "next_index=" .. tostring(nextIndex),
        "visual_status=" .. urlEncode(visualStatus),
        "resolved_class_name=" .. urlEncode(exactVisualClass(cachedClass) and VISUAL_CLASS_NAME or ""),
        "transmitter_ready=" .. (valid(transmitter) and "1" or "0"),
        "transmitter_source=" .. urlEncode(transmitterSource),
        "last_guid=" .. urlEncode(lastGuid),
        "last_error=" .. urlEncode(lastError),
        "last_active_valid=" .. tostring(lastActive.valid),
        "last_active_broadcast_ok=" .. tostring(lastActive.sent),
        "last_active_broadcast_failed=" .. tostring(lastActive.failed),
        "last_active_next_index=" .. tostring(lastActive.nextIndex),
        "last_active_visual_status=" .. urlEncode(lastActive.status),
        "last_active_transmitter_source=" .. urlEncode(lastActive.transmitterSource),
        "last_active_last_guid=" .. urlEncode(lastActive.lastGuid),
        "last_active_center_x=" .. tostring(lastActive.centerX),
        "last_active_center_y=" .. tostring(lastActive.centerY),
        "last_active_center_z=" .. tostring(lastActive.centerZ),
        "last_active_visual_z=" .. tostring(lastActive.visualZ),
        "last_active_error=" .. urlEncode(lastActive.error)
    }
    writeAll(visualStatusFile, table.concat(lines, "\n") .. "\n")
end

local function resolveVisualClass()
    if exactVisualClass(cachedClass) then return cachedClass end
    local ok, instance = pcall(FindFirstOf, VISUAL_CLASS_NAME)
    instance = unwrap(instance)
    if ok and valid(instance) then
        local got, class = pcall(function() return instance:GetClass() end)
        class = unwrap(class)
        if got and exactVisualClass(class) then cachedClass = class; return class end
    end
    local allOk, classes = pcall(FindAllOf, "BlueprintGeneratedClass")
    if allOk and type(classes) == "table" then
        for _, class in ipairs(classes) do
            class = unwrap(class)
            if exactVisualClass(class) then cachedClass = class; return class end
        end
    end
    return nil
end

local function resolvePalUtility()
    if valid(palUtility) then return palUtility end
    local candidates = {
        "/Script/Pal.Default__PalUtility",
        "PalUtility /Script/Pal.Default__PalUtility"
    }
    for _, path in ipairs(candidates) do
        local ok, obj = pcall(StaticFindObject, path)
        obj = unwrap(obj)
        if ok and valid(obj) then palUtility = obj; return obj end
    end
    return nil
end

local function resolveTransmitter(players)
    if valid(transmitter) then return transmitter end
    local util = resolvePalUtility()
    if not util then
        transmitterSource = "palutility_unavailable"
        return nil
    end

    for _, p in ipairs(players or {}) do
        if valid(p.pawn) then
            local ok, tx = pcall(function() return util:GetNetworkTransmitter(p.pawn) end)
            tx = unwrap(tx)
            if ok and valid(tx) then
                transmitter = tx
                transmitterSource = "PalUtility.GetNetworkTransmitter(player_pawn)"
                return tx
            end
        end
    end

    transmitterSource = "transmitter_unavailable"
    return nil
end

local function chooseVisualZ(raid, players)
    local anchor = string.lower(tostring(raid.anchor_name or ""))
    if anchor ~= "" then
        for _, p in ipairs(players) do
            if string.lower(tostring(p.name or "")) == anchor then
                visualZSource = "anchor_player_ground"
                return (p.at.Z or 0) - GROUND_OFFSET
            end
        end
    end
    if players[1] and players[1].at then
        visualZSource = "first_player_ground"
        return (players[1].at.Z or 0) - GROUND_OFFSET
    end
    visualZSource = "raid_center_fallback"
    return (tonumber(raid.z) or 0) - 100.0
end

local function resetRaid(raidId)
    currentRaidId = tostring(raidId or "")
    center = nil
    visualZ = 0
    visualZSource = "none"
    nextIndex = 0
    visualStatus = "waiting_active_raid"
    lastError = ""
    broadcastOk = 0
    broadcastFailed = 0
    lastGuid = ""
    transmitter = nil
    transmitterSource = "none"
    lastActive = {
        valid = 0, sent = 0, failed = 0, nextIndex = 0, status = "", error = "",
        transmitterSource = "", lastGuid = "", centerX = 0, centerY = 0, centerZ = 0, visualZ = 0
    }
end

local function beginVisual(raid)
    center = {
        X = tonumber(raid.x) or 0,
        Y = tonumber(raid.y) or 0,
        Z = tonumber(raid.z) or 0
    }
    local players = onlinePlayers()
    visualZ = chooseVisualZ(raid, players)

    if not resolveVisualClass() then
        visualStatus = "class_unavailable"
        lastError = "Exact loaded brazier class unavailable"
        snapshotActive(); writeStatus(raid); return false
    end

    if not resolveTransmitter(players) then
        visualStatus = "transmitter_unavailable"
        lastError = transmitterSource
        snapshotActive(); writeStatus(raid); return false
    end

    nextIndex = 0
    visualStatus = "broadcasting_pal_native"
    lastError = ""
    snapshotActive()
    log(string.format("Pal native broadcast arena start: radius=%d markers=%d", math.floor(RADIUS), MARKERS))
    writeStatus(raid)
    return true
end

local function makeName(index)
    local token = tostring(currentRaidId or "raid"):gsub("[^%w]", "")
    if #token > 18 then token = token:sub(-18) end
    local raw = string.format("PalPanelArena_%s_%02d", token, index)
    local ok, name = pcall(FName, raw)
    return ok and name or raw
end

local function sendBatch(raid)
    if not center and not beginVisual(raid) then return end
    local class = resolveVisualClass()
    local players = onlinePlayers()
    local tx = resolveTransmitter(players)
    if not class or not valid(tx) then return end

    local sent = 0
    while nextIndex < MARKERS and sent < SPAWN_BATCH do
        local i = nextIndex
        local angle = (math.pi * 2 * i) / MARKERS
        local location = {
            X = center.X + math.cos(angle) * RADIUS,
            Y = center.Y + math.sin(angle) * RADIUS,
            Z = visualZ
        }
        local rotation = { Pitch = 0, Yaw = math.deg(angle) + 90, Roll = 0 }
        local param = {
            NetworkOwner = tx,
            Name = makeName(i + 1),
            Owner = tx,
            SpawnLocation = location,
            SpawnRotation = rotation,
            SpawnScale = { X = MARKER_SCALE, Y = MARKER_SCALE, Z = MARKER_SCALE },
            ControllerClass = nil,
            SpawnCollisionHandlingOverride = ALWAYS_SPAWN,
            bAlwaysRelevant = true,
            bNeedAdjustToFloor = false,
            AdjustUpOffset = 0.0,
            bAdjustShortRayLength = false,
            bStartAsInactivePalCharacter = false
        }

        local ok, guidOrErr = pcall(function()
            return tx:SpawnNonReliableActorBroadcast(class, param, nil)
        end)
        if ok then
            broadcastOk = broadcastOk + 1
            lastGuid = guidHex(guidOrErr)
            lastError = ""
        else
            broadcastFailed = broadcastFailed + 1
            lastError = "marker " .. tostring(i + 1) .. " broadcast failed: " .. tostring(guidOrErr)
            log(lastError)
        end

        nextIndex = nextIndex + 1
        sent = sent + 1
    end

    if nextIndex >= MARKERS then
        if broadcastOk == MARKERS then
            visualStatus = "pal_native_broadcast_sent"
        elseif broadcastOk > 0 then
            visualStatus = "pal_native_broadcast_partial"
        else
            visualStatus = "pal_native_broadcast_failed"
        end
        log(string.format("Pal native arena broadcast finished: ok=%d failed=%d", broadcastOk, broadcastFailed))
    else
        visualStatus = "broadcasting_pal_native"
    end

    snapshotActive()
    writeStatus(raid)
end

LoopAsync(TICK_MS, function()
    local raid = parseKv(readAll(raidStatusFile) or "active=0\nstate=IDLE\n")
    local raidId = tostring(raid.raid_id or "")
    local isActive = raid.active == "1" and raid.state == "ACTIVE"

    if scheduled then return false end

    if raidId ~= currentRaidId then
        scheduled = true
        ExecuteInGameThread(function()
            local ok, err = xpcall(function() resetRaid(raidId); writeStatus(raid) end, debug.traceback)
            if not ok then log("raid reset failed: " .. tostring(err)) end
            scheduled = false
        end)
        return false
    end

    if not isActive then
        if center ~= nil then snapshotActive() end
        center = nil
        visualStatus = "released"
        writeStatus(raid)
        return false
    end

    if nextIndex < MARKERS then
        scheduled = true
        ExecuteInGameThread(function()
            local ok, err = xpcall(function() sendBatch(raid) end, debug.traceback)
            if not ok then
                visualStatus = "broadcast_exception"
                lastError = tostring(err)
                snapshotActive()
                log("broadcast task failed: " .. lastError)
                writeStatus(raid)
            end
            scheduled = false
        end)
    else
        snapshotActive()
        writeStatus(raid)
    end

    return false
end)

writeStatus({ state = "IDLE", active = "0" })
log("v" .. VERSION .. " loaded; PalNetworkTransmitter native broadcast visual backend")
log("SERVER-ONLY, no client mod, 16-marker proof ring")
