-- PalPanelServerMods v0.1.0
-- Isolated server-side UE4SS action mod. No client install required.

local MOD_NAME = "PalPanelServerMods"
local MOD_VERSION = "0.1.0"

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

local function member(value, name)
    if value == nil then return nil end
    local ok, field = pcall(function() return value[name] end)
    if ok then return field end
    return nil
end

local function playerName(ps)
    return toText(member(ps, "PlayerNamePrivate")) or toText(member(ps, "SavedPlayerName")) or "Unbekannt"
end

local ZERO_UID = string.rep("0", 32)
local function hex32(word)
    return string.format("%08X", (tonumber(word) or 0) % 0x100000000)
end
local function playerUid(ps)
    if not valid(ps) then return "" end
    local guid = member(ps, "PlayerUId")
    if guid == nil then return "" end
    local ok, text = pcall(function()
        return hex32(guid.A) .. hex32(guid.B) .. hex32(guid.C) .. hex32(guid.D)
    end)
    if ok and text and text ~= ZERO_UID then return text end
    return ""
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

local function eventPulse(id, params)
    local itemId = tostring(params.item or "PalSphere")
    local qty = math.tointeger(tonumber(params.count or "1") or 0)
    if not itemId:match("^[%w_]+$") then return writeResponse(id, false, "invalid item id") end
    if not qty or qty < 1 or qty > 20 then return writeResponse(id, false, "count must be between 1 and 20") end

    local states = nil
    local okStates, errStates = pcall(function() states = FindAllOf("PalPlayerState") end)
    if not okStates or type(states) ~= "table" then
        return writeResponse(id, false, "PalPlayerState unavailable: " .. tostring(errStates or "not found"))
    end

    ExecuteInGameThread(function()
        local delivered = 0
        local failed = 0
        local seen = {}
        for _, ps in ipairs(states) do
            if valid(ps) then
                local uid = playerUid(ps)
                local dedupeKey = uid ~= "" and uid or string.lower(playerName(ps))
                if dedupeKey ~= "" and not seen[dedupeKey] then
                    seen[dedupeKey] = true
                    local invOk, inventory = pcall(function() return ps:GetInventoryData() end)
                    if invOk and inventory then
                        local addOk, result = pcall(function()
                            return inventory:AddItem_ServerInternal(FName(itemId), qty, false, 0.0, true)
                        end)
                        if addOk then
                            delivered = delivered + 1
                            log(string.format("event pulse -> %s: %d x %s (result=%s)", playerName(ps), qty, itemId, tostring(result)))
                        else
                            failed = failed + 1
                        end
                    else
                        failed = failed + 1
                    end
                end
            end
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
        "capabilities=heartbeat,ping,event_pulse",
        "client_install_required=0"
    }, "\n") .. "\n")
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

log("v" .. MOD_VERSION .. " loaded")
log("IPC: " .. ipcDir)
log("Capabilities: heartbeat, ping, event_pulse")
log("Client installation required: NO")
