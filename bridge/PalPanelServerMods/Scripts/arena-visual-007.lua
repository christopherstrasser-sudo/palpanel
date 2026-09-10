-- PalPanelServerMods raid arena visual v0.7.0
-- SERVER-ONLY / NO CLIENT MOD.
-- One-marker safety probe using Palworld's direct NetMulticast spawn RPC.
--
-- Differences vs v0.6.0:
--   * exactly ONE marker
--   * no SpawnNonReliableActorBroadcast wrapper
--   * no delegate parameter
--   * NetworkOwner=nil / Owner=nil (Palworld struct defaults)
--   * direct SpawnedNonReliableActor_ToALL(class, params, issuerID)
--   * persistent pre-call/post-call diagnostics
--   * 2 second delay after ACTIVE so crashes cannot be confused with raid spawn/combat

local MOD = "PalPanelRaidArenaVisual"
local VERSION = "0.7.0"
local TICK_MS = 250
local ARM_TICKS = 8
local RADIUS = 6000.0
local GROUND_OFFSET = 70.0
local MARKER_SCALE = 2.5
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
local cachedClass = nil
local palUtility = nil
local transmitter = nil
local transmitterSource = "none"
local activeTicks = 0
local callAttempted = 0
local callReturned = 0
local callOk = 0
local visualStatus = "idle"
local lastError = ""
local scheduled = false

local lastActive = {
    valid = 0,
    attempted = 0,
    returned = 0,
    ok = 0,
    status = "",
    error = "",
    transmitterSource = "",
    centerX = 0,
    centerY = 0,
    centerZ = 0,
    visualZ = 0
}

