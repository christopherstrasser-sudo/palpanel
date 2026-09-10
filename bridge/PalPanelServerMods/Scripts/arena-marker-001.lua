-- PalPanelServerMods raid arena visible marker ring v0.1.0
-- SERVER-ONLY / NO CLIENT MOD.
--
-- Purpose:
--   Provide a boundary that the vanilla client can actually SEE by using the
--   exact same proven server spawn path as the raid boss:
--     UPalNPCManager::SpawnNPCForServer(FPalNPCSpawnInfo, callback)
--
-- arena-027.lua remains authoritative for the real 6000-unit keep-in/keep-out
-- boundary. These marker Pals are visual only: movement disabled, collision
-- disabled where possible, controller tick stopped where possible, and they
-- are destroyed when the raid leaves ACTIVE.
--
-- Deliberately avoids:
--   * PalNetworkTransmitter / direct NetMulticast
--   * PalBuildObject / MapObject spawning
--   * SkillEffect barrier actors
--   * client-side mods

local MOD = "PalPanelRaidArenaMarker"
local VERSION = "0.1.0"
local TICK_MS = 250
local ARM_TICKS = 8
local RADIUS = 6000.0
local MARKER_COUNT = 12
local SPAWN_BATCH = 2
local RESOLVE_DELAY_MS = 450
local MARKER_CHARACTER_ID = "DreamDemon" -- Daedream; floating/dark and visually obvious
local MARKER_LEVEL = 1
local MARKER_SCALE = 1.35
local MARKER_Z_OFFSET = 80.0
local FREEZE_FLAG = "PalPanelArenaMarker"

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

local scriptsDir = scriptDir()
if not scriptsDir then
    log("Scripts directory unavailable; marker ring disabled")
    return
end
local modDir = scriptsDir:match("^(.+)\\Scripts$") or scriptsDir
local ipcDir = readAll(modDir .. "\\ipc_path.txt")
if ipcDir then ipcDir = ipcDir:gsub("[\r\n]+$", "") end
if not ipcDir or ipcDir == "" then
    log("ipc_path.txt unavailable; marker ring disabled")
    return
end

local raidStatusFile = ipcDir .. "\\raid-status.txt"
local markerStatusFile = ipcDir .. "\\raid-arena-marker-status.txt"

local currentRaidId = ""
local activeTicks = 0
local center = nil
local spawnIndex = 0
local spawnAttempts = 0
local spawnHandlesOk = 0
local spawnHandlesFailed = 0
local resolvedActors = 0
local frozenActors = 0
local collisionDisabled = 0
local destroyedActors = 0
local visualStatus = "idle"
local callInflight = "none"
local lastError = ""
local entries = {}
local scheduled = false
local generation = 0

local lastActive = {
    valid = 0,
    spawnAttempts = 0,
    spawnHandlesOk = 0,
    spawnHandlesFailed = 0,
    resolvedActors = 0,
    frozenActors = 0,
    collisionDisabled = 0,
    status = "",
    error = ""
}

local palUtil = nil
pcall(function() palUtil = StaticFindObject("/Script/Pal.Default__PalUtility") end)
palUtil = unwrap(palUtil)

local function anyPlayerController()
    local states = nil
    pcall(function() states = FindAllOf("PalPlayerState") end)
    if type(states) ~= "table" then return nil end
    for _, raw in ipairs(states) do
        local ps = unwrap(raw)
        if valid(ps) then
            local pc = nil
            pcall(function() pc = ps:GetPlayerController() end)
            pc = unwrap(pc)
            if not valid(pc) then pc = member(ps, "Owner") end
            if valid(pc) then return pc end
        end
    end
    return nil
end

local function snapshotActive()
    if not center then return end
    lastActive.valid = 1
    lastActive.spawnAttempts = spawnAttempts
    lastActive.spawnHandlesOk = spawnHandlesOk
    lastActive.spawnHandlesFailed = spawnHandlesFailed
    lastActive.resolvedActors = resolvedActors
    lastActive.frozenActors = frozenActors
    lastActive.collisionDisabled = collisionDisabled
    lastActive.status = visualStatus
    lastActive.error = lastError
