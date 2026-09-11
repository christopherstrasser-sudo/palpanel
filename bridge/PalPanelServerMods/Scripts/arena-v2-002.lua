-- PalPanelServerMods Arena v2 step 1 / v0.1.0
-- SERVER-ONLY / NO CLIENT MOD.
--
-- Minimal authoritative keep-in boundary.
-- No visuals, NPCs, collision edits, AI edits, actor spawns or RPC calls.
-- The only world mutation is K2_TeleportTo on a recorded raid participant
-- after that player moves beyond the configured arena radius.

local MOD = "PalPanelArenaV2"
local VERSION = "0.1.0"
local TICK_MS = 250
local RADIUS = 3500.0
local RETURN_RADIUS = 3200.0

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
    return toText(member(ps, "PlayerNamePrivate"))
        or toText(member(ps, "SavedPlayerName"))
        or "Unbekannt"
end

local function playerUid(ps)
    if not valid(ps) then return "" end
    return guidHex(member(ps, "PlayerUId"))
end

local function playerPawn(ps)
    if not valid(ps) then return nil end
    local pc = nil
    pcall(function() pc = ps:GetPlayerController() end)
    pc = unwrap(pc)
    if not valid(pc) then pc = member(ps, "Owner") end
    if not valid(pc) then return nil end

    local pawn = member(pc, "Pawn")
    if valid(pawn) then return pawn end
    pcall(function() pawn = pc:GetPawn() end)
    pawn = unwrap(pawn)
    return valid(pawn) and pawn or nil
end

local function actorLocation(actor)
    if not valid(actor) then return nil end
    local at = nil
    pcall(function() at = actor:K2_GetActorLocation() end)
    if not at then return nil end
    return {
        X = tonumber(at.X) or 0,
        Y = tonumber(at.Y) or 0,
        Z = tonumber(at.Z) or 0
    }
end

local function onlinePlayers()
    local states = nil
    pcall(function() states = FindAllOf("PalPlayerState") end)
    if type(states) ~= "table" then return {} end

    local rows, seen = {}, {}
    for _, raw in ipairs(states) do
        local ps = unwrap(raw)
        if valid(ps) then
            local pawn = playerPawn(ps)
            if valid(pawn) then
                local name = playerName(ps)
                local uid = playerUid(ps)
                local key = uid ~= "" and uid or string.lower(name)
                if key ~= "" and not seen[key] then
                    local at = actorLocation(pawn)
                    if at then
                        seen[key] = true
                        rows[#rows + 1] = {
                            uid = uid,
                            name = name,
                            pawn = pawn,
                            at = at
                        }
                    end
                end
            end
        end
    end
    return rows
end

local scriptsDir = scriptDir()
if not scriptsDir then log("Scripts directory unavailable; Arena v2 step 1 disabled"); return end
local modDir = scriptsDir:match("^(.+)\\Scripts$") or scriptsDir
local ipcDir = readAll(modDir .. "\\ipc_path.txt")
if ipcDir then ipcDir = ipcDir:gsub("[\r\n]+$", "") end
if not ipcDir or ipcDir == "" then log("ipc_path.txt unavailable; Arena v2 step 1 disabled"); return end

local raidStatusFile = ipcDir .. "\\raid-status.txt"
local arenaStatusFile = ipcDir .. "\\raid-arena-v2-status.txt"

local currentRaidId = ""
local active = false
local center = nil
local centerFrozenAt = 0
local participants = {}
local participantNames = {}
local teleports = 0
local teleportFailures = 0
local lastState = "IDLE"
local lastError = ""
local scheduled = false

local function resetForRaid(raidId)
    currentRaidId = tostring(raidId or "")
    active = false
    center = nil
    centerFrozenAt = 0
    participants = {}
    participantNames = {}
    teleports = 0
    teleportFailures = 0
    lastState = "IDLE"
    lastError = ""
end

local function participantCount()
    local n = 0
    for _ in pairs(participants) do n = n + 1 end
    return n
end

local function addParticipant(uid, name)
    uid = tostring(uid or "")
    name = tostring(name or "")
    if uid ~= "" then
        participants["uid:" .. string.upper(uid)] = true
        participantNames["uid:" .. string.upper(uid)] = name ~= "" and name or uid
    end
    if name ~= "" then
        participants["name:" .. string.lower(name)] = true
        participantNames["name:" .. string.lower(name)] = name
    end
end

local function mergeParticipants(raid)
    addParticipant("", raid.anchor_name or "")
    local count = math.max(0, math.min(100, math.floor(tonumber(raid.participants) or 0)))
    for i = 1, count do
        addParticipant(raid["participant_" .. i .. "_uid"], raid["participant_" .. i .. "_name"])
    end
