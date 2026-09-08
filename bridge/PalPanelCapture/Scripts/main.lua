-- PalPanelCapture v0.1.0
-- Isolated server-side capture observer for PalPanel.
-- Intentionally separate from PalPanelBridge so experimental capture hooks cannot
-- destabilize the proven heartbeat / give_item path.

local MOD_NAME = "PalPanelCapture"
local MOD_VERSION = "0.1.0"

local THROW_HOOK = "/Script/Pal.PalPlayerController:SetupInternalForSphere_ToServer"
local SUCCESS_HOOKS = {
    "/Game/Pal/Blueprint/Weapon/Other/NewPalSphere/BP_PalCaptureBodyBase.BP_PalCaptureBodyBase_C:OnSuccessedCapture",
    "/Game/Pal/Blueprint/Weapon/Other/NewPalSphere/BP_PalCaptureBodyBase.BP_PalCaptureBodyBase_C:OnSuccessedCapture__DelegateSignature"
}

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

local eventsDir = ipcDir .. "\\events"
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
    if object == nil then return false end
    local addressOk, address = pcall(function() return object:GetAddress() end)
    if addressOk and tonumber(address) == 0 then return false end
    local ok, result = pcall(function() return object:IsValid() end)
    return ok and result == true
end

local function fullName(object)
    if not valid(object) then return "" end
    local ok, value = pcall(function() return object:GetFullName() end)
    if ok and type(value) == "string" then return value end
    return ""
end

local function objectAddress(object)
    if not valid(object) then return nil end
    local ok, value = pcall(function() return object:GetAddress() end)
    local n = ok and tonumber(value) or nil
    if not n or n == 0 then return nil end
    return string.format("%X", n)
end

local function toText(value)
    if value == nil then return nil end
    if type(value) == "string" then return value end
    local ok, text = pcall(function() return value:ToString() end)
    if ok and type(text) == "string" and text ~= "" then return text end
    return nil
end

local ZERO_GUID = string.rep("0", 32)
local function asInt(value)
    if type(value) == "number" then return math.floor(value) end
    local ok, inner = pcall(function() return value:get() end)
    if ok and type(inner) == "number" then return math.floor(inner) end
    return nil
end

local function guidHex(guid)
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

local function playerUid(playerState)
    if not valid(playerState) then return "" end
    return guidHex(member(playerState, "PlayerUId"))
end

local function playerName(playerState)
    if not valid(playerState) then return nil end
    local name = toText(member(playerState, "PlayerNamePrivate"))
    if not name or name == "" then name = toText(member(playerState, "SavedPlayerName")) end
    return name
end

local function playerStateFromController(controller)
    if not valid(controller) then return nil end

    local state = member(controller, "PlayerState")
    if valid(state) then return state end

    local ok, result = pcall(function() return controller:GetPlayerState() end)
    if ok and valid(result) then return result end
    return nil
end

local function normalizeSpecies(raw)
    return tostring(raw or ""):gsub("^BOSS_", ""):gsub("^Boss_", "")
end

local function asFlag(value)
    if type(value) == "boolean" then return value end
    if type(value) == "number" and (value == 0 or value == 1) then return value == 1 end
    return nil
end

local function urlEncode(value)
    value = tostring(value or "")
    return (value:gsub("([^%w%-%._~])", function(c)
        return string.format("%%%02X", string.byte(c))
    end))
end

local eventCounter = 0
local emitted = {}
local emittedOrder = {}

