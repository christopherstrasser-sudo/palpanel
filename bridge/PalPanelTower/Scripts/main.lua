-- PalPanelTower v0.1.0
-- Dedicated-server Tower Boss completion observer.
-- Isolated from PalPanelBridge / PalPanelCapture / PalPanelGameplay.

local MOD_NAME = "PalPanelTower"
local MOD_VERSION = "0.1.0"
local TOWER_SUCCESS_HOOK = "/Script/Pal.PalBossBattleInstanceModel:GiftSuccessItem_OnePlayer"

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
local emitted = {}

local function writeBossEvent(identity, bossKey, bossPalId, bossType, level)
    local eventId = "towerboss:" .. identity.uid .. ":" .. bossKey
    if emitted[eventId] then return true end
    emitted[eventId] = true

    eventCounter = eventCounter + 1
    local body = table.concat({
        "event_id=" .. urlEncode(eventId),
        "type=boss",
        "player_uid=" .. urlEncode(identity.uid),
        "player_name=" .. urlEncode(identity.name or ""),
        "boss_key=" .. urlEncode(bossKey),
        "species=" .. urlEncode(bossPalId or bossKey),
        "level=" .. tostring(math.max(0, math.floor(tonumber(level) or 0))),
        "pal_id=",
        "boss_type=" .. urlEncode(bossType or ""),
        "time=" .. tostring(os.time()),
        "source=PalBossBattleInstanceModel.GiftSuccessItem_OnePlayer"
    }, "\n") .. "\n"

    local fileName = string.format("tower_%d_%06d.evt", os.time(), eventCounter)
    if not writeAll(eventsDir .. "\\" .. fileName, body) then
        emitted[eventId] = nil
        log("tower boss event write failed")
        return false
    end

    log(string.format("TOWER CLEAR: %s -> %s", identity.name, bossKey))
    return true
end

local function bossInfo(model)
    local bossPalId = nil
    local bossTypeRaw = nil
    local level = nil

    pcall(function() bossPalId = toText(model:GetBossPalId()) end)
    if not bossPalId or bossPalId == "" or bossPalId == "None" then
        bossPalId = toText(member(model, "BossPalId"))
    end

    pcall(function() bossTypeRaw = unwrap(model:GetBossType()) end)
    if bossTypeRaw == nil then bossTypeRaw = unwrap(member(model, "BossType")) end

    pcall(function() level = model:GetLevel() end)
    if level == nil then level = unwrap(member(model, "Level")) end

    local bossTypeText = toText(bossTypeRaw)
    if not bossTypeText or bossTypeText == "" then
        local n = asInt(bossTypeRaw)
        if n ~= nil then bossTypeText = tostring(n) end
    end

    local bossKey
    if bossPalId and bossPalId ~= "" and bossPalId ~= "None" then
        bossKey = "Tower:" .. bossPalId
    elseif bossTypeText and bossTypeText ~= "" then
        bossKey = "TowerType:" .. bossTypeText
    else
        bossKey = "Tower:Unknown"
    end

    return bossKey, bossPalId, bossTypeText, asInt(level) or 0
end

local function onTowerSuccess(context, playerParam)
    local model = unwrap(context)
    local player = unwrap(playerParam)

    if not valid(model) then
        log("tower success ignored: instance model unavailable")
        return
    end
    if not valid(player) then
        log("tower success ignored: winning player unavailable")
        return
    end

    local identity = playerIdentity(player)
    if not identity then
        log("tower success ignored: player identity unavailable")
        return
    end

    local bossKey, bossPalId, bossType, level = bossInfo(model)
    writeBossEvent(identity, bossKey, bossPalId, bossType, level)
end

local hookOk, hookErr = pcall(function()
    RegisterHook(TOWER_SUCCESS_HOOK, function(...)
        local ok, err = pcall(onTowerSuccess, ...)
        if not ok then log("tower success hook failed: " .. tostring(err)) end
    end)
end)

if hookOk then
    log("tower success hook registered: " .. TOWER_SUCCESS_HOOK)
else
    log("ERROR: tower success hook unavailable: " .. tostring(hookErr))
end

log("v" .. MOD_VERSION .. " loaded")
log("IPC: " .. ipcDir)
log("Mode: Tower success event hook only; no polling")
