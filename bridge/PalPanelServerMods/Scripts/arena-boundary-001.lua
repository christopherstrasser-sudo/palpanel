-- PalPanelServerMods visual arena boundary v1.0.0
-- SERVER-ONLY / NO CLIENT MOD.
--
-- Architecture:
--   * arena-027.lua remains the authoritative 6000-unit gameplay boundary.
--   * Proven UPalNPCManager::SpawnNPCForServer creates replicated vanilla carriers.
--   * Carriers are permanently neutralized (no damage/collision/movement/AI).
--   * Palworld's own UPalVisualEffectComponent is used for client visuals:
--       FadeOut (4)       -> hides the carrier character visually on clients
--       FireCondition (15)-> leaves a visible vanilla fire boundary effect
--   * No free visual actors, PalNetworkTransmitter, BuildObjects or SkillEffects.
--
-- The visible result is intended to be a ring of vanilla fire VFX with no
-- interactable Pal boundary actors.

local MOD = "PalPanelRaidArenaBoundary"
local VERSION = "1.0.0"

local TICK_MS = 250
local ARM_TICKS = 8
local RADIUS = 6000.0
local CARRIER_COUNT = 20
local SPAWN_BATCH = 2
local RESOLVE_DELAY_MS = 300
local RESOLVE_RETRY_MS = 250
local RESOLVE_RETRIES = 12
local ENFORCE_EVERY_TICKS = 4
local VFX_REFRESH_EVERY_TICKS = 20
local FIRE_AFTER_FADE_DELAY_MS = 700

local CARRIER_CHARACTER_ID = "GrassMammoth"
local CARRIER_SCALE = 1.8
local CARRIER_Z_OFFSET = 80.0
local FREEZE_FLAG = "PalPanelArenaBoundaryCarrier"
local NO_COLLISION = 0

-- EPalVisualEffectID values from vanilla Palworld SDK.
local VFX_FADE_OUT = 4
local VFX_FIRE_CONDITION = 15

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
    log("Scripts directory unavailable; boundary disabled")
    return
end
local modDir = scriptsDir:match("^(.+)\\Scripts$") or scriptsDir
local ipcDir = readAll(modDir .. "\\ipc_path.txt")
if ipcDir then ipcDir = ipcDir:gsub("[\r\n]+$", "") end
if not ipcDir or ipcDir == "" then
    log("ipc_path.txt unavailable; boundary disabled")
    return
end

local raidStatusFile = ipcDir .. "\\raid-status.txt"
local boundaryStatusFile = ipcDir .. "\\raid-arena-boundary-status.txt"

local currentRaidId = ""
local currentCarrierLevel = 1
local activeTicks = 0
local center = nil
local spawnIndex = 0
local spawnAttempts = 0
local spawnHandlesOk = 0
local spawnHandlesFailed = 0
local resolvedActors = 0
local neutralizedActors = 0
local fadeCallsOk = 0
local fadeCallsFailed = 0
local fireCallsOk = 0
local fireCallsFailed = 0
local fireReapplyOk = 0
local fireReapplyFailed = 0
local fireRefreshOk = 0
local fireRefreshFailed = 0
local replicatedNeutralFlags = 0
local invulnerabilityApplied = 0
local collisionGuardsApplied = 0
local movementGuardsApplied = 0
local aiGuardsApplied = 0
local enforcePasses = 0
local destroyedActors = 0
local visualStatus = "idle"
local callInflight = "none"
local lastError = ""
local entries = {}
local scheduled = false
local generation = 0

