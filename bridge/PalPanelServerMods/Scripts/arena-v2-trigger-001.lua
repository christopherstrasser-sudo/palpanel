-- PalPanelServerMods Arena v2 first-hit trigger / v0.1.0
-- SERVER-ONLY / NO CLIENT MOD.
--
-- The arena must not exist merely because a raid boss is ACTIVE. This module
-- listens to the same authoritative Palworld damage event as the raid runtime,
-- verifies that the damaged actor is the exact raid boss by Individual InstanceId,
-- and only then arms the arena. The boss is moved once back to the published
-- raid center before the trigger file is released to the arena/visual modules.
--
-- No AI mutation, collision mutation, Niagara or custom RPCs.

local MOD = "PalPanelArenaV2Trigger"
local VERSION = "0.1.0"
local DAMAGE_HOOK = "/Script/Pal.PalEventNotify_Character:OnCharacterDamaged_ServerInternal"

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

local function actorInstanceId(actor)
    if not valid(actor) then return "" end
    local component = member(actor, "CharacterParameterComponent")
    if not valid(component) then return "" end

    local handle = member(component, "IndividualHandle")
    if valid(handle) then
        local id = nil
        pcall(function() id = handle:GetIndividualID() end)
        id = unwrap(id)
        local instance = guidHex(member(id, "InstanceId"))
        if instance ~= "" then return instance end
    end

    local parameter = member(component, "IndividualParameter")
    if valid(parameter) then
        local id = nil
        pcall(function() id = parameter:GetIndividualID() end)
        id = unwrap(id)
        local instance = guidHex(member(id, "InstanceId"))
        if instance ~= "" then return instance end
    end
    return ""
end

local scriptsDir = scriptDir()
if not scriptsDir then log("Scripts directory unavailable; trigger disabled"); return end
local modDir = scriptsDir:match("^(.+)\\Scripts$") or scriptsDir
local ipcDir = readAll(modDir .. "\\ipc_path.txt")
if ipcDir then ipcDir = ipcDir:gsub("[\r\n]+$", "") end
if not ipcDir or ipcDir == "" then log("ipc_path.txt unavailable; trigger disabled"); return end

local raidStatusFile = ipcDir .. "\\raid-status.txt"
local triggerFile = ipcDir .. "\\raid-arena-trigger.txt"

local currentRaidId = ""
local triggered = false
local triggerPending = false
local triggerAt = 0
local bossTeleportAttempted = false
local bossTeleportOk = false
local bossInstanceObserved = ""
local centerX, centerY, centerZ = 0, 0, 0
local lastError = ""

local function writeTrigger()
    writeAll(triggerFile, table.concat({
        "version=" .. VERSION,
        "time=" .. tostring(os.time()),
        "raid_id=" .. urlEncode(currentRaidId),
        "triggered=" .. (triggered and "1" or "0"),
        "trigger_pending=" .. (triggerPending and "1" or "0"),
        "triggered_at=" .. tostring(triggerAt),
        "boss_teleport_attempted=" .. (bossTeleportAttempted and "1" or "0"),
        "boss_teleport_ok=" .. (bossTeleportOk and "1" or "0"),
        "boss_instance_observed=" .. urlEncode(bossInstanceObserved),
        "center_x=" .. tostring(centerX),
        "center_y=" .. tostring(centerY),
        "center_z=" .. tostring(centerZ),
        "last_error=" .. urlEncode(lastError)
    }, "\n") .. "\n")
end

local function resetRaid(raidId)
    currentRaidId = tostring(raidId or "")
    triggered = false
    triggerPending = false
    triggerAt = 0
    bossTeleportAttempted = false
    bossTeleportOk = false
    bossInstanceObserved = ""
    centerX, centerY, centerZ = 0, 0, 0
    lastError = ""
    writeTrigger()
end

local function armArena(defender, raid)
    if triggered or triggerPending then return end
    triggerPending = true
    centerX = tonumber(raid.x) or 0
    centerY = tonumber(raid.y) or 0
    centerZ = tonumber(raid.z) or 0
    writeTrigger()

    ExecuteInGameThread(function()
        bossTeleportAttempted = true
        local target = { X = centerX, Y = centerY, Z = centerZ }
        local ok, result = pcall(function()
            return defender:K2_TeleportTo(target, { Pitch = 0, Yaw = 0, Roll = 0 })
        end)
        bossTeleportOk = ok and result ~= false
        if not bossTeleportOk then
            lastError = "boss arena-entry teleport failed: " .. tostring(result)
            log(lastError)
        end

        triggered = true
        triggerPending = false
        triggerAt = os.time()
        writeTrigger()
        log(string.format("FIRST HIT -> arena armed at %.0f %.0f %.0f; boss teleport=%s", centerX, centerY, centerZ, tostring(bossTeleportOk)))
    end)
end

local hookOk, hookErr = pcall(function()
    RegisterHook(DAMAGE_HOOK, function(_context, damageParam)
        local ok, err = xpcall(function()
            local raid = parseKv(readAll(raidStatusFile) or "")
            local raidId = tostring(raid.raid_id or "")
            if raidId ~= currentRaidId then resetRaid(raidId) end
            if raid.active ~= "1" or raid.state ~= "ACTIVE" or raidId == "" then return end
            if triggered or triggerPending then return end

            local result = unwrap(damageParam)
            if result == nil then return end
            local defender = member(result, "Defender")
            if not valid(defender) then return end

            local expected = string.upper(tostring(raid.boss_instance_id or ""))
            if expected == "" then return end
            local observed = string.upper(actorInstanceId(defender))
            bossInstanceObserved = observed
            if observed == "" or observed ~= expected then return end

            armArena(defender, raid)
        end, debug.traceback)
        if not ok then
            lastError = tostring(err)
            log("damage trigger failed: " .. lastError)
            writeTrigger()
        end
    end)
end)

if not hookOk then
    lastError = "RegisterHook failed: " .. tostring(hookErr)
    log(lastError)
end

resetRaid("")
log("v" .. VERSION .. " loaded; arena waits for first verified hit on the raid boss")
