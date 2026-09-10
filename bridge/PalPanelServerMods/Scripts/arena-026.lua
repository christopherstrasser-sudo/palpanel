-- PalPanelServerMods raid arena v0.2.6
-- Static authoritative raid arena.
-- The arena center is frozen exactly once when the raid becomes ACTIVE and can
-- never follow the raid boss afterwards. Gameplay enforcement is independent
-- from visuals. Visual lookup uses AssetRegistry instead of guessed LoadAsset
-- paths, because the dedicated server may not have the blueprint package loaded.

local MOD = "PalPanelRaidArena"
local VERSION = "0.2.6"
local RADIUS = 6000.0
local SEGMENTS = 32
local MIN_VISUAL_SEGMENTS = 20
local INNER_MARGIN = 400.0
local OUTER_MARGIN = 400.0
local TICK_MS = 250
local BARRIER_ASSET_NAME = "BP_LevelGimmick_AreaBarrier"
local BARRIER_CLASS_NAME = "BP_LevelGimmick_AreaBarrier_C"

local ASSET_SEARCH_ROOTS = {
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
    local okString, textString = pcall(tostring, value)
    if okString and type(textString) == "string" and textString ~= "" then return textString end
    return nil
end

local function shortName(obj)
    obj = unwrap(obj)
    if not valid(obj) then return "" end
    local value = nil
    pcall(function() value = obj:GetFName() end)
    return toText(value) or ""
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
local visualPackage = ""
local registryStatus = "not_attempted"
local barrierActors = {}
local cachedBarrierClass = nil

local function participantCount()
    local n = 0
    for _ in pairs(participants) do n = n + 1 end
    return n
end

local function writeStatus(raid)
    local center = arenaCenter or { X = 0, Y = 0, Z = 0 }
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
        "visual_package=" .. urlEncode(visualPackage),
        "registry_status=" .. urlEncode(registryStatus),
        "radius=" .. tostring(math.floor(RADIUS)),
        "segments_requested=" .. tostring(SEGMENTS),
        "segments_spawned=" .. tostring(#barrierActors),
        "participant_count=" .. tostring(participantCount()),
        "locked_at=" .. tostring(lockedAt),
        "bounce_in=" .. tostring(bounceIn),
        "bounce_out=" .. tostring(bounceOut),
        "last_error=" .. urlEncode(lastError)
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
    visualPackage = ""
    registryStatus = "not_attempted"
    barrierActors = {}
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

local function classFromLoadedObjects()
    local found, instance = pcall(FindFirstOf, BARRIER_CLASS_NAME)
    instance = unwrap(instance)
    if found and valid(instance) then
        local ok, class = pcall(function() return instance:GetClass() end)
        class = unwrap(class)
        if ok and valid(class) then
            classSource = "live_instance"
            visualPackage = "already_loaded"
            return class
        end
    end

    local ok, classes = pcall(FindAllOf, "BlueprintGeneratedClass")
    if ok and type(classes) == "table" then
        for _, class in ipairs(classes) do
            class = unwrap(class)
            if valid(class) then
                local name = shortName(class)
                if name == BARRIER_CLASS_NAME or name:find("LevelGimmick_AreaBarrier", 1, true) then
                    classSource = "loaded_class_scan"
                    visualPackage = "already_loaded"
                    return class
                end
            end
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

local function resolveAssetDataClass(helpers, data, packageName, assetName)
    local asset = nil
    local getOk, getResult = pcall(function() return helpers:GetAsset(data) end)
    if getOk then asset = unwrap(getResult) end

    if valid(asset) then
        local generated = member(asset, "GeneratedClass")
        if valid(generated) then
            classSource = "asset_registry_generated_class"
            visualPackage = packageName
            return generated
        end

        local assetClass = nil
        pcall(function() assetClass = asset:GetClass() end)
        assetClass = unwrap(assetClass)
        if valid(assetClass) and shortName(assetClass) == BARRIER_CLASS_NAME then
            classSource = "asset_registry_asset_class"
            visualPackage = packageName
            return assetClass
        end
    end

    local classNames = {
        packageName .. "." .. BARRIER_CLASS_NAME,
        packageName .. "." .. assetName .. "_C",
        "BlueprintGeneratedClass " .. packageName .. "." .. BARRIER_CLASS_NAME,
        "/Script/Engine.BlueprintGeneratedClass'" .. packageName .. "." .. BARRIER_CLASS_NAME .. "'"
    }

    for _, objectPath in ipairs(classNames) do
        local ok, found = pcall(StaticFindObject, objectPath)
        found = unwrap(found)
        if ok and valid(found) then
            classSource = "asset_registry_static_find"
            visualPackage = packageName
            return found
        end
    end

    return nil
end

local function classFromAssetRegistry()
    local helpers, registry = getAssetRegistry()
    if not valid(helpers) or not valid(registry) then return nil end

    for _, root in ipairs(ASSET_SEARCH_ROOTS) do
        -- Best effort registry refresh. Some UE4SS/game builds expose this
        -- IAssetRegistry method, others do not; failure is harmless.
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
                    if assetName == BARRIER_ASSET_NAME
                        or assetName == BARRIER_CLASS_NAME
                        or assetName:find("LevelGimmick_AreaBarrier", 1, true) then
                        log(string.format("AssetRegistry candidate: %s -> %s", assetName, packageName))
                        local class = resolveAssetDataClass(helpers, data, packageName, assetName)
                        if valid(class) then
                            registryStatus = "found"
                            return class
                        end
                    end
                end
            end
        else
            log("AssetRegistry GetAssetsByPath failed for " .. root .. ": " .. tostring(err))
        end
    end

    registryStatus = "not_found"
    return nil
end

local function barrierClass()
    if valid(cachedBarrierClass) then return cachedBarrierClass end

    local class = classFromLoadedObjects()
    if valid(class) then
        cachedBarrierClass = class
        return class
    end

    class = classFromAssetRegistry()
    if valid(class) then
        cachedBarrierClass = class
        return class
    end

    class = classFromLoadedObjects()
    if valid(class) then
        cachedBarrierClass = class
        return class
    end

    classSource = "unavailable"
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
    if not valid(actor) then return end
    pcall(function() actor:SetReplicates(true) end)
    pcall(function() actor:SetActorEnableCollision(false) end)
    pcall(function() actor:SetActorScale3D({ X = 2.4, Y = 2.4, Z = 3.0 }) end)
    pcall(function() actor:ResetNiagara() end)

    local niagara = member(actor, "Niagara")
    if valid(niagara) then
        pcall(function() niagara:SetVisibility(true, true) end)
        pcall(function() niagara:Activate(true) end)
    end

    pcall(function() actor:ForceNetUpdate() end)
end

local function spawnVisualRing(center, players)
    visualAttempted = true
    visualStatus = "resolving_barrier"

    local class = barrierClass()
    if not valid(class) then
        visualStatus = "class_unavailable_locked"
        lastError = "Arena-Lock aktiv; sichtbare AreaBarrier konnte auch per AssetRegistry nicht aufgeloest werden"
        log(lastError)
        return false
    end

    local world = worldFromPlayers(players)
    if not valid(world) then
        visualStatus = "world_unavailable_locked"
        lastError = "Arena-Lock aktiv, aber UWorld ist fuer die sichtbare Barriere nicht verfuegbar"
        log(lastError)
        return false
    end

    visualStatus = "spawning"
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
            log("barrier segment " .. tostring(i + 1) .. " could not be spawned")
        end
    end

    barrierActors = created
    if #barrierActors < MIN_VISUAL_SEGMENTS then
        visualStatus = "spawn_incomplete_locked"
        lastError = string.format(
            "Arena-Lock aktiv, sichtbare Barriere unvollstaendig: %d/%d Segmente",
            #barrierActors,
            SEGMENTS
        )
        log(lastError)
        cleanupVisual()
        return false
    end

    visualReady = true
    visualStatus = "visible_locked"
    lastError = ""
    log(string.format(
        "visible STATIC raid barrier ready: %d/%d segments (%s, %s)",
        #barrierActors,
        SEGMENTS,
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
    writeStatus(raid)
end

local function enforceArena(raid)
    if not locked then return end

    local center = arenaCenter
    if not center then
        center = freezeCenter(raid)
    end

    mergeRecordedParticipants(raid)

    for _, p in ipairs(onlinePlayers()) do
        local dist, dx, dy = distance2d(p.at, center)

        if participants[p.uid] then
            participantNames[p.uid] = p.name
            if dist > RADIUS then
                local target = boundaryPoint(
                    center,
                    p.at,
                    RADIUS - INNER_MARGIN,
                    dx,
                    dy,
                    dist
                )
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
            local target = boundaryPoint(
                center,
                p.at,
                RADIUS + OUTER_MARGIN,
                dx,
                dy,
                dist
            )
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
            if not locked then
                startArena(raid)
            end
            enforceArena(raid)
        end, debug.traceback)

        if not ok then
            lastError = tostring(err)
            log("arena tick failed: " .. lastError)
            writeStatus(raid)
        end

        scheduled = false
    end)
    return false
end)

reset("")
writeStatus({ state = "IDLE", participants = "0" })
log("v" .. VERSION .. " loaded; static radius=" .. tostring(math.floor(RADIUS)) .. " units")
log("Arena center freezes on ACTIVE; visual lookup uses AssetRegistry; lock never follows the boss")