local function snapshotActive()
    if not center then return end
    lastActive.valid = 1
    lastActive.attempted = callAttempted
    lastActive.returned = callReturned
    lastActive.ok = callOk
    lastActive.status = visualStatus
    lastActive.error = lastError
    lastActive.transmitterSource = transmitterSource
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
        "backend=pal_network_transmitter_direct_multicast_probe",
        "client_install_required=0",
        "active=" .. (activeRaid and "1" or "0"),
        "center_frozen=" .. (center and "1" or "0"),
        "center_x=" .. tostring(c.X or 0),
        "center_y=" .. tostring(c.Y or 0),
        "raid_center_z=" .. tostring(c.Z or 0),
        "visual_z=" .. tostring(visualZ or 0),
        "visual_z_source=" .. urlEncode(visualZSource),
        "radius=" .. tostring(math.floor(RADIUS)),
        "markers_requested=1",
        "active_ticks=" .. tostring(activeTicks),
        "probe_delay_ticks=" .. tostring(ARM_TICKS),
        "call_attempted=" .. tostring(callAttempted),
        "call_returned=" .. tostring(callReturned),
        "call_ok=" .. tostring(callOk),
        "visual_status=" .. urlEncode(visualStatus),
        "resolved_class_name=" .. urlEncode(exactVisualClass(cachedClass) and VISUAL_CLASS_NAME or ""),
        "transmitter_ready=" .. (valid(transmitter) and "1" or "0"),
        "transmitter_source=" .. urlEncode(transmitterSource),
        "network_owner=null",
        "owner=null",
        "delegate=not_used",
        "rpc=SpawnedNonReliableActor_ToALL",
        "last_error=" .. urlEncode(lastError),
        "last_active_valid=" .. tostring(lastActive.valid),
        "last_active_call_attempted=" .. tostring(lastActive.attempted),
        "last_active_call_returned=" .. tostring(lastActive.returned),
        "last_active_call_ok=" .. tostring(lastActive.ok),
        "last_active_visual_status=" .. urlEncode(lastActive.status),
        "last_active_transmitter_source=" .. urlEncode(lastActive.transmitterSource),
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
    if not util then transmitterSource = "palutility_unavailable"; return nil end
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
    transmitter = nil
    transmitterSource = "none"
    activeTicks = 0
    callAttempted = 0
    callReturned = 0
    callOk = 0
    visualStatus = "waiting_active_raid"
    lastError = ""
    lastActive = {
        valid = 0, attempted = 0, returned = 0, ok = 0, status = "", error = "",
        transmitterSource = "", centerX = 0, centerY = 0, centerZ = 0, visualZ = 0
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
    activeTicks = 0
    visualStatus = "arming_direct_multicast_probe"
    lastError = ""
    snapshotActive(); writeStatus(raid)
    log("direct multicast probe armed; one marker will be sent after 2 seconds")
    return true
end

local function sendProbe(raid)
    if callAttempted ~= 0 then return end
    local class = resolveVisualClass()
    local players = onlinePlayers()
    local tx = resolveTransmitter(players)
    if not class or not valid(tx) then
        visualStatus = "probe_prerequisite_lost"
        lastError = "class or transmitter unavailable"
        snapshotActive(); writeStatus(raid); return
    end

    local location = {
        X = center.X + RADIUS,
        Y = center.Y,
        Z = visualZ
    }
    local param = {
        NetworkOwner = nil,
        Name = FName("PalPanelArenaProbe"),
        Owner = nil,
        SpawnLocation = location,
        SpawnRotation = { Pitch = 0, Yaw = 90, Roll = 0 },
        SpawnScale = { X = MARKER_SCALE, Y = MARKER_SCALE, Z = MARKER_SCALE },
        ControllerClass = nil,
        SpawnCollisionHandlingOverride = ALWAYS_SPAWN,
        bAlwaysRelevant = true,
        bNeedAdjustToFloor = false,
        AdjustUpOffset = 0.0,
        bAdjustShortRayLength = false,
        bStartAsInactivePalCharacter = false
    }

    -- Persist this BEFORE entering the native RPC. If the process dies inside
    -- ProcessEvent, this tells us exactly which call was in flight.
    callAttempted = 1
    visualStatus = "before_direct_multicast_call"
    lastError = ""
    snapshotActive(); writeStatus(raid)
    log(string.format("DIRECT multicast probe CALL: X=%.1f Y=%.1f Z=%.1f", location.X, location.Y, location.Z))

    local ok, err = pcall(function()
        tx:SpawnedNonReliableActor_ToALL(class, param, 0)
    end)

    callReturned = 1
    if ok then
        callOk = 1
        visualStatus = "direct_multicast_returned"
        lastError = ""
        log("DIRECT multicast probe RETURNED successfully")
    else
        callOk = 0
        visualStatus = "direct_multicast_lua_error"
        lastError = tostring(err)
        log("DIRECT multicast probe Lua error: " .. lastError)
    end
    snapshotActive(); writeStatus(raid)
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
        activeTicks = 0
        visualStatus = "released"
        writeStatus(raid)
        return false
    end

    if not center then
        scheduled = true
        ExecuteInGameThread(function()
            local ok, err = xpcall(function() beginVisual(raid) end, debug.traceback)
            if not ok then
                visualStatus = "begin_exception"
                lastError = tostring(err)
                log("probe begin failed: " .. lastError)
                writeStatus(raid)
            end
            scheduled = false
        end)
        return false
    end

    if callAttempted == 0 then
        activeTicks = activeTicks + 1
        visualStatus = "arming_direct_multicast_probe"
        snapshotActive(); writeStatus(raid)
        if activeTicks >= ARM_TICKS then
            scheduled = true
            ExecuteInGameThread(function()
                local ok, err = xpcall(function() sendProbe(raid) end, debug.traceback)
                if not ok then
                    visualStatus = "probe_exception"
                    lastError = tostring(err)
                    snapshotActive(); writeStatus(raid)
                    log("probe task failed: " .. lastError)
                end
                scheduled = false
            end)
        end
    else
        snapshotActive(); writeStatus(raid)
    end

    return false
end)

writeStatus({ state = "IDLE", active = "0" })
log("v" .. VERSION .. " loaded; one-marker direct PalNetworkTransmitter multicast probe")
log("SERVER-ONLY; no delegate; Owner/NetworkOwner null; 2-second delayed probe")
