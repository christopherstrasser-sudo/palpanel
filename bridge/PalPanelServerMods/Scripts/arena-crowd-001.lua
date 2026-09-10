-- PalPanelServerMods arena crowd boundary v1.0.0
-- SERVER-ONLY / NO CLIENT MOD.
--
-- 32-character arena crowd: 16 human NPCs + 16 Pals, alternating around
-- the authoritative 6000-unit arena ring. Characters are scenery only:
-- invulnerable, uncapturable where applicable, no collision, no movement,
-- no combat AI, and no interaction collision. They face the arena center.
--
-- Animation uses each spawned character's own vanilla EmoteList and
-- APalCharacter::PlayCosmeticMontage_ToAll. If no usable emote montage is
-- available, the character remains as static crowd scenery rather than
-- falling back to risky gameplay/effect actors.

local MOD = "PalPanelRaidArenaCrowd"
local VERSION = "1.0.0"

local TICK_MS = 250
local ARM_TICKS = 8
local RADIUS = 6000.0
local BOUNDARY_COUNT = 32
local SPAWN_BATCH = 2
local RESOLVE_DELAY_MS = 300
local RESOLVE_RETRY_MS = 250
local RESOLVE_RETRIES = 12
local ENFORCE_EVERY_TICKS = 4
local EMOTE_REFRESH_EVERY_TICKS = 48 -- ~12 seconds
local CHARACTER_Z_OFFSET = 80.0
local FREEZE_FLAG = "PalPanelArenaCrowdBoundary"
local NO_COLLISION = 0

-- Current Palworld human IDs deliberately chosen from generic/non-special NPCs.
local HUMAN_IDS = {
    "Male_Kigurumi01_v01",
    "Female_Presenter01",
    "Female_Nomad01_v01",
    "Female_Nomad01_v02",
    "Female_Farmer01_v01",
    "Female_Farmer01_v02",
    "Female_Ranger01_v01",
    "Female_Ranger01_v02",
    "Male_Scholar01_v01",
    "Male_Scholar01_v02",
    "Male_Breeder01_v01",
    "Male_Breeder01_v02",
    "Female_SurveyGirl01",
    "Female_SurveyGirl02",
    "Male_SurveyMan01",
    "Male_StrongOldMan01"
}

local PAL_IDS = {
    "SheepBall",
    "PinkCat",
    "ChickenPal",
    "Carbunclo",
    "Penguin",
    "Kitsunebi",
    "Alpaca",
    "GrassMammoth",
    "Gorilla",
    "Deer",
    "RaijinDaughter",
    "SweetsSheep",
    "BluePlatypus",
    "Windchimes",
    "NegativeKoala",
    "Werewolf"
}

-- Palworld's player-facing Dance is normally among the later base emotes.
-- Try likely dance slots first, then other safe cosmetic emotes. We only play
-- the montage itself, never an attack/action object, so even a fallback emote
-- remains cosmetic.
local EMOTE_ZERO_INDEX_CANDIDATES = { 5, 4, 6, 2, 1, 0, 3, 7 }

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
    log("Scripts directory unavailable; crowd boundary disabled")
    return