end

local function writeStatus(raid)
    local c = center or { X = 0, Y = 0, Z = 0 }
    local lines = {
        "version=" .. VERSION,
        "time=" .. tostring(os.time()),
        "raid_id=" .. urlEncode(currentRaidId),
        "raid_state=" .. urlEncode(raid and raid.state or "IDLE"),
        "backend=npc_manager_visible_marker_ring",
        "client_install_required=0",
        "marker_character_id=" .. MARKER_CHARACTER_ID,
        "marker_count_requested=" .. tostring(MARKER_COUNT),
        "marker_level=" .. tostring(MARKER_LEVEL),
        "marker_scale=" .. tostring(MARKER_SCALE),
        "radius=" .. tostring(math.floor(RADIUS)),
        "center_x=" .. tostring(c.X or 0),
        "center_y=" .. tostring(c.Y or 0),
        "center_z=" .. tostring(c.Z or 0),
        "active_ticks=" .. tostring(activeTicks),
        "arm_ticks=" .. tostring(ARM_TICKS),
        "spawn_index=" .. tostring(spawnIndex),
        "spawn_attempts=" .. tostring(spawnAttempts),
        "spawn_handles_ok=" .. tostring(spawnHandlesOk),
        "spawn_handles_failed=" .. tostring(spawnHandlesFailed),
        "resolved_actors=" .. tostring(resolvedActors),
        "frozen_actors=" .. tostring(frozenActors),
        "collision_disabled=" .. tostring(collisionDisabled),
        "destroyed_actors=" .. tostring(destroyedActors),
        "visual_status=" .. urlEncode(visualStatus),
        "call_inflight=" .. urlEncode(callInflight),
        "last_error=" .. urlEncode(lastError),
        "last_active_valid=" .. tostring(lastActive.valid),
        "last_active_spawn_attempts=" .. tostring(lastActive.spawnAttempts),
        "last_active_spawn_handles_ok=" .. tostring(lastActive.spawnHandlesOk),
        "last_active_spawn_handles_failed=" .. tostring(lastActive.spawnHandlesFailed),
        "last_active_resolved_actors=" .. tostring(lastActive.resolvedActors),
        "last_active_frozen_actors=" .. tostring(lastActive.frozenActors),
        "last_active_collision_disabled=" .. tostring(lastActive.collisionDisabled),
        "last_active_visual_status=" .. urlEncode(lastActive.status),
        "last_active_error=" .. urlEncode(lastActive.error)
    }
    writeAll(markerStatusFile, table.concat(lines, "\n") .. "\n")
end

local function runGameThread(label, fn)
    ExecuteInGameThread(function()
        local ok, err = xpcall(fn, debug.traceback)
        if not ok then
            lastError = label .. ": " .. tostring(err)
            visualStatus = "game_thread_error"
            log(lastError)
        end
    end)
end

local function destroyEntry(entry)
    if not entry then return end
    local actor = unwrap(entry.actor)
    if not valid(actor) and valid(entry.handle) then
        pcall(function() actor = entry.handle:TryGetIndividualActor() end)
        actor = unwrap(actor)
    end
    if valid(actor) then
        local controller = nil
        pcall(function() controller = actor:GetController() end)
        controller = unwrap(controller)
        if valid(controller) then pcall(function() controller:K2_DestroyActor() end) end
        local ok = pcall(function() actor:K2_DestroyActor() end)
        if ok then destroyedActors = destroyedActors + 1 end
    end
    entry.actor = nil
    entry.handle = nil
end

local function cleanup()
    generation = generation + 1
    local old = entries
    entries = {}
    runGameThread("marker_cleanup", function()
        for _, entry in ipairs(old) do destroyEntry(entry) end
    end)
end

