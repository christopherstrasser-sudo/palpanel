-- PalPanelServerMods Arena v2 step 6 / visual v0.7.0
-- SERVER-ONLY / NO CLIENT MOD.
--
-- The TowerLockBarrier blueprint itself switches ECollisionEnabled from its
-- bLocked state. Therefore actor-level collision alone is insufficient. This
-- version applies bLocked=true first, then neutralizes collision once on the
-- actual BarrierMesh and BP_InteractableBox primitive components, and finally
-- disables actor collision as a belt-and-suspenders fallback. No repeated writes.

local MOD = "PalPanelArenaV2Visual"
local VERSION = "0.7.0"
local TICK_MS = 250
local SPAWN_DELAY_TICKS = 8
local COMPONENT_DISABLE_DELAY_MS = 300
local OBSERVE_EVERY_TICKS = 8
local SCALE_XY = 5.0
local SCALE_Z = 2.2

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

local function boolText(value)
    value = unwrap(value)
    if value == nil then return "unknown" end
    if value == true then return "true" end
    if value == false then return "false" end
    local s = tostring(value)
    if s == "1" then return "true" end
    if s == "0" then return "false" end
    return s
end

local scriptsDir = scriptDir()
if not scriptsDir then log("Scripts directory unavailable; visual arena disabled"); return end
local modDir = scriptsDir:match("^(.+)\\Scripts$") or scriptsDir
local ipcDir = readAll(modDir .. "\\ipc_path.txt")
if ipcDir then ipcDir = ipcDir:gsub("[\r\n]+$", "") end
if not ipcDir or ipcDir == "" then log("ipc_path.txt unavailable; visual arena disabled"); return end

local raidStatusFile = ipcDir .. "\\raid-status.txt"
local triggerFile = ipcDir .. "\\raid-arena-trigger.txt"
local statusFile = ipcDir .. "\\raid-arena-v2-visual-status.txt"

