-- PalPanelServerMods arena crowd boundary v1.3.0
-- SERVER-ONLY / NO CLIENT MOD.
--
-- 32-character compact crowd boundary:
--   * 16 generic villagers + 16 proven GrassMammoths
--   * gameplay radius 4000, crowd radius 4500
--   * NO position pinning and NO recurring Z teleports
--   * character capsule keeps ONLY WorldStatic/Terrain blocking enabled
--   * all other collision channels are ignored
--   * mesh/body-part hitboxes are disabled
--   * CharacterMovement stays alive for normal floor/gravity handling, but
--     walking acceleration/speed is forced to zero and controller AI is stopped
--   * characters are invulnerable and uncapturable where supported
--
-- This deliberately fixes the previous design error: disabling the complete
-- actor/capsule collision removed the floor beneath the decorative NPCs.

local MOD = "PalPanelRaidArenaCrowd"
local VERSION = "1.3.0"

local TICK_MS = 250
local ARM_TICKS = 8
local GAMEPLAY_RADIUS = 4000.0
local CROWD_RADIUS = 4500.0
local BOUNDARY_COUNT = 32
local SPAWN_BATCH = 1
local RESOLVE_DELAY_MS = 350
local RESOLVE_RETRY_MS = 300
local RESOLVE_RETRIES = 12
local ENFORCE_EVERY_TICKS = 4
local SPAWN_Z_OFFSET = 600.0

-- Unreal collision enums.
local COLLISION_QUERY_AND_PHYSICS = 3
local COLLISION_NONE = 0
local RESPONSE_IGNORE = 0
local RESPONSE_BLOCK = 2
local CHANNEL_WORLD_STATIC = 0

local HUMAN_IDS = { "MobuCitizen", "MobuCitizen_Male" }
local PAL_ID = "GrassMammoth"

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
if not scriptsDir then log("Scripts directory unavailable; crowd disabled"); return end
local modDir = scriptsDir:match("^(.+)\\Scripts$") or scriptsDir
local ipcDir = readAll(modDir .. "\\ipc_path.txt")
if ipcDir then ipcDir = ipcDir:gsub("[\r\n]+$", "") end
if not ipcDir or ipcDir == "" then log("ipc_path.txt unavailable; crowd disabled"); return end

local raidStatusFile = ipcDir .. "\\raid-status.txt"
local crowdStatusFile = ipcDir .. "\\raid-arena-crowd-status.txt"

local currentRaidId = ""
local currentLevel = 1
local activeTicks = 0
local center = nil
local spawnIndex = 0
local spawnAttempts = 0
local spawnHandlesOk = 0
local spawnHandlesFailed = 0
local resolvedActors = 0
local humanResolved = 0
local palResolved = 0
local configuredActors = 0
local floorCapsulesOk = 0
local uncapturableApplied = 0
local invulnerabilityApplied = 0
local movementLocksApplied = 0
local aiLocksApplied = 0
local destroyedActors = 0
local visualStatus = "idle"
local callInflight = "none"
local lastError = ""
local entries = {}
local scheduled = false
local generation = 0

local lastActive = {
    valid = 0, resolvedActors = 0, humanResolved = 0, palResolved = 0,
    configuredActors = 0, floorCapsulesOk = 0, status = "", error = ""
}

local palUtil = nil
pcall(function() palUtil = StaticFindObject("/Script/Pal.Default__PalUtility") end)
palUtil = unwrap(palUtil)

local function ensurePalUtil()
    if valid(palUtil) then return true end
    pcall(function() palUtil = StaticFindObject("/Script/Pal.Default__PalUtility") end)
    palUtil = unwrap(palUtil)
    return valid(palUtil)
