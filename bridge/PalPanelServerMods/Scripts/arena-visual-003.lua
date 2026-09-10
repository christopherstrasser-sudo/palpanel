-- PalPanelServerMods raid arena visual v0.3.0
--
-- SERVER-ONLY visual proof/fallback.
-- Uses a vanilla AStaticMeshActor blueprint with only visual components:
-- BP_pal_b00_building_Lordenfel_Brazier_Lit_01_C.
--
-- This deliberately avoids every gameplay-heavy class that has already proven
-- unsafe for dynamic spawning on the dedicated server:
--   * NO PalBuildObject actors
--   * NO SkillEffect actors
--   * NO AI / damage / target calls
--   * NO custom client mod
--
-- The authoritative keep-in/keep-out arena remains arena-027.lua.  This module
-- only places clearly visible vanilla fire markers around the same frozen
-- 6000-unit radius. Actors are spawned in small batches to avoid a large single
-- frame replication/construction spike.

local MOD = "PalPanelRaidArenaVisual"
local VERSION = "0.3.0"
local TICK_MS = 250
local RADIUS = 6000.0
local MARKERS = 32
local SPAWN_BATCH = 4
local MARKER_SCALE = 1.8
local GROUND_OFFSET = 70.0

local VISUAL_ASSET_NAME = "BP_pal_b00_building_Lordenfel_Brazier_Lit_01"
local VISUAL_CLASS_NAME = "BP_pal_b00_building_Lordenfel_Brazier_Lit_01_C"