local lastActive = {
    valid = 0,
    carrierLevel = 1,
    spawnAttempts = 0,
    spawnHandlesOk = 0,
    spawnHandlesFailed = 0,
    resolvedActors = 0,
    neutralizedActors = 0,
    fadeCallsOk = 0,
    fireCallsOk = 0,
    fireReapplyOk = 0,
    fireRefreshOk = 0,
    replicatedNeutralFlags = 0,
    enforcePasses = 0,
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
    lastActive.carrierLevel = currentCarrierLevel
    lastActive.spawnAttempts = spawnAttempts
    lastActive.spawnHandlesOk = spawnHandlesOk
    lastActive.spawnHandlesFailed = spawnHandlesFailed
    lastActive.resolvedActors = resolvedActors
    lastActive.neutralizedActors = neutralizedActors
    lastActive.fadeCallsOk = fadeCallsOk
    lastActive.fireCallsOk = fireCallsOk
    lastActive.fireReapplyOk = fireReapplyOk
    lastActive.fireRefreshOk = fireRefreshOk
    lastActive.replicatedNeutralFlags = replicatedNeutralFlags
    lastActive.enforcePasses = enforcePasses
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
        "backend=replicated_hidden_carriers_pal_visual_effect",
        "client_install_required=0",
        "carrier_character_id=" .. CARRIER_CHARACTER_ID,
        "carrier_count_requested=" .. tostring(CARRIER_COUNT),
        "carrier_level=" .. tostring(currentCarrierLevel),
        "carrier_level_source=raid_level",
        "carrier_scale=" .. tostring(CARRIER_SCALE),
        "radius=" .. tostring(math.floor(RADIUS)),
        "vfx_fade_out_id=" .. tostring(VFX_FADE_OUT),
        "vfx_fire_condition_id=" .. tostring(VFX_FIRE_CONDITION),
        "center_x=" .. tostring(c.X or 0),
        "center_y=" .. tostring(c.Y or 0),
        "center_z=" .. tostring(c.Z or 0),
        "active_ticks=" .. tostring(activeTicks),
        "spawn_index=" .. tostring(spawnIndex),
        "spawn_attempts=" .. tostring(spawnAttempts),
        "spawn_handles_ok=" .. tostring(spawnHandlesOk),
        "spawn_handles_failed=" .. tostring(spawnHandlesFailed),
        "resolved_actors=" .. tostring(resolvedActors),
        "neutralized_actors=" .. tostring(neutralizedActors),
        "fade_calls_ok=" .. tostring(fadeCallsOk),
        "fade_calls_failed=" .. tostring(fadeCallsFailed),
        "fire_calls_ok=" .. tostring(fireCallsOk),
        "fire_calls_failed=" .. tostring(fireCallsFailed),
        "fire_reapply_ok=" .. tostring(fireReapplyOk),
        "fire_reapply_failed=" .. tostring(fireReapplyFailed),
        "fire_refresh_ok=" .. tostring(fireRefreshOk),
        "fire_refresh_failed=" .. tostring(fireRefreshFailed),
        "replicated_neutral_flags=" .. tostring(replicatedNeutralFlags),
        "invulnerability_applied=" .. tostring(invulnerabilityApplied),
        "collision_guards_applied=" .. tostring(collisionGuardsApplied),
        "movement_guards_applied=" .. tostring(movementGuardsApplied),
        "ai_guards_applied=" .. tostring(aiGuardsApplied),
        "enforce_passes=" .. tostring(enforcePasses),
        "destroyed_actors=" .. tostring(destroyedActors),
        "visual_status=" .. urlEncode(visualStatus),
        "call_inflight=" .. urlEncode(callInflight),
        "last_error=" .. urlEncode(lastError),
        "last_active_valid=" .. tostring(lastActive.valid),
        "last_active_carrier_level=" .. tostring(lastActive.carrierLevel),
        "last_active_spawn_attempts=" .. tostring(lastActive.spawnAttempts),
        "last_active_spawn_handles_ok=" .. tostring(lastActive.spawnHandlesOk),
        "last_active_spawn_handles_failed=" .. tostring(lastActive.spawnHandlesFailed),
        "last_active_resolved_actors=" .. tostring(lastActive.resolvedActors),
        "last_active_neutralized_actors=" .. tostring(lastActive.neutralizedActors),
        "last_active_fade_calls_ok=" .. tostring(lastActive.fadeCallsOk),
        "last_active_fire_calls_ok=" .. tostring(lastActive.fireCallsOk),
        "last_active_fire_reapply_ok=" .. tostring(lastActive.fireReapplyOk),
        "last_active_fire_refresh_ok=" .. tostring(lastActive.fireRefreshOk),
        "last_active_replicated_neutral_flags=" .. tostring(lastActive.replicatedNeutralFlags),
        "last_active_enforce_passes=" .. tostring(lastActive.enforcePasses),
        "last_active_visual_status=" .. urlEncode(lastActive.status),
        "last_active_error=" .. urlEncode(lastActive.error)
    }
    writeAll(boundaryStatusFile, table.concat(lines, "\n") .. "\n")
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

