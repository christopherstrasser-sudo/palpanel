-- PalPanelServerMods raid arena v0.2.7
-- Static authoritative raid arena with exact visual-class resolution.
--
-- v0.2.6 accidentally accepted any AssetRegistry entry containing
-- "LevelGimmick_AreaBarrier" and could therefore resolve
-- BP_CutsceneActor_LevelGimmick_AreaBarrier_C instead of the real
-- BP_LevelGimmick_AreaBarrier_C. v0.2.7 accepts the exact class only,
-- enables the blueprint's locked ViewModel/Niagara state, and preserves
-- the last ACTIVE visual diagnostics after a raid is cancelled/finished.

local MOD = "PalPanelRaidArena"
local VERSION = "0.2.7"
local RADIUS = 6000.0
local SEGMENTS = 32
local MIN_VISUAL_SEGMENTS = 20
local INNER_MARGIN = 400.0
local OUTER_MARGIN = 400.0
local TICK_MS = 250

local BARRIER_ASSET_NAME = "BP_LevelGimmick_AreaBarrier"
local BARRIER_CLASS_NAME = "BP_LevelGimmick_AreaBarrier_C"

-- The previous registry result revealed the real LevelGimmickAreaBarrier
-- directory on current Palworld builds. We still keep recursive roots as a
-- fallback because Pocketpair may move the asset in a later update.
local DIRECT_PACKAGES = {
    "/Game/Pal/Blueprint/MapObject/Object/LevelObject/LevelGimmickAreaBarrier/BP_LevelGimmick_AreaBarrier"
}

