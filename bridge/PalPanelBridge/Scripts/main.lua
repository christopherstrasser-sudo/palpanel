-- PalPanelBridge v0.2.0
-- Server-side UE4SS Lua mod for local file-based IPC with PalPanel.
-- No network listener is opened by this mod.

local MOD_NAME = "PalPanelBridge"
local MOD_VERSION = "0.2.0"

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
    if root and root ~= "" then
        return root .. "\\data\\bridge-ipc"
    end
    return nil
end

local ipcDir = readAll(pathFile)
if ipcDir then ipcDir = ipcDir:gsub("[\r\n]+$", "") end

if not ipcDir or ipcDir == "" then
    ipcDir = deriveIpcDir()
    if not ipcDir then
        log("ERROR: ipc_path.txt missing and IPC path could not be derived from mod location")
        return
    end
    pcall(function() writeAll(pathFile, ipcDir .. "\r\n") end)
    log("ipc_path.txt missing; derived IPC path: " .. ipcDir)
end

local commandFile = ipcDir .. "\\command.txt"
local responseFile = ipcDir .. "\\response.txt"
local heartbeatFile = ipcDir .. "\\heartbeat.txt"
local processedDir = ipcDir .. "\\processed"
local eventsDir = ipcDir .. "\\events"

os.execute('mkdir "' .. ipcDir .. '" 2>nul')
os.execute('mkdir "' .. processedDir .. '" 2>nul')
os.execute('mkdir "' .. eventsDir .. '" 2>nul')

local function urlDecode(value)
    value = tostring(value or "")
    value = value:gsub("%+", " ")
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

local function writeResponse(id, ok, message)
    local body = table.concat({
        "id=" .. urlEncode(id),
        "ok=" .. (ok and "1" or "0"),
        "message=" .. urlEncode(message or "")
    }, "\n") .. "\n"
    writeAll(responseFile, body)
end

local function unwrap(param)
    if param == nil then return nil end
    local ok, value = pcall(function() return param:get() end)
    if ok then return value end
    return param
end

local function member(value, name)
    if value == nil then return nil end
    local ok, field = pcall(function() return value[name] end)
    if ok then return field end
    return nil
end

local function valid(object)
    if object == nil then return false end
    local ok, result = pcall(function() return object:IsValid() end)
    return ok and result == true
end

local function toText(value)
    if value == nil then return nil end
    if type(value) == "string" then return value end
    local ok, text = pcall(function() return value:ToString() end)
    if ok and type(text) == "string" and text ~= "" then return text end
    return nil
end

local function playerName(ps)
    local name = toText(member(ps, "PlayerNamePrivate"))
    if not name or name == "" then name = toText(member(ps, "SavedPlayerName")) end
    return name
end

local ZERO_UID = string.rep("0", 32)
local function hex32(word)
    return string.format("%08X", (tonumber(word) or 0) % 0x100000000)
end

local function guidHex(guid)
    if guid == nil then return "" end
    local ok, text = pcall(function()
        return hex32(guid.A) .. hex32(guid.B) .. hex32(guid.C) .. hex32(guid.D)
    end)
    if ok and text ~= ZERO_UID then return text end
    return ""
end

local function playerUid(ps)
    if not valid(ps) then return "" end
    return guidHex(member(ps, "PlayerUId"))
end

local function findPlayerExact(target)
    local states = nil
    pcall(function() states = FindAllOf("PalPlayerState") end)
    if not states then return nil end
    local wanted = string.lower(tostring(target or ""))
    for _, ps in ipairs(states) do
        if valid(ps) then
            local name = playerName(ps)
            if name and string.lower(name) == wanted then return ps, name end
        end
    end
    return nil
end

local function safeId(id)
    return tostring(id or ""):gsub("[^%w%-%_]", "")
end

local function processedPath(id)
    return processedDir .. "\\" .. safeId(id) .. ".ok"
end

local function markProcessed(id, message)
    writeAll(processedPath(id), tostring(message or "ok"))
end

local function alreadyProcessed(id)
    return readAll(processedPath(id)) ~= nil