end
local modDir = scriptsDir:match("^(.+)\\Scripts$") or scriptsDir
local ipcDir = readAll(modDir .. "\\ipc_path.txt")
if ipcDir then ipcDir = ipcDir:gsub("[\r\n]+$", "") end
if not ipcDir or ipcDir == "" then
    log("ipc_path.txt unavailable; crowd boundary disabled")
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
local neutralGroupApplied = 0
local emoteAttempts = 0
local emoteStarted = 0
local emoteUnavailable = 0
local emoteRefreshPasses = 0
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
    emoteStarted = 0,
    emoteUnavailable = 0,
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
    lastActive.emoteStarted = emoteStarted
    lastActive.emoteUnavailable = emoteUnavailable
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
        "backend=npc_manager_32_character_crowd_boundary",
        "client_install_required=0",
        "boundary_count_requested=" .. tostring(BOUNDARY_COUNT),
        "humans_requested=16",
        "pals_requested=16",
        "raid_level=" .. tostring(currentLevel),
        "radius=" .. tostring(math.floor(RADIUS)),
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
        "neutral_group_applied=" .. tostring(neutralGroupApplied),
        "emote_attempts=" .. tostring(emoteAttempts),
        "emote_started=" .. tostring(emoteStarted),
        "emote_unavailable=" .. tostring(emoteUnavailable),
        "emote_refresh_passes=" .. tostring(emoteRefreshPasses),
        "destroyed_actors=" .. tostring(destroyedActors),
        "visual_status=" .. urlEncode(visualStatus),
        "call_inflight=" .. urlEncode(callInflight),
        "last_error=" .. urlEncode(lastError),
        "last_active_valid=" .. tostring(lastActive.valid),
        "last_active_resolved_actors=" .. tostring(lastActive.resolvedActors),
        "last_active_human_resolved=" .. tostring(lastActive.humanResolved),
        "last_active_pal_resolved=" .. tostring(lastActive.palResolved),
        "last_active_neutralized_actors=" .. tostring(lastActive.neutralizedActors),
        "last_active_emote_started=" .. tostring(lastActive.emoteStarted),
        "last_active_emote_unavailable=" .. tostring(lastActive.emoteUnavailable),
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
    pcall(function() component:SetCollisionProfileName(FName("NoCollision"), true) end)
    return any
end

