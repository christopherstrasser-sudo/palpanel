-- PalPanelServerMods controller adapter v0.2.3
-- Temporarily swaps PalNPCManager.NPCAIControllerBaseClass to the real wild-pal
-- controller only while the proven raid runtime executes a SPAWNING game-thread task.
-- This keeps the 0.2.1 runtime untouched and restores the manager immediately after.

local MOD = "PalPanelRaidController"
local VERSION = "0.2.3"
local WILD_CONTROLLER = "/Game/Pal/Blueprint/Controller/Monster/BP_MonsterAIController_Wild.BP_MonsterAIController_Wild_C"

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

local function parseKv(raw)
    local out = {}
    for line in tostring(raw or ""):gmatch("[^\r\n]+") do
        local k, v = line:match("^([^=]+)=(.*)$")
        if k then
            v = tostring(v or ""):gsub("%+", " ")
            out[k] = (v:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end))
        end
    end
    return out
end

local function valid(obj)
    if obj == nil then return false end
    local ok, value = pcall(function() return obj:get() end)
    if ok and value ~= nil then obj = value end
    if obj == nil then return false end
    local addrOk, addr = pcall(function() return obj:GetAddress() end)
    if addrOk and tonumber(addr) == 0 then return false end
    local validOk, isValid = pcall(function() return obj:IsValid() end)
    return validOk and isValid == true
end

local function member(obj, name)
    if obj == nil then return nil end
    local ok, value = pcall(function() return obj[name] end)
    if not ok then return nil end
    local getOk, inner = pcall(function() return value:get() end)
    if getOk and inner ~= nil then return inner end
    return value
end

local scriptsDir = scriptDir()
if not scriptsDir then
    log("Scripts directory unavailable; adapter disabled")
    return
end
local modDir = scriptsDir:match("^(.+)\\Scripts$") or scriptsDir
local ipcDir = readAll(modDir .. "\\ipc_path.txt")
if ipcDir then ipcDir = ipcDir:gsub("[\r\n]+$", "") end
if not ipcDir or ipcDir == "" then
    log("ipc_path.txt unavailable; adapter disabled")
    return
end

local raidStatusFile = ipcDir .. "\\raid-status.txt"
local controllerStatusFile = ipcDir .. "\\raid-controller-status.txt"

local status = {
    patched = false,
    source = "none",
    applications = 0,
    lastError = ""
}

local function writeStatus()
    writeAll(controllerStatusFile, table.concat({
        "version=" .. VERSION,
        "time=" .. tostring(os.time()),
        "patched=" .. (status.patched and "1" or "0"),
        "source=" .. tostring(status.source or "none"),
        "applications=" .. tostring(status.applications or 0),
        "last_error=" .. tostring(status.lastError or "")
    }, "\n") .. "\n")
end

local function raidIsSpawning()
    local raw = readAll(raidStatusFile)
    if not raw then return false end
    local s = parseKv(raw)
    return s.active == "1" and s.state == "SPAWNING"
end

local cachedWildClass = nil
local function wildControllerClass()
    if valid(cachedWildClass) then return cachedWildClass end

    local ok, class = pcall(StaticFindObject, WILD_CONTROLLER)
    if ok and valid(class) then
        cachedWildClass = class
        status.source = "static_path"
        return class
    end

    local found, instance = pcall(FindFirstOf, "BP_MonsterAIController_Wild_C")
    if found and valid(instance) then
        local got, liveClass = pcall(function() return instance:GetClass() end)
        if got and valid(liveClass) then
            cachedWildClass = liveClass
            status.source = "live_wild_instance"
            return liveClass
        end
    end

    status.source = "unavailable"
    return nil
end

local function anyPlayerController()
    local states = nil
    pcall(function() states = FindAllOf("PalPlayerState") end)
    if type(states) ~= "table" then return nil end
    for _, ps in ipairs(states) do
        if valid(ps) then
            local pc = nil
            pcall(function() pc = ps:GetPlayerController() end)
            if valid(pc) then return pc end
            pc = member(ps, "Owner")
            if valid(pc) then return pc end
        end
    end
    return nil
end

local function npcManager()
    local pc = anyPlayerController()
    if not valid(pc) then return nil end
    local util = nil
    pcall(function() util = StaticFindObject("/Script/Pal.Default__PalUtility") end)
    if not valid(util) then return nil end
    local manager = nil
    pcall(function() manager = util:GetNPCManager(pc) end)
    local getOk, inner = pcall(function() return manager:get() end)
    if getOk and inner ~= nil then manager = inner end
    return valid(manager) and manager or nil
end

local originalExecuteInGameThread = ExecuteInGameThread
if type(originalExecuteInGameThread) ~= "function" then
    status.lastError = "ExecuteInGameThread is not replaceable"
    writeStatus()
    log(status.lastError)
    return
end

_G.ExecuteInGameThread = function(callback)
    return originalExecuteInGameThread(function()
        local manager, originalClass, swapped = nil, nil, false

        if raidIsSpawning() then
            local wildClass = wildControllerClass()
            manager = npcManager()
            if valid(wildClass) and valid(manager) then
                originalClass = member(manager, "NPCAIControllerBaseClass")
                local ok, err = pcall(function()
                    manager.NPCAIControllerBaseClass = wildClass
                end)
                if ok then
                    swapped = true
                    status.patched = true
                    status.applications = status.applications + 1
                    status.lastError = ""
                    log("wild raid controller armed for spawning task (" .. status.source .. ")")
                else
                    status.lastError = "controller swap failed: " .. tostring(err)
                    log(status.lastError)
                end
                writeStatus()
            elseif not valid(wildClass) then
                status.lastError = "wild controller class unavailable"
                writeStatus()
            elseif not valid(manager) then
                status.lastError = "NPC manager unavailable"
                writeStatus()
            end
        end

        local ok, err = xpcall(callback, debug.traceback)

        if swapped and valid(manager) and valid(originalClass) then
            local restoreOk, restoreErr = pcall(function()
                manager.NPCAIControllerBaseClass = originalClass
            end)
            if not restoreOk then
                status.lastError = "controller restore failed: " .. tostring(restoreErr)
                log(status.lastError)
            end
        end

        status.patched = false
        writeStatus()
        if not ok then error(err, 0) end
    end)
end

writeStatus()
log("v" .. VERSION .. " loaded; wild controller path ready")