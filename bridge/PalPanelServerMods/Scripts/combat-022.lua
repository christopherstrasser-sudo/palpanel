-- PalPanelServerMods Raid Combat AI v0.2.2
-- Isolated from the proven 0.2.1 spawn/reward runtime.
-- Activates the spawned raid boss AI and opens combat against online players.

local MOD_NAME = "PalPanelRaidCombat"
local MOD_VERSION = "0.2.2"

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
    log("ERROR: script directory unavailable")
    return
end

local modDir = scriptsDir:match("^(.+)\\Scripts$") or scriptsDir
local ipcPathFile = modDir .. "\\ipc_path.txt"
local ipcDir = readAll(ipcPathFile)
if ipcDir then ipcDir = ipcDir:gsub("[\r\n]+$", "") end
if not ipcDir or ipcDir == "" then
    log("ERROR: ipc_path.txt unavailable")
    return
end

local raidStatusFile = ipcDir .. "\\raid-status.txt"
local combatStatusFile = ipcDir .. "\\raid-combat-status.txt"

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

local function member(value, name)
    value = unwrap(value)
    if value == nil then return nil end
    local ok, field = pcall(function() return value[name] end)
    if ok then return unwrap(field) end
    return nil
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
    return toText(member(ps, "PlayerNamePrivate")) or toText(member(ps, "SavedPlayerName")) or "Unbekannt"
end

local function playerUid(ps)
    if not valid(ps) then return "" end
    return guidHex(member(ps, "PlayerUId"))
end

local function playerController(ps)
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

local function onlinePlayers()
    local states = nil
    pcall(function() states = FindAllOf("PalPlayerState") end)
    if type(states) ~= "table" then return {} end
    local out, seen = {}, {}
    for _, ps in ipairs(states) do
        ps = unwrap(ps)
        if valid(ps) then
            local uid = playerUid(ps)
            local pawn = playerPawn(ps)
            if uid ~= "" and valid(pawn) and not seen[uid] then
                seen[uid] = true
                table.insert(out, { uid = uid, name = playerName(ps), pawn = pawn })
            end
        end
    end
    return out
end

local function actorInstanceId(actor)
    actor = unwrap(actor)
    if not valid(actor) then return "" end
    local component = member(actor, "CharacterParameterComponent")
    if not valid(component) then return "" end
    local handle = member(component, "IndividualHandle")
    if not valid(handle) then
        local parameter = member(component, "IndividualParameter")
        if valid(parameter) then
            local individualId = member(parameter, "IndividualId")
            return guidHex(member(individualId, "InstanceId"))
        end
        return ""
    end
    local individualId = nil
    pcall(function() individualId = handle:GetIndividualID() end)
    individualId = unwrap(individualId)
    return guidHex(member(individualId, "InstanceId"))
end

local function findRaidBoss(instanceId)
    local wanted = string.upper(tostring(instanceId or ""):gsub("[^0-9A-Fa-f]", ""))
    if wanted == "" then return nil end
    local actors = nil
    pcall(function() actors = FindAllOf("PalCharacter") end)
    if type(actors) ~= "table" then return nil end
    for _, actor in ipairs(actors) do
        actor = unwrap(actor)
        if valid(actor) and string.upper(actorInstanceId(actor)) == wanted then
            return actor
        end
    end
    return nil
end

local function actorController(actor)
    actor = unwrap(actor)
    if not valid(actor) then return nil end
    local controller = member(actor, "Controller")
    if valid(controller) then return controller end
    pcall(function() controller = actor:GetController() end)
    controller = unwrap(controller)
    if valid(controller) then return controller end
    return nil
end

local currentRaidId = ""
local bossActor = nil
local bossController = nil
local targetedPawns = {}
local engagedPawn = nil
local engagedName = ""
local activeAISet = false
local lastError = ""
local targetCount = 0
local bossFound = false
local controllerFound = false
local engaged = false

local function resetRuntime(raidId)
    currentRaidId = tostring(raidId or "")
    bossActor = nil
    bossController = nil
    targetedPawns = {}
    engagedPawn = nil
    engagedName = ""
    activeAISet = false
    lastError = ""
    targetCount = 0
    bossFound = false
    controllerFound = false
    engaged = false
end