local currentRaidId = ""
local raidState = "IDLE"
local active = false
local arenaTriggered = false
local triggerAt = 0
local triggerTicks = 0
local attempted = false
local spawnOk = false
local barrier = nil
local classResolved = false
local classSource = ""
local classFullName = ""
local worldResolved = false
local forceNetUpdates = 0
local cleanupCalls = 0
local lockBefore = "unknown"
local lockAfter = "unknown"
local lockObserved = "unknown"
local scaleWriteOk = false
local actorCollisionDisableOk = false
local actorCollisionObserved = "unknown"
local meshValid = false
local interactableValid = false
local meshCollisionDisableOk = false
local interactableCollisionDisableOk = false
local meshCollisionObserved = "unknown"
local interactableCollisionObserved = "unknown"
local meshReplicationOk = false
local interactableReplicationOk = false
local componentNeutralized = false
local componentNeutralizeCalls = 0
local barrierX, barrierY, barrierZ = 0, 0, 0
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
        "arena_triggered=" .. (arenaTriggered and "1" or "0"),
        "triggered_at=" .. tostring(triggerAt),
        "trigger_ticks=" .. tostring(triggerTicks),
        "spawn_delay_ticks=" .. tostring(SPAWN_DELAY_TICKS),
        "component_disable_delay_ms=" .. tostring(COMPONENT_DISABLE_DELAY_MS),
        "attempted=" .. (attempted and "1" or "0"),
        "spawn_ok=" .. (spawnOk and "1" or "0"),
        "barrier_valid=" .. (valid(barrier) and "1" or "0"),
        "class_resolved=" .. (classResolved and "1" or "0"),
        "class_source=" .. urlEncode(classSource),
        "class_full_name=" .. urlEncode(classFullName),
        "world_resolved=" .. (worldResolved and "1" or "0"),
        "configured_scale_xy=" .. tostring(SCALE_XY),
        "configured_scale_z=" .. tostring(SCALE_Z),
        "scale_write_ok=" .. (scaleWriteOk and "1" or "0"),
        "lock_before=" .. urlEncode(lockBefore),
        "lock_after=" .. urlEncode(lockAfter),
        "lock_observed=" .. urlEncode(lockObserved),
        "component_neutralized=" .. (componentNeutralized and "1" or "0"),
        "component_neutralize_calls=" .. tostring(componentNeutralizeCalls),
        "mesh_valid=" .. (meshValid and "1" or "0"),
        "mesh_replication_ok=" .. (meshReplicationOk and "1" or "0"),
        "mesh_collision_disable_ok=" .. (meshCollisionDisableOk and "1" or "0"),
        "mesh_collision_observed=" .. urlEncode(meshCollisionObserved),
        "interactable_valid=" .. (interactableValid and "1" or "0"),
        "interactable_replication_ok=" .. (interactableReplicationOk and "1" or "0"),
        "interactable_collision_disable_ok=" .. (interactableCollisionDisableOk and "1" or "0"),
        "interactable_collision_observed=" .. urlEncode(interactableCollisionObserved),
        "actor_collision_disable_ok=" .. (actorCollisionDisableOk and "1" or "0"),
        "actor_collision_observed=" .. urlEncode(actorCollisionObserved),
        "force_net_updates=" .. tostring(forceNetUpdates),
        "cleanup_calls=" .. tostring(cleanupCalls),
        "barrier_x=" .. tostring(barrierX),
        "barrier_y=" .. tostring(barrierY),
        "barrier_z=" .. tostring(barrierZ),
        "backend=first_hit_component_neutralized_tower_lock_barrier",
        "actor_spawn=" .. (attempted and "1" or "0"),
        "npc_spawn=0",
        "rpc_calls=0",
        "niagara_calls=0",
        "visibility_mutation=0",
        "collision_mutation=1",
        "ai_mutation=0",
        "client_install_required=0",
        "visual_status=" .. urlEncode(visualStatus),
        "last_error=" .. urlEncode(lastError)
    }
    writeAll(statusFile, table.concat(lines, "\n") .. "\n")
end

local function resetRaid(raidId)
    currentRaidId = tostring(raidId or "")
    raidState = "IDLE"
    active = false
    arenaTriggered = false
    triggerAt = 0
    triggerTicks = 0
    attempted = false
    spawnOk = false
    barrier = nil
    classResolved = false
    classSource = ""
    classFullName = ""
    worldResolved = false
    forceNetUpdates = 0
    cleanupCalls = 0
    lockBefore = "unknown"
    lockAfter = "unknown"
    lockObserved = "unknown"
    scaleWriteOk = false
    actorCollisionDisableOk = false
    actorCollisionObserved = "unknown"
    meshValid = false
    interactableValid = false
    meshCollisionDisableOk = false
    interactableCollisionDisableOk = false
    meshCollisionObserved = "unknown"
    interactableCollisionObserved = "unknown"
    meshReplicationOk = false
    interactableReplicationOk = false
    componentNeutralized = false
    componentNeutralizeCalls = 0
    barrierX, barrierY, barrierZ = 0, 0, 0
    lastError = ""
    visualStatus = "waiting_for_first_hit"
end

local function resolveClass()
    local cls = nil
    pcall(function()
        if FindObject ~= nil then cls = FindObject(nil, "BP_LevelObject_TowerLockBarrier_C") end
    end)
    cls = unwrap(cls)
    if valid(cls) then
        classResolved = true
        classSource = "FindObject_short_name"
        classFullName = fullName(cls)
        return cls
    end

    if LoadAsset ~= nil then
        for _, path in ipairs(LOAD_PATHS) do
            pcall(function() LoadAsset(path) end)
            cls = nil
            pcall(function()
                if FindObject ~= nil then cls = FindObject(nil, "BP_LevelObject_TowerLockBarrier_C") end
            end)
            cls = unwrap(cls)
            if valid(cls) then
                classResolved = true
                classSource = "LoadAsset_then_FindObject:" .. path
                classFullName = fullName(cls)
                return cls
            end
        end
    end

    lastError = "BP_LevelObject_TowerLockBarrier_C could not be resolved"
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