-- Narrow roots first. /Game/Pal is last-resort only and is queried once.
local SEARCH_ROOTS = {
    "/Game/Pal/Maps",
    "/Game/Pal/MapObject",
    "/Game/Pal/Blueprint",
    "/Game/Pal"
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

    local out = {}
    for _, ps in ipairs(states) do
        ps = unwrap(ps)
        if valid(ps) then
            local pawn = playerPawn(ps)
            local at = actorLocation(pawn)
            if valid(pawn) and at then
                out[#out + 1] = {
                    ps = ps,
                    pawn = pawn,
                    name = playerName(ps),
                    at = at
                }
            end
        end
    end
    return out
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

local currentRaidId = ""
local center = nil
local visualZ = 0
local visualZSource = "none"
local actors = {}
local nextIndex = 0
local visualStatus = "idle"
local classSource = "none"
local visualPackage = ""
local registryStatus = "not_attempted"
local lastError = ""
local scheduled = false
local cachedClass = nil
local resolutionAttempted = false

local function writeStatus(raid)
    local c = center or { X = 0, Y = 0, Z = 0 }
    local activeRaid = raid and raid.active == "1" and raid.state == "ACTIVE"
    local lines = {
        "version=" .. VERSION,
        "time=" .. tostring(os.time()),
        "raid_id=" .. urlEncode(currentRaidId),
        "raid_state=" .. urlEncode(raid and raid.state or "IDLE"),
        "backend=vanilla_static_mesh_actor",
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
        "markers_spawned=" .. tostring(#actors),
        "next_index=" .. tostring(nextIndex),
        "visual_status=" .. urlEncode(visualStatus),
        "asset=" .. urlEncode(VISUAL_ASSET_NAME),
        "resolved_class_name=" .. urlEncode(exactVisualClass(cachedClass) and VISUAL_CLASS_NAME or ""),
        "class_source=" .. urlEncode(classSource),
        "visual_package=" .. urlEncode(visualPackage),
        "registry_status=" .. urlEncode(registryStatus),
        "server_spawn_success=" .. (#actors > 0 and "1" or "0"),
        "client_visual_confirmation=required",
        "last_error=" .. urlEncode(lastError)
    }
    writeAll(visualStatusFile, table.concat(lines, "\n") .. "\n")
end

local function destroyActors()
    for _, actor in ipairs(actors) do
        if valid(actor) then
            pcall(function() actor:K2_DestroyActor() end)
        end
    end
    actors = {}
    nextIndex = 0
end

local function resetRaid(raidId)
    destroyActors()
    currentRaidId = tostring(raidId or "")
    center = nil
    visualZ = 0
    visualZSource = "none"
    nextIndex = 0
    visualStatus = "waiting_active_raid"
    lastError = ""
    resolutionAttempted = false
end

local function acceptClass(obj, source, packageName)
    obj = unwrap(obj)
    if not exactVisualClass(obj) then return nil end
    classSource = source
    visualPackage = packageName or ""
    return obj
end

local function classFromLoadedObjects()
    local found, instance = pcall(FindFirstOf, VISUAL_CLASS_NAME)
    instance = unwrap(instance)
    if found and valid(instance) then
        local ok, class = pcall(function() return instance:GetClass() end)
        if ok then
            class = acceptClass(class, "live_instance", "already_loaded")
            if class then return class end
        end
    end

    local ok, classes = pcall(FindAllOf, "BlueprintGeneratedClass")
    if ok and type(classes) == "table" then
        for _, class in ipairs(classes) do
            local accepted = acceptClass(class, "loaded_class_scan", "already_loaded")
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
        local assets = {}
        local ok, err = pcall(function()
            registry:GetAssetsByPath(FName(root), assets, true, true)
        end)
        if ok then
            local count = 0
            pcall(function() count = #assets end)
            log(string.format("AssetRegistry %s -> %d assets", root, count))

            for i = 1, count do
                local data = unwrap(assets[i])
                if data ~= nil then
                    local assetName = toText(member(data, "AssetName")) or ""
                    if assetName == VISUAL_ASSET_NAME or assetName == VISUAL_CLASS_NAME then
                        local packageName = toText(member(data, "PackageName")) or ""
                        log("exact visual asset found: " .. assetName .. " -> " .. packageName)

                        local asset = nil
                        local gotAsset, result = pcall(function() return helpers:GetAsset(data) end)
                        if gotAsset then asset = unwrap(result) end
                        if valid(asset) then
                            local generated = member(asset, "GeneratedClass")
                            local accepted = acceptClass(generated, "asset_registry_generated_class", packageName)
                            if accepted then
                                registryStatus = "found_exact"
                                return accepted
                            end
                        end

                        local objectPaths = {
                            packageName .. "." .. VISUAL_CLASS_NAME,
                            "BlueprintGeneratedClass " .. packageName .. "." .. VISUAL_CLASS_NAME,
                            "/Script/Engine.BlueprintGeneratedClass'" .. packageName .. "." .. VISUAL_CLASS_NAME .. "'"
                        }
                        for _, objectPath in ipairs(objectPaths) do
                            local findOk, foundClass = pcall(StaticFindObject, objectPath)
                            if findOk then
                                local accepted = acceptClass(foundClass, "asset_registry_static_find", packageName)
                                if accepted then
                                    registryStatus = "found_exact"
                                    return accepted
                                end
                            end
                        end

                        registryStatus = "exact_asset_class_unresolved"
                    end
                end
            end
        else
            log("AssetRegistry query failed for " .. root .. ": " .. tostring(err))
        end
    end

    if registryStatus == "ready" then registryStatus = "exact_asset_not_found" end
    return nil
end

local function visualClass()
    if exactVisualClass(cachedClass) then return cachedClass end

    local class = classFromLoadedObjects()
    if class then cachedClass = class; return class end

    if not resolutionAttempted then
        resolutionAttempted = true
        class = classFromAssetRegistry()
        if class then cachedClass = class; return class end
    end

    class = classFromLoadedObjects()
    if class then cachedClass = class; return class end
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

    visualZSource = "raid_center_fallback"
    return (tonumber(raid.z) or 0) - 100.0
end

local function beginVisual(raid)
    center = {
        X = tonumber(raid.x) or 0,
        Y = tonumber(raid.y) or 0,
        Z = tonumber(raid.z) or 0
    }

    local players = onlinePlayers()
    visualZ = chooseVisualZ(raid, players)

    local class = visualClass()
    if not class then
        visualStatus = "class_unavailable"
        lastError = "Vanilla brazier visual class could not be resolved"
        log(lastError)
        writeStatus(raid)
        return false
    end

    if not valid(worldFromPlayers(players)) then
        visualStatus = "world_unavailable"
        lastError = "UWorld unavailable for server-side visual ring"
        log(lastError)
        writeStatus(raid)
        return false
    end

    visualStatus = "spawning_batched"
    lastError = ""
    nextIndex = 0
    log(string.format(
        "server-only FIRE arena starting: radius=%d markers=%d class=%s",
        math.floor(RADIUS), MARKERS, VISUAL_CLASS_NAME
    ))
    writeStatus(raid)
    return true
end

local function spawnBatch(raid)
    if not center then
        if not beginVisual(raid) then return end
    end

    local class = visualClass()
    if not class then return end

    local players = onlinePlayers()
    local world = worldFromPlayers(players)
    if not valid(world) then
        visualStatus = "world_lost"
        lastError = "UWorld became unavailable while spawning fire ring"
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
            -- Final transform first, then enable replication so the initial
            -- network spawn sees the finished transform.  No component state
            -- or gameplay functions are touched.
            pcall(function()
                actor:SetActorScale3D({ X = MARKER_SCALE, Y = MARKER_SCALE, Z = MARKER_SCALE })
            end)
            pcall(function() actor:SetReplicateMovement(true) end)
            pcall(function() actor:SetReplicates(true) end)
            pcall(function() actor:SetActorHiddenInGame(false) end)
            pcall(function() actor:ForceNetUpdate() end)
            actors[#actors + 1] = actor
        else
            lastError = "marker " .. tostring(i + 1) .. " spawn failed: " .. tostring(result)
            log(lastError)
        end

        nextIndex = nextIndex + 1
        spawnedThisBatch = spawnedThisBatch + 1
    end

    if nextIndex >= MARKERS then
        if #actors == MARKERS then
            visualStatus = "server_fire_ring_spawned"
            lastError = ""
        elseif #actors > 0 then
            visualStatus = "server_fire_ring_partial"
        else
            visualStatus = "server_fire_ring_failed"
        end
        log(string.format("fire arena server spawn finished: %d/%d", #actors, MARKERS))
    else
        visualStatus = "spawning_batched"
    end

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
            local ok, err = xpcall(function()
                spawnBatch(raid)
            end, debug.traceback)
            if not ok then
                visualStatus = "spawn_exception"
                lastError = tostring(err)
                log("visual spawn failed: " .. lastError)
                writeStatus(raid)
            end
            scheduled = false
        end)
    else
        writeStatus(raid)
    end

    return false
end)

writeStatus({ state = "IDLE", active = "0" })
log("v" .. VERSION .. " loaded; SERVER-ONLY vanilla AStaticMeshActor fire-ring backend")
log("No BuildObject, no SkillEffect, no client mod; markers spawn in batches of " .. tostring(SPAWN_BATCH))