local function resetRaid(raidId)
    cleanup()
    currentRaidId = tostring(raidId or "")
    activeTicks = 0
    center = nil
    spawnIndex = 0
    spawnAttempts = 0
    spawnHandlesOk = 0
    spawnHandlesFailed = 0
    resolvedActors = 0
    frozenActors = 0
    collisionDisabled = 0
    destroyedActors = 0
    visualStatus = "waiting_active_raid"
    callInflight = "none"
    lastError = ""
    lastActive = {
        valid = 0, spawnAttempts = 0, spawnHandlesOk = 0,
        spawnHandlesFailed = 0, resolvedActors = 0, frozenActors = 0,
        collisionDisabled = 0, status = "", error = ""
    }
end

local function npcManagerAndController()
    if not valid(palUtil) then
        pcall(function() palUtil = StaticFindObject("/Script/Pal.Default__PalUtility") end)
        palUtil = unwrap(palUtil)
    end
    if not valid(palUtil) then return nil, nil, "PalUtility unavailable" end
    local pc = anyPlayerController()
    if not valid(pc) then return nil, nil, "player controller unavailable" end
    local manager = nil
    pcall(function() manager = palUtil:GetNPCManager(pc) end)
    manager = unwrap(manager)
    if not valid(manager) then return nil, nil, "NPC manager unavailable" end
    local controllerClass = member(manager, "NPCAIControllerBaseClass")
    if not valid(controllerClass) then return nil, nil, "NPC base controller unavailable" end
    return manager, controllerClass, nil
end

local function freezeMarker(actor)
    actor = unwrap(actor)
    if not valid(actor) then return false end

    pcall(function() actor:SetActorScale3D({ X = MARKER_SCALE, Y = MARKER_SCALE, Z = MARKER_SCALE }) end)

    local disabledCollision = false
    local okCollision = pcall(function() actor:SetActorEnableCollision(false) end)
    if okCollision then disabledCollision = true end
    if valid(palUtil) then
        pcall(function() palUtil:SetBodyPartsCollisionEnable(actor, false) end)
        local moveOk = pcall(function() palUtil:SetMoveDisableFlag(actor, true, FName(FREEZE_FLAG)) end)
        if moveOk then frozenActors = frozenActors + 1 end
    end
    if disabledCollision then collisionDisabled = collisionDisabled + 1 end

    pcall(function() actor:SetCanBeDamaged(false) end)

    local controller = nil
    pcall(function() controller = actor:GetController() end)
    controller = unwrap(controller)
    if valid(controller) then
        pcall(function() controller:StopMovement() end)
        pcall(function() controller:SetActorTickEnabled(false) end)
    end

    pcall(function() actor:ForceNetUpdate() end)
    return true
end

local function resolveEntry(entry, expectedGeneration, expectedRaidId)
    ExecuteWithDelay(RESOLVE_DELAY_MS, function()
        runGameThread("marker_resolve_" .. tostring(entry.index), function()
            if expectedGeneration ~= generation or currentRaidId ~= expectedRaidId then
                destroyEntry(entry)
                return
            end
            local actor = nil
            if valid(entry.handle) then pcall(function() actor = entry.handle:TryGetIndividualActor() end) end
            actor = unwrap(actor)
            if valid(actor) then
                entry.actor = actor
                resolvedActors = resolvedActors + 1
                freezeMarker(actor)
                visualStatus = resolvedActors >= MARKER_COUNT and "visible_marker_ring_ready" or "resolving_markers"
                snapshotActive()
                log(string.format("marker %d resolved/frozen (%d/%d)", entry.index, resolvedActors, MARKER_COUNT))
            else
                lastError = "marker " .. tostring(entry.index) .. " actor not resolved"
                visualStatus = "marker_resolve_failed"
            end
        end)
    end)
end