local function getCollisionText(comp)
    if not valid(comp) then return "invalid" end
    local value = nil
    local ok = pcall(function() value = comp:GetCollisionEnabled() end)
    if not ok then return "unknown" end
    return tostring(value)
end

local function neutralizePrimitive(comp, label)
    comp = unwrap(comp)
    if not valid(comp) then return false end

    local success = false
    local repOk = pcall(function() comp:SetIsReplicated(true) end)
    if label == "mesh" then meshReplicationOk = repOk else interactableReplicationOk = repOk end

    local profileOk = false
    if FName ~= nil then
        profileOk = pcall(function() comp:SetCollisionProfileName(FName("NoCollision"), true) end)
    end
    local enabledOk = pcall(function() comp:SetCollisionEnabled(0) end)
    local responseOk = pcall(function() comp:SetCollisionResponseToAllChannels(0) end)
    local overlapOk = pcall(function() comp:SetGenerateOverlapEvents(false) end)

    success = profileOk or enabledOk or responseOk or overlapOk
    log(string.format("%s collision neutralize: profile=%s enabled=%s responses=%s overlaps=%s", label, tostring(profileOk), tostring(enabledOk), tostring(responseOk), tostring(overlapOk)))
    return success
end

local function observeCollision()
    if not valid(barrier) then return end
    lockObserved = boolText(member(barrier, "bLocked"))

    local actorCollision = nil
    local actorOk = pcall(function() actorCollision = barrier:GetActorEnableCollision() end)
    if actorOk then actorCollisionObserved = boolText(actorCollision) end

    local mesh = member(barrier, "BarrierMesh")
    local interactable = member(barrier, "BP_InteractableBox")
    meshValid = valid(mesh)
    interactableValid = valid(interactable)
    if meshValid then meshCollisionObserved = getCollisionText(mesh) end
    if interactableValid then interactableCollisionObserved = getCollisionText(interactable) end
end

local function neutralizeBarrierCollision()
    if componentNeutralized or not valid(barrier) then return end
    componentNeutralizeCalls = componentNeutralizeCalls + 1

    local mesh = member(barrier, "BarrierMesh")
    local interactable = member(barrier, "BP_InteractableBox")
    meshValid = valid(mesh)
    interactableValid = valid(interactable)

    if meshValid then meshCollisionDisableOk = neutralizePrimitive(mesh, "mesh") end
    if interactableValid then interactableCollisionDisableOk = neutralizePrimitive(interactable, "interactable") end

    local actorOk, actorErr = pcall(function() barrier:SetActorEnableCollision(false) end)
    actorCollisionDisableOk = actorOk
    if not actorOk then lastError = "SetActorEnableCollision(false) failed: " .. tostring(actorErr) end

    local netOk = pcall(function() barrier:ForceNetUpdate() end)
    if netOk then forceNetUpdates = forceNetUpdates + 1 end

    componentNeutralized = true
    visualStatus = "barrier_active_components_no_collision"
    observeCollision()
    writeStatus()
end

local function cleanupBarrier()
    if not valid(barrier) then barrier = nil; return end
    cleanupCalls = cleanupCalls + 1
    pcall(function() barrier:K2_DestroyActor() end)
    barrier = nil
    visualStatus = "released"
    writeStatus()
end