local ASSET_SEARCH_ROOTS = {
    "/Game/Pal/Blueprint/MapObject/Object/LevelObject/LevelGimmickAreaBarrier",
    "/Game/Pal/Blueprint/MapObject",
    "/Game/Pal/Blueprint/LevelObject",
    "/Game/Pal/Blueprint/LevelGimmick",
    "/Game/Pal/MapObject",
    "/Game/Pal/LevelObject",
    "/Game/Pal/LevelGimmick",
    "/Game/Pal/Blueprint"
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
    local addressOk, address = pcall(function() return obj:GetAddress() end)
    if addressOk and tonumber(address) == 0 then return false end
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
    local value = nil
    pcall(function() value = obj:GetFName() end)
    return toText(value) or ""
end

local function exactBarrierClass(obj)
    obj = unwrap(obj)
    return valid(obj) and shortName(obj) == BARRIER_CLASS_NAME
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

local function playerName(ps)
    return toText(member(ps, "PlayerNamePrivate"))
        or toText(member(ps, "SavedPlayerName"))
        or "Unbekannt"
end

local function playerUid(ps)
    if not valid(ps) then return "" end
    return guidHex(member(ps, "PlayerUId"))
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
    if not valid(actor) then return nil end
    local at = nil
    pcall(function() at = actor:K2_GetActorLocation() end)
    if not at then return nil end
    return {
        X = tonumber(at.X) or 0,
        Y = tonumber(at.Y) or 0,
        Z = tonumber(at.Z) or 0
    }
end

local function onlinePlayers()
    local states = nil
    pcall(function() states = FindAllOf("PalPlayerState") end)
    if type(states) ~= "table" then return {} end

    local rows, seen = {}, {}
    for _, ps in ipairs(states) do
        ps = unwrap(ps)
        if valid(ps) then
            local uid = playerUid(ps)
            local pawn = playerPawn(ps)
            local key = uid ~= "" and uid or string.lower(playerName(ps))
            if key ~= "" and not seen[key] and valid(pawn) then
                local at = actorLocation(pawn)
                if at then
                    seen[key] = true
                    rows[#rows + 1] = {
                        uid = uid ~= "" and uid or key,
                        name = playerName(ps),
                        pawn = pawn,
                        at = at
                    }
                end
            end
        end
    end
    return rows
end

local scriptsDir = scriptDir()
if not scriptsDir then
    log("Scripts directory unavailable; arena disabled")
    return
end

local modDir = scriptsDir:match("^(.+)\\Scripts$") or scriptsDir
local ipcDir = readAll(modDir .. "\\ipc_path.txt")
if ipcDir then ipcDir = ipcDir:gsub("[\r\n]+$", "") end
if not ipcDir or ipcDir == "" then
    log("ipc_path.txt unavailable; arena disabled")
    return
end

local raidStatusFile = ipcDir .. "\\raid-status.txt"
local arenaStatusFile = ipcDir .. "\\raid-arena-status.txt"

local currentRaidId = ""
local locked = false
local lockedAt = 0
local arenaCenter = nil
local centerSource = "none"
local participants = {}
local participantNames = {}
local bounceIn = 0
local bounceOut = 0
local lastError = ""
local scheduled = false

local visualReady = false
local visualAttempted = false
local visualStatus = "waiting"
local classSource = "none"
local resolvedClassName = ""
local visualPackage = ""
local registryStatus = "not_attempted"
local barrierActors = {}
local cachedBarrierClass = nil
local viewUpdatesOk = 0
local lastSpawnAttemptCount = 0

-- Persisted ACTIVE snapshot. v0.2.6 erased the useful evidence during cleanup.
local lastActive = {
    valid = false,
    visible = false,
    visualStatus = "none",
    classSource = "none",
    resolvedClassName = "",
    visualPackage = "",
    registryStatus = "not_attempted",
    segments = 0,
    viewUpdatesOk = 0,
    error = "",
    center = nil,
    lockedAt = 0
}

local function participantCount()
    local n = 0
    for _ in pairs(participants) do n = n + 1 end
    return n
end

local function snapshotActive()
    if not arenaCenter and not visualAttempted and not locked then return end
    lastActive.valid = true
    lastActive.visible = visualReady
    lastActive.visualStatus = visualStatus
    lastActive.classSource = classSource
    lastActive.resolvedClassName = resolvedClassName
    lastActive.visualPackage = visualPackage
    lastActive.registryStatus = registryStatus
    lastActive.segments = math.max(#barrierActors, lastSpawnAttemptCount)
    lastActive.viewUpdatesOk = viewUpdatesOk
    lastActive.error = lastError
    lastActive.lockedAt = lockedAt
    if arenaCenter then
        lastActive.center = { X = arenaCenter.X, Y = arenaCenter.Y, Z = arenaCenter.Z }
    end
end

local function writeStatus(raid)
    local center = arenaCenter or { X = 0, Y = 0, Z = 0 }
    local lastCenter = lastActive.center or { X = 0, Y = 0, Z = 0 }
    local lines = {
        "version=" .. VERSION,
        "time=" .. tostring(os.time()),
        "raid_id=" .. urlEncode(currentRaidId),
        "raid_state=" .. urlEncode(raid and raid.state or "IDLE"),
        "locked=" .. (locked and "1" or "0"),
        "center_frozen=" .. (arenaCenter and "1" or "0"),
        "center_source=" .. urlEncode(centerSource),
        "center_x=" .. tostring(center.X or 0),
        "center_y=" .. tostring(center.Y or 0),
        "center_z=" .. tostring(center.Z or 0),
        "visible=" .. (visualReady and "1" or "0"),
        "visual_attempted=" .. (visualAttempted and "1" or "0"),
        "visual_status=" .. urlEncode(visualStatus),
        "class_source=" .. urlEncode(classSource),
        "resolved_class_name=" .. urlEncode(resolvedClassName),
        "visual_package=" .. urlEncode(visualPackage),
        "registry_status=" .. urlEncode(registryStatus),
        "radius=" .. tostring(math.floor(RADIUS)),
        "segments_requested=" .. tostring(SEGMENTS),
        "segments_spawned=" .. tostring(#barrierActors),
        "segments_last_attempt=" .. tostring(lastSpawnAttemptCount),
        "view_updates_ok=" .. tostring(viewUpdatesOk),
        "participant_count=" .. tostring(participantCount()),
        "locked_at=" .. tostring(lockedAt),
        "bounce_in=" .. tostring(bounceIn),
        "bounce_out=" .. tostring(bounceOut),
        "last_error=" .. urlEncode(lastError),
        "last_active_valid=" .. (lastActive.valid and "1" or "0"),
        "last_active_visible=" .. (lastActive.visible and "1" or "0"),
        "last_active_visual_status=" .. urlEncode(lastActive.visualStatus),
        "last_active_class_source=" .. urlEncode(lastActive.classSource),
        "last_active_resolved_class_name=" .. urlEncode(lastActive.resolvedClassName),
        "last_active_visual_package=" .. urlEncode(lastActive.visualPackage),
        "last_active_registry_status=" .. urlEncode(lastActive.registryStatus),
        "last_active_segments=" .. tostring(lastActive.segments or 0),
        "last_active_view_updates_ok=" .. tostring(lastActive.viewUpdatesOk or 0),
        "last_active_error=" .. urlEncode(lastActive.error),
        "last_active_locked_at=" .. tostring(lastActive.lockedAt or 0),
        "last_active_center_x=" .. tostring(lastCenter.X or 0),
        "last_active_center_y=" .. tostring(lastCenter.Y or 0),
        "last_active_center_z=" .. tostring(lastCenter.Z or 0)
    }

    local i = 0
    for uid, name in pairs(participantNames) do
        i = i + 1
        lines[#lines + 1] = string.format("participant_%d_uid=%s", i, urlEncode(uid))
        lines[#lines + 1] = string.format("participant_%d_name=%s", i, urlEncode(name))
    end

    writeAll(arenaStatusFile, table.concat(lines, "\n") .. "\n")
end

local function cleanupVisual()
    for _, actor in ipairs(barrierActors) do
        if valid(actor) then
            pcall(function() actor:K2_DestroyActor() end)
        end
    end
    barrierActors = {}
    visualReady = false
end

local function reset(raidId)
    currentRaidId = tostring(raidId or "")
    locked = false
    lockedAt = 0
    arenaCenter = nil
    centerSource = "none"
    participants = {}
    participantNames = {}
    bounceIn = 0
    bounceOut = 0
    lastError = ""
    visualReady = false
    visualAttempted = false
    visualStatus = "waiting_active_raid"
    classSource = "none"
    resolvedClassName = ""
    visualPackage = ""
    registryStatus = "not_attempted"
    barrierActors = {}
    cachedBarrierClass = nil
    viewUpdatesOk = 0
    lastSpawnAttemptCount = 0
    lastActive = {
        valid = false,
        visible = false,
        visualStatus = "none",
        classSource = "none",
        resolvedClassName = "",
        visualPackage = "",
        registryStatus = "not_attempted",
        segments = 0,
        viewUpdatesOk = 0,
        error = "",
        center = nil,
        lockedAt = 0
    }
end

local function distance2d(at, center)
    local dx = (at.X or 0) - (center.X or 0)
    local dy = (at.Y or 0) - (center.Y or 0)
    return math.sqrt(dx * dx + dy * dy), dx, dy
end

local function teleport(actor, at)
    if not valid(actor) then return false, "invalid pawn" end
    local ok, result = pcall(function()
        return actor:K2_TeleportTo(
            { X = at.X, Y = at.Y, Z = at.Z },
            { Pitch = 0, Yaw = 0, Roll = 0 }
        )
    end)
    if not ok then return false, tostring(result) end
    return result ~= false, result == false and "K2_TeleportTo returned false" or nil
end

local function boundaryPoint(center, current, radius, dx, dy, dist)
    local nx, ny = 1, 0
    if dist and dist > 0.001 then
        nx, ny = dx / dist, dy / dist
    end
    local z = current.Z
    if dist and dist > RADIUS * 2 then
        z = (center.Z or current.Z) + 120
    end
    return {
        X = (center.X or 0) + nx * radius,
        Y = (center.Y or 0) + ny * radius,
        Z = z
    }
end

local function acceptClass(obj, source, packageName)
    obj = unwrap(obj)
    if not exactBarrierClass(obj) then return nil end
    classSource = source
    resolvedClassName = shortName(obj)
    visualPackage = packageName or ""
    return obj
end

local function tryStaticClass(packageName, source)
    if not packageName or packageName == "" then return nil end
    local candidates = {
        packageName .. "." .. BARRIER_CLASS_NAME,
        "BlueprintGeneratedClass " .. packageName .. "." .. BARRIER_CLASS_NAME,
        "/Script/Engine.BlueprintGeneratedClass'" .. packageName .. "." .. BARRIER_CLASS_NAME .. "'"
    }
    for _, path in ipairs(candidates) do
        local ok, found = pcall(StaticFindObject, path)
        if ok then
            local accepted = acceptClass(found, source, packageName)
            if accepted then return accepted end
        end
    end
    return nil
end

local function classFromLoadedObjects()
    local found, instance = pcall(FindFirstOf, BARRIER_CLASS_NAME)
    instance = unwrap(instance)
    if found and valid(instance) then
        local ok, class = pcall(function() return instance:GetClass() end)
        if ok then
            class = acceptClass(class, "live_exact_instance", "already_loaded")
            if class then return class end
        end
    end

    local ok, classes = pcall(FindAllOf, "BlueprintGeneratedClass")
    if ok and type(classes) == "table" then
        for _, class in ipairs(classes) do
            local accepted = acceptClass(class, "loaded_exact_class_scan", "already_loaded")
            if accepted then return accepted end
        end
    end
    return nil
end

local function getAssetRegistry()
    local helpers = nil
    pcall(function()
        helpers = StaticFindObject("/Script/AssetRegistry.Default__AssetRegistryHelpers")
    end)
    helpers = unwrap(helpers)
    if not valid(helpers) then
        registryStatus = "helpers_unavailable"
        return nil, nil
    end

    local registry = nil
    local ok, result = pcall(function() return helpers:GetAssetRegistry() end)
    if ok then registry = unwrap(result) end

    if not valid(registry) then
        local impl = nil
        pcall(function()
            impl = StaticFindObject("/Script/AssetRegistry.Default__AssetRegistryImpl")
        end)
        impl = unwrap(impl)
        if valid(impl) then registry = impl end
    end

    if not valid(registry) then
        registryStatus = "registry_unavailable"
        return helpers, nil
    end

    registryStatus = "ready"
    return helpers, registry
end

local function resolveExactAssetDataClass(helpers, data, packageName)
    -- Load the exact blueprint through AssetRegistry first. Never accept the
    -- GeneratedClass of another blueprint with a similar name.
    local asset = nil
    local ok, result = pcall(function() return helpers:GetAsset(data) end)
    if ok then asset = unwrap(result) end

    if valid(asset) then
        local generated = member(asset, "GeneratedClass")
        local accepted = acceptClass(generated, "asset_registry_exact_generated_class", packageName)
        if accepted then return accepted end
    end

    return tryStaticClass(packageName, "asset_registry_exact_static_find")
end

local function classFromAssetRegistry()
    local helpers, registry = getAssetRegistry()
    if not valid(helpers) or not valid(registry) then return nil end

    for _, root in ipairs(ASSET_SEARCH_ROOTS) do
        pcall(function()
            if registry.ScanPathsSynchronous then
                registry:ScanPathsSynchronous({ root }, false, true)
            end
        end)

        local assets = {}
        local ok, err = pcall(function()
            registry:GetAssetsByPath(FName(root), assets, true, true)
        end)
        if ok then
            local count = 0
            pcall(function() count = #assets end)
            log(string.format("AssetRegistry scan %s -> %d assets", root, count))

            for i = 1, count do
                local data = unwrap(assets[i])
                if data ~= nil then
                    local assetName = toText(member(data, "AssetName")) or ""
                    local packageName = toText(member(data, "PackageName")) or ""
                    if assetName == BARRIER_ASSET_NAME or assetName == BARRIER_CLASS_NAME then
                        log(string.format("EXACT AreaBarrier asset: %s -> %s", assetName, packageName))
                        local class = resolveExactAssetDataClass(helpers, data, packageName)
                        if class then
                            registryStatus = "found_exact"
                            return class
                        end
                        registryStatus = "exact_asset_class_unresolved"
                        lastError = "Exact AreaBarrier asset found, but generated class could not be resolved"
                    end
                end
            end
        else
            log("AssetRegistry GetAssetsByPath failed for " .. root .. ": " .. tostring(err))
        end
    end

    if registryStatus == "ready" then registryStatus = "exact_asset_not_found" end
    return nil
end

local function barrierClass()
    if exactBarrierClass(cachedBarrierClass) then return cachedBarrierClass end

    local class = classFromLoadedObjects()
    if class then cachedBarrierClass = class; return class end

    -- First try the directory discovered from the server's own v0.2.6
    -- AssetRegistry output. If the exact class was already loaded by a nearby
    -- asset lookup this resolves immediately.
    for _, packageName in ipairs(DIRECT_PACKAGES) do
        class = tryStaticClass(packageName, "known_exact_package")
        if class then cachedBarrierClass = class; return class end
    end

    class = classFromAssetRegistry()
    if class then cachedBarrierClass = class; return class end

    class = classFromLoadedObjects()
    if class then cachedBarrierClass = class; return class end

    classSource = "unavailable"
    resolvedClassName = ""
    return nil
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

local function prepareVisualActor(actor)
    if not valid(actor) then return false end

    pcall(function() actor:SetReplicates(true) end)
    pcall(function() actor:SetReplicateMovement(false) end)
    pcall(function() actor:SetActorEnableCollision(false) end)
    pcall(function() actor:SetActorHiddenInGame(false) end)
    pcall(function() actor:SetActorScale3D({ X = 2.4, Y = 2.4, Z = 3.0 }) end)

    -- The real blueprint exposes FPalLevelGimmick_AreaBarrier_ViewModel with
    -- a single bLocked flag. Merely activating the Niagara component is not
    -- enough; tell the blueprint that its barrier is in the locked state.
    pcall(function() actor:ResetNiagara() end)
    local viewOk = pcall(function()
        actor:UpdateView({ bLocked = true })
    end)
    if viewOk then viewUpdatesOk = viewUpdatesOk + 1 end

    pcall(function() actor:SetNiagaraParams(1.0, 0.0, 0.0) end)

    local niagara = member(actor, "Niagara")
    if valid(niagara) then
        pcall(function() niagara:SetVisibility(true, true) end)
        pcall(function() niagara:Activate(true) end)
    end

    pcall(function() actor:ForceNetUpdate() end)
    return viewOk
end

local function spawnVisualRing(center, players)
    visualAttempted = true
    visualStatus = "resolving_exact_barrier"
    lastSpawnAttemptCount = 0
    viewUpdatesOk = 0

    local class = barrierClass()
    if not class then
        visualStatus = "exact_class_unavailable_locked"
        if lastError == "" then
            lastError = "Arena-Lock aktiv; exakte BP_LevelGimmick_AreaBarrier_C nicht aufloesbar"
        end
        log(lastError)
        snapshotActive()
        return false
    end

    local world = worldFromPlayers(players)
    if not valid(world) then
        visualStatus = "world_unavailable_locked"
        lastError = "Arena-Lock aktiv, aber UWorld ist fuer die sichtbare Barriere nicht verfuegbar"
        log(lastError)
        snapshotActive()
        return false
    end

    visualStatus = "spawning_exact_barrier"
    local created = {}

    for i = 0, SEGMENTS - 1 do
        local angle = (math.pi * 2 * i) / SEGMENTS
        local location = {
            X = center.X + math.cos(angle) * RADIUS,
            Y = center.Y + math.sin(angle) * RADIUS,
            Z = center.Z
        }
        local rotation = {
            Pitch = 0,
            Yaw = math.deg(angle) + 90,
            Roll = 0
        }

        local ok, result = pcall(function()
            return world:SpawnActor(class, location, rotation)
        end)
        local actor = unwrap(result)

        if ok and valid(actor) then
            prepareVisualActor(actor)
            created[#created + 1] = actor
        else
            log("exact barrier segment " .. tostring(i + 1) .. " spawn failed: " .. tostring(result))
        end
    end

    barrierActors = created
    lastSpawnAttemptCount = #created

    if #barrierActors < MIN_VISUAL_SEGMENTS then
        visualStatus = "spawn_incomplete_locked"
        lastError = string.format(
            "Arena-Lock aktiv, exakte sichtbare Barriere unvollstaendig: %d/%d Segmente",
            #barrierActors,
            SEGMENTS
        )
        log(lastError)
        snapshotActive()
        cleanupVisual()
        return false
    end

    visualReady = true
    visualStatus = viewUpdatesOk > 0 and "visible_locked_viewmodel_applied" or "spawned_locked_viewmodel_failed"
    if viewUpdatesOk == 0 then
        lastError = "Barrier-Actors gespawnt, aber UpdateView(bLocked=true) schlug fuer alle Segmente fehl"
    else
        lastError = ""
    end
    snapshotActive()
    log(string.format(
        "EXACT STATIC raid barrier ready: %d/%d segments, UpdateView=%d (%s, %s)",
        #barrierActors,
        SEGMENTS,
        viewUpdatesOk,
        classSource,
        visualPackage
    ))
    return true
end

local function captureParticipants(raid, players, center)
    participants = {}
    participantNames = {}

    for _, p in ipairs(players) do
        local dist = distance2d(p.at, center)
        if dist <= RADIUS then
            participants[p.uid] = true
            participantNames[p.uid] = p.name
        end
    end

    local anchor = string.lower(tostring(raid.anchor_name or ""))
    if anchor ~= "" then
        for _, p in ipairs(players) do
            if string.lower(tostring(p.name or "")) == anchor then
                participants[p.uid] = true
                participantNames[p.uid] = p.name
            end
        end
    end
end

local function mergeRecordedParticipants(raid)
    local count = math.max(0, math.min(100, tonumber(raid.participants) or 0))
    for i = 1, count do
        local uid = tostring(raid["participant_" .. i .. "_uid"] or "")
        local name = tostring(raid["participant_" .. i .. "_name"] or uid)
        if uid ~= "" then
            participants[uid] = true
            participantNames[uid] = name
        end
    end
end

local function freezeCenter(raid)
    if arenaCenter then return arenaCenter end
    arenaCenter = {
        X = tonumber(raid.x) or 0,
        Y = tonumber(raid.y) or 0,
        Z = tonumber(raid.z) or 0
    }
    centerSource = "raid_active_snapshot"
    log(string.format(
        "arena center FROZEN: X=%.1f Y=%.1f Z=%.1f",
        arenaCenter.X,
        arenaCenter.Y,
        arenaCenter.Z
    ))
    return arenaCenter
end

local function startArena(raid)
    local center = freezeCenter(raid)
    local players = onlinePlayers()

    captureParticipants(raid, players, center)
    mergeRecordedParticipants(raid)

    locked = true
    lockedAt = os.time()
    visualStatus = "lock_active_visual_pending"
    log(string.format(
        "STATIC arena LOCKED; radius=%d; participants=%d",
        RADIUS,
        participantCount()
    ))

    spawnVisualRing(center, players)
    snapshotActive()
    writeStatus(raid)
end

local function enforceArena(raid)
    if not locked then return end

    local center = arenaCenter or freezeCenter(raid)
    mergeRecordedParticipants(raid)

    for _, p in ipairs(onlinePlayers()) do
        local dist, dx, dy = distance2d(p.at, center)

        if participants[p.uid] then
            participantNames[p.uid] = p.name
            if dist > RADIUS then
                local target = boundaryPoint(center, p.at, RADIUS - INNER_MARGIN, dx, dy, dist)
                local ok, err = teleport(p.pawn, target)
                if ok then
                    bounceIn = bounceIn + 1
                    log("kept participant inside STATIC arena: " .. tostring(p.name))
                else
                    lastError = "keep-in teleport failed for " .. tostring(p.name) .. ": " .. tostring(err)
                    log(lastError)
                end
            end
        elseif dist < RADIUS then
            local target = boundaryPoint(center, p.at, RADIUS + OUTER_MARGIN, dx, dy, dist)
            local ok, err = teleport(p.pawn, target)
            if ok then
                bounceOut = bounceOut + 1
                log("kept outsider outside STATIC arena: " .. tostring(p.name))
            else
                lastError = "keep-out teleport failed for " .. tostring(p.name) .. ": " .. tostring(err)
                log(lastError)
            end
        end
    end

    snapshotActive()
    writeStatus(raid)
end

LoopAsync(TICK_MS, function()
    local raid = parseKv(readAll(raidStatusFile) or "active=0\nstate=IDLE\n")
    local raidId = tostring(raid.raid_id or "")

    if raidId ~= currentRaidId and currentRaidId == "" then
        reset(raidId)
    end

    if scheduled then return false end

    if raidId ~= currentRaidId and currentRaidId ~= "" then
        scheduled = true
        ExecuteInGameThread(function()
            snapshotActive()
            cleanupVisual()
            reset(raidId)
            writeStatus(raid)
            scheduled = false
        end)
        return false
    end

    if raid.active ~= "1" or raid.state ~= "ACTIVE" then
        if locked or #barrierActors > 0 then
            scheduled = true
            ExecuteInGameThread(function()
                snapshotActive()
                cleanupVisual()
                locked = false
                lockedAt = 0
                arenaCenter = nil
                centerSource = "released"
                participants = {}
                participantNames = {}
                visualStatus = "released"
                writeStatus(raid)
                scheduled = false
            end)
        else
            writeStatus(raid)
        end
        return false
    end

    scheduled = true
    ExecuteInGameThread(function()
        local ok, err = xpcall(function()
            if not locked then startArena(raid) end
            enforceArena(raid)
        end, debug.traceback)

        if not ok then
            lastError = tostring(err)
            log("arena tick failed: " .. lastError)
            snapshotActive()
            writeStatus(raid)
        end

        scheduled = false
    end)
    return false
end)

reset("")
writeStatus({ state = "IDLE", participants = "0" })
log("v" .. VERSION .. " loaded; static radius=" .. tostring(math.floor(RADIUS)) .. " units")
log("Exact BP_LevelGimmick_AreaBarrier_C only; UpdateView(bLocked=true); ACTIVE diagnostics persist after cleanup")
