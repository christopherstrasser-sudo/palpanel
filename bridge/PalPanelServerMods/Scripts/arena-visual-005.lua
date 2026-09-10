-- PalPanelServerMods raid arena visual v0.5.0
-- SERVER-ONLY / NO CLIENT MOD.
--
-- v0.4.0 had a Lua multi-return bug in withBornReplication(): the spawned
-- actor reference was discarded and the caller received the trailing boolean
-- instead. v0.5.0 removes that wrapper entirely and uses Unreal's real
-- deferred Blueprint spawn path:
--   BeginDeferredActorSpawnFromClass(..., AlwaysSpawn, ...)
--   -> enable replication/relevancy on the deferred actor
--   -> FinishSpawningActor(...)
--
-- This is intentionally visual-only. arena-027.lua remains authoritative.

local MOD = "PalPanelRaidArenaVisual"
local VERSION = "0.5.0"
local TICK_MS = 250
local RADIUS = 6000.0
local MARKERS = 32
local SPAWN_BATCH = 4
local GROUND_OFFSET = 70.0
local MARKER_SCALE = 1.8
local NET_CULL_DISTANCE_SQUARED = 2500000000.0
local ALWAYS_SPAWN = 1
local TRANSFORM_SCALE_MULTIPLY_WITH_ROOT = 0

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

local function worldFromPlayers(players)
    for _, p in ipairs(players or {}) do
        if valid(p.pawn) then
            local world = nil
            pcall(function() world = p.pawn:GetWorld() end)
            world = unwrap(world)
            if valid(world) then return world end
        end
    end
    return nil
end

local scriptsDir = scriptDir()
if not scriptsDir then
    log("Scripts directory unavailable; visual module disabled")
    return
end

local modDir = scriptsDir:match("^(.+)\\Scripts$") or scriptsDir
local ipcDir = readAll(modDir .. "\\ipc_path.txt")
if ipcDir then ipcDir = ipcDir:gsub("[\r\n]+$", "") end
if not ipcDir or ipcDir == "" then
    log("ipc_path.txt unavailable; visual module disabled")
    return
end

local raidStatusFile = ipcDir .. "\\raid-status.txt"
local visualStatusFile = ipcDir .. "\\raid-arena-fire-status.txt"

local ueHelpers = nil
local gameplayStatics = nil
local mathLibrary = nil
local helperStatus = "not_initialized"
local helperError = ""

do
    local ok, helpersOrErr = pcall(require, "UEHelpers")
    if ok and helpersOrErr then
        ueHelpers = helpersOrErr
        local gpOk, gp = pcall(function() return ueHelpers.GetGameplayStatics() end)
        local mathOk, km = pcall(function() return ueHelpers.GetKismetMathLibrary() end)
        gp = unwrap(gp)
        km = unwrap(km)
        if gpOk and mathOk and valid(gp) and valid(km) then
            gameplayStatics = gp
            mathLibrary = km
            helperStatus = "ready"
        else
            helperStatus = "helper_objects_invalid"
            helperError = "GameplayStatics or KismetMathLibrary invalid"
        end
    else
        helperStatus = "uehelpers_unavailable"
        helperError = tostring(helpersOrErr)
    end
end

local currentRaidId = ""
local center = nil
local visualZ = 0
local visualZSource = "none"
local actors = {}
local nextIndex = 0
local visualStatus = "idle"
local classSource = "none"
local lastError = ""
local scheduled = false
local cachedClass = nil
local beginOkCount = 0
local finishOkCount = 0
local replicationBoostCount = 0
local beginSignature = "none"

local lastActive = {
    valid = 0, markers = 0, nextIndex = 0, status = "", classSource = "",
    resolvedClass = "", error = "", beginOk = 0, finishOk = 0,
    replicationBoost = 0, beginSignature = "none", centerX = 0, centerY = 0,
    centerZ = 0, visualZ = 0
}

