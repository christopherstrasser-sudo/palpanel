-- PalPanelServerMods raid arena visual fallback v0.1.0
--
-- The native BP_LevelGimmick_AreaBarrier_C can be spawned successfully on the
-- dedicated server but its Niagara presentation is not replicated to ordinary
-- clients. This module therefore renders the SAME static raid circle with
-- ordinary Palworld build-wall actors whose class defaults contain a visible
-- static mesh and whose actor spawn is replicated normally.
--
-- Important: this module is VISUAL ONLY. Collision is disabled on every wall.
-- arena-027.lua remains the authoritative keep-in / keep-out boundary.

local MOD = "PalPanelRaidArenaVisual"
local VERSION = "0.1.0"
local TICK_MS = 500
local RETRY_SECONDS = 5
local RADIUS = 6000.0
local SEGMENTS = 48
local MIN_SEGMENTS = 36
local GROUND_OFFSET = 95.0
local WALL_ASSET_NAME = "BP_BuildObject_Wood_Wall_V2"
local WALL_CLASS_NAME = "BP_BuildObject_Wood_Wall_V2_C"
local WALL_SCALE = { X = 2.6, Y = 2.6, Z = 2.8 }

local SEARCH_ROOTS = {
    "/Game/Pal/Blueprint/MapObject/BuildObject",
    "/Game/Pal/Blueprint/MapObject",
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

local function exactWallClass(obj)
    obj = unwrap(obj)
    return valid(obj) and shortName(obj) == WALL_CLASS_NAME
end

local function actorLocation(actor)
    actor = unwrap(actor)
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
                out[#out + 1] = {
                    name = playerName(ps),
                    pawn = pawn,
                    at = at
                }
            end
        end
    end
    return out
end

local scriptsDir = scriptDir()
if not scriptsDir then
    log("Scripts directory unavailable; visual fallback disabled")
    return
end

local modDir = scriptsDir:match("^(.+)\\Scripts$") or scriptsDir
local ipcDir = readAll(modDir .. "\\ipc_path.txt")
if ipcDir then ipcDir = ipcDir:gsub("[\r\n]+$", "") end
if not ipcDir or ipcDir == "" then
    log("ipc_path.txt unavailable; visual fallback disabled")
    return
end

local raidStatusFile = ipcDir .. "\\raid-status.txt"
local visualStatusFile = ipcDir .. "\\raid-arena-wall-status.txt"

local currentRaidId = ""
local center = nil
local visualZ = 0
local visualZSource = "none"
local wallActors = {}
local visualStatus = "idle"
local classSource = "none"
local resolvedClassName = ""
local visualPackage = ""
local registryStatus = "not_attempted"
local meshReadyCount = 0
local lastError = ""
local lastAttemptAt = 0
local scheduled = false
local cachedWallClass = nil

local function writeStatus(raid)
    local c = center or { X = 0, Y = 0, Z = 0 }
    local lines = {
        "version=" .. VERSION,
        "time=" .. tostring(os.time()),
        "raid_id=" .. urlEncode(currentRaidId),
        "raid_state=" .. urlEncode(raid and raid.state or "IDLE"),
        "backend=replicated_build_wall",
        "active=" .. ((raid and raid.active == "1" and raid.state == "ACTIVE") and "1" or "0"),
        "center_frozen=" .. (center and "1" or "0"),
        "center_x=" .. tostring(c.X or 0),
        "center_y=" .. tostring(c.Y or 0),
        "raid_center_z=" .. tostring(c.Z or 0),
        "visual_z=" .. tostring(visualZ or 0),
        "visual_z_source=" .. urlEncode(visualZSource),
        "radius=" .. tostring(math.floor(RADIUS)),
        "segments_requested=" .. tostring(SEGMENTS),
        "segments_spawned=" .. tostring(#wallActors),
        "mesh_components_ready=" .. tostring(meshReadyCount),
        "visual_status=" .. urlEncode(visualStatus),
        "wall_asset=" .. urlEncode(WALL_ASSET_NAME),
        "resolved_class_name=" .. urlEncode(resolvedClassName),
        "class_source=" .. urlEncode(classSource),
        "visual_package=" .. urlEncode(visualPackage),
        "registry_status=" .. urlEncode(registryStatus),
        "last_error=" .. urlEncode(lastError)
    }
    writeAll(visualStatusFile, table.concat(lines, "\n") .. "\n")
end

local function destroyWalls()
    for _, actor in ipairs(wallActors) do
        if valid(actor) then
            pcall(function() actor:K2_DestroyActor() end)
        end
    end
    wallActors = {}
    meshReadyCount = 0
end

local function resetRaid(raidId)
    destroyWalls()
    currentRaidId = tostring(raidId or "")
    center = nil
    visualZ = 0
    visualZSource = "none"
    visualStatus = "waiting_active_raid"
    lastError = ""
    lastAttemptAt = 0
end

local function acceptWallClass(obj, source, packageName)
    obj = unwrap(obj)
    if not exactWallClass(obj) then return nil end
    classSource = source
    resolvedClassName = shortName(obj)
    visualPackage = packageName or ""
    return obj
end

local function tryStaticClass(packageName, source)
    if not packageName or packageName == "" then return nil end
    local paths = {
        packageName .. "." .. WALL_CLASS_NAME,
        "BlueprintGeneratedClass " .. packageName .. "." .. WALL_CLASS_NAME,
        "/Script/Engine.BlueprintGeneratedClass'" .. packageName .. "." .. WALL_CLASS_NAME .. "'"
    }
    for _, path in ipairs(paths) do
        local ok, found = pcall(StaticFindObject, path)
        if ok then
            local accepted = acceptWallClass(found, source, packageName)
            if accepted then return accepted end
        end
    end
    return nil
end

local function classFromLoadedObjects()
    local found, instance = pcall(FindFirstOf, WALL_CLASS_NAME)
    instance = unwrap(instance)
    if found and valid(instance) then
        local ok, class = pcall(function() return instance:GetClass() end)
        if ok then
            class = acceptWallClass(class, "live_wall_instance", "already_loaded")
            if class then return class end
        end
    end

    local ok, classes = pcall(FindAllOf, "BlueprintGeneratedClass")
    if ok and type(classes) == "table" then
        for _, class in ipairs(classes) do
            local accepted = acceptWallClass(class, "loaded_wall_class_scan", "already_loaded")
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

local function classFromAssetRegistry()
    local helpers, registry = getAssetRegistry()
    if not valid(helpers) or not valid(registry) then return nil end

    for _, root in ipairs(SEARCH_ROOTS) do
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
                    if assetName == WALL_ASSET_NAME or assetName == WALL_CLASS_NAME then
                        log(string.format("exact fallback wall asset: %s -> %s", assetName, packageName))
                        local asset = nil
                        local gotAsset, result = pcall(function() return helpers:GetAsset(data) end)
                        if gotAsset then asset = unwrap(result) end
                        if valid(asset) then
                            local generated = member(asset, "GeneratedClass")
                            local accepted = acceptWallClass(generated, "asset_registry_generated_class", packageName)
                            if accepted then
                                registryStatus = "found_exact"
                                return accepted
                            end
                        end
                        local byPath = tryStaticClass(packageName, "asset_registry_static_find")
                        if byPath then
                            registryStatus = "found_exact"
                            return byPath
                        end
                        registryStatus = "exact_asset_class_unresolved"
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

local function wallClass()
    if exactWallClass(cachedWallClass) then return cachedWallClass end
    local class = classFromLoadedObjects()
    if class then cachedWallClass = class; return class end
    class = classFromAssetRegistry()
    if class then cachedWallClass = class; return class end
    class = classFromLoadedObjects()
    if class then cachedWallClass = class; return class end
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
    visualZSource = "raid_center_offset"
    return (tonumber(raid.z) or 0) - 180.0
end

local function disableComponent(comp)
    if not valid(comp) then return end
    pcall(function() comp:SetCollisionEnabled(0) end)
    pcall(function() comp:SetGenerateOverlapEvents(false) end)
    pcall(function() comp:Deactivate() end)
end

local function prepareWall(actor)
    if not valid(actor) then return false end

    pcall(function() actor:SetReplicates(true) end)
    pcall(function() actor:SetReplicateMovement(false) end)
    pcall(function() actor:SetActorHiddenInGame(false) end)
    pcall(function() actor:SetActorEnableCollision(false) end)
    pcall(function() actor:SetCanBeDamaged(false) end)
    pcall(function() actor:SetActorScale3D(WALL_SCALE) end)

    local mesh = member(actor, "SM_Wall_Wood")
    local meshOk = false
    if valid(mesh) then
        meshOk = true
        pcall(function() mesh:SetVisibility(true, true) end)
        pcall(function() mesh:SetHiddenInGame(false, true) end)
        pcall(function() mesh:SetCollisionEnabled(0) end)
        pcall(function() mesh:SetGenerateOverlapEvents(false) end)
        pcall(function() mesh:MarkRenderStateDirty() end)
    end

    disableComponent(member(actor, "BP_InteractableBox"))
    disableComponent(member(actor, "AffectNavigationBox"))
    disableComponent(member(actor, "BuildWorkableBounds"))
    disableComponent(member(actor, "CheckOverlapCollision"))

    local arrow = member(actor, "BP_BuildObjectSimulateArrowComponent")
    if valid(arrow) then
        pcall(function() arrow:SetVisibility(false, true) end)
        pcall(function() arrow:Deactivate() end)
    end

    pcall(function() actor:FlushNetDormancy() end)
    pcall(function() actor:ForceNetUpdate() end)
    return meshOk
end

local function spawnRing(raid)
    lastAttemptAt = os.time()
    visualStatus = "resolving_replicated_wall"
    lastError = ""

    local class = wallClass()
    if not class then
        visualStatus = "wall_class_unavailable"
        lastError = "BP_BuildObject_Wood_Wall_V2_C konnte nicht exakt aufgeloest werden"
        log(lastError)
        return false
    end

    local players = onlinePlayers()
    local world = worldFromPlayers(players)
    if not valid(world) then
        visualStatus = "world_unavailable"
        lastError = "UWorld fuer replizierte Arena-Waende nicht verfuegbar"
        log(lastError)
        return false
    end

    if not center then
        center = {
            X = tonumber(raid.x) or 0,
            Y = tonumber(raid.y) or 0,
            Z = tonumber(raid.z) or 0
        }
    end
    visualZ = chooseVisualZ(raid, players)

    visualStatus = "spawning_replicated_walls"
    local created = {}
    local readyMeshes = 0

    for i = 0, SEGMENTS - 1 do
        local angle = (math.pi * 2 * i) / SEGMENTS
        local location = {
            X = center.X + math.cos(angle) * RADIUS,
            Y = center.Y + math.sin(angle) * RADIUS,
            Z = visualZ
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
            if prepareWall(actor) then readyMeshes = readyMeshes + 1 end
            created[#created + 1] = actor
        else
            log("fallback wall " .. tostring(i + 1) .. " spawn failed: " .. tostring(result))
        end
    end

    wallActors = created
    meshReadyCount = readyMeshes

    if #wallActors < MIN_SEGMENTS then
        visualStatus = "replicated_wall_spawn_incomplete"
        lastError = string.format("nur %d/%d Fallback-Waende gespawnt", #wallActors, SEGMENTS)
        log(lastError)
        destroyWalls()
        return false
    end

    visualStatus = "replicated_wall_ring_ready"
    lastError = ""
    log(string.format(
        "REPLICATED WALL RING READY: %d/%d actors, mesh=%d, Z=%.1f (%s), class=%s",
        #wallActors,
        SEGMENTS,
        meshReadyCount,
        visualZ,
        visualZSource,
        resolvedClassName
    ))
    return true
end

LoopAsync(TICK_MS, function()
    local raid = parseKv(readAll(raidStatusFile) or "active=0\nstate=IDLE\n")
    local raidId = tostring(raid.raid_id or "")

    if scheduled then return false end

    if raidId ~= currentRaidId then
        scheduled = true
        ExecuteInGameThread(function()
            resetRaid(raidId)
            writeStatus(raid)
            scheduled = false
        end)
        return false
    end

    if raid.active ~= "1" or raid.state ~= "ACTIVE" then
        if #wallActors > 0 or center ~= nil then
            scheduled = true
            ExecuteInGameThread(function()
                destroyWalls()
                center = nil
                visualStatus = "released"
                writeStatus(raid)
                scheduled = false
            end)
        else
            writeStatus(raid)
        end
        return false
    end

    if not center then
        center = {
            X = tonumber(raid.x) or 0,
            Y = tonumber(raid.y) or 0,
            Z = tonumber(raid.z) or 0
        }
        log(string.format("visual arena center frozen: X=%.1f Y=%.1f Z=%.1f", center.X, center.Y, center.Z))
    end

    if #wallActors >= MIN_SEGMENTS then
        writeStatus(raid)
        return false
    end

    if os.time() - lastAttemptAt < RETRY_SECONDS then
        writeStatus(raid)
        return false
    end

    scheduled = true
    ExecuteInGameThread(function()
        local ok, err = xpcall(function() spawnRing(raid) end, debug.traceback)
        if not ok then
            visualStatus = "spawn_exception"
            lastError = tostring(err)
            log("fallback visual failed: " .. lastError)
        end
        writeStatus(raid)
        scheduled = false
    end)
    return false
end)

writeStatus({ active = "0", state = "IDLE" })
log("v" .. VERSION .. " loaded; replicated build-wall fallback ready")
log("Visual only: 48 non-colliding BP_BuildObject_Wood_Wall_V2_C actors; arena-027 remains authoritative")