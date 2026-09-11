-- PalPanelServerMods Arena v2 step 2C / visual retention probe v0.2.0
-- SERVER-ONLY / NO CLIENT MOD.
--
-- Keeps the proven Arena v2 3500-unit keep-in module completely separate.
-- This module still spawns exactly ONE vanilla BP_LevelObject_TowerLockBarrier_C
-- at radius 3700, but now explicitly keeps its BarrierMesh replicated/visible
-- after the Blueprint's initial data-change pass. It also records targeted
-- LockedObstacle/TowerLockBarrier UFunctions for the next state-level step.
--
-- No NPC spawn, custom RPC, Niagara call, collision mutation or AI mutation.

local MOD = "PalPanelArenaV2Visual"
local VERSION = "0.2.0"
local TICK_MS = 250
local ARM_TICKS = 8
local MARKER_RADIUS = 3700.0
local RETAIN_EVERY_TICKS = 4       -- once per second
local REFLECTION_DELAY_TICKS = 12  -- run after the actor had time to initialize
local MAX_LOCK_FUNCTIONS = 48

local LOAD_PATHS = {
    "/Game/Pal/Blueprint/MapObject/Object/LevelObject/BP_LevelObject_TowerLockBarrier",
    "/Game/Pal/Blueprint/MapObject/Object/LevelObject/Tower/BP_LevelObject_TowerLockBarrier",
    "/Game/Pal/Blueprint/MapObject/Object/LevelObject/TowerLockBarrier/BP_LevelObject_TowerLockBarrier",
    "/Game/Pal/Blueprint/LevelObject/BP_LevelObject_TowerLockBarrier"
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
    if not ok then return nil end
    return unwrap(value)
end

local function fullName(obj)
    obj = unwrap(obj)
    if not valid(obj) then return "" end
    local text = ""
    pcall(function() text = obj:GetFullName() end)
    return type(text) == "string" and text or ""
end

local function shortName(obj)
    obj = unwrap(obj)
    if not valid(obj) then return "" end
    local name = nil
    pcall(function() name = obj:GetFName() end)
    if name == nil then return "" end
    local text = ""
    pcall(function() text = name:ToString() end)
    if type(text) == "string" and text ~= "" then return text end
    local ok, fallback = pcall(tostring, name)
    return ok and tostring(fallback or "") or ""
end

local scriptsDir = scriptDir()
if not scriptsDir then
    log("Scripts directory unavailable; visual retention probe disabled")
    return
end
local modDir = scriptsDir:match("^(.+)\\Scripts$") or scriptsDir
local ipcDir = readAll(modDir .. "\\ipc_path.txt")
if ipcDir then ipcDir = ipcDir:gsub("[\r\n]+$", "") end
if not ipcDir or ipcDir == "" then
    log("ipc_path.txt unavailable; visual retention probe disabled")
    return
end

local raidStatusFile = ipcDir .. "\\raid-status.txt"
local statusFile = ipcDir .. "\\raid-arena-v2-visual-status.txt"

local currentRaidId = ""
local raidState = "IDLE"
local active = false
local activeTicks = 0
local attempted = false
local spawnCallReturned = false
local spawnOk = false
local marker = nil
local markerClass = nil
local classResolved = false
local classSource = ""
local classFullName = ""
local loadAttempts = 0
local loadSuccesses = 0
local worldResolved = false
local forceNetUpdates = 0
local cleanupCalls = 0
local markerMeshValid = false
local markerMeshVisible = "unknown"
local markerMeshHidden = "unknown"
local markerActorHidden = "unknown"
local markerMeshAsset = ""
local interactableValid = false
local componentReplicationCalls = 0
local componentReplicationOk = 0
local visibilityCalls = 0
local visibilityOk = 0
local hiddenCalls = 0
local hiddenOk = 0
local actorUnhideCalls = 0
local actorUnhideOk = 0
local retentionPasses = 0
local reflectionScanned = false
local reflectionObjectsSeen = 0
local lockFunctions = {}
local markerX, markerY, markerZ = 0, 0, 0
local lastError = ""
local visualStatus = "idle"
local scheduled = false

local function writeStatus()
    local lines = {
        "version=" .. VERSION,
        "time=" .. tostring(os.time()),
        "raid_id=" .. urlEncode(currentRaidId),
        "raid_state=" .. urlEncode(raidState),
        "active=" .. (active and "1" or "0"),
        "active_ticks=" .. tostring(activeTicks),
        "arm_ticks=" .. tostring(ARM_TICKS),
        "marker_radius=" .. tostring(math.floor(MARKER_RADIUS)),
        "attempted=" .. (attempted and "1" or "0"),
        "spawn_call_returned=" .. (spawnCallReturned and "1" or "0"),
        "spawn_ok=" .. (spawnOk and "1" or "0"),
        "marker_valid=" .. (valid(marker) and "1" or "0"),
        "class_resolved=" .. (classResolved and "1" or "0"),
        "class_source=" .. urlEncode(classSource),
        "class_full_name=" .. urlEncode(classFullName),
        "load_attempts=" .. tostring(loadAttempts),
        "load_successes=" .. tostring(loadSuccesses),
        "world_resolved=" .. (worldResolved and "1" or "0"),
        "force_net_updates=" .. tostring(forceNetUpdates),
        "cleanup_calls=" .. tostring(cleanupCalls),
        "marker_mesh_valid=" .. (markerMeshValid and "1" or "0"),
        "marker_mesh_visible=" .. urlEncode(markerMeshVisible),
        "marker_mesh_hidden=" .. urlEncode(markerMeshHidden),
        "marker_actor_hidden=" .. urlEncode(markerActorHidden),
        "marker_mesh_asset=" .. urlEncode(markerMeshAsset),
        "interactable_valid=" .. (interactableValid and "1" or "0"),
        "component_replication_calls=" .. tostring(componentReplicationCalls),
        "component_replication_ok=" .. tostring(componentReplicationOk),
        "visibility_calls=" .. tostring(visibilityCalls),
        "visibility_ok=" .. tostring(visibilityOk),
        "hidden_calls=" .. tostring(hiddenCalls),
        "hidden_ok=" .. tostring(hiddenOk),
        "actor_unhide_calls=" .. tostring(actorUnhideCalls),
        "actor_unhide_ok=" .. tostring(actorUnhideOk),
        "retention_passes=" .. tostring(retentionPasses),
        "reflection_scanned=" .. (reflectionScanned and "1" or "0"),
        "reflection_objects_seen=" .. tostring(reflectionObjectsSeen),
        "lock_function_count=" .. tostring(#lockFunctions),
        "marker_x=" .. tostring(markerX),
        "marker_y=" .. tostring(markerY),
        "marker_z=" .. tostring(markerZ),
        "backend=single_replicated_tower_lock_barrier_visibility_retention",
        "actor_spawn=" .. (attempted and "1" or "0"),
        "npc_spawn=0",
        "rpc_calls=0",
        "niagara_calls=0",
        "collision_mutation=0",
        "ai_mutation=0",
        "client_install_required=0",
        "visual_status=" .. urlEncode(visualStatus),
        "last_error=" .. urlEncode(lastError)
    }
    for i, row in ipairs(lockFunctions) do
        lines[#lines + 1] = string.format("lock_function_%d_name=%s", i, urlEncode(row.name))
        lines[#lines + 1] = string.format("lock_function_%d_full_name=%s", i, urlEncode(row.full_name))
    end
    writeAll(statusFile, table.concat(lines, "\n") .. "\n")
end

local function resetRaid(raidId)
    currentRaidId = tostring(raidId or "")
    raidState = "IDLE"
    active = false
    activeTicks = 0
    attempted = false
    spawnCallReturned = false
    spawnOk = false
    marker = nil
    markerClass = nil
    classResolved = false
    classSource = ""
    classFullName = ""
    loadAttempts = 0
    loadSuccesses = 0
    worldResolved = false
    forceNetUpdates = 0
    cleanupCalls = 0
    markerMeshValid = false
    markerMeshVisible = "unknown"
    markerMeshHidden = "unknown"
    markerActorHidden = "unknown"
    markerMeshAsset = ""
    interactableValid = false
    componentReplicationCalls = 0
    componentReplicationOk = 0
    visibilityCalls = 0
    visibilityOk = 0
    hiddenCalls = 0
    hiddenOk = 0
    actorUnhideCalls = 0
    actorUnhideOk = 0
    retentionPasses = 0
    reflectionScanned = false
    reflectionObjectsSeen = 0
    lockFunctions = {}
    markerX, markerY, markerZ = 0, 0, 0
    lastError = ""
    visualStatus = "waiting_for_active"
end

local function resolveClass()
    local cls = nil
    local ok = pcall(function()
        if FindObject ~= nil then cls = FindObject(nil, "BP_LevelObject_TowerLockBarrier_C") end
    end)
    cls = unwrap(cls)
    if ok and valid(cls) then
        markerClass = cls
        classResolved = true
        classSource = "FindObject_short_name"
        classFullName = fullName(cls)
        return cls
    end

    if LoadAsset ~= nil then
        for _, path in ipairs(LOAD_PATHS) do
            loadAttempts = loadAttempts + 1
            local loadOk = pcall(function() LoadAsset(path) end)
            if loadOk then loadSuccesses = loadSuccesses + 1 end
            cls = nil
            pcall(function()
                if FindObject ~= nil then cls = FindObject(nil, "BP_LevelObject_TowerLockBarrier_C") end
            end)
            cls = unwrap(cls)
            if valid(cls) then
                markerClass = cls
                classResolved = true
                classSource = "LoadAsset_then_FindObject:" .. path
                classFullName = fullName(cls)
                return cls
            end
        end
    end

    lastError = "BP_LevelObject_TowerLockBarrier_C could not be resolved"
    visualStatus = "class_not_resolved"
    return nil
end

local function resolveWorld()
    local actor = nil
    pcall(function() actor = FindFirstOf("PalPlayerCharacter") end)
    actor = unwrap(actor)
    if not valid(actor) then
        lastError = "no PalPlayerCharacter available for world context"
        return nil
    end

    local world = nil
    pcall(function() world = actor:GetWorld() end)
    world = unwrap(world)
    if not valid(world) then
        lastError = "GetWorld from PalPlayerCharacter failed"
        return nil
    end
    worldResolved = true
    return world
end

local function boolText(fn)
    local value = nil
    local ok = pcall(function() value = fn() end)
    if not ok or value == nil then return "unknown" end
    return tostring(value)
end

local function inspectMarker()
    if not valid(marker) then return end

    markerActorHidden = boolText(function() return marker:IsHidden() end)

    local mesh = member(marker, "BarrierMesh")
    markerMeshValid = valid(mesh)
    interactableValid = valid(member(marker, "BP_InteractableBox"))
    if not markerMeshValid then return end

    markerMeshVisible = boolText(function() return mesh:IsVisible() end)
    local hiddenValue = member(mesh, "bHiddenInGame")
    markerMeshHidden = hiddenValue == nil and "unknown" or tostring(hiddenValue)

    local asset = nil
    pcall(function() asset = mesh:GetStaticMesh() end)
    asset = unwrap(asset)
    if valid(asset) then markerMeshAsset = fullName(asset) end
end

local function forceVisible()
    if not valid(marker) then return end
    retentionPasses = retentionPasses + 1

    actorUnhideCalls = actorUnhideCalls + 1
    local actorOk = pcall(function() marker:SetActorHiddenInGame(false) end)
    if actorOk then actorUnhideOk = actorUnhideOk + 1 end

    local mesh = member(marker, "BarrierMesh")
    markerMeshValid = valid(mesh)
    if valid(mesh) then
        componentReplicationCalls = componentReplicationCalls + 1
        local repOk = pcall(function() mesh:SetIsReplicated(true) end)
        if repOk then componentReplicationOk = componentReplicationOk + 1 end

        visibilityCalls = visibilityCalls + 1
        local visOk = pcall(function() mesh:SetVisibility(true, true) end)
        if visOk then visibilityOk = visibilityOk + 1 end

        hiddenCalls = hiddenCalls + 1
        local hidOk = pcall(function() mesh:SetHiddenInGame(false, true) end)
        if hidOk then hiddenOk = hiddenOk + 1 end

        pcall(function() mesh.bVisible = true end)
        pcall(function() mesh.bHiddenInGame = false end)
    end

    local netOk = pcall(function() marker:ForceNetUpdate() end)
    if netOk then forceNetUpdates = forceNetUpdates + 1 end
    inspectMarker()
end

local function targetedReflectionScan()
    if reflectionScanned then return end
    reflectionScanned = true
    if ForEachUObject == nil then return end

    local seen = {}
    local rows = {}
    local ok, err = pcall(function()
        ForEachUObject(function(raw)
            local obj = unwrap(raw)
            if not valid(obj) then return end
            reflectionObjectsSeen = reflectionObjectsSeen + 1
            local fn = fullName(obj)
            local lower = string.lower(fn)
            if lower:find("pallevelobject_lockedobstacle", 1, true)
                or lower:find("bp_levelobject_towerlockbarrier", 1, true) then
                if lower:find("function ", 1, true) then
                    local key = lower
                    if not seen[key] then
                        seen[key] = true
                        rows[#rows + 1] = { name = shortName(obj), full_name = fn }
                    end
                end
            end
        end)
    end)
    if not ok then
        lastError = "targeted reflection scan failed: " .. tostring(err)
        return
    end

    table.sort(rows, function(a, b) return tostring(a.full_name) < tostring(b.full_name) end)
    for i = 1, math.min(#rows, MAX_LOCK_FUNCTIONS) do
        lockFunctions[#lockFunctions + 1] = rows[i]
    end
    log(string.format("targeted LockedObstacle scan: %d functions recorded", #lockFunctions))
end

local function cleanupMarker()
    if not valid(marker) then
        marker = nil
        return
    end
    cleanupCalls = cleanupCalls + 1
    visualStatus = "cleanup_before_destroy"
    writeStatus()
    local ok, err = pcall(function() marker:K2_DestroyActor() end)
    if not ok then lastError = "marker destroy failed: " .. tostring(err) end
    marker = nil
    visualStatus = "released"
    writeStatus()
end

local function spawnProbe(raid)
    if attempted then return end
    attempted = true
    spawnCallReturned = false
    spawnOk = false
    visualStatus = "resolving_class"
    writeStatus()

    local cls = resolveClass()
    if not valid(cls) then writeStatus(); return end

    local world = resolveWorld()
    if not valid(world) then
        visualStatus = "world_not_resolved"
        writeStatus()
        return
    end

    local cx = tonumber(raid.x) or 0
    local cy = tonumber(raid.y) or 0
    local cz = tonumber(raid.z) or 0
    markerX = cx + MARKER_RADIUS
    markerY = cy
    markerZ = cz

    local location = { X = markerX, Y = markerY, Z = markerZ }
    local rotation = { Pitch = 0, Yaw = 90, Roll = 0 }

    visualStatus = "before_spawn_call"
    writeStatus()
    log(string.format("retention probe spawning at %.1f %.1f %.1f via %s", markerX, markerY, markerZ, classSource))

    local ok, result = pcall(function() return world:SpawnActor(cls, location, rotation) end)
    spawnCallReturned = true
    local spawned = unwrap(result)

    if not ok then
        lastError = "SpawnActor Lua/native call failed: " .. tostring(result)
        visualStatus = "spawn_call_failed"
        writeStatus()
        return
    end
    if not valid(spawned) then
        lastError = "SpawnActor returned no valid actor"
        visualStatus = "spawn_returned_invalid"
        writeStatus()
        return
    end

    marker = spawned
    spawnOk = true
    visualStatus = "spawned_forcing_visibility"

    pcall(function() marker:SetReplicates(true) end)
    pcall(function() marker.bAlwaysRelevant = true end)
    pcall(function() marker.NetCullDistanceSquared = 2500000000.0 end)

    forceVisible()
    visualStatus = "tower_lock_barrier_visibility_retained"
    writeStatus()
    log("single replicated TowerLockBarrier spawned; BarrierMesh retention enabled")
end

local function tick()
    local raw = readAll(raidStatusFile)
    local raid = raw and parseKv(raw) or { state = "IDLE", active = "0", raid_id = "" }
    local raidId = tostring(raid.raid_id or "")

    if raidId ~= currentRaidId then
        cleanupMarker()
        resetRaid(raidId)
    end

    raidState = tostring(raid.state or "IDLE")
    local nowActive = raid.active == "1" and raidState == "ACTIVE" and raidId ~= ""
    active = nowActive

    if nowActive then
        activeTicks = activeTicks + 1
        if activeTicks >= ARM_TICKS and not attempted then
            ExecuteInGameThread(function()
                local ok, err = xpcall(function() spawnProbe(raid) end, debug.traceback)
                if not ok then
                    lastError = tostring(err)
                    visualStatus = "probe_exception"
                    writeStatus()
                    log("visual retention probe exception: " .. lastError)
                end
            end)
        elseif valid(marker) and activeTicks % RETAIN_EVERY_TICKS == 0 then
            ExecuteInGameThread(function()
                forceVisible()
                if not reflectionScanned and activeTicks >= REFLECTION_DELAY_TICKS then
                    targetedReflectionScan()
                end
                writeStatus()
            end)
        end
    else
        activeTicks = 0
        if valid(marker) then ExecuteInGameThread(function() cleanupMarker() end) end
    end

    writeStatus()
end

local function schedule()
    if scheduled then return end
    scheduled = true
    local function loop()
        local ok, err = xpcall(tick, debug.traceback)
        if not ok then
            lastError = tostring(err)
            visualStatus = "tick_exception"
            writeStatus()
            log("visual tick failed: " .. lastError)
        end
        ExecuteWithDelay(TICK_MS, loop)
    end
    ExecuteWithDelay(TICK_MS, loop)
end

resetRaid("")
visualStatus = "idle"
writeStatus()
schedule()
log("v" .. VERSION .. " loaded; TowerLockBarrier visibility retention probe ready")