local function neutralizeCarrier(entry)
    if not entry then return false end
    local actor = unwrap(entry.actor)
    if not valid(actor) then return false end

    local invuln = false
    local collision = false
    local movement = false
    local ai = false
    local neutralReplicated = false

    pcall(function() actor:SetActorScale3D({ X = CARRIER_SCALE, Y = CARRIER_SCALE, Z = CARRIER_SCALE }) end)

    -- bIsNeutralGroup is explicitly replicated by APalCharacter.
    if pcall(function() actor.bIsNeutralGroup = true end) then neutralReplicated = true end
    -- RootCollisionProfileName is also replicated with an OnRep handler.
    if pcall(function() actor.RootCollisionProfileName = FName("NoCollision") end) then neutralReplicated = true end

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

    -- Server-side local hide is a backup; client hide is driven by FadeOut VFX.
    pcall(function() actor:SetVisibleCharacterMesh(false) end)
    pcall(function() actor:ForceNetUpdate() end)

    if neutralReplicated and not entry.neutralReplicated then
        entry.neutralReplicated = true
        replicatedNeutralFlags = replicatedNeutralFlags + 1
    end
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

local function addVfx(entry, effectId, fieldOk, fieldFailed, raid)
    if not entry or not valid(entry.actor) then return false end
    local visual = member(entry.actor, "VisualEffectComponent")
    if not valid(visual) then
        lastError = "VisualEffectComponent unavailable for carrier " .. tostring(entry.index)
        return false
    end

    callInflight = "AddVisualEffect_" .. tostring(effectId) .. "_carrier_" .. tostring(entry.index)
    snapshotActive()
    if raid then writeStatus(raid) end

    local ok, result = pcall(function()
        return visual:AddVisualEffect(effectId, { FloatValues = {} })
    end)
    callInflight = "none"

    if ok then
        if fieldOk == "fade" then fadeCallsOk = fadeCallsOk + 1
        elseif fieldOk == "fire" then fireCallsOk = fireCallsOk + 1
        elseif fieldOk == "fire_reapply" then fireReapplyOk = fireReapplyOk + 1 end
        return true
    end

    if fieldFailed == "fade" then fadeCallsFailed = fadeCallsFailed + 1
    elseif fieldFailed == "fire" then fireCallsFailed = fireCallsFailed + 1
    elseif fieldFailed == "fire_reapply" then fireReapplyFailed = fireReapplyFailed + 1 end
    lastError = "AddVisualEffect " .. tostring(effectId) .. " failed on carrier " .. tostring(entry.index) .. ": " .. tostring(result)
    log(lastError)
    return false
end

