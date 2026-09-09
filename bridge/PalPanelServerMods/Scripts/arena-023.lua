-- PalPanelServerMods raid arena v0.2.3
-- Server-side arena lock. No client mod required.
-- Once combat engages (or the first participant damage is recorded), players
-- inside the raid radius are locked IN and all other players are locked OUT.

local MOD = "PalPanelRaidArena"
local VERSION = "0.2.3"
local RADIUS = 6000.0
local INNER_MARGIN = 450.0
local OUTER_MARGIN = 450.0
local TICK_MS = 350

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
    return (value:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end))
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
    return ok and unwrap(value) or nil
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

local function location(actor)
    if not valid(actor) then return nil end
    local at = nil
    pcall(function() at = actor:K2_GetActorLocation() end)
    if not at then return nil end
    return { X = tonumber(at.X) or 0, Y = tonumber(at.Y) or 0, Z = tonumber(at.Z) or 0 }
end

local function onlinePlayers()
    local states = nil
    pcall(function() states = FindAllOf("PalPlayerState") end)
    if type(states) ~= "table" then return {} end
    local rows, seen = {}, {}
    for _, ps in ipairs(states) do
        ps = unwrap(ps)
        if valid(ps) then
            local uid = playerUid(ps)
            local pawn = playerPawn(ps)
            local key = uid ~= "" and uid or string.lower(playerName(ps))
            if key ~= "" and not seen[key] and valid(pawn) then
                local at = location(pawn)
                if at then
                    seen[key] = true
                    table.insert(rows, { uid = uid ~= "" and uid or key, name = playerName(ps), pawn = pawn, at = at })
                end
            end
        end
    end
    return rows
end

local scriptsDir = scriptDir()
if not scriptsDir then
    log("Scripts directory unavailable; arena disabled")
    return
end
local modDir = scriptsDir:match("^(.+)\\Scripts$") or scriptsDir
local ipcDir = readAll(modDir .. "\\ipc_path.txt")
if ipcDir then ipcDir = ipcDir:gsub("[\r\n]+$", "") end
if not ipcDir or ipcDir == "" then
    log("ipc_path.txt unavailable; arena disabled")
    return
end

local raidStatusFile = ipcDir .. "\\raid-status.txt"
local combatStatusFile = ipcDir .. "\\raid-combat-status.txt"
local arenaStatusFile = ipcDir .. "\\raid-arena-status.txt"

local currentRaidId = ""
local locked = false
local lockedAt = 0
local participants = {}
local participantNames = {}
local bounceIn = 0
local bounceOut = 0
local lastError = ""
local scheduled = false

local function reset(raidId)
    currentRaidId = tostring(raidId or "")
    locked = false
    lockedAt = 0
    participants = {}
    participantNames = {}
    bounceIn = 0
    bounceOut = 0
    lastError = ""
end

local function writeStatus(raid)
    local count = 0
    for _ in pairs(participants) do count = count + 1 end
    local lines = {
        "version=" .. VERSION,
        "time=" .. tostring(os.time()),
        "raid_id=" .. urlEncode(currentRaidId),
        "raid_state=" .. urlEncode(raid and raid.state or "IDLE"),
        "locked=" .. (locked and "1" or "0"),
        "radius=" .. tostring(math.floor(RADIUS)),
        "participant_count=" .. tostring(count),
        "locked_at=" .. tostring(lockedAt),
        "bounce_in=" .. tostring(bounceIn),
        "bounce_out=" .. tostring(bounceOut),
        "last_error=" .. urlEncode(lastError)
    }
    local i = 0
    for uid, name in pairs(participantNames) do
        i = i + 1
        table.insert(lines, string.format("participant_%d_uid=%s", i, urlEncode(uid)))
        table.insert(lines, string.format("participant_%d_name=%s", i, urlEncode(name)))
    end
    writeAll(arenaStatusFile, table.concat(lines, "\n") .. "\n")
end

local function distance2d(at, center)
    local dx = (at.X or 0) - (center.X or 0)
    local dy = (at.Y or 0) - (center.Y or 0)
    return math.sqrt(dx * dx + dy * dy), dx, dy
end

local function teleport(actor, at)
    if not valid(actor) then return false, "invalid pawn" end
    local ok, result = pcall(function()
        return actor:K2_TeleportTo(
            { X = at.X, Y = at.Y, Z = at.Z },
            { Pitch = 0, Yaw = 0, Roll = 0 }
        )
    end)
    if not ok then return false, tostring(result) end
    return result ~= false, result == false and "K2_TeleportTo returned false" or nil
