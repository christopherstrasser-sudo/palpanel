-- PalPanelServerMods v0.2.1
-- Isolated server-side UE4SS action mod. No client install required.
-- Runtime-hardening release: delayed UObject work always returns to the game thread.
-- Guild map markers are temporarily disabled until their native struct path is verified safely.

local MOD_NAME = "PalPanelServerMods"
local MOD_VERSION = "0.2.1"
local DAMAGE_HOOK = "/Script/Pal.PalEventNotify_Character:OnCharacterDamaged_ServerInternal"
local DEATH_HOOK = "/Script/Pal.PalEventNotify_Character:OnCharacterDead_ServerInternal"

local function log(msg)
    print(string.format("[%s] %s\n", MOD_NAME, tostring(msg)))
end

local function scriptDir()
    local src = debug.getinfo(1, "S").source
    src = src:match("^@(.+)$") or src
    return src:match("^(.+)\\[^\\]+$")
end

local function readAll(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local content = f:read("*a")
    f:close()
    return content
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

local scriptsDir = scriptDir()
if not scriptsDir then
    log("ERROR: script directory could not be resolved")
    return
end

local modDir = scriptsDir:match("^(.+)\\Scripts$") or scriptsDir
local pathFile = modDir .. "\\ipc_path.txt"

local function deriveIpcDir()
    local root = scriptsDir:match("^(.-)\\server\\Pal\\Binaries\\Win64\\")
    if root and root ~= "" then return root .. "\\data\\bridge-ipc\\server-mods" end
    return nil
end

local ipcDir = readAll(pathFile)
if ipcDir then ipcDir = ipcDir:gsub("[\r\n]+$", "") end
if not ipcDir or ipcDir == "" then
    ipcDir = deriveIpcDir()
    if not ipcDir then
        log("ERROR: ipc_path.txt missing and IPC path could not be derived")
        return
    end
    pcall(function() writeAll(pathFile, ipcDir .. "\r\n") end)
end

local commandFile = ipcDir .. "\\command.txt"
local responseFile = ipcDir .. "\\response.txt"
local heartbeatFile = ipcDir .. "\\heartbeat.txt"
local processedDir = ipcDir .. "\\processed"
local raidStatusFile = ipcDir .. "\\raid-status.txt"

os.execute('mkdir "' .. ipcDir .. '" 2>nul')
os.execute('mkdir "' .. processedDir .. '" 2>nul')

local function urlDecode(value)
    value = tostring(value or ""):gsub("%+", " ")
    return (value:gsub("%%(%x%x)", function(hex)
        return string.char(tonumber(hex, 16))
    end))
end

local function urlEncode(value)
    value = tostring(value or "")
    return (value:gsub("([^%w%-%._~])", function(c)
        return string.format("%%%02X", string.byte(c))
    end))
end

local function parseKv(content)
    local out = {}
    for line in tostring(content or ""):gmatch("[^\r\n]+") do
        local key, value = line:match("^([^=]+)=(.*)$")
        if key then out[key] = urlDecode(value) end
    end
    return out
end

local function unwrap(value)
    if value == nil then return nil end
    local ok, inner = pcall(function() return value:get() end)
    if ok and inner ~= nil then return inner end
    return value
end

local function valid(object)
    object = unwrap(object)
    if object == nil then return false end
    local addrOk, addr = pcall(function() return object:GetAddress() end)
    if addrOk and tonumber(addr) == 0 then return false end
    local ok, result = pcall(function() return object:IsValid() end)
    return ok and result == true
end

local function objectAddress(object)
    object = unwrap(object)
    if not valid(object) then return "" end
    local ok, value = pcall(function() return object:GetAddress() end)
    local n = ok and tonumber(value) or nil
    if not n or n == 0 then return "" end
    return string.format("%X", n)
end

local function toText(value)
    value = unwrap(value)
    if value == nil then return nil end
    if type(value) == "string" then return value end
    local ok, text = pcall(function() return value:ToString() end)
    if ok and type(text) == "string" and text ~= "" then return text end
    return nil
end

local function member(value, name)
    value = unwrap(value)
    if value == nil then return nil end
    local ok, field = pcall(function() return value[name] end)
    if ok then return unwrap(field) end
    return nil
end

local ZERO_UID = string.rep("0", 32)
local function hex32(word)
    return string.format("%08X", (tonumber(word) or 0) % 0x100000000)
end

local function guidHex(guid)
    guid = unwrap(guid)
    if guid == nil then return "" end
    local ok, text = pcall(function()
        return hex32(guid.A) .. hex32(guid.B) .. hex32(guid.C) .. hex32(guid.D)
    end)
    if ok and text and text ~= ZERO_UID then return text end
    return ""
end

local function playerName(ps)
    ps = unwrap(ps)
    return toText(member(ps, "PlayerNamePrivate")) or toText(member(ps, "SavedPlayerName")) or "Unbekannt"
end

local function playerUid(ps)
    ps = unwrap(ps)
    if not valid(ps) then return "" end
    return guidHex(member(ps, "PlayerUId"))
end

local function playerController(ps)
    ps = unwrap(ps)
    if not valid(ps) then return nil end
    local controller = nil
    pcall(function() controller = ps:GetPlayerController() end)
    controller = unwrap(controller)
    if valid(controller) then return controller end
    controller = member(ps, "Owner")
    if valid(controller) then return controller end
    return nil
end

local function playerPawn(ps)
    local pc = playerController(ps)
    if not valid(pc) then return nil end
    local pawn = member(pc, "Pawn")
    if valid(pawn) then return pawn end
    pcall(function() pawn = pc:GetPawn() end)
    pawn = unwrap(pawn)
    if valid(pawn) then return pawn end
    return nil
end

local function onlinePlayerStates()
    local rows = nil
    pcall(function() rows = FindAllOf("PalPlayerState") end)
    if type(rows) ~= "table" then return {} end
    local out, seen = {}, {}
    for _, ps in ipairs(rows) do
        ps = unwrap(ps)
        if valid(ps) then
            local uid = playerUid(ps)
            local key = uid ~= "" and uid or string.lower(playerName(ps))
            local pawn = playerPawn(ps)
            if key ~= "" and not seen[key] and valid(pawn) then
                seen[key] = true
                table.insert(out, ps)
            end
        end
    end
    return out
end

local function findPlayerByName(name)
    local wanted = string.lower(tostring(name or ""))
    for _, ps in ipairs(onlinePlayerStates()) do
        if string.lower(playerName(ps)) == wanted then return ps end
    end
    return nil
end

local function findPlayerByUid(uid)
    local wanted = string.upper(tostring(uid or ""):gsub("[^0-9A-Fa-f]", ""))
    if wanted == "" then return nil end
    for _, ps in ipairs(onlinePlayerStates()) do
        if string.upper(playerUid(ps)) == wanted then return ps end
    end
    return nil
end

local function playerStateFromActor(actor)
    actor = unwrap(actor)
    if not valid(actor) then return nil end
    local ps = member(actor, "PlayerState")
    if valid(ps) and playerUid(ps) ~= "" then return ps end
    local controller = nil
    pcall(function() controller = actor:GetController() end)
    controller = unwrap(controller)
    if valid(controller) then
        ps = member(controller, "PlayerState")
        if valid(ps) and playerUid(ps) ~= "" then return ps end
    end
    return nil
end

local function parameterFromActor(actor)
    actor = unwrap(actor)
    if not valid(actor) then return nil end
    local component = member(actor, "CharacterParameterComponent")
    if not valid(component) then return nil end
    local parameter = member(component, "IndividualParameter")
    if valid(parameter) then return parameter end
    local handle = member(component, "IndividualHandle")
    if valid(handle) then
        pcall(function() parameter = handle:TryGetIndividualParameter() end)
        parameter = unwrap(parameter)
        if valid(parameter) then return parameter end
    end
    return nil
end

local function ownerUidFromActor(actor)
    local parameter = parameterFromActor(actor)
    if not valid(parameter) then return "" end
    local save = member(parameter, "SaveParameter")
    if save == nil then return "" end
    return guidHex(member(save, "OwnerPlayerUId"))
end

local function participantIdentityFromAttacker(attacker)
    attacker = unwrap(attacker)
    if not valid(attacker) then return nil end
    local direct = playerStateFromActor(attacker)
    if valid(direct) then
        local uid = playerUid(direct)
        if uid ~= "" then return uid, playerName(direct) end
    end
    local ownerUid = ownerUidFromActor(attacker)
    if ownerUid ~= "" then
        local owner = findPlayerByUid(ownerUid)
        if valid(owner) then return ownerUid, playerName(owner) end
        return ownerUid, ownerUid
    end
    return nil
end

local function safeId(id)
    return tostring(id or ""):gsub("[^%w%-%_]", "")
end
local function processedPath(id)
    return processedDir .. "\\" .. safeId(id) .. ".ok"
end
local function alreadyProcessed(id)
    return readAll(processedPath(id)) ~= nil
end
local function markProcessed(id, message)
    writeAll(processedPath(id), tostring(message or "ok"))
end

local function writeResponse(id, ok, message, extra)
    local lines = {
        "id=" .. urlEncode(id),
        "ok=" .. (ok and "1" or "0"),
        "message=" .. urlEncode(message or "")
    }
    if type(extra) == "table" then
        for key, value in pairs(extra) do
            table.insert(lines, tostring(key) .. "=" .. urlEncode(value))
        end
    end
    writeAll(responseFile, table.concat(lines, "\n") .. "\n")
end

local function freshRaid()
    return {
        active = false,
        state = "IDLE",
        stage = "idle",
        id = "",
        species = "",
        level = 0,
        power = 0,
        scale = 1.0,
        onlineAtStart = 0,
        anchorName = "",
        location = { X = 0, Y = 0, Z = 0 },
        startedAt = 0,
        endedAt = 0,
        handle = nil,
        actor = nil,
        actorAddress = "",
        instanceId = "",
        markerCount = 0,
        markerStatus = "disabled_safe_mode",
        participants = {},
        rewardItems = {},
        rewardPending = 0,
        error = ""
    }
end

local raid = freshRaid()

local function participantRows()
    local rows = {}
    for _, p in pairs(raid.participants or {}) do table.insert(rows, p) end
    table.sort(rows, function(a, b)
        if (tonumber(a.damage) or 0) == (tonumber(b.damage) or 0) then
            return tostring(a.name or "") < tostring(b.name or "")
        end
        return (tonumber(a.damage) or 0) > (tonumber(b.damage) or 0)
    end)
    return rows
end

local function writeRaidStatus()
    local rows = participantRows()
    local lines = {
        "version=" .. urlEncode(MOD_VERSION),
        "active=" .. (raid.active and "1" or "0"),
        "state=" .. urlEncode(raid.state or "IDLE"),
        "stage=" .. urlEncode(raid.stage or ""),
        "raid_id=" .. urlEncode(raid.id or ""),
        "species=" .. urlEncode(raid.species or ""),
        "level=" .. tostring(math.floor(tonumber(raid.level) or 0)),
        "power=" .. tostring(math.floor(tonumber(raid.power) or 0)),
        "scale=" .. tostring(tonumber(raid.scale) or 1),
        "online_at_start=" .. tostring(math.floor(tonumber(raid.onlineAtStart) or 0)),
        "anchor_name=" .. urlEncode(raid.anchorName or ""),
        "x=" .. tostring(tonumber(raid.location and raid.location.X) or 0),
        "y=" .. tostring(tonumber(raid.location and raid.location.Y) or 0),
        "z=" .. tostring(tonumber(raid.location and raid.location.Z) or 0),
        "started_at=" .. tostring(math.floor(tonumber(raid.startedAt) or 0)),
        "ended_at=" .. tostring(math.floor(tonumber(raid.endedAt) or 0)),
        "boss_instance_id=" .. urlEncode(raid.instanceId or ""),
        "marker_count=" .. tostring(math.floor(tonumber(raid.markerCount) or 0)),
        "marker_status=" .. urlEncode(raid.markerStatus or ""),
        "participants=" .. tostring(#rows),
        "last_error=" .. urlEncode(raid.error or "")
    }
    for i, p in ipairs(rows) do
        table.insert(lines, string.format("participant_%d_uid=%s", i, urlEncode(p.uid or "")))
        table.insert(lines, string.format("participant_%d_name=%s", i, urlEncode(p.name or "")))
        table.insert(lines, string.format("participant_%d_damage=%d", i, math.floor(tonumber(p.damage) or 0)))
        table.insert(lines, string.format("participant_%d_first_hit=%d", i, math.floor(tonumber(p.firstHitAt) or 0)))
        table.insert(lines, string.format("participant_%d_last_hit=%d", i, math.floor(tonumber(p.lastHitAt) or 0)))
        table.insert(lines, string.format("participant_%d_item_reward=%s", i, urlEncode(p.itemReward or "none")))
        table.insert(lines, string.format("participant_%d_pal_reward=%s", i, urlEncode(p.palReward or "none")))
        table.insert(lines, string.format("participant_%d_reward_error=%s", i, urlEncode(p.rewardError or "")))
    end
    writeAll(raidStatusFile, table.concat(lines, "\n") .. "\n")
end

local function setStage(stage)
    raid.stage = stage
    writeRaidStatus()
    log("raid stage: " .. tostring(stage))
end

local function runGameThread(label, fn)
    ExecuteInGameThread(function()
        local ok, err = xpcall(fn, debug.traceback)
        if not ok then
            raid.error = label .. ": " .. tostring(err)
            log("game-thread task failed: " .. raid.error)
            writeRaidStatus()
        end
    end)
end

local function delayGameThread(ms, label, fn)
    ExecuteWithDelay(ms, function()
        runGameThread(label, fn)
    end)
end

local function eventPulse(id, params)
    local itemId = tostring(params.item or "PalSphere")
    local qty = math.tointeger(tonumber(params.count or "1") or 0)
    if not itemId:match("^[%w_]+$") then return writeResponse(id, false, "invalid item id") end
    if not qty or qty < 1 or qty > 20 then return writeResponse(id, false, "count must be between 1 and 20") end

    runGameThread("event_pulse", function()
        local states = onlinePlayerStates()
        local delivered, failed = 0, 0
        for _, ps in ipairs(states) do
            local invOk, inventory = pcall(function() return ps:GetInventoryData() end)
            inventory = unwrap(inventory)
            if invOk and inventory then
                local addOk, result = pcall(function()
                    return inventory:AddItem_ServerInternal(FName(itemId), qty, false, 0.0, true)
                end)
                if addOk then
                    delivered = delivered + 1
                    log(string.format("event pulse -> %s: %d x %s (result=%s)", playerName(ps), qty, itemId, tostring(result)))
                else failed = failed + 1 end
            else failed = failed + 1 end
        end
        if delivered < 1 then
            return writeResponse(id, false, "no online player inventory could be updated", { delivered = 0, failed = failed })
        end
        local msg = string.format("event pulse delivered %d x %s to %d player(s)", qty, itemId, delivered)
        markProcessed(id, msg)
        writeResponse(id, true, msg, { delivered = delivered, failed = failed, item = itemId, count = qty })
        log(msg)
    end)
end

local function bossInstanceId(handle)
    if not valid(handle) then return "" end
    local id = nil
    pcall(function() id = handle:GetIndividualID() end)
    id = unwrap(id)
    if id == nil then return "" end
    return guidHex(member(id, "InstanceId"))
end

local function configureBossSafe(parameter, actor)
    setStage("configure_boss")
    if valid(parameter) then
        pcall(function() parameter.bIsUncapturable = true end)
        pcall(function() parameter.bIsForceCapturable = false end)
    end
    if valid(actor) then
        local static = member(actor, "StaticCharacterParameterComponent")
        if valid(static) then pcall(function() static.IsUncapturable = true end) end
        local ok, err = pcall(function()
            actor:SetActorScale3D({ X = raid.scale, Y = raid.scale, Z = raid.scale })
        end)
        if not ok then
            raid.error = "boss scale skipped: " .. tostring(err)
            log(raid.error)
        end
    end
    setStage("boss_configured")
end

local function completeSpawn(commandId, attempt)
    if not raid.active or raid.state ~= "SPAWNING" then return end
    setStage("resolve_spawn_" .. tostring(attempt))
    if not valid(raid.handle) then
        raid.error = "spawn handle became invalid"
        raid.active = false
        raid.state = "FAILED"
        raid.endedAt = os.time()
        writeRaidStatus()
        return writeResponse(commandId, false, raid.error)
    end

    local actor, parameter = nil, nil
    pcall(function() actor = raid.handle:TryGetIndividualActor() end)
    pcall(function() parameter = raid.handle:TryGetIndividualParameter() end)
    actor, parameter = unwrap(actor), unwrap(parameter)

    if not valid(actor) and attempt < 16 then
        return delayGameThread(250, "complete_spawn_retry", function()
            completeSpawn(commandId, attempt + 1)
        end)
    end

    if not valid(actor) then
        raid.error = "spawned raid actor could not be resolved"
        raid.active = false
        raid.state = "FAILED"
        raid.endedAt = os.time()
        writeRaidStatus()
        return writeResponse(commandId, false, raid.error)
    end

    raid.actor = actor
    raid.actorAddress = objectAddress(actor)
    raid.instanceId = bossInstanceId(raid.handle)
    local location = nil
    pcall(function() location = actor:K2_GetActorLocation() end)
    if location then
        raid.location = {
            X = tonumber(location.X) or raid.location.X,
            Y = tonumber(location.Y) or raid.location.Y,
            Z = tonumber(location.Z) or raid.location.Z
        }
    end

    configureBossSafe(parameter, actor)

    raid.markerCount = 0
    raid.markerStatus = "disabled_safe_mode"
    raid.state = "ACTIVE"
    setStage("active")

    local msg = string.format("raid %s spawned: %s Lv.%d", raid.id, raid.species, raid.level)
    markProcessed(commandId, msg)
    writeResponse(commandId, true, msg, {
        raid_id = raid.id,
        species = raid.species,
        level = raid.level,
        power = raid.power,
        scale = raid.scale,
        x = raid.location.X,
        y = raid.location.Y,
        z = raid.location.Z,
        marker_count = 0,
        marker_status = raid.markerStatus,
        boss_instance_id = raid.instanceId
    })
    log(msg)
end

local function parseRewardItems(params)
    local out = {}
    for i = 1, 8 do
        local item = tostring(params["reward_" .. i .. "_item"] or "")
        local count = math.floor(tonumber(params["reward_" .. i .. "_count"] or 0) or 0)
        if item:match("^[%w_]+$") and count > 0 and count <= 9999 then
            table.insert(out, { item = item, count = count })
        end
    end
    return out
end

local function startRaid(commandId, params)
    if raid.active or raid.state == "SPAWNING" or raid.state == "ACTIVE" or raid.state == "REWARDING" then
        return writeResponse(commandId, false, "a raid is already active")
    end

    local species = tostring(params.species or "")
    local level = math.floor(tonumber(params.level or 0) or 0)
    local power = math.floor(tonumber(params.power or 0) or 0)
    local scale = tonumber(params.scale or 0) or 0
    local distance = tonumber(params.distance or 1500) or 1500
    local angle = tonumber(params.angle or 0) or 0

    if not species:match("^[%w_]+$") then return writeResponse(commandId, false, "invalid species") end
    if level < 1 or level > 100 then return writeResponse(commandId, false, "level must be between 1 and 100") end
    if power < 0 or power > 100 then return writeResponse(commandId, false, "power must be between 0 and 100") end
    if scale < 1.0 or scale > 5.0 then return writeResponse(commandId, false, "scale must be between 1 and 5") end

    raid = freshRaid()
    raid.active = true
    raid.state = "SPAWNING"
    raid.stage = "queued"
    raid.id = tostring(params.raid_id or commandId)
    raid.species = species
    raid.level = level
    raid.power = power
    raid.scale = scale
    raid.onlineAtStart = math.floor(tonumber(params.online_players or 0) or 0)
    raid.anchorName = tostring(params.anchor_name or "")
    raid.startedAt = os.time()
    raid.rewardItems = parseRewardItems(params)
    writeRaidStatus()

    runGameThread("start_raid", function()
        setStage("find_anchor")
        local states = onlinePlayerStates()
        local anchor = raid.anchorName ~= "" and findPlayerByName(raid.anchorName) or states[1]
        if not valid(anchor) then
            raid.error = "no online anchor player"
            raid.active = false
            raid.state = "FAILED"
            raid.endedAt = os.time()
            writeRaidStatus()
            return writeResponse(commandId, false, raid.error)
        end

        raid.anchorName = playerName(anchor)
        local pc, pawn = playerController(anchor), playerPawn(anchor)
        if not valid(pc) or not valid(pawn) then
            raid.error = "anchor controller/pawn unavailable"
            raid.active = false
            raid.state = "FAILED"
            raid.endedAt = os.time()
            writeRaidStatus()
            return writeResponse(commandId, false, raid.error)
        end

        local base = nil
        pcall(function() base = pawn:K2_GetActorLocation() end)
        if not base then
            raid.error = "anchor location unavailable"
            raid.active = false
            raid.state = "FAILED"
            raid.endedAt = os.time()
            writeRaidStatus()
            return writeResponse(commandId, false, raid.error)
        end

        raid.location = {
            X = (tonumber(base.X) or 0) + math.cos(angle) * distance,
            Y = (tonumber(base.Y) or 0) + math.sin(angle) * distance,
            Z = (tonumber(base.Z) or 0) + 180
        }

        setStage("get_npc_manager")
        local palUtil = nil
        pcall(function() palUtil = StaticFindObject("/Script/Pal.Default__PalUtility") end)
        if not valid(palUtil) then
            raid.error = "PalUtility unavailable"
            raid.active = false
            raid.state = "FAILED"
            raid.endedAt = os.time()
            writeRaidStatus()
            return writeResponse(commandId, false, raid.error)
        end

        local npcManager = nil
        pcall(function() npcManager = palUtil:GetNPCManager(pc) end)
        npcManager = unwrap(npcManager)
        if not valid(npcManager) then
            raid.error = "NPC manager unavailable"
            raid.active = false
            raid.state = "FAILED"
            raid.endedAt = os.time()
            writeRaidStatus()
            return writeResponse(commandId, false, raid.error)
        end

        local controllerClass = member(npcManager, "NPCAIControllerBaseClass")
        if not valid(controllerClass) then
            raid.error = "NPC AI controller class unavailable"
            raid.active = false
            raid.state = "FAILED"
            raid.endedAt = os.time()
            writeRaidStatus()
            return writeResponse(commandId, false, raid.error)
        end

        local spawnInfo = {
            ControllerClass = controllerClass,
            CharacterID = FName(raid.species),
            Level = raid.level,
            Location = raid.location,
            Yaw = 0.0,
            Squad = nil
        }

        setStage("spawn_npc")
        local ok, handle = pcall(function()
            return npcManager:SpawnNPCForServer(spawnInfo, nil)
        end)
        handle = unwrap(handle)
        if not ok or not valid(handle) then
            raid.error = "SpawnNPCForServer failed: " .. tostring(handle or "invalid handle")
            raid.active = false
            raid.state = "FAILED"
            raid.endedAt = os.time()
            writeRaidStatus()
            return writeResponse(commandId, false, raid.error)
        end

        raid.handle = handle
        setStage("spawn_handle_ready")
        delayGameThread(350, "complete_spawn", function()
            completeSpawn(commandId, 1)
        end)
    end)
end

local function rewardItems(ps, participant)
    local inventory = nil
    pcall(function() inventory = ps:GetInventoryData() end)
    inventory = unwrap(inventory)
    if not inventory then
        participant.itemReward = "pending"
        participant.rewardError = "inventory unavailable"
        return false
    end

    local allOk = true
    for _, reward in ipairs(raid.rewardItems or {}) do
        local ok = pcall(function()
            inventory:AddItem_ServerInternal(FName(reward.item), reward.count, false, 0.0, true)
        end)
        if not ok then allOk = false end
    end
    participant.itemReward = allOk and "delivered" or "partial"
    return allOk
end

local function finishReward(uid, palOk)
    local p = raid.participants[uid]
    if p and p.itemReward == "none" then p.itemReward = "failed" end
    if p and p.palReward == "none" then p.palReward = palOk and "delivered" or "failed" end
    raid.rewardPending = math.max(0, (raid.rewardPending or 1) - 1)
    if raid.rewardPending <= 0 then
        raid.active = false
        raid.state = "COMPLETED"
        raid.stage = "completed"
        raid.endedAt = raid.endedAt > 0 and raid.endedAt or os.time()
        log(string.format("raid %s completed with %d participant(s)", raid.id, #participantRows()))
    end
    writeRaidStatus()
end

local function rewardPalAttempt(ps, participant, done, attempt, handle, palUtil)
    if not valid(ps) then
        participant.palReward = "pending"
        participant.rewardError = "player offline"
        return done(false)
    end

    if valid(handle) then
        local actor = nil
        pcall(function() actor = handle:TryGetIndividualActor() end)
        actor = unwrap(actor)
        if valid(actor) then
            local pawn = playerPawn(ps)
            if valid(pawn) and valid(palUtil) then
                local ok, err = pcall(function() palUtil:PalCaptureSuccess(pawn, actor) end)
                if ok then
                    participant.palReward = "delivered"
                    return done(true)
                end
                participant.rewardError = tostring(err)
            end
        end
        if attempt < 15 then
            return delayGameThread(200, "reward_pal_retry", function()
                rewardPalAttempt(ps, participant, done, attempt + 1, handle, palUtil)
            end)
        end
        participant.palReward = "failed"
        return done(false)
    end

    local pc, pawn = playerController(ps), playerPawn(ps)
    if not valid(pc) or not valid(pawn) then
        participant.palReward = "pending"
        participant.rewardError = "player controller unavailable"
        return done(false)
    end

    pcall(function() palUtil = StaticFindObject("/Script/Pal.Default__PalUtility") end)
    if not valid(palUtil) then
        participant.palReward = "failed"
        participant.rewardError = "PalUtility unavailable"
        return done(false)
    end

    local npcManager = nil
    pcall(function() npcManager = palUtil:GetNPCManager(pc) end)
    npcManager = unwrap(npcManager)
    if not valid(npcManager) then
        participant.palReward = "failed"
        participant.rewardError = "NPC manager unavailable"
        return done(false)
    end

    local controllerClass = member(npcManager, "NPCAIControllerBaseClass")
    local base = nil
    pcall(function() base = pawn:K2_GetActorLocation() end)
    if not valid(controllerClass) or not base then
        participant.palReward = "failed"
        participant.rewardError = "reward spawn prerequisites unavailable"
        return done(false)
    end

    local spawnInfo = {
        ControllerClass = controllerClass,
        CharacterID = FName(raid.species),
        Level = raid.level,
        Location = {
            X = (tonumber(base.X) or 0) + 300,
            Y = tonumber(base.Y) or 0,
            Z = (tonumber(base.Z) or 0) + 120
        },
        Yaw = 0.0,
        Squad = nil
    }

    local ok, newHandle = pcall(function()
        return npcManager:SpawnNPCForServer(spawnInfo, nil)
    end)
    newHandle = unwrap(newHandle)
    if not ok or not valid(newHandle) then
        participant.palReward = "failed"
        participant.rewardError = "reward pal spawn failed"
        return done(false)
    end

    participant.palReward = "delivering"
    delayGameThread(250, "reward_pal_capture", function()
        rewardPalAttempt(ps, participant, done, 1, newHandle, palUtil)
    end)
end

local function finalizeRaid(lastAttacker)
    if not raid.active or raid.state ~= "ACTIVE" then return end

    if valid(lastAttacker) then
        local uid, name = participantIdentityFromAttacker(lastAttacker)
        if uid and not raid.participants[uid] then
            raid.participants[uid] = {
                uid = uid,
                name = name or uid,
                damage = 1,
                firstHitAt = os.time(),
                lastHitAt = os.time(),
                itemReward = "none",
                palReward = "none",
                rewardError = ""
            }
        end
    end

    raid.state = "REWARDING"
    raid.stage = "rewarding"
    raid.endedAt = os.time()
    local rows = participantRows()
    raid.rewardPending = #rows
    writeRaidStatus()

    if #rows == 0 then
        raid.active = false
        raid.state = "COMPLETED"
        raid.stage = "completed_no_participants"
        writeRaidStatus()
        return
    end

    for index, participant in ipairs(rows) do
        delayGameThread((index - 1) * 350, "reward_participant", function()
            local ps = findPlayerByUid(participant.uid)
            if not valid(ps) then
                participant.itemReward = "pending"
                participant.palReward = "pending"
                participant.rewardError = "player offline at raid completion"
                return finishReward(participant.uid, false)
            end
            rewardItems(ps, participant)
            rewardPalAttempt(ps, participant, function(ok)
                finishReward(participant.uid, ok)
            end, 0, nil, nil)
            writeRaidStatus()
        end)
    end
end

local function cancelRaid(commandId)
    if not raid.active and raid.state ~= "SPAWNING" and raid.state ~= "ACTIVE" and raid.state ~= "REWARDING" then
        return writeResponse(commandId, false, "no active raid")
    end

    runGameThread("cancel_raid", function()
        if valid(raid.actor) then pcall(function() raid.actor:K2_DestroyActor() end) end
        raid.active = false
        raid.state = "CANCELLED"
        raid.stage = "cancelled"
        raid.endedAt = os.time()
        raid.error = "cancelled by admin"
        writeRaidStatus()
        local msg = "raid cancelled: " .. tostring(raid.id)
        markProcessed(commandId, msg)
        writeResponse(commandId, true, msg, { raid_id = raid.id })
        log(msg)
    end)
end

local function raidStatus(commandId)
    writeRaidStatus()
    writeResponse(commandId, true, raid.state or "IDLE", {
        raid_id = raid.id or "",
        state = raid.state or "IDLE",
        stage = raid.stage or "",
        active = raid.active and 1 or 0,
        species = raid.species or "",
        level = raid.level or 0,
        participants = #participantRows(),
        marker_status = raid.markerStatus or ""
    })
end

local function onRaidDamage(_context, damageParam)
    if not raid.active or raid.state ~= "ACTIVE" or raid.actorAddress == "" then return end
    local result = unwrap(damageParam)
    if result == nil then return end
    local defender = member(result, "Defender")
    if not valid(defender) or objectAddress(defender) ~= raid.actorAddress then return end
    local attacker = member(result, "Attacker")
    local uid, name = participantIdentityFromAttacker(attacker)
    if not uid or uid == "" then return end
    local damage = tonumber(member(result, "ActualDamage")) or tonumber(member(result, "Damage")) or 0
    damage = math.max(1, math.floor(damage))
    local now = os.time()
    local p = raid.participants[uid]
    if not p then
        p = {
            uid = uid,
            name = name or uid,
            damage = 0,
            firstHitAt = now,
            lastHitAt = now,
            itemReward = "none",
            palReward = "none",
            rewardError = ""
        }
        raid.participants[uid] = p
    end
    p.name = name or p.name
    p.damage = (tonumber(p.damage) or 0) + damage
    p.lastHitAt = now
    writeRaidStatus()
end

local function onRaidDeath(_context, deadInfoParam)
    if not raid.active or raid.state ~= "ACTIVE" or raid.actorAddress == "" then return end
    local info = unwrap(deadInfoParam)
    if info == nil then return end
    local victim = member(info, "SelfActor")
    if not valid(victim) or objectAddress(victim) ~= raid.actorAddress then return end
    log("raid boss death detected: " .. tostring(raid.species))
    finalizeRaid(member(info, "LastAttacker"))
end

local function registerRaidHooks()
    local damageOk, damageErr = pcall(function()
        RegisterHook(DAMAGE_HOOK, function(...)
            local args = { ... }
            local ok, err = xpcall(function()
                onRaidDamage(table.unpack(args))
            end, debug.traceback)
            if not ok then log("raid damage hook failed: " .. tostring(err)) end
        end)
    end)
    local deathOk, deathErr = pcall(function()
        RegisterHook(DEATH_HOOK, function(...)
            local args = { ... }
            local ok, err = xpcall(function()
                onRaidDeath(table.unpack(args))
            end, debug.traceback)
            if not ok then log("raid death hook failed: " .. tostring(err)) end
        end)
    end)
    log(damageOk and "raid damage hook registered" or ("raid damage hook unavailable: " .. tostring(damageErr)))
    log(deathOk and "raid death hook registered" or ("raid death hook unavailable: " .. tostring(deathErr)))
    return damageOk, deathOk
end

local function processCommand(cmd)
    local id = tostring(cmd.id or "")
    local kind = tostring(cmd.type or "")
    if id == "" then return end
    if alreadyProcessed(id) then return writeResponse(id, true, "already_processed") end

    if kind == "ping" then
        markProcessed(id, "pong")
        return writeResponse(id, true, "pong")
    elseif kind == "event_pulse" then
        return eventPulse(id, cmd)
    elseif kind == "start_raid" then
        return startRaid(id, cmd)
    elseif kind == "raid_status" then
        return raidStatus(id)
    elseif kind == "cancel_raid" then
        return cancelRaid(id)
    end
    writeResponse(id, false, "unknown command: " .. kind)
end

local function pollCommand()
    local content = readAll(commandFile)
    if not content or content == "" then return end
    os.remove(commandFile)
    local ok, cmd = pcall(parseKv, content)
    if not ok or not cmd then return writeResponse("unknown", false, "invalid command") end
    processCommand(cmd)
end

local function writeHeartbeat()
    writeAll(heartbeatFile, table.concat({
        "version=" .. urlEncode(MOD_VERSION),
        "time=" .. tostring(os.time()),
        "state=ready",
        "capabilities=heartbeat,ping,event_pulse,start_raid,raid_status,cancel_raid,raid_damage_tracking,raid_rewards,raid_safe_runtime",
        "raid_state=" .. urlEncode(raid.state or "IDLE"),
        "raid_stage=" .. urlEncode(raid.stage or ""),
        "raid_active=" .. (raid.active and "1" or "0"),
        "client_install_required=0"
    }, "\n") .. "\n")
end

os.remove(commandFile)
os.remove(responseFile)
raid = freshRaid()
writeRaidStatus()
writeHeartbeat()

LoopAsync(500, function()
    local ok, err = xpcall(pollCommand, debug.traceback)
    if not ok then log("poll error: " .. tostring(err)) end
    return false
end)

LoopAsync(2000, function()
    local ok, err = pcall(writeHeartbeat)
    if not ok then log("heartbeat error: " .. tostring(err)) end
    return false
end)

local damageHook, deathHook = registerRaidHooks()
log("v" .. MOD_VERSION .. " loaded")
log("IPC: " .. ipcDir)
log("Capabilities: event_pulse + dynamic raids + raid rewards + safe runtime")
log("Raid hooks: damage=" .. tostring(damageHook) .. " death=" .. tostring(deathHook))
log("Guild map markers: temporarily disabled in 0.2.1 safe mode")
log("Client installation required: NO")