end

local function isParticipant(player)
    if player.uid ~= "" and participants["uid:" .. string.upper(player.uid)] then return true end
    return participants["name:" .. string.lower(player.name or "")] == true
end

local function writeStatus()
    local c = center or { X = 0, Y = 0, Z = 0 }
    local lines = {
        "version=" .. VERSION,
        "time=" .. tostring(os.time()),
        "raid_id=" .. urlEncode(currentRaidId),
        "raid_state=" .. urlEncode(lastState),
        "active=" .. (active and "1" or "0"),
        "center_frozen=" .. (center and "1" or "0"),
        "center_x=" .. tostring(c.X or 0),
        "center_y=" .. tostring(c.Y or 0),
        "center_z=" .. tostring(c.Z or 0),
        "center_frozen_at=" .. tostring(centerFrozenAt),
        "radius=" .. tostring(math.floor(RADIUS)),
        "return_radius=" .. tostring(math.floor(RETURN_RADIUS)),
        "participant_count=" .. tostring(participantCount()),
        "keep_in_teleports=" .. tostring(teleports),
        "keep_in_failures=" .. tostring(teleportFailures),
        "backend=arena_v2_minimal_keep_in",
        "world_mutation=participant_teleport_only",
        "actor_spawn=0",
        "npc_spawn=0",
        "collision_mutation=0",
        "ai_mutation=0",
        "rpc_calls=0",
        "visual_effects=0",
        "client_install_required=0",
        "last_error=" .. urlEncode(lastError)
    }
    writeAll(arenaStatusFile, table.concat(lines, "\n") .. "\n")
end

local function enforceKeepIn(raid)
    if not center then return end
    mergeParticipants(raid)

    for _, player in ipairs(onlinePlayers()) do
        if isParticipant(player) then
            local dx = (player.at.X or 0) - center.X
            local dy = (player.at.Y or 0) - center.Y
            local dist = math.sqrt(dx * dx + dy * dy)
            if dist > RADIUS then
                local nx, ny = 1.0, 0.0
                if dist > 0.001 then nx, ny = dx / dist, dy / dist end
                local target = {
                    X = center.X + nx * RETURN_RADIUS,
                    Y = center.Y + ny * RETURN_RADIUS,
                    Z = player.at.Z
                }
                local ok, result = pcall(function()
                    return player.pawn:K2_TeleportTo(target, { Pitch = 0, Yaw = 0, Roll = 0 })
                end)
                if ok and result ~= false then
                    teleports = teleports + 1
                    log(string.format("keep-in -> %s (%.0f -> %.0f)", player.name, dist, RETURN_RADIUS))
                else
                    teleportFailures = teleportFailures + 1
                    lastError = "keep-in teleport failed for " .. tostring(player.name) .. ": " .. tostring(result)
                    log(lastError)
                end
            end
        end
    end
end

local function tick()
    local raw = readAll(raidStatusFile)
    local raid = raw and parseKv(raw) or { state = "IDLE", active = "0", raid_id = "" }
    local raidId = tostring(raid.raid_id or "")

    if raidId ~= currentRaidId then resetForRaid(raidId) end

    lastState = tostring(raid.state or "IDLE")
    local nowActive = raid.active == "1" and lastState == "ACTIVE" and raidId ~= ""

    if nowActive and not center then
        center = {
            X = tonumber(raid.x) or 0,
            Y = tonumber(raid.y) or 0,
            Z = tonumber(raid.z) or 0
        }
        centerFrozenAt = os.time()
        mergeParticipants(raid)
        log(string.format("step 1 armed: center %.1f %.1f %.1f radius %.0f", center.X, center.Y, center.Z, RADIUS))
    end

    active = nowActive
    if nowActive then
        ExecuteInGameThread(function()
            local ok, err = xpcall(function() enforceKeepIn(raid) end, debug.traceback)
            if not ok then
                lastError = tostring(err)
                log("keep-in tick failed: " .. lastError)
            end
        end)
    elseif raidId == "" then
        center = nil
        centerFrozenAt = 0
        participants = {}
        participantNames = {}
    end

    writeStatus()
end

local function schedule()
    if scheduled then return end
    scheduled = true
    local function loop()
        local ok, err = xpcall(tick, debug.traceback)
        if not ok then
            lastError = tostring(err)
            log("step 1 tick failed: " .. lastError)
        end
        ExecuteWithDelay(TICK_MS, loop)
    end
    ExecuteWithDelay(TICK_MS, loop)
end

resetForRaid("")
writeStatus()
schedule()
log("v" .. VERSION .. " loaded; Arena v2 minimal keep-in ready")
