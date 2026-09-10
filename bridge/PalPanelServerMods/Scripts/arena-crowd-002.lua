-- PalPanelServerMods arena crowd boundary v1.1.0
-- SERVER-ONLY / NO CLIENT MOD.
--
-- Safe 32-character crowd arena:
--   * 16 generic human villagers + 16 proven GrassMammoth Pals
--   * alternating around a visual ring OUTSIDE the authoritative 6000-unit lock
--   * no direct NetMulticast calls, no cosmetic montage RPCs, no effect actors
--   * same proven UPalNPCManager::SpawnNPCForServer path as the raid boss/marker test
--   * continuously forced invulnerable, no collision, no movement AI
--   * Pals additionally use UPalIndividualCharacterParameter::SetUncapturable(true)
--   * crowd motion is a safe replicated sway/bounce using K2_TeleportTo, the same
--     primitive already used by arena-027.lua for the authoritative boundary.
--
-- The visual crowd radius is intentionally 6750 while gameplay lock remains 6000,
-- keeping scenery outside normal interaction distance.

local MOD = "PalPanelRaidArenaCrowd"
local VERSION = "1.1.0"

local TICK_MS = 250
local ARM_TICKS = 8
local GAMEPLAY_RADIUS = 6000.0
local CROWD_RADIUS = 6750.0
local BOUNDARY_COUNT = 32
local SPAWN_BATCH = 1
local RESOLVE_DELAY_MS = 350
local RESOLVE_RETRY_MS = 300
local RESOLVE_RETRIES = 12
local ENFORCE_EVERY_TICKS = 4
local DANCE_EVERY_TICKS = 4 -- ~1 second
local DANCE_BOB = 28.0
local DANCE_SWAY_DEGREES = 14.0
local CHARACTER_Z_OFFSET = 80.0
local FREEZE_FLAG = "PalPanelArenaCrowdBoundarySafe"
local NO_COLLISION = 0

-- Keep human spawning conservative: two generic vanilla villager IDs only.
local HUMAN_IDS = { "MobuCitizen", "MobuCitizen_Male" }
-- GrassMammoth is the exact Pal species already proven visible/stable in the
-- successful server-only marker-ring test.
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
if not scriptsDir then
    log("Scripts directory unavailable; crowd disabled")
    return
end
local modDir = scriptsDir:match("^(.+)\\Scripts$") or scriptsDir
local ipcDir = readAll(modDir .. "\\ipc_path.txt")
if ipcDir then ipcDir = ipcDir:gsub("[\r\n]+$", "") end
if not ipcDir or ipcDir == "" then
    log("ipc_path.txt unavailable; crowd disabled")
    return
end

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
local neutralizedActors = 0
local uncapturableApplied = 0
local invulnerabilityApplied = 0
local collisionGuardsApplied = 0
local movementGuardsApplied = 0
local aiGuardsApplied = 0
local dancePasses = 0
local danceMovesOk = 0
local danceMovesFailed = 0
local destroyedActors = 0
local visualStatus = "idle"
local callInflight = "none"
local lastError = ""
local entries = {}
local scheduled = false
local generation = 0

