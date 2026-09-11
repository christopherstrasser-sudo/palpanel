-- PalPanelServerMods Arena v2 step 5 / visual v0.6.0
-- SERVER-ONLY / NO CLIENT MOD.
--
-- First-hit gated persistent BP_LevelObject_TowerLockBarrier_C.
-- Players are given time to teleport before the barrier is spawned. The barrier
-- keeps the proven bLocked=true visual state, but actor collision is disabled once
-- on the authoritative server so the visual shell cannot pin raid participants.

local MOD = "PalPanelArenaV2Visual"
local VERSION = "0.6.0"
local TICK_MS = 250
local SPAWN_DELAY_TICKS = 4
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
local spawnCallReturned = false
local spawnOk = false
local barrier = nil
local classResolved = false
local classSource = ""
local classFullName = ""
local loadAttempts = 0
local loadSuccesses = 0
local worldResolved = false
local forceNetUpdates = 0
local cleanupCalls = 0
local scaleWriteAttempted = false
local scaleWriteOk = false
local scaleObservedX, scaleObservedY, scaleObservedZ = 0, 0, 0
local lockWriteAttempted = false
local lockWriteOk = false
local lockBefore = "unknown"
local lockAfter = "unknown"
local lockObserved = "unknown"
local collisionDisableAttempted = false
local collisionDisableOk = false
local collisionObserved = "unknown"
local observePasses = 0
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
        "attempted=" .. (attempted and "1" or "0"),
        "spawn_call_returned=" .. (spawnCallReturned and "1" or "0"),
        "spawn_ok=" .. (spawnOk and "1" or "0"),
        "barrier_valid=" .. (valid(barrier) and "1" or "0"),
        "class_resolved=" .. (classResolved and "1" or "0"),
        "class_source=" .. urlEncode(classSource),
        "class_full_name=" .. urlEncode(classFullName),
        "load_attempts=" .. tostring(loadAttempts),
        "load_successes=" .. tostring(loadSuccesses),
        "world_resolved=" .. (worldResolved and "1" or "0"),
        "force_net_updates=" .. tostring(forceNetUpdates),
        "cleanup_calls=" .. tostring(cleanupCalls),
        "configured_scale_xy=" .. tostring(SCALE_XY),
        "configured_scale_z=" .. tostring(SCALE_Z),
        "scale_write_attempted=" .. (scaleWriteAttempted and "1" or "0"),
        "scale_write_ok=" .. (scaleWriteOk and "1" or "0"),
        "scale_observed_x=" .. tostring(scaleObservedX),
        "scale_observed_y=" .. tostring(scaleObservedY),
        "scale_observed_z=" .. tostring(scaleObservedZ),
        "lock_write_attempted=" .. (lockWriteAttempted and "1" or "0"),
        "lock_write_ok=" .. (lockWriteOk and "1" or "0"),
        "lock_before=" .. urlEncode(lockBefore),
        "lock_after=" .. urlEncode(lockAfter),
        "lock_observed=" .. urlEncode(lockObserved),
        "collision_disable_attempted=" .. (collisionDisableAttempted and "1" or "0"),
        "collision_disable_ok=" .. (collisionDisableOk and "1" or "0"),
        "collision_observed=" .. urlEncode(collisionObserved),
        "observe_passes=" .. tostring(observePasses),
        "barrier_x=" .. tostring(barrierX),
        "barrier_y=" .. tostring(barrierY),
        "barrier_z=" .. tostring(barrierZ),
        "backend=first_hit_delayed_nonblocking_tower_lock_barrier",
        "actor_spawn=" .. (attempted and "1" or "0"),
        "npc_spawn=0",
        "rpc_calls=0",
        "niagara_calls=0",
        "component_replication_mutation=0",
        "visibility_mutation=0",
        "collision_mutation=" .. (collisionDisableAttempted and "1" or "0"),
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
    spawnCallReturned = false
    spawnOk = false
    barrier = nil
    classResolved = false
    classSource = ""
    classFullName = ""
    loadAttempts = 0
    loadSuccesses = 0
    worldResolved = false
    forceNetUpdates = 0
    cleanupCalls = 0
    scaleWriteAttempted = false
    scaleWriteOk = false
    scaleObservedX, scaleObservedY, scaleObservedZ = 0, 0, 0
    lockWriteAttempted = false
    lockWriteOk = false
    lockBefore = "unknown"
    lockAfter = "unknown"
    lockObserved = "unknown"
    collisionDisableAttempted = false
    collisionDisableOk = false
    collisionObserved = "unknown"
    observePasses = 0
    barrierX, barrierY, barrierZ = 0, 0, 0
    lastError = ""
    visualStatus = "waiting_for_first_hit"
end

local function resolveClass()
    local cls = nil
    local ok = pcall(function()
        if FindObject ~= nil then cls = FindObject(nil, "BP_LevelObject_TowerLockBarrier_C") end
    end)
    cls = unwrap(cls)
    if ok and valid(cls) then
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