local function applyBoundaryVisuals(entry, expectedGeneration, expectedRaidId, raid)
    if not entry or not valid(entry.actor) then return end
    if entry.visualsApplied then return end

    local fadeOk = addVfx(entry, VFX_FADE_OUT, "fade", "fade", raid)
    local fireOk = addVfx(entry, VFX_FIRE_CONDITION, "fire", "fire", raid)
    entry.fadeApplied = fadeOk
    entry.fireApplied = fireOk
    entry.visualsApplied = fadeOk or fireOk

    -- Re-add the fire effect after FadeOut has had time to finish. This keeps
    -- the carrier hidden even if those two vanilla visual effects conflict.
    ExecuteWithDelay(FIRE_AFTER_FADE_DELAY_MS, function()
        runGameThread("boundary_fire_reapply_" .. tostring(entry.index), function()
            if expectedGeneration ~= generation or currentRaidId ~= expectedRaidId then return end
            if not valid(entry.actor) then return end
            local ok = addVfx(entry, VFX_FIRE_CONDITION, "fire_reapply", "fire_reapply", nil)
            if ok then entry.fireApplied = true end
            if resolvedActors >= CARRIER_COUNT and neutralizedActors >= CARRIER_COUNT then
                visualStatus = "fire_boundary_ready"
            end
            snapshotActive()
        end)
    end)
end

local function refreshFireVisuals()
    for _, entry in ipairs(entries) do
        if valid(entry.actor) then
            local visual = member(entry.actor, "VisualEffectComponent")
            if valid(visual) then
                local ok = pcall(function() visual:RefreshVisualEffectIfExist(VFX_FIRE_CONDITION) end)
                if ok then fireRefreshOk = fireRefreshOk + 1 else fireRefreshFailed = fireRefreshFailed + 1 end
            end
        end
    end
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
    runGameThread("boundary_cleanup", function()
        for _, entry in ipairs(old) do destroyEntry(entry) end
    end)
end

local function resetLastActive()
    lastActive = {
        valid = 0, carrierLevel = 1, spawnAttempts = 0, spawnHandlesOk = 0,
        spawnHandlesFailed = 0, resolvedActors = 0, neutralizedActors = 0,
        fadeCallsOk = 0, fireCallsOk = 0, fireReapplyOk = 0, fireRefreshOk = 0,
        replicatedNeutralFlags = 0, enforcePasses = 0, status = "", error = ""
    }
end

local function resetRaid(raidId)
    cleanup()
    currentRaidId = tostring(raidId or "")
    currentCarrierLevel = 1
    activeTicks = 0
    center = nil
    spawnIndex = 0
    spawnAttempts = 0
    spawnHandlesOk = 0
    spawnHandlesFailed = 0
    resolvedActors = 0
    neutralizedActors = 0
    fadeCallsOk = 0
    fadeCallsFailed = 0
    fireCallsOk = 0
    fireCallsFailed = 0
    fireReapplyOk = 0
    fireReapplyFailed = 0
    fireRefreshOk = 0
    fireRefreshFailed = 0
    replicatedNeutralFlags = 0
    invulnerabilityApplied = 0
    collisionGuardsApplied = 0
    movementGuardsApplied = 0
    aiGuardsApplied = 0
    enforcePasses = 0
    destroyedActors = 0
    visualStatus = "waiting_active_raid"
    callInflight = "none"
    lastError = ""
    resetLastActive()
end

local function resolveEntry(entry, expectedGeneration, expectedRaidId, raid, attempt)
    attempt = attempt or 1
    ExecuteWithDelay(attempt == 1 and RESOLVE_DELAY_MS or RESOLVE_RETRY_MS, function()
        runGameThread("boundary_resolve_" .. tostring(entry.index), function()
            if expectedGeneration ~= generation or currentRaidId ~= expectedRaidId then
                destroyEntry(entry)
                return
            end
            if valid(entry.actor) then
                neutralizeCarrier(entry)
                applyBoundaryVisuals(entry, expectedGeneration, expectedRaidId, raid)
                return
            end

            local actor = nil
            if valid(entry.handle) then pcall(function() actor = entry.handle:TryGetIndividualActor() end) end
            actor = unwrap(actor)
            if valid(actor) then
                entry.actor = actor
                resolvedActors = resolvedActors + 1
                neutralizeCarrier(entry)
                applyBoundaryVisuals(entry, expectedGeneration, expectedRaidId, raid)
                visualStatus = resolvedActors >= CARRIER_COUNT and "boundary_visualizing" or "resolving_carriers"
                snapshotActive()
                log(string.format("carrier %d resolved (%d/%d)", entry.index, resolvedActors, CARRIER_COUNT))
            elseif attempt < RESOLVE_RETRIES then
                resolveEntry(entry, expectedGeneration, expectedRaidId, raid, attempt + 1)
            else
                lastError = "carrier " .. tostring(entry.index) .. " actor not resolved after retries"
                visualStatus = "carrier_resolve_failed"
            end
        end)
    end)