local function spawnMarker(index, raid)
    if not center then return end
    local manager, controllerClass, err = npcManagerAndController()
    if not valid(manager) then
        lastError = err or "NPC spawn prerequisites unavailable"
        visualStatus = "npc_manager_unavailable"
        return
    end

    local angle = (math.pi * 2.0 * index) / MARKER_COUNT
    local location = {
        X = center.X + math.cos(angle) * RADIUS,
        Y = center.Y + math.sin(angle) * RADIUS,
        Z = center.Z + MARKER_Z_OFFSET
    }
    local yaw = math.deg(angle) + 180.0
    local spawnInfo = {
        ControllerClass = controllerClass,
        CharacterID = FName(MARKER_CHARACTER_ID),
        Level = MARKER_LEVEL,
        Location = location,
        Yaw = yaw,
        Squad = nil
    }

    spawnAttempts = spawnAttempts + 1
    callInflight = "SpawnNPCForServer_" .. tostring(index)
    visualStatus = "spawning_visible_markers"
    snapshotActive(); writeStatus(raid)

    local ok, handle = pcall(function()
        return manager:SpawnNPCForServer(spawnInfo, nil)
    end)
    handle = unwrap(handle)
    callInflight = "none"

    if ok and valid(handle) then
        spawnHandlesOk = spawnHandlesOk + 1
        local entry = { index = index, handle = handle, actor = nil }
        entries[#entries + 1] = entry
        resolveEntry(entry, generation, currentRaidId)
    else
        spawnHandlesFailed = spawnHandlesFailed + 1
        lastError = "SpawnNPCForServer marker " .. tostring(index) .. " failed: " .. tostring(handle)
        visualStatus = "marker_spawn_failed"
        log(lastError)
    end
end

local function tick()
    local raw = readAll(raidStatusFile)
    local raid = raw and parseKv(raw) or { state = "IDLE", active = "0", raid_id = "" }
    local raidId = tostring(raid.raid_id or "")

    if raidId ~= currentRaidId then resetRaid(raidId) end

    local active = raid.active == "1" and raid.state == "ACTIVE" and raidId ~= ""
    if not active then
        if #entries > 0 then
            snapshotActive()
            cleanup()
        end
        activeTicks = 0
        center = nil
        if raid.state == "CANCELLED" or raid.state == "COMPLETED" or raid.state == "FAILED" then
            visualStatus = "released"
        elseif currentRaidId == "" then
            visualStatus = "idle"
        else
            visualStatus = "waiting_active_raid"
        end
        writeStatus(raid)
        return
    end

    activeTicks = activeTicks + 1
    if not center then
        center = {
            X = tonumber(raid.x) or 0,
            Y = tonumber(raid.y) or 0,
            Z = tonumber(raid.z) or 0
        }
        visualStatus = "armed"
        log(string.format("marker ring armed at %.1f %.1f %.1f", center.X, center.Y, center.Z))
    end

    if activeTicks >= ARM_TICKS and spawnIndex < MARKER_COUNT then
        local remaining = math.min(SPAWN_BATCH, MARKER_COUNT - spawnIndex)
        for _ = 1, remaining do
            local idx = spawnIndex
            spawnIndex = spawnIndex + 1
            runGameThread("marker_spawn_" .. tostring(idx), function() spawnMarker(idx, raid) end)
        end
    end

    if spawnIndex >= MARKER_COUNT and resolvedActors >= MARKER_COUNT then
        visualStatus = "visible_marker_ring_ready"
    elseif spawnIndex >= MARKER_COUNT then
        visualStatus = "waiting_marker_resolution"
    end

    snapshotActive()
    writeStatus(raid)
end

local function schedule()
    if scheduled then return end
    scheduled = true
    local function loop()
        local ok, err = xpcall(tick, debug.traceback)
        if not ok then
            lastError = tostring(err)
            visualStatus = "tick_error"
            log("tick failed: " .. lastError)
        end
        ExecuteWithDelay(TICK_MS, loop)
    end
    ExecuteWithDelay(TICK_MS, loop)
end

schedule()
log(string.format("v%s loaded; server-visible %s marker ring ready (%d markers, radius %.0f)", VERSION, MARKER_CHARACTER_ID, MARKER_COUNT, RADIUS))