end

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
    lastActive.resolvedActors = resolvedActors
    lastActive.humanResolved = humanResolved
    lastActive.palResolved = palResolved
    lastActive.configuredActors = configuredActors
    lastActive.floorCapsulesOk = floorCapsulesOk
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
        "backend=floor_only_collision_32_character_crowd",
        "client_install_required=0",
        "boundary_count_requested=" .. tostring(BOUNDARY_COUNT),
        "humans_requested=16",
        "pals_requested=16",
        "raid_level=" .. tostring(currentLevel),
        "gameplay_radius=" .. tostring(math.floor(GAMEPLAY_RADIUS)),
        "crowd_radius=" .. tostring(math.floor(CROWD_RADIUS)),
        "center_x=" .. tostring(c.X or 0),
        "center_y=" .. tostring(c.Y or 0),
        "center_z=" .. tostring(c.Z or 0),
        "active_ticks=" .. tostring(activeTicks),
        "spawn_index=" .. tostring(spawnIndex),
        "spawn_attempts=" .. tostring(spawnAttempts),
        "spawn_handles_ok=" .. tostring(spawnHandlesOk),
        "spawn_handles_failed=" .. tostring(spawnHandlesFailed),
        "resolved_actors=" .. tostring(resolvedActors),
        "human_resolved=" .. tostring(humanResolved),
        "pal_resolved=" .. tostring(palResolved),
        "configured_actors=" .. tostring(configuredActors),
        "floor_capsules_ok=" .. tostring(floorCapsulesOk),
        "uncapturable_applied=" .. tostring(uncapturableApplied),
        "invulnerability_applied=" .. tostring(invulnerabilityApplied),
        "movement_locks_applied=" .. tostring(movementLocksApplied),
        "ai_locks_applied=" .. tostring(aiLocksApplied),
        "motion_mode=normal_character_floor_no_pin_no_z_teleport",
        "destroyed_actors=" .. tostring(destroyedActors),
        "visual_status=" .. urlEncode(visualStatus),
        "call_inflight=" .. urlEncode(callInflight),
        "last_error=" .. urlEncode(lastError),
        "last_active_valid=" .. tostring(lastActive.valid),
        "last_active_resolved_actors=" .. tostring(lastActive.resolvedActors),
        "last_active_human_resolved=" .. tostring(lastActive.humanResolved),
        "last_active_pal_resolved=" .. tostring(lastActive.palResolved),
        "last_active_configured_actors=" .. tostring(lastActive.configuredActors),
        "last_active_floor_capsules_ok=" .. tostring(lastActive.floorCapsulesOk),
        "last_active_visual_status=" .. urlEncode(lastActive.status),
        "last_active_error=" .. urlEncode(lastActive.error)
    }
    writeAll(crowdStatusFile, table.concat(lines, "\n") .. "\n")
end

local function runGameThread(label, fn)
    ExecuteInGameThread(function()
        local ok, err = xpcall(fn, debug.traceback)
        if not ok then
            lastError = label .. ": " .. tostring(err)
            visualStatus = "game_thread_error"
            callInflight = "none"
            log(lastError)
        end
    end)
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

local function applyUncapturable(entry, actor)
    if entry.uncapturable then return true end
    if not ensurePalUtil() then return false end
    local param = nil
    pcall(function() param = palUtil:GetIndividualCharacterParameterByActor(actor) end)
    param = unwrap(param)
    if not valid(param) then return false end
    local ok = pcall(function() param:SetUncapturable(true) end)
    if ok then
        entry.uncapturable = true
        uncapturableApplied = uncapturableApplied + 1
        return true
    end
    return false
end

local function configureFloorOnlyCapsule(actor)
    local capsule = nil
    pcall(function() capsule = actor:GetCapsuleComponent() end)
    capsule = unwrap(capsule)
    if not valid(capsule) then return false end

    local ok = true
    if not pcall(function() capsule:SetCollisionEnabled(COLLISION_QUERY_AND_PHYSICS) end) then ok = false end
    if not pcall(function() capsule:SetCollisionResponseToAllChannels(RESPONSE_IGNORE) end) then ok = false end
    if not pcall(function() capsule:SetCollisionResponseToChannel(CHANNEL_WORLD_STATIC, RESPONSE_BLOCK) end) then ok = false end
    pcall(function() capsule:SetGenerateOverlapEvents(false) end)
    pcall(function() capsule:SetSimulatePhysics(false) end)
    pcall(function() capsule:SetEnableGravity(false) end) -- capsule itself does not drive CharacterMovement gravity
    return ok
end

local function disableHitGeometry(actor)
    if ensurePalUtil() then
        pcall(function() palUtil:SetBodyPartsCollisionEnable(actor, false) end)
        pcall(function() palUtil:SetBodyPartsCollisionProfile(actor, FName("NoCollision")) end)
    end

    local mesh = nil
    pcall(function() mesh = actor:GetMesh() end)
    mesh = unwrap(mesh)
    if valid(mesh) then
        pcall(function() mesh:SetCollisionEnabled(COLLISION_NONE) end)
        pcall(function() mesh:SetGenerateOverlapEvents(false) end)
        pcall(function() mesh:SetSimulatePhysics(false) end)
    end
end