end

local function boundaryPoint(center, current, radius, dx, dy, dist)
    local nx, ny
    if dist and dist > 0.001 then
        nx, ny = dx / dist, dy / dist
    else
        nx, ny = 1, 0
    end
    local z = current.Z
    if dist and dist > RADIUS * 2 then z = (center.Z or current.Z) + 120 end
    return {
        X = (center.X or 0) + nx * radius,
        Y = (center.Y or 0) + ny * radius,
        Z = z
    }
end

local function lockArena(raid)
    local center = { X = tonumber(raid.x) or 0, Y = tonumber(raid.y) or 0, Z = tonumber(raid.z) or 0 }
    local rows = onlinePlayers()
    for _, p in ipairs(rows) do
        local dist = distance2d(p.at, center)
        if dist <= RADIUS then
            participants[p.uid] = true
            participantNames[p.uid] = p.name
        end
    end

    -- The selected anchor is always intended to be a raid participant. The normal
    -- spawn distance is well inside the radius, but retain this name fallback for
    -- odd terrain/teleport cases.
    local anchor = string.lower(tostring(raid.anchor_name or ""))
    if anchor ~= "" then
        for _, p in ipairs(rows) do
            if string.lower(p.name or "") == anchor then
                participants[p.uid] = true
                participantNames[p.uid] = p.name
            end
        end
    end

    locked = true
    lockedAt = os.time()
    log(string.format("arena LOCKED for raid %s; radius=%d; players=%d", currentRaidId, RADIUS, #rows))
    writeStatus(raid)
end

local function enforceArena(raid)
    local center = { X = tonumber(raid.x) or 0, Y = tonumber(raid.y) or 0, Z = tonumber(raid.z) or 0 }
    for _, p in ipairs(onlinePlayers()) do
        local dist, dx, dy = distance2d(p.at, center)
        if participants[p.uid] then
            participantNames[p.uid] = p.name
            if dist > RADIUS then
                local target = boundaryPoint(center, p.at, RADIUS - INNER_MARGIN, dx, dy, dist)
                local ok, err = teleport(p.pawn, target)
                if ok then
                    bounceIn = bounceIn + 1
                    log("kept participant inside: " .. tostring(p.name))
                else
                    lastError = "keep-in teleport failed for " .. tostring(p.name) .. ": " .. tostring(err)
                    log(lastError)
                end
            end
        elseif dist < RADIUS then
            local target = boundaryPoint(center, p.at, RADIUS + OUTER_MARGIN, dx, dy, dist)
            local ok, err = teleport(p.pawn, target)
            if ok then
                bounceOut = bounceOut + 1
                log("kept outsider outside: " .. tostring(p.name))
            else
                lastError = "keep-out teleport failed for " .. tostring(p.name) .. ": " .. tostring(err)
                log(lastError)
            end
        end
    end
    writeStatus(raid)
end

local function shouldLock(raid, combat)
    if not raid or raid.active ~= "1" or raid.state ~= "ACTIVE" then return false end
    if combat and combat.raid_id == raid.raid_id and combat.engaged == "1" then return true end
    return (tonumber(raid.participants) or 0) > 0
end

LoopAsync(TICK_MS, function()
    local raid = parseKv(readAll(raidStatusFile) or "active=0\nstate=IDLE\n")
    local combat = parseKv(readAll(combatStatusFile) or "")

    if tostring(raid.raid_id or "") ~= currentRaidId then reset(raid.raid_id) end

    if raid.active ~= "1" or raid.state ~= "ACTIVE" then
        if locked then log("arena released for raid " .. tostring(currentRaidId)) end
        locked = false
        participants = {}
        participantNames = {}
        writeStatus(raid)
        return false
    end

    if scheduled then return false end
    if not locked and not shouldLock(raid, combat) then
        writeStatus(raid)
        return false
    end

    scheduled = true
    ExecuteInGameThread(function()
        local ok, err = xpcall(function()
            if not locked then lockArena(raid) end
            if locked then enforceArena(raid) end
        end, debug.traceback)
        if not ok then
            lastError = tostring(err)
            log("arena tick failed: " .. lastError)
            writeStatus(raid)
        end
        scheduled = false
    end)
    return false
end)

writeStatus({ state = "IDLE" })
log("v" .. VERSION .. " loaded; radius=" .. tostring(math.floor(RADIUS)) .. " units")
log("Lock trigger: combat engaged OR first recorded raid damage")