local function rememberEmitted(eventId)
    if emitted[eventId] then return false end
    emitted[eventId] = true
    emittedOrder[#emittedOrder + 1] = eventId
    if #emittedOrder > 256 then
        emitted[table.remove(emittedOrder, 1)] = nil
    end
    return true
end

local function writeCaptureEvent(fields)
    if not rememberEmitted(fields.eventId) then return true end

    eventCounter = eventCounter + 1
    local body = table.concat({
        "event_id=" .. urlEncode(fields.eventId),
        "type=capture",
        "player_uid=" .. urlEncode(fields.uid),
        "player_name=" .. urlEncode(fields.playerName or ""),
        "species=" .. urlEncode(fields.species),
        "raw_species=" .. urlEncode(fields.rawSpecies or fields.species),
        "capture_count=0",
        "level=" .. tostring(math.floor(tonumber(fields.level) or 0)),
        "unique_npc=",
        "rare=" .. (fields.rare and "1" or "0"),
        "alpha=" .. (fields.alpha and "1" or "0"),
        "pal_id=" .. urlEncode(fields.palId or ""),
        "source=" .. urlEncode(fields.source or "PalCaptureBody.OnSuccessedCapture"),
        "time=" .. tostring(os.time())
    }, "\n") .. "\n"

    local fileName = string.format("capture_%d_%06d.evt", os.time(), eventCounter)
    local ok = writeAll(eventsDir .. "\\" .. fileName, body)
    if ok then
        log(string.format("CAPTURE: %s -> %s%s", fields.playerName or fields.uid, fields.species,
            fields.alpha and " [ALPHA]" or ""))
    else
        emitted[fields.eventId] = nil
        log("capture event write failed")
    end
    return ok
end

-- Store only plain strings, never UObject wrappers. This avoids retaining a
-- controller/player-state after disconnect or a sphere after it is destroyed.
local sphereOwners = {}
local sphereOrder = {}
local throwTraceLeft = 8

local function rememberSphere(sphere, owner)
    local key = objectAddress(sphere)
    if not key then return false end
    if sphereOwners[key] == nil then
        sphereOrder[#sphereOrder + 1] = key
        if #sphereOrder > 128 then sphereOwners[table.remove(sphereOrder, 1)] = nil end
    end
    sphereOwners[key] = owner
    return true
end

local function findSphere(...)
    for index = 1, select("#", ...) do
        local value = unwrap(select(index, ...))
        if valid(value) then
            local name = fullName(value)
            if name:find("PalSphere", 1, true) or name:find("PalCaptureBody", 1, true) then
                return value
            end
        end
    end
    return nil
end

local successHookCount = 0
local successHookTried = false

local function parameterFromHandle(handle)
    if not valid(handle) then return nil end
    local ok, parameter = pcall(function() return handle:TryGetIndividualParameter() end)
    if ok and valid(parameter) then return parameter end
    return nil
end

local function speciesFromParameter(parameter)
    if not valid(parameter) then return nil end
    local ok, characterId = pcall(function() return parameter:GetCharacterID() end)
    if ok then
        local text = toText(characterId)
        if text and text ~= "" and text ~= "None" then return text end
    end
    return nil
end

local function levelFromParameter(parameter)
    local ok, value = pcall(function() return parameter:GetLevel() end)
    if ok and type(value) == "number" then return math.floor(value) end
    return 0
end

local function rareFromParameter(parameter)
    for _, method in ipairs({ "IsRarePal", "GetIsRarePal" }) do
        local ok, value = pcall(function() return parameter[method](parameter) end)
        if ok and type(value) == "boolean" then return value end
    end
    return false
end

local function alphaFromHandle(handle, rawSpecies)
    if tostring(rawSpecies or ""):match("^BOSS_") or tostring(rawSpecies or ""):match("^Boss_") then
        return true
    end

    local ok, actor = pcall(function() return handle:TryGetIndividualActor() end)
    if not ok or not valid(actor) then return false end
    local static = member(actor, "StaticCharacterParameterComponent")
    if not valid(static) then return false end

    for _, field in ipairs({ "IsBoss_Database", "IsTowerBoss_Database", "IsPredatorBoss_Database", "IsRaidBoss_Database" }) do
        if asFlag(member(static, field)) == true then return true end
    end
    return false
end

local function palIdFromHandle(handle)
    local ok, id = pcall(function() return handle:GetIndividualID() end)
    if not ok or id == nil then return "" end
    return guidHex(member(id, "InstanceId"))
end

local function onCaptureSuccess(context, targetHandleParam)
    local sphere = unwrap(context)
    local sphereKey = objectAddress(sphere)
    if not sphereKey then
        log("capture success ignored: sphere address unavailable")
        return
    end

    local owner = sphereOwners[sphereKey]
    if not owner then
        log("capture success ignored: no player mapped for sphere " .. sphereKey)
        return
    end

    local handle = unwrap(targetHandleParam)
    local parameter = parameterFromHandle(handle)
    if not parameter then
        log("capture success ignored: target parameter unavailable")
        return
    end

    local rawSpecies = speciesFromParameter(parameter)
    if not rawSpecies then
        log("capture success ignored: CharacterID unavailable")
        return
    end

    local palId = palIdFromHandle(handle)
    local species = normalizeSpecies(rawSpecies)
    local eventId = palId ~= ""
        and ("capture:" .. owner.uid .. ":pal:" .. palId)
        or ("capture:" .. owner.uid .. ":sphere:" .. sphereKey .. ":" .. tostring(os.time()))

    writeCaptureEvent({
        eventId = eventId,
        uid = owner.uid,
        playerName = owner.name,
        species = species,
        rawSpecies = rawSpecies,
        level = levelFromParameter(parameter),
        rare = rareFromParameter(parameter),
        alpha = alphaFromHandle(handle, rawSpecies),
        palId = palId,
        source = "BP_PalCaptureBodyBase.OnSuccessedCapture"
    })
end

local function ensureSuccessHooks()
    if successHookCount > 0 then return end
    -- The blueprint class does not exist during early server boot. We therefore
    -- register only after a real sphere throw, when the asset is known to be loaded.
    successHookTried = true
    local registered = 0
    for _, path in ipairs(SUCCESS_HOOKS) do
        local ok, err = pcall(function()
            RegisterHook(path, function(...)
                local hookOk, hookErr = pcall(onCaptureSuccess, ...)
                if not hookOk then log("capture success hook failed: " .. tostring(hookErr)) end
            end)
        end)
        if ok then
            registered = registered + 1
            log("success hook registered: " .. path)
        else
            log("success hook unavailable: " .. path .. " -> " .. tostring(err))
        end
    end
    successHookCount = registered
    log("Capture success hooks active: " .. tostring(registered) .. "/" .. tostring(#SUCCESS_HOOKS))
end

local function onSphereThrow(context, idParam, sphereParam, targetCharacterParam)
    local controller = unwrap(context)
    local sphere = unwrap(sphereParam)
    if not valid(sphere) then sphere = findSphere(idParam, sphereParam, targetCharacterParam) end
    if not valid(controller) or not valid(sphere) then
        if throwTraceLeft > 0 then
            throwTraceLeft = throwTraceLeft - 1
            log("sphere throw seen but controller/sphere could not be resolved")
        end
        return
    end

    local state = playerStateFromController(controller)
    local uid = playerUid(state)
    if uid == "" then
        if throwTraceLeft > 0 then
            throwTraceLeft = throwTraceLeft - 1
            log("sphere throw seen but PlayerUId is unavailable")
        end
        return
    end

    local name = playerName(state) or uid
    if rememberSphere(sphere, { uid = uid, name = name, at = os.time() }) and throwTraceLeft > 0 then
        throwTraceLeft = throwTraceLeft - 1
        log("sphere mapped: " .. name .. " -> " .. tostring(objectAddress(sphere)))
    end

    ensureSuccessHooks()
end

local throwHookOk, throwHookErr = pcall(function()
    RegisterHook(THROW_HOOK, function(...)
        local ok, err = pcall(onSphereThrow, ...)
        if not ok then log("sphere throw hook failed: " .. tostring(err)) end
    end)
end)

if throwHookOk then
    log("throw hook registered: " .. THROW_HOOK)
else
    log("ERROR: throw hook unavailable: " .. tostring(throwHookErr))
end

log("v" .. MOD_VERSION .. " loaded")
log("IPC: " .. ipcDir)
log("Mode: event hooks only; no polling")
log("Success hook registration: lazy after first sphere throw")
