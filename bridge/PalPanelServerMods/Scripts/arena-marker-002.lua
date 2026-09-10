-- PalPanelServerMods raid arena visible marker ring v0.2.0
-- SERVER-ONLY / NO CLIENT MOD.
--
-- Uses the same proven UPalNPCManager::SpawnNPCForServer path as the raid boss.
-- arena-027.lua remains authoritative for the real 6000-unit keep-in/keep-out boundary.
-- Marker Pals are only visual carriers. v0.2.0 continuously enforces a neutral state
-- after character initialization so collision/damage/AI cannot be re-enabled later.

local MOD = "PalPanelRaidArenaMarker"
local VERSION = "0.2.0"
local TICK_MS = 250
local ARM_TICKS = 8
local RADIUS = 6000.0
local MARKER_COUNT = 12
local SPAWN_BATCH = 2
local RESOLVE_DELAY_MS = 300
local RESOLVE_RETRY_MS = 250
local RESOLVE_RETRIES = 12
local NEUTRALIZE_EVERY_TICKS = 4
local MARKER_CHARACTER_ID = "GrassMammoth"
local MARKER_SCALE = 1.0
local MARKER_Z_OFFSET = 80.0
local FREEZE_FLAG = "PalPanelArenaMarker"
local NO_COLLISION = 0

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
local currentMarkerLevel = 1
local activeTicks = 0
local center = nil
local spawnIndex = 0
local spawnAttempts = 0
local spawnHandlesOk = 0
local spawnHandlesFailed = 0
local resolvedActors = 0
local neutralizedActors = 0
local invulnerabilityApplied = 0
local collisionGuardsApplied = 0
local movementGuardsApplied = 0
local aiGuardsApplied = 0
local neutralizePasses = 0
local destroyedActors = 0
local visualStatus = "idle"
local callInflight = "none"
local lastError = ""
local entries = {}
local scheduled = false
local generation = 0

