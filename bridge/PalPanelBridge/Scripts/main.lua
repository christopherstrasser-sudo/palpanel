-- PalPanelBridge v0.1.2
-- Server-side UE4SS Lua mod for local file-based IPC with PalPanel.
-- No network listener is opened by this mod.

local MOD_NAME = "PalPanelBridge"
local MOD_VERSION = "0.1.2"

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
    -- Standard PalPanel layout:
    -- C:\\PalPanel\\server\\Pal\\Binaries\\Win64\\Mods\\PalPanelBridge\\Scripts
    -- or an older nested UE4SS layout below Win64\\ue4ss.
    local root = scriptsDir:match("^(.-)\\server\\Pal\\Binaries\\Win64\\")
    if root and root ~= "" then
        return root .. "\\data\\bridge-ipc"
    end
    return nil
end

local ipcDir = readAll(pathFile)
if ipcDir then
    ipcDir = ipcDir:gsub("[\r\n]+$", "")
end

if not ipcDir or ipcDir == "" then
    ipcDir = deriveIpcDir()
    if not ipcDir then
        log("ERROR: ipc_path.txt missing and IPC path could not be derived from mod location")
        return
    end

    -- Self-heal the optional path file so future starts also have an explicit path.
    pcall(function()
        writeAll(pathFile, ipcDir .. "\r\n")
    end)
    log("ipc_path.txt missing; derived IPC path: " .. ipcDir)
end

local commandFile = ipcDir .. "\\command.txt"
local responseFile = ipcDir .. "\\response.txt"
local heartbeatFile = ipcDir .. "\\heartbeat.txt"
local processedDir = ipcDir .. "\\processed"

os.execute('mkdir "' .. ipcDir .. '" 2>nul')
os.execute('mkdir "' .. processedDir .. '" 2>nul')

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

local function playerName(ps)
    local name = nil
    pcall(function()
        if ps.PlayerNamePrivate then name = ps.PlayerNamePrivate:ToString() end
    end)
    if not name or name == "" then
        pcall(function()
            if ps.SavedPlayerName then name = ps.SavedPlayerName:ToString() end
        end)
    end
    return name
end

local function findPlayerExact(target)
    local states = nil
    pcall(function() states = FindAllOf("PalPlayerState") end)
    if not states then return nil end
    local wanted = string.lower(tostring(target or ""))
    for _, ps in ipairs(states) do
        local valid = false
        pcall(function() valid = ps:IsValid() end)
        if valid then
            local name = playerName(ps)
            if name and string.lower(name) == wanted then
                return ps, name
            end
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
    if not invOk or not inventory then
        return writeResponse(id, false, "inventory unavailable")
    end

    ExecuteInGameThread(function()
        local ok, result = pcall(function()
            -- Palworld 1.0 signature:
            -- AddItem_ServerInternal(FName StaticItemId, int32 Count,
            --   bool IsAssignPassive, float LogDelay, bool bNotifyLog)
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
        "state=ready"
    }, "\n") .. "\n"
    writeAll(heartbeatFile, body)
end

-- Remove only transient IPC files; processed markers intentionally survive restarts.
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
log("Capabilities: heartbeat, give_item")