local lastActive = {
    valid = 0,
    resolvedActors = 0,
    humanResolved = 0,
    palResolved = 0,
    neutralizedActors = 0,
    uncapturableApplied = 0,
    danceMovesOk = 0,
    danceMovesFailed = 0,
    status = "",
    error = ""
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
    lastActive.neutralizedActors = neutralizedActors
    lastActive.uncapturableApplied = uncapturableApplied
    lastActive.danceMovesOk = danceMovesOk
    lastActive.danceMovesFailed = danceMovesFailed
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
        "backend=safe_npc_manager_32_character_crowd",
        "client_install_required=0",
        "boundary_count_requested=" .. tostring(BOUNDARY_COUNT),
        "humans_requested=16",
        "pals_requested=16",
        "human_ids=" .. urlEncode(table.concat(HUMAN_IDS, ",")),
        "pal_id=" .. PAL_ID,
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
        "neutralized_actors=" .. tostring(neutralizedActors),
        "uncapturable_applied=" .. tostring(uncapturableApplied),
        "invulnerability_applied=" .. tostring(invulnerabilityApplied),
        "collision_guards_applied=" .. tostring(collisionGuardsApplied),
        "movement_guards_applied=" .. tostring(movementGuardsApplied),
        "ai_guards_applied=" .. tostring(aiGuardsApplied),
        "dance_mode=replicated_teleport_sway_no_rpc",
        "dance_passes=" .. tostring(dancePasses),
        "dance_moves_ok=" .. tostring(danceMovesOk),
        "dance_moves_failed=" .. tostring(danceMovesFailed),
        "destroyed_actors=" .. tostring(destroyedActors),
        "visual_status=" .. urlEncode(visualStatus),
        "call_inflight=" .. urlEncode(callInflight),
        "last_error=" .. urlEncode(lastError),
        "last_active_valid=" .. tostring(lastActive.valid),
        "last_active_resolved_actors=" .. tostring(lastActive.resolvedActors),
        "last_active_human_resolved=" .. tostring(lastActive.humanResolved),
        "last_active_pal_resolved=" .. tostring(lastActive.palResolved),
        "last_active_neutralized_actors=" .. tostring(lastActive.neutralizedActors),
        "last_active_uncapturable_applied=" .. tostring(lastActive.uncapturableApplied),
        "last_active_dance_moves_ok=" .. tostring(lastActive.danceMovesOk),
        "last_active_dance_moves_failed=" .. tostring(lastActive.danceMovesFailed),
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

local function disablePrimitiveCollision(component)
    component = unwrap(component)
    if not valid(component) then return false end
    local any = false
    if pcall(function() component:SetCollisionEnabled(NO_COLLISION) end) then any = true end
    pcall(function() component:SetGenerateOverlapEvents(false) end)
    return any
end

local function applyUncapturable(entry, actor)
    if entry.kind ~= "pal" or entry.uncapturable then return true end
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

local function neutralizeEntry(entry)
    if not entry or not valid(entry.actor) then return false end
    local actor = unwrap(entry.actor)
    local invuln = false
    local collision = false
    local movement = false
    local ai = false

    -- Preserve visible character meshes; only gameplay interaction is removed.
    pcall(function() actor:SetVisibleCharacterMesh(true) end)

    if pcall(function() actor.bCanBeDamaged = false end) then invuln = true end
    if pcall(function() actor:SetCanBeDamaged(false) end) then invuln = true end

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
    else
        movement = true
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

    applyUncapturable(entry, actor)
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

    local captureSafe = entry.kind == "human" or entry.uncapturable == true
    if entry.invuln and entry.collision and entry.movement and entry.ai and captureSafe and not entry.neutralized then
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
    neutralizedActors = 0
    uncapturableApplied = 0
    invulnerabilityApplied = 0
    collisionGuardsApplied = 0
    movementGuardsApplied = 0
    aiGuardsApplied = 0
    dancePasses = 0
    danceMovesOk = 0
    danceMovesFailed = 0
    destroyedActors = 0
    visualStatus = "waiting_active_raid"
    callInflight = "none"
    lastError = ""
    lastActive = {
        valid = 0, resolvedActors = 0, humanResolved = 0, palResolved = 0,
        neutralizedActors = 0, uncapturableApplied = 0,
        danceMovesOk = 0, danceMovesFailed = 0,
        status = "", error = ""
    }
end

local function identityForIndex(index)
    local slot = math.floor(index / 2)
    if index % 2 == 0 then
        return "pal", PAL_ID
    end
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
                neutralizeEntry(entry)
                return
            end

            local actor = nil
            if valid(entry.handle) then pcall(function() actor = entry.handle:TryGetIndividualActor() end) end
            actor = unwrap(actor)
            if valid(actor) then
                entry.actor = actor
                resolvedActors = resolvedActors + 1
                if entry.kind == "human" then humanResolved = humanResolved + 1 else palResolved = palResolved + 1 end
                neutralizeEntry(entry)
                visualStatus = resolvedActors >= BOUNDARY_COUNT and "crowd_boundary_ready" or "resolving_crowd"
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
    local baseLocation = {
        X = center.X + math.cos(angle) * CROWD_RADIUS,
        Y = center.Y + math.sin(angle) * CROWD_RADIUS,
        Z = center.Z + CHARACTER_Z_OFFSET
    }
    local baseYaw = math.deg(angle) + 180.0

    local spawnInfo = {
        ControllerClass = controllerClass,
        CharacterID = FName(characterId),
        Level = currentLevel,
        Location = baseLocation,
        Yaw = baseYaw,
        Squad = nil
    }

    spawnAttempts = spawnAttempts + 1
    callInflight = "SpawnNPCForServer_" .. tostring(index) .. "_" .. kind
    visualStatus = "spawning_crowd"
    snapshotActive(); writeStatus(raid)

    local ok, handle = pcall(function()
        return manager:SpawnNPCForServer(spawnInfo, nil)
    end)
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
            baseLocation = baseLocation,
            baseYaw = baseYaw,
            phase = index % 4,
            invuln = false,
            collision = false,
            movement = false,
            ai = false,
            uncapturable = kind == "human",
            neutralized = false
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

local function enforceCrowdState()
    for _, entry in ipairs(entries) do
        if valid(entry.actor) then neutralizeEntry(entry) end
    end
end

local function danceCrowd()
    dancePasses = dancePasses + 1
    local step = dancePasses % 4
    for _, entry in ipairs(entries) do
        local actor = unwrap(entry.actor)
        if valid(actor) and entry.baseLocation then
            local localPhase = (step + (entry.phase or 0)) % 4
            local bob = 0.0
            local sway = 0.0
            if localPhase == 0 then
                bob = DANCE_BOB
                sway = DANCE_SWAY_DEGREES
            elseif localPhase == 1 then
                bob = 0.0
                sway = 0.0
            elseif localPhase == 2 then
                bob = DANCE_BOB
                sway = -DANCE_SWAY_DEGREES
            else
                bob = 0.0
                sway = 0.0
            end

            local location = {
                X = entry.baseLocation.X,
                Y = entry.baseLocation.Y,
                Z = entry.baseLocation.Z + bob
            }
            local rotation = { Pitch = 0, Yaw = entry.baseYaw + sway, Roll = 0 }
            local ok, result = pcall(function()
                return actor:K2_TeleportTo(location, rotation)
            end)
            if ok and result ~= false then
                danceMovesOk = danceMovesOk + 1
                pcall(function() actor:ForceNetUpdate() end)
            else
                danceMovesFailed = danceMovesFailed + 1
            end
        end
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
        currentLevel = math.max(1, math.floor(tonumber(raid.level) or 1))
        visualStatus = "armed"
        log(string.format("safe 32-crowd armed at %.1f %.1f %.1f, level=%d", center.X, center.Y, center.Z, currentLevel))
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
        runGameThread("crowd_neutralize_pass", enforceCrowdState)
    end

    -- Start visible motion only after at least four actors have resolved, and use
    -- only K2_TeleportTo. No animation RPC or action multicast is called here.
    if activeTicks % DANCE_EVERY_TICKS == 0 and resolvedActors >= 4 then
        runGameThread("crowd_safe_dance_pass", danceCrowd)
    end

    if resolvedActors >= BOUNDARY_COUNT and neutralizedActors >= BOUNDARY_COUNT then
        visualStatus = "crowd_boundary_ready_safe_dance"
    elseif resolvedActors >= BOUNDARY_COUNT then
        visualStatus = "crowd_boundary_neutralizing"
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
log(string.format("v%s loaded; SAFE 32-character crowd boundary ready (16 generic humans + 16 proven Pals, radius %.0f)", VERSION, CROWD_RADIUS))