local lastActive = {
    valid = 0,
    markerLevel = 1,
    spawnAttempts = 0,
    spawnHandlesOk = 0,
    spawnHandlesFailed = 0,
    resolvedActors = 0,
    neutralizedActors = 0,
    invulnerabilityApplied = 0,
    collisionGuardsApplied = 0,
    movementGuardsApplied = 0,
    aiGuardsApplied = 0,
    neutralizePasses = 0,
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
    lastActive.markerLevel = currentMarkerLevel
    lastActive.spawnAttempts = spawnAttempts
    lastActive.spawnHandlesOk = spawnHandlesOk
    lastActive.spawnHandlesFailed = spawnHandlesFailed
    lastActive.resolvedActors = resolvedActors
    lastActive.neutralizedActors = neutralizedActors
    lastActive.invulnerabilityApplied = invulnerabilityApplied
    lastActive.collisionGuardsApplied = collisionGuardsApplied
    lastActive.movementGuardsApplied = movementGuardsApplied
    lastActive.aiGuardsApplied = aiGuardsApplied
    lastActive.neutralizePasses = neutralizePasses
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
        "backend=npc_manager_neutral_visible_marker_ring",
        "client_install_required=0",
        "marker_character_id=" .. MARKER_CHARACTER_ID,
        "marker_count_requested=" .. tostring(MARKER_COUNT),
        "marker_level=" .. tostring(currentMarkerLevel),
        "marker_level_source=raid_level",
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
        "neutralized_actors=" .. tostring(neutralizedActors),
        "invulnerability_applied=" .. tostring(invulnerabilityApplied),
        "collision_guards_applied=" .. tostring(collisionGuardsApplied),
        "movement_guards_applied=" .. tostring(movementGuardsApplied),
        "ai_guards_applied=" .. tostring(aiGuardsApplied),
        "neutralize_passes=" .. tostring(neutralizePasses),
        "destroyed_actors=" .. tostring(destroyedActors),
        "visual_status=" .. urlEncode(visualStatus),
        "call_inflight=" .. urlEncode(callInflight),
        "last_error=" .. urlEncode(lastError),
        "last_active_valid=" .. tostring(lastActive.valid),
        "last_active_marker_level=" .. tostring(lastActive.markerLevel),
        "last_active_spawn_attempts=" .. tostring(lastActive.spawnAttempts),
        "last_active_spawn_handles_ok=" .. tostring(lastActive.spawnHandlesOk),
        "last_active_spawn_handles_failed=" .. tostring(lastActive.spawnHandlesFailed),
        "last_active_resolved_actors=" .. tostring(lastActive.resolvedActors),
        "last_active_neutralized_actors=" .. tostring(lastActive.neutralizedActors),
        "last_active_invulnerability_applied=" .. tostring(lastActive.invulnerabilityApplied),
        "last_active_collision_guards_applied=" .. tostring(lastActive.collisionGuardsApplied),
        "last_active_movement_guards_applied=" .. tostring(lastActive.movementGuardsApplied),
        "last_active_ai_guards_applied=" .. tostring(lastActive.aiGuardsApplied),
        "last_active_neutralize_passes=" .. tostring(lastActive.neutralizePasses),
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

local function ensurePalUtil()
    if valid(palUtil) then return true end
    pcall(function() palUtil = StaticFindObject("/Script/Pal.Default__PalUtility") end)
    palUtil = unwrap(palUtil)
    return valid(palUtil)
end

local function npcManagerAndController()
    if not ensurePalUtil() then return nil, nil, "PalUtility unavailable" end
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

local function disablePrimitiveCollision(component)
    component = unwrap(component)
    if not valid(component) then return false end
    local any = false
    if pcall(function() component:SetCollisionEnabled(NO_COLLISION) end) then any = true end
    pcall(function() component:SetGenerateOverlapEvents(false) end)
    return any
end

local function neutralizeMarker(entry)
    if not entry then return false end
    local actor = unwrap(entry.actor)
    if not valid(actor) then return false end

    local invuln = false
    local collision = false
    local movement = false
    local ai = false

    pcall(function() actor:SetActorScale3D({ X = MARKER_SCALE, Y = MARKER_SCALE, Z = MARKER_SCALE }) end)

    -- Server-side damage guard. Keep both paths because UE4SS builds expose
    -- AActor's damage flag differently depending on reflection metadata.
    if pcall(function() actor.bCanBeDamaged = false end) then invuln = true end
    if pcall(function() actor:SetCanBeDamaged(false) end) then invuln = true end

    -- Disable every normal character hit/query surface we can reach. This is
    -- re-applied periodically because Pal character initialization may restore
    -- collision after the first resolved frame.
    if pcall(function() actor:SetActorEnableCollision(false) end) then collision = true end
    if ensurePalUtil() then
        if pcall(function() palUtil:SetBodyPartsCollisionEnable(actor, false) end) then collision = true end
        pcall(function() palUtil:SetBodyPartsCollisionProfile(actor, FName("NoCollision")) end)
        if pcall(function() palUtil:SetMoveDisableFlag(actor, true, FName(FREEZE_FLAG)) end) then movement = true end
    end

    local capsule = nil
    pcall(function() capsule = actor:GetCapsuleComponent() end)
    if disablePrimitiveCollision(capsule) then collision = true end

    local mesh = nil
    pcall(function() mesh = actor:GetMesh() end)
    if disablePrimitiveCollision(mesh) then collision = true end

    local move = nil
    pcall(function() move = actor:GetCharacterMovement() end)
    move = unwrap(move)
    if valid(move) then
        if pcall(function() move:StopMovementImmediately() end) then movement = true end
        if pcall(function() move:DisableMovement() end) then movement = true end
    end

    local controller = nil
    pcall(function() controller = actor:GetController() end)
    controller = unwrap(controller)
    if valid(controller) then
        pcall(function() controller:StopMovement() end)
        if pcall(function() controller:SetActorTickEnabled(false) end) then ai = true end
    else
        ai = true
    end

    pcall(function() actor:ForceNetUpdate() end)

    if invuln and not entry.invuln then
        entry.invuln = true
        invulnerabilityApplied = invulnerabilityApplied + 1
    end
    if collision and not entry.collision then
        entry.collision = true
        collisionGuardsApplied = collisionGuardsApplied + 1
    end
    if movement and not entry.movement then
        entry.movement = true
        movementGuardsApplied = movementGuardsApplied + 1
    end
    if ai and not entry.ai then
        entry.ai = true
        aiGuardsApplied = aiGuardsApplied + 1
    end
    if entry.invuln and entry.collision and entry.movement and entry.ai and not entry.neutralized then
        entry.neutralized = true
        neutralizedActors = neutralizedActors + 1
    end
    return entry.neutralized == true
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
    currentMarkerLevel = 1
    activeTicks = 0
    center = nil
    spawnIndex = 0
    spawnAttempts = 0
    spawnHandlesOk = 0
    spawnHandlesFailed = 0
    resolvedActors = 0
    neutralizedActors = 0
    invulnerabilityApplied = 0
    collisionGuardsApplied = 0
    movementGuardsApplied = 0
    aiGuardsApplied = 0
    neutralizePasses = 0
    destroyedActors = 0
    visualStatus = "waiting_active_raid"
    callInflight = "none"
    lastError = ""
    lastActive = {
        valid = 0, markerLevel = 1, spawnAttempts = 0, spawnHandlesOk = 0,
        spawnHandlesFailed = 0, resolvedActors = 0, neutralizedActors = 0,
        invulnerabilityApplied = 0, collisionGuardsApplied = 0,
        movementGuardsApplied = 0, aiGuardsApplied = 0, neutralizePasses = 0,
        status = "", error = ""
    }
end

local function resolveEntry(entry, expectedGeneration, expectedRaidId, attempt)
    attempt = attempt or 1
    ExecuteWithDelay(attempt == 1 and RESOLVE_DELAY_MS or RESOLVE_RETRY_MS, function()
        runGameThread("marker_resolve_" .. tostring(entry.index), function()
            if expectedGeneration ~= generation or currentRaidId ~= expectedRaidId then
                destroyEntry(entry)
                return
            end
            if valid(entry.actor) then
                neutralizeMarker(entry)
                return
            end
            local actor = nil
            if valid(entry.handle) then pcall(function() actor = entry.handle:TryGetIndividualActor() end) end
            actor = unwrap(actor)
            if valid(actor) then
                entry.actor = actor
                resolvedActors = resolvedActors + 1
                neutralizeMarker(entry)
                visualStatus = resolvedActors >= MARKER_COUNT and "visible_neutral_marker_ring_ready" or "resolving_markers"
                snapshotActive()
                log(string.format("marker %d resolved/neutralized (%d/%d)", entry.index, resolvedActors, MARKER_COUNT))
            elseif attempt < RESOLVE_RETRIES then
                resolveEntry(entry, expectedGeneration, expectedRaidId, attempt + 1)
            else
                lastError = "marker " .. tostring(entry.index) .. " actor not resolved after retries"
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
    local spawnInfo = {
        ControllerClass = controllerClass,
        CharacterID = FName(MARKER_CHARACTER_ID),
        Level = currentMarkerLevel,
        Location = location,
        Yaw = math.deg(angle) + 180.0,
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
        local entry = {
            index = index, handle = handle, actor = nil,
            invuln = false, collision = false, movement = false,
            ai = false, neutralized = false
        }
        entries[#entries + 1] = entry
        resolveEntry(entry, generation, currentRaidId, 1)
    else
        spawnHandlesFailed = spawnHandlesFailed + 1
        lastError = "SpawnNPCForServer marker " .. tostring(index) .. " failed: " .. tostring(handle)
        visualStatus = "marker_spawn_failed"
        log(lastError)
    end
end

local function enforceNeutralState()
    neutralizePasses = neutralizePasses + 1
    for _, entry in ipairs(entries) do
        if valid(entry.actor) then neutralizeMarker(entry) end
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
        currentMarkerLevel = math.max(1, math.floor(tonumber(raid.level) or 1))
        visualStatus = "armed"
        log(string.format("neutral marker ring armed at %.1f %.1f %.1f, level=%d", center.X, center.Y, center.Z, currentMarkerLevel))
    end

    if activeTicks >= ARM_TICKS and spawnIndex < MARKER_COUNT then
        local remaining = math.min(SPAWN_BATCH, MARKER_COUNT - spawnIndex)
        for _ = 1, remaining do
            local idx = spawnIndex
            spawnIndex = spawnIndex + 1
            runGameThread("marker_spawn_" .. tostring(idx), function() spawnMarker(idx, raid) end)
        end
    end

    if activeTicks % NEUTRALIZE_EVERY_TICKS == 0 and #entries > 0 then
        runGameThread("marker_neutralize_pass", enforceNeutralState)
    end

    if resolvedActors >= MARKER_COUNT and neutralizedActors >= MARKER_COUNT then
        visualStatus = "visible_neutral_marker_ring_ready"
    elseif resolvedActors >= MARKER_COUNT then
        visualStatus = "visible_ring_neutralizing"
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
log(string.format("v%s loaded; neutral server-visible %s marker ring ready (%d markers, radius %.0f)", VERSION, MARKER_CHARACTER_ID, MARKER_COUNT, RADIUS))