local function snapshotActive()
    if not center then return end
    lastActive.valid = 1
    lastActive.markers = #actors
    lastActive.nextIndex = nextIndex
    lastActive.status = visualStatus
    lastActive.classSource = classSource
    lastActive.resolvedClass = exactVisualClass(cachedClass) and VISUAL_CLASS_NAME or ""
    lastActive.error = lastError
    lastActive.beginOk = beginOkCount
    lastActive.finishOk = finishOkCount
    lastActive.replicationBoost = replicationBoostCount
    lastActive.beginSignature = beginSignature
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
        "backend=deferred_always_spawn_vanilla_static_mesh",
        "client_install_required=0",
        "active=" .. (activeRaid and "1" or "0"),
        "helper_status=" .. urlEncode(helperStatus),
        "helper_error=" .. urlEncode(helperError),
        "center_frozen=" .. (center and "1" or "0"),
        "center_x=" .. tostring(c.X or 0),
        "center_y=" .. tostring(c.Y or 0),
        "raid_center_z=" .. tostring(c.Z or 0),
        "visual_z=" .. tostring(visualZ or 0),
        "visual_z_source=" .. urlEncode(visualZSource),
        "radius=" .. tostring(math.floor(RADIUS)),
        "markers_requested=" .. tostring(MARKERS),
        "markers_spawned=" .. tostring(#actors),
        "next_index=" .. tostring(nextIndex),
        "visual_status=" .. urlEncode(visualStatus),
        "resolved_class_name=" .. urlEncode(exactVisualClass(cachedClass) and VISUAL_CLASS_NAME or ""),
        "class_source=" .. urlEncode(classSource),
        "spawn_mode=begin_deferred_always_spawn_finish",
        "begin_signature=" .. urlEncode(beginSignature),
        "begin_ok=" .. tostring(beginOkCount),
        "finish_ok=" .. tostring(finishOkCount),
        "replication_boost=" .. tostring(replicationBoostCount),
        "server_spawn_success=" .. (#actors > 0 and "1" or "0"),
        "client_visual_confirmation=required",
        "last_error=" .. urlEncode(lastError),
        "last_active_valid=" .. tostring(lastActive.valid),
        "last_active_markers=" .. tostring(lastActive.markers),
        "last_active_next_index=" .. tostring(lastActive.nextIndex),
        "last_active_visual_status=" .. urlEncode(lastActive.status),
        "last_active_class_source=" .. urlEncode(lastActive.classSource),
        "last_active_resolved_class_name=" .. urlEncode(lastActive.resolvedClass),
        "last_active_begin_signature=" .. urlEncode(lastActive.beginSignature),
        "last_active_begin_ok=" .. tostring(lastActive.beginOk),
        "last_active_finish_ok=" .. tostring(lastActive.finishOk),
        "last_active_replication_boost=" .. tostring(lastActive.replicationBoost),
        "last_active_center_x=" .. tostring(lastActive.centerX),
        "last_active_center_y=" .. tostring(lastActive.centerY),
        "last_active_center_z=" .. tostring(lastActive.centerZ),
        "last_active_visual_z=" .. tostring(lastActive.visualZ),
        "last_active_error=" .. urlEncode(lastActive.error)
    }
    writeAll(visualStatusFile, table.concat(lines, "\n") .. "\n")
end

local function destroyActors()
    for _, actor in ipairs(actors) do
        if valid(actor) then pcall(function() actor:K2_DestroyActor() end) end
    end
    actors = {}
    nextIndex = 0
end

local function resetLastActive()
    lastActive.valid = 0
    lastActive.markers = 0
    lastActive.nextIndex = 0
    lastActive.status = ""
    lastActive.classSource = ""
    lastActive.resolvedClass = ""
    lastActive.error = ""
    lastActive.beginOk = 0
    lastActive.finishOk = 0
    lastActive.replicationBoost = 0
    lastActive.beginSignature = "none"
    lastActive.centerX = 0
    lastActive.centerY = 0
    lastActive.centerZ = 0
    lastActive.visualZ = 0
end

local function resetRaid(raidId)
    destroyActors()
    currentRaidId = tostring(raidId or "")
    center = nil
    visualZ = 0
    visualZSource = "none"
    visualStatus = "waiting_active_raid"
    lastError = ""
    beginOkCount = 0
    finishOkCount = 0
    replicationBoostCount = 0
    beginSignature = "none"
    resetLastActive()
end

local function resolveVisualClass()
    if exactVisualClass(cachedClass) then return cachedClass end
    local ok, instance = pcall(FindFirstOf, VISUAL_CLASS_NAME)
    instance = unwrap(instance)
    if ok and valid(instance) then
        local gotClass, class = pcall(function() return instance:GetClass() end)
        class = unwrap(class)
        if gotClass and exactVisualClass(class) then
            cachedClass = class
            classSource = "live_instance_exact"
            return class
        end
    end
    local allOk, classes = pcall(FindAllOf, "BlueprintGeneratedClass")
    if allOk and type(classes) == "table" then
        for _, class in ipairs(classes) do
            class = unwrap(class)
            if exactVisualClass(class) then
                cachedClass = class
                classSource = "loaded_exact_class_scan"
                return class
            end
        end
    end
    classSource = "unavailable"
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

local function makeTransform(location, rotation)
    if not valid(mathLibrary) then return nil, "KismetMathLibrary invalid" end
    local ok, transform = pcall(function()
        return mathLibrary:MakeTransform(
            location,
            rotation,
            { X = MARKER_SCALE, Y = MARKER_SCALE, Z = MARKER_SCALE }
        )
    end)
    if not ok then return nil, tostring(transform) end
    return transform, nil
end

local function setProperty(obj, name, value)
    if not valid(obj) then return false end
    return pcall(function() obj[name] = value end)
end

local function primeDeferredActor(actor)
    if not valid(actor) then return 0 end
    local applied = 0
    pcall(function() actor:SetReplicates(true) end)
    pcall(function() actor:SetReplicateMovement(true) end)
    if setProperty(actor, "bAlwaysRelevant", true) then applied = applied + 1 end
    if setProperty(actor, "bNetLoadOnClient", true) then applied = applied + 1 end
    if setProperty(actor, "NetCullDistanceSquared", NET_CULL_DISTANCE_SQUARED) then applied = applied + 1 end
    return applied
end

local function finalizeActor(actor)
    if not valid(actor) then return end
    pcall(function() actor:SetActorEnableCollision(false) end)
    pcall(function() actor:SetActorHiddenInGame(false) end)
    pcall(function() actor:SetReplicates(true) end)
    pcall(function() actor:SetReplicateMovement(true) end)
    pcall(function() actor:FlushNetDormancy() end)
    pcall(function() actor:ForceNetUpdate() end)
end

local function deferredSpawn(world, class, location, rotation)
    if helperStatus ~= "ready" or not valid(gameplayStatics) then
        return nil, "UEHelpers GameplayStatics unavailable"
    end

    local transform, transformErr = makeTransform(location, rotation)
    if transform == nil then return nil, "MakeTransform failed: " .. tostring(transformErr) end

    local beginCallOk, deferred = pcall(function()
        return gameplayStatics:BeginDeferredActorSpawnFromClass(
            world,
            class,
            transform,
            ALWAYS_SPAWN,
            nil
        )
    end)
    deferred = unwrap(deferred)
    if beginCallOk and valid(deferred) then
        beginSignature = "5_args"
    else
        local firstErr = tostring(deferred)
        beginCallOk, deferred = pcall(function()
            return gameplayStatics:BeginDeferredActorSpawnFromClass(
                world,
                class,
                transform,
                ALWAYS_SPAWN,
                nil,
                TRANSFORM_SCALE_MULTIPLY_WITH_ROOT
            )
        end)
        deferred = unwrap(deferred)
        if beginCallOk and valid(deferred) then
            beginSignature = "6_args"
        else
            return nil, "BeginDeferred failed (5=" .. firstErr .. "; 6=" .. tostring(deferred) .. ")"
        end
    end

    beginOkCount = beginOkCount + 1
    replicationBoostCount = replicationBoostCount + primeDeferredActor(deferred)

    local finishCallOk, finished = pcall(function()
        return gameplayStatics:FinishSpawningActor(deferred, transform)
    end)
    finished = unwrap(finished)

    local actor = valid(finished) and finished or deferred
    if not finishCallOk or not valid(actor) then
        if valid(deferred) then pcall(function() deferred:K2_DestroyActor() end) end
        return nil, "FinishSpawningActor failed: " .. tostring(finished)
    end

    finishOkCount = finishOkCount + 1
    finalizeActor(actor)
    return actor, nil
end

local function beginVisual(raid)
    center = {
        X = tonumber(raid.x) or 0,
        Y = tonumber(raid.y) or 0,
        Z = tonumber(raid.z) or 0
    }
    local players = onlinePlayers()
    visualZ = chooseVisualZ(raid, players)

    if helperStatus ~= "ready" then
        visualStatus = "uehelpers_unavailable"
        lastError = helperError
        snapshotActive()
        writeStatus(raid)
        return false
    end

    if not resolveVisualClass() then
        visualStatus = "class_unavailable"
        lastError = "Exact loaded brazier class unavailable"
        snapshotActive()
        writeStatus(raid)
        return false
    end

    if not valid(worldFromPlayers(players)) then
        visualStatus = "world_unavailable"
        lastError = "UWorld unavailable"
        snapshotActive()
        writeStatus(raid)
        return false
    end

    nextIndex = 0
    visualStatus = "spawning_deferred_always_spawn"
    lastError = ""
    snapshotActive()
    log(string.format("deferred FIRE arena start: radius=%d markers=%d", math.floor(RADIUS), MARKERS))
    writeStatus(raid)
    return true
end

local function spawnBatch(raid)
    if not center and not beginVisual(raid) then return end
    local class = resolveVisualClass()
    if not class then return end
    local players = onlinePlayers()
    local world = worldFromPlayers(players)
    if not valid(world) then
        visualStatus = "world_lost"
        lastError = "UWorld unavailable during spawn"
        snapshotActive()
        writeStatus(raid)
        return
    end

    local spawnedThisBatch = 0
    while nextIndex < MARKERS and spawnedThisBatch < SPAWN_BATCH do
        local i = nextIndex
        local angle = (math.pi * 2 * i) / MARKERS
        local location = {
            X = center.X + math.cos(angle) * RADIUS,
            Y = center.Y + math.sin(angle) * RADIUS,
            Z = visualZ
        }
        local rotation = { Pitch = 0, Yaw = math.deg(angle) + 90, Roll = 0 }

        local actor, err = deferredSpawn(world, class, location, rotation)
        if valid(actor) then
            actors[#actors + 1] = actor
            lastError = ""
        else
            lastError = "marker " .. tostring(i + 1) .. ": " .. tostring(err)
            log(lastError)
        end

        nextIndex = nextIndex + 1
        spawnedThisBatch = spawnedThisBatch + 1
    end

    if nextIndex >= MARKERS then
        if #actors == MARKERS then
            visualStatus = "server_fire_ring_deferred_replicating"
            lastError = ""
        elseif #actors > 0 then
            visualStatus = "server_fire_ring_partial"
        else
            visualStatus = "server_fire_ring_failed"
        end
        log(string.format("deferred fire arena finished: %d/%d begin=%d finish=%d", #actors, MARKERS, beginOkCount, finishOkCount))
    else
        visualStatus = "spawning_deferred_always_spawn"
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
            local ok, err = xpcall(function()
                resetRaid(raidId)
                writeStatus(raid)
            end, debug.traceback)
            if not ok then log("raid reset failed: " .. tostring(err)) end
            scheduled = false
        end)
        return false
    end

    if not isActive then
        if #actors > 0 or center ~= nil then
            scheduled = true
            ExecuteInGameThread(function()
                local ok, err = xpcall(function()
                    snapshotActive()
                    destroyActors()
                    center = nil
                    visualStatus = "released"
                    writeStatus(raid)
                end, debug.traceback)
                if not ok then log("visual cleanup failed: " .. tostring(err)) end
                scheduled = false
            end)
        else
            writeStatus(raid)
        end
        return false
    end

    if nextIndex < MARKERS then
        scheduled = true
        ExecuteInGameThread(function()
            local ok, err = xpcall(function() spawnBatch(raid) end, debug.traceback)
            if not ok then
                visualStatus = "spawn_exception"
                lastError = tostring(err)
                snapshotActive()
                log("visual spawn failed: " .. lastError)
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
log("v" .. VERSION .. " loaded; DEFERRED AlwaysSpawn server-only fire arena")
log("v0.4 multi-return actor-loss bug removed; replication enabled before FinishSpawningActor")