local function observeBarrier()
    if not valid(barrier) then return end
    observePasses = observePasses + 1
    lockObserved = boolText(member(barrier, "bLocked"))

    local scale = nil
    pcall(function() scale = barrier:GetActorScale3D() end)
    if scale then
        scaleObservedX = tonumber(scale.X) or scaleObservedX
        scaleObservedY = tonumber(scale.Y) or scaleObservedY
        scaleObservedZ = tonumber(scale.Z) or scaleObservedZ
    end

    local collision = nil
    local collisionOk = pcall(function() collision = barrier:GetActorEnableCollision() end)
    if collisionOk then collisionObserved = boolText(collision) end
end

local function cleanupBarrier()
    if not valid(barrier) then barrier = nil; return end
    cleanupCalls = cleanupCalls + 1
    visualStatus = "cleanup_before_destroy"
    writeStatus()
    local ok, err = pcall(function() barrier:K2_DestroyActor() end)
    if not ok then lastError = "barrier destroy failed: " .. tostring(err) end
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
    if not valid(cls) then writeStatus(); return end
    local world = resolveWorld()
    if not valid(world) then visualStatus = "world_not_resolved"; writeStatus(); return end

    barrierX = tonumber(trigger.center_x) or 0
    barrierY = tonumber(trigger.center_y) or 0
    barrierZ = tonumber(trigger.center_z) or 0

    local location = { X = barrierX, Y = barrierY, Z = barrierZ }
    local rotation = { Pitch = 0, Yaw = 0, Roll = 0 }
    visualStatus = "before_spawn_call"
    writeStatus()

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

    barrier = spawned
    spawnOk = true
    pcall(function() barrier:SetReplicates(true) end)
    pcall(function() barrier.bAlwaysRelevant = true end)
    pcall(function() barrier.NetCullDistanceSquared = 2500000000.0 end)

    scaleWriteAttempted = true
    local scaleOk, scaleErr = pcall(function()
        barrier:SetActorScale3D({ X = SCALE_XY, Y = SCALE_XY, Z = SCALE_Z })
    end)
    scaleWriteOk = scaleOk
    if not scaleOk then lastError = "barrier scale write failed: " .. tostring(scaleErr) end

    lockBefore = boolText(member(barrier, "bLocked"))
    lockWriteAttempted = true
    local lockOk, lockErr = pcall(function() barrier.bLocked = true end)
    lockWriteOk = lockOk
    if not lockOk then
        lastError = "bLocked write failed: " .. tostring(lockErr)
        visualStatus = "locked_write_failed"
        writeStatus()
        return
    end
    lockAfter = boolText(member(barrier, "bLocked"))
    lockObserved = lockAfter

    -- One-time authoritative collision disable. The visual stays active through
    -- bLocked=true; the actual raid boundary is the server-side keep-in module.
    collisionDisableAttempted = true
    local collisionOk, collisionErr = pcall(function()
        barrier:SetActorEnableCollision(false)
    end)
    collisionDisableOk = collisionOk
    if not collisionOk then
        lastError = "SetActorEnableCollision(false) failed: " .. tostring(collisionErr)
    end

    local netOk = pcall(function() barrier:ForceNetUpdate() end)
    if netOk then forceNetUpdates = forceNetUpdates + 1 end

    observeBarrier()
    visualStatus = "first_hit_nonblocking_barrier_active"
    writeStatus()
    log(string.format("barrier active after player entry; collision=%s; scale %.1fx%.1fx%.1f", collisionObserved, SCALE_XY, SCALE_XY, SCALE_Z))
end

local function tick()
    local raid = parseKv(readAll(raidStatusFile) or "active=0\nstate=IDLE\nraid_id=\n")
    local trigger = parseKv(readAll(triggerFile) or "triggered=0\nraid_id=\n")
    local raidId = tostring(raid.raid_id or "")

    if raidId ~= currentRaidId then
        if valid(barrier) then
            ExecuteInGameThread(function() cleanupBarrier() end)
        end
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
            visualStatus = "waiting_for_player_entry"
            writeStatus()
        end

        triggerTicks = triggerTicks + 1
        if not attempted and triggerTicks >= SPAWN_DELAY_TICKS then
            ExecuteInGameThread(function()
                local callOk, callErr = xpcall(function() spawnBarrier(trigger) end, debug.traceback)
                if not callOk then
                    lastError = tostring(callErr)
                    visualStatus = "spawn_exception"
                    log("barrier spawn failed: " .. lastError)
                    writeStatus()
                end
            end)
        elseif valid(barrier) and triggerTicks % OBSERVE_EVERY_TICKS == 0 then
            ExecuteInGameThread(function()
                local callOk, callErr = xpcall(observeBarrier, debug.traceback)
                if not callOk then
                    lastError = tostring(callErr)
                    log("barrier observation failed: " .. lastError)
                end
                writeStatus()
            end)
        end
    elseif valid(barrier) then
        ExecuteInGameThread(function() cleanupBarrier() end)
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
log("v" .. VERSION .. " loaded; delayed nonblocking first-hit barrier ready")