local function configureDecorativeActor(entry)
    if not entry or not valid(entry.actor) then return false end
    local actor = unwrap(entry.actor)
    local invuln, floorOk, movementOk, aiOk = false, false, false, false

    pcall(function() actor:SetVisibleCharacterMesh(true) end)
    pcall(function() actor:SetReplicateMovement(true) end)

    if pcall(function() actor.bCanBeDamaged = false end) then invuln = true end
    if pcall(function() actor:SetCanBeDamaged(false) end) then invuln = true end

    -- IMPORTANT: actor collision stays enabled. Only the capsule blocks terrain.
    pcall(function() actor:SetActorEnableCollision(true) end)
    floorOk = configureFloorOnlyCapsule(actor)
    disableHitGeometry(actor)

    -- Keep CharacterMovement alive so Unreal continues normal floor detection and
    -- gravity handling. We only remove locomotion ability instead of disabling
    -- the movement component itself.
    local move = nil
    pcall(function() move = actor:GetCharacterMovement() end)
    move = unwrap(move)
    if valid(move) then
        pcall(function() move:StopMovementImmediately() end)
        pcall(function() move.MaxWalkSpeed = 0.0 end)
        pcall(function() move.MaxWalkSpeedCrouched = 0.0 end)
        pcall(function() move.MaxSwimSpeed = 0.0 end)
        pcall(function() move.MaxFlySpeed = 0.0 end)
        pcall(function() move.MaxAcceleration = 0.0 end)
        pcall(function() move.MinAnalogWalkSpeed = 0.0 end)
        pcall(function() move.bOrientRotationToMovement = false end)
        -- Explicitly leave GravityScale and component tick untouched.
        movementOk = true
    else
        movementOk = true
    end

    local controller = nil
    pcall(function() controller = actor:GetController() end)
    controller = unwrap(controller)
    if valid(controller) then
        pcall(function() controller:StopMovement() end)
        if pcall(function() controller:SetActorTickEnabled(false) end) then aiOk = true end
    else
        aiOk = true
    end

    applyUncapturable(entry, actor)
    pcall(function() actor:ForceNetUpdate() end)

    if invuln and not entry.invuln then
        entry.invuln = true
        invulnerabilityApplied = invulnerabilityApplied + 1
    end
    if floorOk and not entry.floorOk then
        entry.floorOk = true
        floorCapsulesOk = floorCapsulesOk + 1
    end
    if movementOk and not entry.movement then
        entry.movement = true
        movementLocksApplied = movementLocksApplied + 1
    end
    if aiOk and not entry.ai then
        entry.ai = true
        aiLocksApplied = aiLocksApplied + 1
    end

    if entry.invuln and entry.floorOk and entry.movement and entry.ai and entry.uncapturable and not entry.configured then
        entry.configured = true
        configuredActors = configuredActors + 1
    end

    return entry.configured == true
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
        if pcall(function() actor:K2_DestroyActor() end) then destroyedActors = destroyedActors + 1 end
    end
    entry.actor = nil
    entry.handle = nil
end

local function cleanup()
    generation = generation + 1
    local old = entries
    entries = {}
    runGameThread("crowd_cleanup", function()
        for _, entry in ipairs(old) do destroyEntry(entry) end
    end)
end

local function resetRaid(raidId)
    cleanup()
    currentRaidId = tostring(raidId or "")
    currentLevel = 1
    activeTicks = 0
    center = nil
    spawnIndex = 0
    spawnAttempts = 0
    spawnHandlesOk = 0
    spawnHandlesFailed = 0
    resolvedActors = 0
    humanResolved = 0
    palResolved = 0
    configuredActors = 0
    floorCapsulesOk = 0
    uncapturableApplied = 0
    invulnerabilityApplied = 0
    movementLocksApplied = 0
    aiLocksApplied = 0
    destroyedActors = 0
    visualStatus = "waiting_active_raid"
    callInflight = "none"
    lastError = ""
    lastActive = {
        valid = 0, resolvedActors = 0, humanResolved = 0, palResolved = 0,
        configuredActors = 0, floorCapsulesOk = 0, status = "", error = ""
    }
end