local function tarrayNum(arr)
    if arr == nil then return 0 end
    local n = nil
    pcall(function() n = arr:GetArrayNum() end)
    if n == nil then pcall(function() n = arr:Num() end) end
    if n == nil then pcall(function() n = #arr end) end
    return math.max(0, tonumber(n) or 0)
end

local function tarrayAt(arr, zeroIndex)
    if arr == nil then return nil end
    local value = nil
    -- UE4SS TArray builds differ in Lua indexing behavior. Try native 0-based
    -- first, then Lua-style 1-based.
    pcall(function() value = arr[zeroIndex] end)
    value = unwrap(value)
    if valid(value) then return value end
    value = nil
    pcall(function() value = arr[zeroIndex + 1] end)
    value = unwrap(value)
    if valid(value) then return value end
    return nil
end

local function neutralizeEntry(entry)
    if not entry or not valid(entry.actor) then return false end
    local actor = unwrap(entry.actor)

    local invuln = false
    local collision = false
    local movement = false
    local ai = false
    local neutral = false
    local uncapturable = false

    pcall(function() actor:SetVisibleCharacterMesh(true) end)

    if pcall(function() actor.bCanBeDamaged = false end) then invuln = true end
    if pcall(function() actor:SetCanBeDamaged(false) end) then invuln = true end

    if pcall(function() actor.bIsNeutralGroup = true end) then neutral = true end
    pcall(function() actor.bIgnoreChangeBattleModeFlag = true end)
    pcall(function() actor.bIsBattleMode = false end)

    if pcall(function() actor:SetActorEnableCollision(false) end) then collision = true end
    pcall(function() actor:SetActiveCollisionMovement(false) end)

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

    local staticParam = member(actor, "StaticCharacterParameterComponent")
    if valid(staticParam) then
        if pcall(function() staticParam.IsUncapturable = true end) then uncapturable = true end
    elseif entry.kind == "human" then
        uncapturable = true
    end

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
    if neutral and not entry.neutral then
        entry.neutral = true
        neutralGroupApplied = neutralGroupApplied + 1
    end
    if uncapturable and not entry.uncapturable then
        entry.uncapturable = true
        uncapturableApplied = uncapturableApplied + 1
    end

    if entry.invuln and entry.collision and entry.movement and entry.ai and entry.neutral and entry.uncapturable and not entry.neutralized then
        entry.neutralized = true
        neutralizedActors = neutralizedActors + 1
    end

    return entry.neutralized == true
end

local function chooseEmoteMontage(entry)
    if not entry or not valid(entry.actor) then return nil, -1 end
    local staticParam = member(entry.actor, "StaticCharacterParameterComponent")
    if not valid(staticParam) then return nil, -1 end
    local list = member(staticParam, "EmoteList")
    if list == nil then return nil, -1 end
    local n = tarrayNum(list)
    if n <= 0 then return nil, -1 end

    for _, idx in ipairs(EMOTE_ZERO_INDEX_CANDIDATES) do
        if idx < n then
            local montage = tarrayAt(list, idx)
            if valid(montage) then return montage, idx end
        end
    end

    for idx = 0, n - 1 do
        local montage = tarrayAt(list, idx)
        if valid(montage) then return montage, idx end
    end
    return nil, -1
end

local function playCrowdEmote(entry)
    if not entry or not valid(entry.actor) then return false end
    local montage, idx = chooseEmoteMontage(entry)
    if not valid(montage) then
        if not entry.emoteUnavailable then
            entry.emoteUnavailable = true
            emoteUnavailable = emoteUnavailable + 1
        end
        return false
    end

    emoteAttempts = emoteAttempts + 1
    callInflight = "PlayCosmeticMontage_ToAll_" .. tostring(entry.index)
    local ok = pcall(function()
        entry.actor:PlayCosmeticMontage_ToAll(montage, 1.0)
    end)
    callInflight = "none"

    if ok then
        entry.emoteIndex = idx
        if not entry.emoteStarted then
            entry.emoteStarted = true
            emoteStarted = emoteStarted + 1
        end
        return true
    end
    return false
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
    neutralGroupApplied = 0
    emoteAttempts = 0
    emoteStarted = 0
    emoteUnavailable = 0
    emoteRefreshPasses = 0
    destroyedActors = 0
    visualStatus = "waiting_active_raid"
    callInflight = "none"
    lastError = ""
    lastActive = {
        valid = 0, resolvedActors = 0, humanResolved = 0, palResolved = 0,
        neutralizedActors = 0, emoteStarted = 0, emoteUnavailable = 0,
        status = "", error = ""
    }
end

local function identityForIndex(index)
    local slot = math.floor(index / 2) + 1
    if index % 2 == 0 then
        return "human", HUMAN_IDS[((slot - 1) % #HUMAN_IDS) + 1], slot
    end
    return "pal", PAL_IDS[((slot - 1) % #PAL_IDS) + 1], slot
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
                playCrowdEmote(entry)
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

    local kind, characterId, slot = identityForIndex(index)
    local angle = (math.pi * 2.0 * index) / BOUNDARY_COUNT
    local location = {
        X = center.X + math.cos(angle) * RADIUS,
        Y = center.Y + math.sin(angle) * RADIUS,
        Z = center.Z + CHARACTER_Z_OFFSET
    }

    -- Ring points face inward toward the raid center.
    local yaw = math.deg(angle) + 180.0
    local spawnInfo = {
        ControllerClass = controllerClass,
        CharacterID = FName(characterId),
        Level = currentLevel,
        Location = location,
        Yaw = yaw,
        Squad = nil
    }

    spawnAttempts = spawnAttempts + 1
    callInflight = "SpawnNPCForServer_" .. tostring(index)
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
            slot = slot,
            kind = kind,
            characterId = characterId,
            handle = handle,
            actor = nil,
            invuln = false,
            collision = false,
            movement = false,
            ai = false,
            neutral = false,
            uncapturable = false,
            neutralized = false,
            emoteStarted = false,
            emoteUnavailable = false,
            emoteIndex = -1
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

local function refreshCrowdEmotes()
    emoteRefreshPasses = emoteRefreshPasses + 1
    for _, entry in ipairs(entries) do
        if valid(entry.actor) then playCrowdEmote(entry) end
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
        log(string.format("32-character crowd boundary armed at %.1f %.1f %.1f, level=%d", center.X, center.Y, center.Z, currentLevel))
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

    if activeTicks % EMOTE_REFRESH_EVERY_TICKS == 0 and #entries > 0 then
        runGameThread("crowd_emote_refresh", refreshCrowdEmotes)
    end

    if resolvedActors >= BOUNDARY_COUNT and neutralizedActors >= BOUNDARY_COUNT then
        visualStatus = "crowd_boundary_ready"
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
log(string.format("v%s loaded; 32-character server-only crowd boundary ready (16 human + 16 Pal, radius %.0f)", VERSION, RADIUS))