local function writeCombatStatus(status)
    local lines = {
        "version=" .. urlEncode(MOD_VERSION),
        "time=" .. tostring(os.time()),
        "raid_id=" .. urlEncode(currentRaidId),
        "raid_state=" .. urlEncode(status and status.state or "IDLE"),
        "boss_found=" .. (bossFound and "1" or "0"),
        "controller_found=" .. (controllerFound and "1" or "0"),
        "ai_active=" .. (activeAISet and "1" or "0"),
        "engaged=" .. (engaged and "1" or "0"),
        "target_count=" .. tostring(targetCount),
        "target_name=" .. urlEncode(engagedName),
        "last_error=" .. urlEncode(lastError)
    }
    writeAll(combatStatusFile, table.concat(lines, "\n") .. "\n")
end

local function readRaidStatus()
    local raw = readAll(raidStatusFile)
    if not raw or raw == "" then return { active = "0", state = "IDLE" } end
    return parseKv(raw)
end

local function engageRaidBoss(status)
    if status.raid_id ~= currentRaidId then resetRuntime(status.raid_id) end

    if status.active ~= "1" or status.state ~= "ACTIVE" then
        if currentRaidId ~= "" and status.raid_id == currentRaidId then
            bossActor = nil
            bossController = nil
            engagedPawn = nil
            engagedName = ""
            targetedPawns = {}
            targetCount = 0
            engaged = false
        end
        writeCombatStatus(status)
        return
    end

    if not valid(bossActor) then
        bossActor = findRaidBoss(status.boss_instance_id)
        bossFound = valid(bossActor)
        if not bossFound then
            lastError = "raid boss actor not resolved yet"
            return writeCombatStatus(status)
        end
        log("raid boss resolved: " .. tostring(status.species or "unknown"))
    end

    if not valid(bossController) then
        bossController = actorController(bossActor)
        controllerFound = valid(bossController)
        if not controllerFound then
            lastError = "raid boss AI controller not resolved yet"
            return writeCombatStatus(status)
        end
        log("raid boss controller resolved")
    end

    if not activeAISet then
        local ok, err = pcall(function() bossController:SetActiveAI(true) end)
        if ok then
            activeAISet = true
            log("raid boss AI activated")
        else
            lastError = "SetActiveAI failed: " .. tostring(err)
        end
    end

    local players = onlinePlayers()
    local anchorPawn, anchorName = nil, ""
    local fallbackPawn, fallbackName = nil, ""
    local wantedAnchor = string.lower(tostring(status.anchor_name or ""))

    for _, player in ipairs(players) do
        local pawnAddress = objectAddress(player.pawn)
        if pawnAddress ~= "" and targetedPawns[player.uid] ~= pawnAddress then
            local ok, err = pcall(function()
                bossController:AddTargetPlayer_ForEnemy(player.pawn)
            end)
            if ok then
                targetedPawns[player.uid] = pawnAddress
                targetCount = targetCount + 1
                log("raid enemy registered: " .. tostring(player.name))
            else
                lastError = "AddTargetPlayer_ForEnemy failed: " .. tostring(err)
            end
        end
        if not fallbackPawn then
            fallbackPawn, fallbackName = player.pawn, player.name
        end
        if wantedAnchor ~= "" and string.lower(player.name or "") == wantedAnchor then
            anchorPawn, anchorName = player.pawn, player.name
        end
    end

    if not valid(engagedPawn) then
        engagedPawn = valid(anchorPawn) and anchorPawn or fallbackPawn
        engagedName = valid(anchorPawn) and anchorName or fallbackName or ""
        engaged = false
    end

    if valid(engagedPawn) and not engaged then
        local ok, err = pcall(function()
            bossController:ForceBattleStartToTarget(engagedPawn)
        end)
        if ok then
            engaged = true
            lastError = ""
            log("raid combat engaged -> " .. tostring(engagedName))
        else
            lastError = "ForceBattleStartToTarget failed: " .. tostring(err)
            log(lastError)
        end
    end

    writeCombatStatus(status)
end

LoopAsync(1250, function()
    local status = readRaidStatus()
    if status.raid_id ~= currentRaidId and status.raid_id ~= nil then
        resetRuntime(status.raid_id)
    end
    if status.active == "1" and status.state == "ACTIVE" then
        ExecuteInGameThread(function()
            local ok, err = xpcall(function() engageRaidBoss(status) end, debug.traceback)
            if not ok then
                lastError = tostring(err)
                log("combat tick failed: " .. lastError)
                writeCombatStatus(status)
            end
        end)
    else
        if currentRaidId ~= "" then
            resetRuntime(status.raid_id or "")
        end
        writeCombatStatus(status)
    end
    return false
end)

log("v" .. MOD_VERSION .. " loaded")
log("Combat lever: AddTargetPlayer_ForEnemy + ForceBattleStartToTarget")
log("IPC: " .. ipcDir)