end

local function spawnCarrier(index, raid)
    if not center then return end
    local manager, controllerClass, err = npcManagerAndController()
    if not valid(manager) then
        lastError = err or "NPC spawn prerequisites unavailable"
        visualStatus = "npc_manager_unavailable"
        return
    end

    local angle = (math.pi * 2.0 * index) / CARRIER_COUNT
    local location = {
        X = center.X + math.cos(angle) * RADIUS,
        Y = center.Y + math.sin(angle) * RADIUS,
        Z = center.Z + CARRIER_Z_OFFSET
    }
    local spawnInfo = {
        ControllerClass = controllerClass,
        CharacterID = FName(CARRIER_CHARACTER_ID),
        Level = currentCarrierLevel,
        Location = location,
        Yaw = math.deg(angle) + 180.0,
        Squad = nil
    }

    spawnAttempts = spawnAttempts + 1
    callInflight = "SpawnNPCForServer_" .. tostring(index)
    visualStatus = "spawning_boundary_carriers"
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
            handle = handle,
            actor = nil,
            neutralReplicated = false,
            invuln = false,
            collision = false,
            movement = false,
            ai = false,
            neutralized = false,
            fadeApplied = false,
            fireApplied = false,
            visualsApplied = false
        }
        entries[#entries + 1] = entry
        resolveEntry(entry, generation, currentRaidId, raid, 1)
    else
        spawnHandlesFailed = spawnHandlesFailed + 1
        lastError = "SpawnNPCForServer carrier " .. tostring(index) .. " failed: " .. tostring(handle)
        visualStatus = "carrier_spawn_failed"
        log(lastError)
    end
end

local function enforceCarrierState()
    enforcePasses = enforcePasses + 1
    for _, entry in ipairs(entries) do
        if valid(entry.actor) then neutralizeCarrier(entry) end
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
        currentCarrierLevel = math.max(1, math.floor(tonumber(raid.level) or 1))
        visualStatus = "armed"
        log(string.format("fire boundary armed at %.1f %.1f %.1f, carriers=%d", center.X, center.Y, center.Z, CARRIER_COUNT))
    end

    if activeTicks >= ARM_TICKS and spawnIndex < CARRIER_COUNT then
        local remaining = math.min(SPAWN_BATCH, CARRIER_COUNT - spawnIndex)
        for _ = 1, remaining do
            local idx = spawnIndex
            spawnIndex = spawnIndex + 1
            runGameThread("boundary_spawn_" .. tostring(idx), function() spawnCarrier(idx, raid) end)
        end
    end

    if activeTicks % ENFORCE_EVERY_TICKS == 0 and #entries > 0 then
        runGameThread("boundary_enforce_pass", enforceCarrierState)
    end

    if activeTicks % VFX_REFRESH_EVERY_TICKS == 0 and #entries > 0 then
        runGameThread("boundary_fire_refresh", refreshFireVisuals)
    end

    if resolvedActors >= CARRIER_COUNT and neutralizedActors >= CARRIER_COUNT and fireReapplyOk >= CARRIER_COUNT then
        visualStatus = "fire_boundary_ready"
    elseif resolvedActors >= CARRIER_COUNT and neutralizedActors >= CARRIER_COUNT then
        visualStatus = "boundary_visualizing"
    elseif spawnIndex >= CARRIER_COUNT then
        visualStatus = "waiting_carrier_resolution"
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
log(string.format("v%s loaded; server-only hidden-carrier fire boundary ready (%d carriers, radius %.0f)", VERSION, CARRIER_COUNT, RADIUS))