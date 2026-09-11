-- PalPanelServerMods Arena v2 step 2B / visual probe v0.1.0
-- SERVER-ONLY / NO CLIENT MOD.
--
-- One deliberately isolated visual probe only:
--   * keeps Arena v2 keep-in completely separate
--   * spawns exactly ONE vanilla BP_LevelObject_TowerLockBarrier_C
--     just outside the technical 3500-unit boundary
--   * no RPCs, no Niagara calls, no NPCs, no AI/collision mutation
--   * actor class itself is a replicated Palworld locked-obstacle Blueprint
--
-- The status file is persisted BEFORE and AFTER the native SpawnActor call so
-- an in-call process crash is distinguishable from an ordinary Lua failure.

local MOD = "PalPanelArenaV2Visual"
local VERSION = "0.1.0"
local TICK_MS = 250
local ARM_TICKS = 8
local MARKER_RADIUS = 3700.0

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

local scriptsDir = scriptDir()
if not scriptsDir then
    log("Scripts directory unavailable; visual probe disabled")
    return
end
local modDir = scriptsDir:match("^(.+)\\Scripts$") or scriptsDir
local ipcDir = readAll(modDir .. "\\ipc_path.txt")
if ipcDir then ipcDir = ipcDir:gsub("[\r\n]+$", "") end
if not ipcDir or ipcDir == "" then
    log("ipc_path.txt unavailable; visual probe disabled")
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
local markerMeshAsset = ""
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
        "marker_mesh_asset=" .. urlEncode(markerMeshAsset),
        "marker_x=" .. tostring(markerX),
        "marker_y=" .. tostring(markerY),
        "marker_z=" .. tostring(markerZ),
        "backend=single_replicated_vanilla_tower_lock_barrier",
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
    markerMeshAsset = ""
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

local function inspectMarker()
    if not valid(marker) then return end
    local mesh = member(marker, "BarrierMesh")
    markerMeshValid = valid(mesh)
    if not markerMeshValid then return end

    local vis = nil
    local visOk = pcall(function() vis = mesh:IsVisible() end)
    if visOk and vis ~= nil then markerMeshVisible = tostring(vis) end

    local asset = nil
    pcall(function() asset = mesh:GetStaticMesh() end)
    asset = unwrap(asset)
    if valid(asset) then markerMeshAsset = fullName(asset) end
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
    if not valid(cls) then
        writeStatus()
        return
    end

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

    -- At +X on the circle, yaw 90 makes a wall-like mesh tangent to the ring.
    local location = { X = markerX, Y = markerY, Z = markerZ }
    local rotation = { Pitch = 0, Yaw = 90, Roll = 0 }

    visualStatus = "before_spawn_call"
    writeStatus()
    log(string.format("visual probe spawning at %.1f %.1f %.1f via %s", markerX, markerY, markerZ, classSource))

    local spawned = nil
    local ok, result = pcall(function()
        return world:SpawnActor(cls, location, rotation)
    end)
    spawnCallReturned = true
    spawned = unwrap(result)

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
    visualStatus = "spawned_waiting_for_replication"

    -- The Palworld base class already has bReplicates=true. These are only
    -- standard replication nudges; there is deliberately no custom RPC call.
    pcall(function() marker:SetReplicates(true) end)
    pcall(function() marker.bAlwaysRelevant = true end)
    pcall(function() marker.NetCullDistanceSquared = 2500000000.0 end)
    local netOk = pcall(function() marker:ForceNetUpdate() end)
    if netOk then forceNetUpdates = forceNetUpdates + 1 end

    inspectMarker()
    visualStatus = "single_tower_lock_barrier_active"
    writeStatus()
    log("single replicated TowerLockBarrier probe spawned successfully")
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
                    log("visual probe exception: " .. lastError)
                end
            end)
        elseif valid(marker) and activeTicks % 8 == 0 then
            ExecuteInGameThread(function()
                inspectMarker()
                local ok = pcall(function() marker:ForceNetUpdate() end)
                if ok then forceNetUpdates = forceNetUpdates + 1 end
                writeStatus()
            end)
        end
    else
        activeTicks = 0
        if valid(marker) then
            ExecuteInGameThread(function() cleanupMarker() end)
        end
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
log("v" .. VERSION .. " loaded; single replicated TowerLockBarrier visual probe ready")
