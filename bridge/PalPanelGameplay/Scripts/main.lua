-- PalPanelGameplay v0.1.0
-- Isolated server-side gameplay observer for PalPanel.
-- Tracks player deaths and player-attributed boss defeats only.
-- No polling, no savegame access and no item-delivery code.

local MOD_NAME = "PalPanelGameplay"
local MOD_VERSION = "0.1.0"

local DEATH_HOOK = "/Script/Pal.PalPlayerCharacter:OnDeadPlayer_Server"
local INIT_HOOK = "/Script/Pal.PalPlayerCharacter:OnCompleteInitializeParameter"
local DEFEAT_SIGNATURE_HOOK = "/Script/Pal.PalPlayerCharacter:OnDefeatCharacterDelegate__DelegateSignature"
local DEFEAT_SIGNATURE_FUNCTION = "OnDefeatCharacterDelegate__DelegateSignature"

local function log(message)
    print(string.format("[%s] %s\n", MOD_NAME, tostring(message)))
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
    if root and root ~= "" then return root .. "\\data\\bridge-ipc" end
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

local eventsDir = ipcDir .. "\\game-events"
os.execute('mkdir "' .. ipcDir .. '" 2>nul')
os.execute('mkdir "' .. eventsDir .. '" 2>nul')

local function unwrap(value)
    if value == nil then return nil end
    local ok, inner = pcall(function() return value:get() end)
    if ok and inner ~= nil then return inner end
    return value
end

local function member(object, name)
    if object == nil then return nil end
    local ok, value = pcall(function() return object[name] end)
    if ok then return value end
    return nil
end

local function valid(object)
    object = unwrap(object)
    if object == nil then return false end
    local addressOk, address = pcall(function() return object:GetAddress() end)
    if addressOk and tonumber(address) == 0 then return false end
    local ok, result = pcall(function() return object:IsValid() end)
    return ok and result == true
end

local function objectAddress(object)
    object = unwrap(object)
    if not valid(object) then return nil end
    local ok, value = pcall(function() return object:GetAddress() end)
    local n = ok and tonumber(value) or nil
    if not n or n == 0 then return nil end
    return string.format("%X", n)
end

local function fullName(object)
    object = unwrap(object)
    if not valid(object) then return "" end
    local ok, value = pcall(function() return object:GetFullName() end)
    if ok and type(value) == "string" then return value end
    return ""
end

local function toText(value)
    value = unwrap(value)
    if value == nil then return nil end
    if type(value) == "string" then return value end
    local ok, text = pcall(function() return value:ToString() end)
    if ok and type(text) == "string" and text ~= "" then return text end
    return nil
end

local function asInt(value)
    value = unwrap(value)
    if type(value) == "number" then return math.floor(value) end
    return nil
end

local function asFlag(value)
    value = unwrap(value)
    if type(value) == "boolean" then return value end
    if type(value) == "number" and (value == 0 or value == 1) then return value == 1 end
    return nil
end

