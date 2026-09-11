-- PalPanelServerMods Arena v2 step 2D / replicated lock-state probe v0.3.0
-- SERVER-ONLY / NO CLIENT MOD.
--
-- Proven observations from step 2C:
--   * BP_LevelObject_TowerLockBarrier_C spawns and replicates to the client.
--   * BarrierMesh can be true/visible server-side while the client hides it.
--   * Repeated component visibility/replication mutations are unsafe and removed.
--
-- APalLevelObject_LockedObstacle exposes bLocked as Net + RepNotify. This probe
-- sets that authoritative replicated state exactly ONCE immediately after spawn,
-- then only observes it. No repeated visibility/component mutations, no UObject
-- scan, no Niagara, no NPC/AI/collision changes and no custom RPCs.

local MOD = "PalPanelArenaV2Visual"
local VERSION = "0.3.0"
local TICK_MS = 250
local ARM_TICKS = 8
local MARKER_RADIUS = 3700.0
local OBSERVE_EVERY_TICKS = 4

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
if not scriptsDir then
    log("Scripts directory unavailable; lock-state probe disabled")
    return
end
local modDir = scriptsDir:match("^(.+)\\Scripts$") or scriptsDir
local ipcDir = readAll(modDir .. "\\ipc_path.txt")
if ipcDir then ipcDir = ipcDir:gsub("[\r\n]+$", "") end
if not ipcDir or ipcDir == "" then
    log("ipc_path.txt unavailable; lock-state probe disabled")
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
local lockWriteAttempted = false
local lockWriteOk = false
local lockBefore = "unknown"
local lockAfter = "unknown"
local lockObserved = "unknown"
local lockObservedChanges = 0
local lastObservedLock = "unknown"
local observePasses = 0
local markerMeshValid = false
local markerMeshVisible = "unknown"
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
        "lock_write_attempted=" .. (lockWriteAttempted and "1" or "0"),
        "lock_write_ok=" .. (lockWriteOk and "1" or "0"),
        "lock_before=" .. urlEncode(lockBefore),
        "lock_after=" .. urlEncode(lockAfter),
        "lock_observed=" .. urlEncode(lockObserved),
        "lock_observed_changes=" .. tostring(lockObservedChanges),
        "observe_passes=" .. tostring(observePasses),
        "marker_mesh_valid=" .. (markerMeshValid and "1" or "0"),
        "marker_mesh_visible=" .. urlEncode(markerMeshVisible),
        "marker_x=" .. tostring(markerX),
        "marker_y=" .. tostring(markerY),
        "marker_z=" .. tostring(markerZ),
        "backend=single_replicated_tower_lock_barrier_authoritative_blocked",
        "actor_spawn=" .. (attempted and "1" or "0"),
        "npc_spawn=0",
        "rpc_calls=0",
        "niagara_calls=0",
        "component_replication_mutation=0",
        "visibility_mutation=0",
        "collision_mutation=0",
        "ai_mutation=0",
        "reflection_scan=0",
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
    lockWriteAttempted = false
    lockWriteOk = false
    lockBefore = "unknown"
    lockAfter = "unknown"
    lockObserved = "unknown"
    lockObservedChanges = 0
    lastObservedLock = "unknown"
    observePasses = 0
    markerMeshValid = false
    markerMeshVisible = "unknown"
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

local function observeMarker()
    if not valid(marker) then return end
    observePasses = observePasses + 1

    local now = boolText(member(marker, "bLocked"))
    lockObserved = now
    if lastObservedLock ~= "unknown" and now ~= lastObservedLock then
        lockObservedChanges = lockObservedChanges + 1
        log(string.format("bLocked changed: %s -> %s", lastObservedLock, now))
    end
    lastObservedLock = now

    local mesh = member(marker, "BarrierMesh")
    markerMeshValid = valid(mesh)
    if markerMeshValid then
        local vis = nil
        local ok = pcall(function() vis = mesh:IsVisible() end)
        markerMeshVisible = ok and boolText(vis) or "unknown"
    end
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
    log(string.format("lock-state probe spawning at %.1f %.1f %.1f via %s", markerX, markerY, markerZ, classSource))

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
    pcall(function() marker:SetReplicates(true) end)
    pcall(function() marker.bAlwaysRelevant = true end)
    pcall(function() marker.NetCullDistanceSquared = 2500000000.0 end)

    -- Authoritative state change: exactly once. bLocked is a replicated
    -- RepNotify property on APalLevelObject_LockedObstacle.
    lockBefore = boolText(member(marker, "bLocked"))
    lockWriteAttempted = true
    local writeOk, writeErr = pcall(function()
        marker.bLocked = true
    end)
    lockWriteOk = writeOk
    if not writeOk then
        lastError = "bLocked write failed: " .. tostring(writeErr)
        visualStatus = "blocked_write_failed"
        writeStatus()
        return
    end

    lockAfter = boolText(member(marker, "bLocked"))
    lockObserved = lockAfter
    lastObservedLock = lockAfter

    local netOk = pcall(function() marker:ForceNetUpdate() end)
    if netOk then forceNetUpdates = forceNetUpdates + 1 end

    observeMarker()
    visualStatus = lockAfter == "true" and "authoritative_blocked_true_sent" or "blocked_write_not_confirmed"
    writeStatus()
    log(string.format("TowerLockBarrier spawned; bLocked %s -> %s; one ForceNetUpdate sent", lockBefore, lockAfter))
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
                    log("lock-state probe exception: " .. lastError)
                end
            end)
        elseif valid(marker) and activeTicks % OBSERVE_EVERY_TICKS == 0 then
            ExecuteInGameThread(function()
                local ok, err = xpcall(function() observeMarker() end, debug.traceback)
                if not ok then
                    lastError = tostring(err)
                    visualStatus = "observe_exception"
                    log("lock-state observation failed: " .. lastError)
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
log("v" .. VERSION .. " loaded; authoritative TowerLockBarrier bLocked probe ready")