local function spawnBarrier(trigger)
    if attempted then return end
    attempted = true
    visualStatus = "resolving_class"
    writeStatus()

    local cls = resolveClass()
    if not valid(cls) then visualStatus = "class_not_resolved"; writeStatus(); return end
    local world = resolveWorld()
    if not valid(world) then visualStatus = "world_not_resolved"; writeStatus(); return end

    barrierX = tonumber(trigger.center_x) or 0
    barrierY = tonumber(trigger.center_y) or 0
    barrierZ = tonumber(trigger.center_z) or 0

    local result = nil
    local ok, err = pcall(function()
        result = world:SpawnActor(cls, { X = barrierX, Y = barrierY, Z = barrierZ }, { Pitch = 0, Yaw = 0, Roll = 0 })
    end)
    result = unwrap(result)
    if not ok or not valid(result) then
        lastError = "SpawnActor failed: " .. tostring(err or result)
        visualStatus = "spawn_failed"
        writeStatus()
        return
    end

    barrier = result
    spawnOk = true
    pcall(function() barrier:SetReplicates(true) end)
    pcall(function() barrier.bAlwaysRelevant = true end)
    pcall(function() barrier.NetCullDistanceSquared = 2500000000.0 end)

    scaleWriteOk = pcall(function()
        barrier:SetActorScale3D({ X = SCALE_XY, Y = SCALE_XY, Z = SCALE_Z })
    end)

    lockBefore = boolText(member(barrier, "bLocked"))
    local lockOk, lockErr = pcall(function() barrier.bLocked = true end)
    if not lockOk then
        lastError = "bLocked write failed: " .. tostring(lockErr)
        visualStatus = "lock_failed"
        writeStatus()
        return
    end
    lockAfter = boolText(member(barrier, "bLocked"))
    lockObserved = lockAfter

    local netOk = pcall(function() barrier:ForceNetUpdate() end)
    if netOk then forceNetUpdates = forceNetUpdates + 1 end

    visualStatus = "barrier_locked_waiting_collision_neutralize"
    writeStatus()

    ExecuteWithDelay(COMPONENT_DISABLE_DELAY_MS, function()
        ExecuteInGameThread(function()
            local nOk, nErr = xpcall(neutralizeBarrierCollision, debug.traceback)
            if not nOk then
                lastError = tostring(nErr)
                visualStatus = "collision_neutralize_exception"
                log(lastError)
                writeStatus()
            end
        end)
    end)
end

local function tick()
    local raid = parseKv(readAll(raidStatusFile) or "active=0\nstate=IDLE\nraid_id=\n")
    local trigger = parseKv(readAll(triggerFile) or "triggered=0\nraid_id=\n")
    local raidId = tostring(raid.raid_id or "")

    if raidId ~= currentRaidId then
        if valid(barrier) then ExecuteInGameThread(cleanupBarrier) end
        resetRaid(raidId)
    end

    raidState = tostring(raid.state or "IDLE")
    active = raid.active == "1" and raidState == "ACTIVE" and raidId ~= ""
    local triggerMatches = trigger.triggered == "1" and tostring(trigger.raid_id or "") == raidId

    if active and triggerMatches then
        if not arenaTriggered then
            arenaTriggered = true
            triggerAt = tonumber(trigger.triggered_at) or os.time()
            triggerTicks = 0
        end
        triggerTicks = triggerTicks + 1

        if triggerTicks >= SPAWN_DELAY_TICKS and not attempted then
            ExecuteInGameThread(function()
                local sOk, sErr = xpcall(function() spawnBarrier(trigger) end, debug.traceback)
                if not sOk then
                    lastError = tostring(sErr)
                    visualStatus = "spawn_exception"
                    log(lastError)
                    writeStatus()
                end
            end)
        elseif valid(barrier) and componentNeutralized and triggerTicks % OBSERVE_EVERY_TICKS == 0 then
            ExecuteInGameThread(function()
                pcall(observeCollision)
                writeStatus()
            end)
        end
    elseif valid(barrier) then
        ExecuteInGameThread(cleanupBarrier)
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
            log("visual tick failed: " .. lastError)
        end
        ExecuteWithDelay(TICK_MS, loop)
    end
    ExecuteWithDelay(TICK_MS, loop)
end

resetRaid("")
writeStatus()
schedule()
log("v" .. VERSION .. " loaded; component-collision-neutralized barrier ready")