local function identityForIndex(index)
    local slot = math.floor(index / 2)
    if index % 2 == 0 then return "pal", PAL_ID end
    return "human", HUMAN_IDS[(slot % #HUMAN_IDS) + 1]
end

local function resolveEntry(entry, expectedGeneration, expectedRaidId, attempt)
    attempt = attempt or 1
    ExecuteWithDelay(attempt == 1 and RESOLVE_DELAY_MS or RESOLVE_RETRY_MS, function()
        runGameThread("crowd_resolve_" .. tostring(entry.index), function()
            if expectedGeneration ~= generation or currentRaidId ~= expectedRaidId then
                destroyEntry(entry)
                return
            end

            if valid(entry.actor) then
                configureDecorativeActor(entry)
                return
            end

            local actor = nil
            if valid(entry.handle) then pcall(function() actor = entry.handle:TryGetIndividualActor() end) end
            actor = unwrap(actor)
            if valid(actor) then
                entry.actor = actor
                resolvedActors = resolvedActors + 1
                if entry.kind == "human" then humanResolved = humanResolved + 1 else palResolved = palResolved + 1 end
                configureDecorativeActor(entry)
                visualStatus = "configuring_floor_only_crowd"
                snapshotActive()
                log(string.format("%s %d (%s) resolved: %d/%d", entry.kind, entry.index, entry.characterId, resolvedActors, BOUNDARY_COUNT))
            elseif attempt < RESOLVE_RETRIES then
                resolveEntry(entry, expectedGeneration, expectedRaidId, attempt + 1)
            else
                lastError = entry.kind .. " " .. tostring(entry.index) .. " (" .. entry.characterId .. ") not resolved after retries"
                visualStatus = "crowd_resolve_failed"
                log(lastError)
            end
        end)
    end)
end

local function spawnBoundaryCharacter(index, raid)
    if not center then return end
    local manager, controllerClass, err = npcManagerAndController()
    if not valid(manager) then
        lastError = err or "NPC spawn prerequisites unavailable"
        visualStatus = "npc_manager_unavailable"
        return
    end

    local kind, characterId = identityForIndex(index)
    local angle = (math.pi * 2.0 * index) / BOUNDARY_COUNT
    local spawnLocation = {
        X = center.X + math.cos(angle) * CROWD_RADIUS,
        Y = center.Y + math.sin(angle) * CROWD_RADIUS,
        Z = center.Z + SPAWN_Z_OFFSET
    }
    local baseYaw = math.deg(angle) + 180.0
    local spawnInfo = {
        ControllerClass = controllerClass,
        CharacterID = FName(characterId),
        Level = currentLevel,
        Location = spawnLocation,
        Yaw = baseYaw,
        Squad = nil
    }

    spawnAttempts = spawnAttempts + 1
    callInflight = "SpawnNPCForServer_" .. tostring(index) .. "_" .. kind
    visualStatus = "spawning_floor_only_crowd"
    snapshotActive(); writeStatus(raid)

    local ok, handle = pcall(function() return manager:SpawnNPCForServer(spawnInfo, nil) end)
    handle = unwrap(handle)
    callInflight = "none"

    if ok and valid(handle) then
        spawnHandlesOk = spawnHandlesOk + 1
        local entry = {
            index = index,
            kind = kind,
            characterId = characterId,
            handle = handle,
            actor = nil,
            invuln = false,
            floorOk = false,
            movement = false,
            ai = false,
            uncapturable = false,
            configured = false
        }
        entries[#entries + 1] = entry
        resolveEntry(entry, generation, currentRaidId, 1)
    else
        spawnHandlesFailed = spawnHandlesFailed + 1
        lastError = "SpawnNPCForServer " .. kind .. " " .. tostring(index) .. " (" .. characterId .. ") failed: " .. tostring(handle)
        visualStatus = "crowd_spawn_failed"
        log(lastError)
    end
end

local function enforceDecorativeState()
    for _, entry in ipairs(entries) do
        if valid(entry.actor) then configureDecorativeActor(entry) end
    end
end

local function tick()
    local raw = readAll(raidStatusFile)
    local raid = raw and parseKv(raw) or { state = "IDLE", active = "0", raid_id = "" }
    local raidId = tostring(raid.raid_id or "")

    if raidId ~= currentRaidId then resetRaid(raidId) end
    local active = raid.active == "1" and raid.state == "ACTIVE" and raidId ~= ""

    if not active then
        if #entries > 0 then snapshotActive(); cleanup() end
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
        currentLevel = math.max(1, math.floor(tonumber(raid.level) or 1))
        visualStatus = "armed"
        log(string.format("floor-only 32-crowd armed; gameplay=%d crowd=%d level=%d", GAMEPLAY_RADIUS, CROWD_RADIUS, currentLevel))
    end

    if activeTicks >= ARM_TICKS and spawnIndex < BOUNDARY_COUNT then
        local remaining = math.min(SPAWN_BATCH, BOUNDARY_COUNT - spawnIndex)
        for _ = 1, remaining do
            local idx = spawnIndex
            spawnIndex = spawnIndex + 1
            runGameThread("crowd_spawn_" .. tostring(idx), function() spawnBoundaryCharacter(idx, raid) end)
        end
    end

    if activeTicks % ENFORCE_EVERY_TICKS == 0 and #entries > 0 then
        runGameThread("crowd_floor_only_enforce", enforceDecorativeState)
    end

    if configuredActors >= BOUNDARY_COUNT then
        visualStatus = "compact_crowd_ready_floor_only_collision"
    elseif resolvedActors >= BOUNDARY_COUNT then
        visualStatus = "configuring_crowd"
    elseif spawnIndex >= BOUNDARY_COUNT then
        visualStatus = "waiting_crowd_resolution"
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
            callInflight = "none"
            log("tick failed: " .. lastError)
        end
        ExecuteWithDelay(TICK_MS, loop)
    end
    ExecuteWithDelay(TICK_MS, loop)
end

schedule()
log(string.format("v%s loaded; floor-only 32-character crowd (gameplay %.0f / crowd %.0f)", VERSION, GAMEPLAY_RADIUS, CROWD_RADIUS))