end

local function palParameter(character)
    if not valid(character) then return nil end
    local component = member(character, "CharacterParameterComponent")
    if not valid(component) then return nil end
    local parameter = member(component, "IndividualParameter")
    if valid(parameter) then return parameter end
    local ok, got = pcall(function() return component:GetIndividualParameter() end)
    if ok and valid(got) then return got end
    return nil
end

local function parameterFromHandle(handle)
    if not valid(handle) then return nil end
    local ok, parameter = pcall(function() return handle:TryGetIndividualParameter() end)
    if ok and valid(parameter) then return parameter end
    ok, parameter = pcall(function() return handle:GetIndividualParameter() end)
    if ok and valid(parameter) then return parameter end
    return nil
end

local function palIdOf(parameter)
    if not valid(parameter) then return "" end
    local individual = member(parameter, "IndividualId")
    if individual == nil then return "" end
    return guidHex(member(individual, "InstanceId"))
end

local function stateFromCharacter(character)
    if not valid(character) then return nil end
    local state = member(character, "PlayerState")
    if valid(state) then return state end

    local controller = member(character, "Controller")
    if valid(controller) then
        state = member(controller, "PlayerState")
        if valid(state) then return state end
    end

    local component = member(character, "CharacterParameterComponent")
    local trainer = valid(component) and member(component, "Trainer") or nil
    if valid(trainer) then
        state = member(trainer, "PlayerState")
        if valid(state) then return state end
        controller = member(trainer, "Controller")
        if valid(controller) then
            state = member(controller, "PlayerState")
            if valid(state) then return state end
        end
    end
    return nil
end

local captureEventCounter = 0
local function emitCaptureEvent(ps, parameter, source)
    if not valid(ps) or not valid(parameter) then return false end

    local uid = playerUid(ps)
    if uid == "" then return false end

    local save = member(parameter, "SaveParameter")
    if save == nil then return false end
    local rawSpecies = toText(member(save, "CharacterID"))
    if not rawSpecies or rawSpecies == "" or rawSpecies == "None" then return false end

    local alpha = false
    if rawSpecies:match("^BOSS_") or rawSpecies:match("^Boss_") then alpha = true end
    if member(save, "IsBoss") == true or member(save, "IsAlpha") == true then alpha = true end

    local species = rawSpecies:gsub("^BOSS_", ""):gsub("^Boss_", "")
    local palId = palIdOf(parameter)
    captureEventCounter = captureEventCounter + 1
    local eventId
    if palId ~= "" then
        eventId = "capture:" .. uid .. ":" .. palId
    else
        eventId = string.format("capture:%s:%s:%d:%d", uid, species, os.time(), captureEventCounter)
    end

    local body = table.concat({
        "event_id=" .. urlEncode(eventId),
        "type=capture",
        "player_uid=" .. urlEncode(uid),
        "player_name=" .. urlEncode(playerName(ps) or ""),
        "species=" .. urlEncode(species),
        "raw_species=" .. urlEncode(rawSpecies),
        "alpha=" .. (alpha and "1" or "0"),
        "pal_id=" .. urlEncode(palId),
        "source=" .. urlEncode(source or "capture_hook"),
        "time=" .. tostring(os.time())
    }, "\n") .. "\n"

    local fileName = string.format("capture_%d_%06d.evt", os.time(), captureEventCounter)
    local ok = writeAll(eventsDir .. "\\" .. fileName, body)
    if ok then
        log(string.format("capture event: %s -> %s%s", playerName(ps) or uid, species, alpha and " [ALPHA]" or ""))
    end
    return ok
end

local function onCapturedCharacter(_, capturedParam, attackerParam)
    local captured = unwrap(capturedParam)
    local attacker = unwrap(attackerParam)
    if not valid(captured) then return end
    local parameter = palParameter(captured)
    if not valid(parameter) then return end
    local ps = stateFromCharacter(attacker)
    if not valid(ps) then return end
    emitCaptureEvent(ps, parameter, "PalCharacter.OnCapturedDelegate")
end