local ZERO_GUID = string.rep("0", 32)
local function guidHex(guid)
    guid = unwrap(guid)
    if guid == nil then return "" end
    local parts = {}
    local ok = pcall(function()
        for _, key in ipairs({ "A", "B", "C", "D" }) do
            local n = asInt(guid[key])
            if n == nil then return end
            parts[#parts + 1] = string.format("%08X", n % 0x100000000)
        end
    end)
    if not ok or #parts ~= 4 then return "" end
    local value = table.concat(parts)
    if value == ZERO_GUID then return "" end
    return value
end

local function playerStateFromCharacter(character)
    character = unwrap(character)
    if not valid(character) then return nil end

    local state = unwrap(member(character, "PlayerState"))
    if valid(state) then return state end

    local controller = nil
    pcall(function() controller = character:GetController() end)
    if valid(controller) then
        state = unwrap(member(controller, "PlayerState"))
        if valid(state) then return state end
        pcall(function() state = controller:GetPlayerState() end)
        if valid(state) then return state end
    end
    return nil
end

local function playerIdentity(character)
    local state = playerStateFromCharacter(character)
    if not valid(state) then return nil end

    local uid = guidHex(member(state, "PlayerUId"))
    if uid == "" then return nil end

    local name = toText(member(state, "PlayerNamePrivate"))
    if not name or name == "" then name = toText(member(state, "SavedPlayerName")) end
    return { uid = uid, name = name or uid }
end

local function urlEncode(value)
    value = tostring(value or "")
    return (value:gsub("([^%w%-%._~])", function(c)
        return string.format("%%%02X", string.byte(c))
    end))
end

local eventCounter = 0
local function writeEvent(fields)
    eventCounter = eventCounter + 1
    local lines = {
        "event_id=" .. urlEncode(fields.eventId),
        "type=" .. urlEncode(fields.type),
        "player_uid=" .. urlEncode(fields.uid),
        "player_name=" .. urlEncode(fields.playerName or ""),
        "time=" .. tostring(os.time()),
        "source=" .. urlEncode(fields.source or MOD_NAME)
    }

    for _, pair in ipairs(fields.extra or {}) do
        lines[#lines + 1] = tostring(pair[1]) .. "=" .. urlEncode(pair[2])
    end

    local body = table.concat(lines, "\n") .. "\n"
    local fileName = string.format("game_%d_%06d.evt", os.time(), eventCounter)
    if not writeAll(eventsDir .. "\\" .. fileName, body) then
        log("event write failed: " .. tostring(fields.type))
        return false
    end
    return true
end

local function parameterFromActor(actor)
    actor = unwrap(actor)
    if not valid(actor) then return nil, nil end

    local component = unwrap(member(actor, "CharacterParameterComponent"))
    if not valid(component) then return nil, nil end

    local parameter = unwrap(member(component, "IndividualParameter"))
    local handle = unwrap(member(component, "IndividualHandle"))

    if not valid(parameter) and valid(handle) then
        pcall(function() parameter = handle:TryGetIndividualParameter() end)
    end
    if not valid(parameter) then parameter = nil end
    if not valid(handle) then handle = nil end
    return parameter, handle
end

local function speciesFromParameter(parameter)
    if not valid(parameter) then return nil end
    local characterId = nil
    pcall(function() characterId = parameter:GetCharacterID() end)
    local text = toText(characterId)
    if text and text ~= "" and text ~= "None" then return text end
    return nil
end

local function levelFromParameter(parameter)
    if not valid(parameter) then return 0 end
    local value = nil
    pcall(function() value = parameter:GetLevel() end)
    return asInt(value) or 0
end

local function instanceIdFromHandle(handle)
    if not valid(handle) then return "" end
    local id = nil
    pcall(function() id = handle:GetIndividualID() end)
    if id == nil then return "" end
    return guidHex(member(id, "InstanceId"))
end

local function isBossActor(actor, rawSpecies)
    if tostring(rawSpecies or ""):match("^BOSS_") or tostring(rawSpecies or ""):match("^Boss_") then
        return true
    end

    local static = unwrap(member(actor, "StaticCharacterParameterComponent"))
    if not valid(static) then return false end

    for _, field in ipairs({
        "IsBoss_Database",
        "IsTowerBoss_Database",
        "IsPredatorBoss_Database",
        "IsRaidBoss_Database"
    }) do
        if asFlag(member(static, field)) == true then return true end
    end
    return false
end

local deathDebounce = {}
local function onPlayerDeath(context, deadInfoParam)
    local character = unwrap(context)
    local identity = playerIdentity(character)
    if not identity then
        log("player death ignored: player identity unavailable")
        return
    end

    local now = os.time()
    if now - tonumber(deathDebounce[identity.uid] or 0) < 5 then return end
    deathDebounce[identity.uid] = now

    local deadInfo = unwrap(deadInfoParam)
    local attacker = unwrap(member(deadInfo, "LastAttacker"))
    local attackerName = fullName(attacker)
    local eventId = string.format("death:%s:%d", identity.uid, now)

    if writeEvent({
        eventId = eventId,
        type = "death",
        uid = identity.uid,
        playerName = identity.name,
        source = "PalPlayerCharacter.OnDeadPlayer_Server",
        extra = {
            { "attacker", attackerName }
        }
    }) then
        log("DEATH: " .. identity.name)
    end
end

local boundCharacters = {}
local bindTraceLeft = 12
local defeatHookRegistered = false

local function onDefeatCharacter(context, deadInfoParam)
    local character = unwrap(context)
    local identity = playerIdentity(character)
    if not identity then return end

    local deadInfo = unwrap(deadInfoParam)
    local victim = unwrap(member(deadInfo, "SelfActor"))
    if not valid(victim) then return end

    local parameter, handle = parameterFromActor(victim)
    local rawSpecies = speciesFromParameter(parameter)
    if not isBossActor(victim, rawSpecies) then return end

    local bossKey = rawSpecies
    if not bossKey or bossKey == "" then
        bossKey = fullName(victim)
        if bossKey == "" then bossKey = "UnknownBoss" end
    end

    local instanceId = instanceIdFromHandle(handle)
    local eventId
    if instanceId ~= "" then
        eventId = "bosskill:" .. identity.uid .. ":" .. instanceId
    else
        eventId = string.format("bosskill:%s:%s:%d", identity.uid, bossKey, os.time())
    end

    if writeEvent({
        eventId = eventId,
        type = "boss",
        uid = identity.uid,
        playerName = identity.name,
        source = "PalPlayerCharacter.OnDefeatCharacterDelegate",
        extra = {
            { "boss_key", bossKey },
            { "species", rawSpecies or "" },
            { "level", tostring(levelFromParameter(parameter)) },
            { "pal_id", instanceId }
        }
    }) then
        log(string.format("BOSS DEFEAT: %s -> %s", identity.name, bossKey))
    end
end

local function ensureDefeatHook()
    if defeatHookRegistered then return true end
    local ok, err = pcall(function()
        RegisterHook(DEFEAT_SIGNATURE_HOOK, function(...)
            local hookOk, hookErr = pcall(onDefeatCharacter, ...)
            if not hookOk then log("defeat hook failed: " .. tostring(hookErr)) end
        end)
    end)
    if not ok then
        log("ERROR: defeat signature hook unavailable: " .. tostring(err))
        return false
    end
    defeatHookRegistered = true
    log("defeat signature hook registered: " .. DEFEAT_SIGNATURE_HOOK)
    return true
end

local function bindDefeatDelegate(character)
    character = unwrap(character)
    if not valid(character) then return false end
    local key = objectAddress(character)
    if not key or boundCharacters[key] then return true end

    local delegate = member(character, "OnDefeatCharacterDelegate")
    if delegate == nil then
        if bindTraceLeft > 0 then
            bindTraceLeft = bindTraceLeft - 1
            log("defeat delegate unavailable on player " .. tostring(key))
        end
        return false
    end

    local ok, err = pcall(function()
        delegate:Add(character, DEFEAT_SIGNATURE_FUNCTION)
    end)
    if not ok then
        if bindTraceLeft > 0 then
            bindTraceLeft = bindTraceLeft - 1
            log("defeat delegate bind failed: " .. tostring(err))
        end
        return false
    end

    boundCharacters[key] = true
    local identity = playerIdentity(character)
    log("defeat delegate bound: " .. (identity and identity.name or key))
    return true
end

ensureDefeatHook()

local initHookOk, initHookErr = pcall(function()
    RegisterHook(INIT_HOOK, function(...)
        local args = { ... }
        local character = unwrap(args[1])
        local ok, err = pcall(bindDefeatDelegate, character)
        if not ok then log("player init binding failed: " .. tostring(err)) end
    end)
end)
if initHookOk then
    log("player init hook registered: " .. INIT_HOOK)
else
    log("ERROR: player init hook unavailable: " .. tostring(initHookErr))
end

local deathHookOk, deathHookErr = pcall(function()
    RegisterHook(DEATH_HOOK, function(...)
        local ok, err = pcall(onPlayerDeath, ...)
        if not ok then log("player death hook failed: " .. tostring(err)) end
    end)
end)
if deathHookOk then
    log("player death hook registered: " .. DEATH_HOOK)
else
    log("ERROR: player death hook unavailable: " .. tostring(deathHookErr))
end

log("v" .. MOD_VERSION .. " loaded")
log("IPC: " .. ipcDir)
log("Mode: event hooks only; no polling")