local function onPlayerCapture(context, handleParam)
    local ps = unwrap(context)
    local handle = unwrap(handleParam)
    if not valid(ps) or playerUid(ps) == "" then return end
    local parameter = parameterFromHandle(handle)
    if not valid(parameter) then return end
    emitCaptureEvent(ps, parameter, "PalPlayerState.CapturePalInServerDelegate")
end

local function registerCaptureHooks()
    local registered = 0
    local targets = {
        {
            "/Script/Pal.PalCharacter:OnCapturedDelegate__DelegateSignature",
            onCapturedCharacter
        },
        {
            "/Script/Pal.PalPlayerState:CapturePalInServerDelegate__DelegateSignature",
            onPlayerCapture
        }
    }

    for _, target in ipairs(targets) do
        local ok, err = pcall(function() RegisterHook(target[1], target[2]) end)
        if ok then
            registered = registered + 1
            log("capture hook registered: " .. target[1])
        else
            log("capture hook unavailable: " .. target[1] .. " -> " .. tostring(err))
        end
    end
    return registered
end

local function giveItem(id, params)
    local target = tostring(params.target or "")
    local itemId = tostring(params.item or "")
    local count = tonumber(params.count or "0") or 0
    local qty = math.tointeger(count)

    if target == "" then return writeResponse(id, false, "target missing") end
    if itemId == "" then return writeResponse(id, false, "item missing") end
    if not qty or qty < 1 or qty > 9999 then return writeResponse(id, false, "count must be an integer between 1 and 9999") end

    local ps, resolvedName = findPlayerExact(target)
    if not ps then return writeResponse(id, false, "player not found: " .. target) end

    local invOk, inventory = pcall(function() return ps:GetInventoryData() end)
    if not invOk or not inventory then return writeResponse(id, false, "inventory unavailable") end

    ExecuteInGameThread(function()
        local ok, result = pcall(function()
            return inventory:AddItem_ServerInternal(FName(itemId), qty, false, 0.0, true)
        end)
        if not ok then
            log("give_item failed: " .. tostring(result))
            writeResponse(id, false, "AddItem_ServerInternal failed: " .. tostring(result))
            return
        end
        local msg = string.format("gave %d x %s to %s (result=%s)", qty, itemId, resolvedName or target, tostring(result))
        markProcessed(id, msg)
        writeResponse(id, true, msg)
        log(msg)
    end)
end

local function processCommand(cmd)
    local id = tostring(cmd.id or "")
    local kind = tostring(cmd.type or "")
    if id == "" then return end

    if alreadyProcessed(id) then
        writeResponse(id, true, "already_processed")
        return
    end

    if kind == "ping" then
        markProcessed(id, "pong")
        return writeResponse(id, true, "pong")
    elseif kind == "give_item" then
        return giveItem(id, cmd)
    end

    writeResponse(id, false, "unknown command: " .. kind)
end

local function pollCommand()
    local content = readAll(commandFile)
    if not content or content == "" then return end
    os.remove(commandFile)
    local ok, cmd = pcall(parseKv, content)
    if not ok or not cmd then
        writeResponse("unknown", false, "invalid command")
        return
    end
    processCommand(cmd)
end

local function writeHeartbeat()
    local body = table.concat({
        "version=" .. urlEncode(MOD_VERSION),
        "time=" .. tostring(os.time()),
        "state=ready",
        "capabilities=heartbeat,give_item,capture_events"
    }, "\n") .. "\n"
    writeAll(heartbeatFile, body)
end

os.remove(commandFile)
os.remove(responseFile)
writeHeartbeat()

LoopAsync(500, function()
    local ok, err = pcall(pollCommand)
    if not ok then log("poll error: " .. tostring(err)) end
    return false
end)

LoopAsync(2000, function()
    pcall(writeHeartbeat)
    return false
end)

local hooks = registerCaptureHooks()
log("v" .. MOD_VERSION .. " loaded")
log("IPC: " .. ipcDir)
log("Capabilities: heartbeat, give_item, capture_events")
log("Capture hooks active: " .. tostring(hooks) .. "/2")