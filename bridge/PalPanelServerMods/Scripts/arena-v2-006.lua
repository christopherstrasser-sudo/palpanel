-- PalPanelServerMods Arena v2 step 6 / v0.5.0
-- SERVER-ONLY / NO CLIENT MOD.
--
-- First-hit gated arena around the live raid boss. Players already close enough
-- to the boss are NOT teleported at all; they are simply tracked in-place.
-- Only players outside the safe inner area are moved to a safe ring, with their
-- target Z lifted above both their current Z and the boss Z so they cannot be
-- embedded in uneven terrain. Keep-in remains server-authoritative.

local MOD = "PalPanelArenaV2"
local VERSION = "0.5.0"
local TICK_MS = 250
local RADIUS = 3000.0
local RETURN_RADIUS = 2600.0
local KEEP_CURRENT_IF_WITHIN = 2200.0
local ENTRY_RADIUS = 1200.0
local ENTRY_Z_ABOVE_BOSS = 400.0
local ENTRY_Z_LIFT_FROM_PLAYER = 250.0

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
                local key = uid ~= "" and ("uid:" .. string.upper(uid)) or ("name:" .. string.lower(name))
                if key ~= "" and not seen[key] then
                    local at = actorLocation(pawn)
                    if at then
                        seen[key] = true
                        rows[#rows + 1] = {
                            key = key,
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
if not scriptsDir then log("Scripts directory unavailable; Arena v2 disabled"); return end
local modDir = scriptsDir:match("^(.+)\\Scripts$") or scriptsDir
local ipcDir = readAll(modDir .. "\\ipc_path.txt")
if ipcDir then ipcDir = ipcDir:gsub("[\r\n]+$", "") end
if not ipcDir or ipcDir == "" then log("ipc_path.txt unavailable; Arena v2 disabled"); return end

local raidStatusFile = ipcDir .. "\\raid-status.txt"
local triggerFile = ipcDir .. "\\raid-arena-trigger.txt"
local arenaStatusFile = ipcDir .. "\\raid-arena-v2-status.txt"

local currentRaidId = ""
local active = false
local arenaTriggered = false
local triggerAt = 0
local center = nil
local tracked = {}
local placementDone = false
local trackedAtTrigger = 0
local keptInPlace = 0
local placements = 0
local placementFailures = 0
local teleports = 0
local teleportFailures = 0
local lastState = "IDLE"
local lastError = ""
local scheduled = false

local function resetForRaid(raidId)
    currentRaidId = tostring(raidId or "")
    active = false
    arenaTriggered = false
    triggerAt = 0
    center = nil
    tracked = {}
    placementDone = false
    trackedAtTrigger = 0
    keptInPlace = 0
    placements = 0
    placementFailures = 0
    teleports = 0
    teleportFailures = 0
    lastState = "IDLE"
    lastError = ""
end

local function canonicalKey(uid, name)
    uid, name = tostring(uid or ""), tostring(name or "")
    if uid ~= "" then return "uid:" .. string.upper(uid) end
    if name ~= "" then return "name:" .. string.lower(name) end
    return ""
end

local function track(uid, name)
    local key = canonicalKey(uid, name)
    if key ~= "" then tracked[key] = true end
end

local function isTracked(player)
    if tracked[canonicalKey(player.uid, player.name)] then return true end
    return player.name and tracked["name:" .. string.lower(player.name)] == true
end

local function mergeRaidParticipants(raid)
    local count = math.max(0, math.min(100, math.floor(tonumber(raid.participants) or 0)))
    for i = 1, count do
        track(raid["participant_" .. i .. "_uid"], raid["participant_" .. i .. "_name"])
    end
end

local function trackedCount()
    local n = 0
    for _ in pairs(tracked) do n = n + 1 end
    return n
end

local function writeStatus()
    local c = center or { X = 0, Y = 0, Z = 0 }
    local lines = {
        "version=" .. VERSION,
        "time=" .. tostring(os.time()),
        "raid_id=" .. urlEncode(currentRaidId),
        "raid_state=" .. urlEncode(lastState),
        "active=" .. (active and "1" or "0"),
        "arena_triggered=" .. (arenaTriggered and "1" or "0"),
        "triggered_at=" .. tostring(triggerAt),
        "center_x=" .. tostring(c.X or 0),
        "center_y=" .. tostring(c.Y or 0),
        "center_z=" .. tostring(c.Z or 0),
        "radius=" .. tostring(math.floor(RADIUS)),
        "return_radius=" .. tostring(math.floor(RETURN_RADIUS)),
        "keep_current_if_within=" .. tostring(math.floor(KEEP_CURRENT_IF_WITHIN)),
        "entry_radius=" .. tostring(math.floor(ENTRY_RADIUS)),
        "entry_z_above_boss=" .. tostring(math.floor(ENTRY_Z_ABOVE_BOSS)),
        "entry_z_lift_from_player=" .. tostring(math.floor(ENTRY_Z_LIFT_FROM_PLAYER)),
        "placement_done=" .. (placementDone and "1" or "0"),
        "tracked_online_at_trigger=" .. tostring(trackedAtTrigger),
        "kept_in_place=" .. tostring(keptInPlace),
        "tracked_count=" .. tostring(trackedCount()),
        "initial_placements=" .. tostring(placements),
        "initial_placement_failures=" .. tostring(placementFailures),
        "keep_in_teleports=" .. tostring(teleports),
        "keep_in_failures=" .. tostring(teleportFailures),
        "backend=first_hit_live_boss_safe_ground_placement",
        "world_mutation=only_move_players_outside_safe_inner_area",
        "actor_spawn=0",
        "npc_spawn=0",
        "boss_mutation=0",
        "collision_mutation=0",
        "ai_mutation=0",
        "rpc_calls=0",
        "visual_effects=0",
        "client_install_required=0",
        "last_error=" .. urlEncode(lastError)
    }
    writeAll(arenaStatusFile, table.concat(lines, "\n") .. "\n")
end

local function teleportPlayer(player, target, reason)
    local ok, result = pcall(function()
        return player.pawn:K2_TeleportTo(target, { Pitch = 0, Yaw = 0, Roll = 0 })
    end)
    if ok and result ~= false then
        log(string.format("%s -> %s at %.0f %.0f %.0f", reason, player.name, target.X, target.Y, target.Z))
        return true
    end
    lastError = string.format("%s teleport failed for %s: %s", reason, tostring(player.name), tostring(result))
    log(lastError)
    return false
end

local function placeInitialPlayers()
    if placementDone or not center then return end
    local players = onlinePlayers()
    if #players < 1 then return end

    trackedAtTrigger = #players
    local movers = {}
    for _, player in ipairs(players) do
        track(player.uid, player.name)
        local dx = player.at.X - center.X
        local dy = player.at.Y - center.Y
        local dist = math.sqrt(dx * dx + dy * dy)
        if dist <= KEEP_CURRENT_IF_WITHIN then
            keptInPlace = keptInPlace + 1
            log(string.format("arena-entry -> %s already inside at %.0f; no teleport", player.name, dist))
        else
            movers[#movers + 1] = player
        end
    end

    local count = #movers
    for index, player in ipairs(movers) do
        local angle = ((index - 1) / math.max(1, count)) * math.pi * 2.0
        local safeZ = math.max(center.Z + ENTRY_Z_ABOVE_BOSS, player.at.Z + ENTRY_Z_LIFT_FROM_PLAYER)
        local target = {
            X = center.X + math.cos(angle) * ENTRY_RADIUS,
            Y = center.Y + math.sin(angle) * ENTRY_RADIUS,
            Z = safeZ
        }
        if teleportPlayer(player, target, "first-hit-arena-entry") then
            placements = placements + 1
        else
            placementFailures = placementFailures + 1
        end
    end

    placementDone = true
    log(string.format("arena entry done: %d kept in-place, %d moved, %d failed", keptInPlace, placements, placementFailures))
end

local function enforceKeepIn(raid)
    if not arenaTriggered or not center then return end
    placeInitialPlayers()
    mergeRaidParticipants(raid)

    for _, player in ipairs(onlinePlayers()) do
        if isTracked(player) then
            local dx = player.at.X - center.X
            local dy = player.at.Y - center.Y
            local dist = math.sqrt(dx * dx + dy * dy)
            if dist > RADIUS then
                local nx, ny = 1.0, 0.0
                if dist > 0.001 then nx, ny = dx / dist, dy / dist end
                local target = {
                    X = center.X + nx * RETURN_RADIUS,
                    Y = center.Y + ny * RETURN_RADIUS,
                    Z = math.max(player.at.Z + 100.0, center.Z + 200.0)
                }
                if teleportPlayer(player, target, "keep-in") then
                    teleports = teleports + 1
                else
                    teleportFailures = teleportFailures + 1
                end
            end
        end
    end
end

local function tick()
    local raid = parseKv(readAll(raidStatusFile) or "active=0\nstate=IDLE\nraid_id=\n")
    local trigger = parseKv(readAll(triggerFile) or "triggered=0\nraid_id=\n")
    local raidId = tostring(raid.raid_id or "")
    if raidId ~= currentRaidId then resetForRaid(raidId) end

    lastState = tostring(raid.state or "IDLE")
    active = raid.active == "1" and lastState == "ACTIVE" and raidId ~= ""
    local triggerMatches = trigger.triggered == "1" and tostring(trigger.raid_id or "") == raidId

    if active and triggerMatches and not arenaTriggered then
        arenaTriggered = true
        triggerAt = tonumber(trigger.triggered_at) or os.time()
        center = {
            X = tonumber(trigger.center_x) or tonumber(raid.x) or 0,
            Y = tonumber(trigger.center_y) or tonumber(raid.y) or 0,
            Z = tonumber(trigger.center_z) or tonumber(raid.z) or 0
        }
        log(string.format("arena activated around live boss: %.1f %.1f %.1f", center.X, center.Y, center.Z))
    end

    if active and arenaTriggered then
        ExecuteInGameThread(function()
            local ok, err = xpcall(function() enforceKeepIn(raid) end, debug.traceback)
            if not ok then
                lastError = tostring(err)
                log("arena tick failed: " .. lastError)
            end
        end)
    elseif not active and raidId == "" then
        center = nil
        tracked = {}
        placementDone = false
        arenaTriggered = false
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
            log("step 6 tick failed: " .. lastError)
        end
        ExecuteWithDelay(TICK_MS, loop)
    end
    ExecuteWithDelay(TICK_MS, loop)
end

resetForRaid("")
writeStatus()
schedule()
log("v" .. VERSION .. " loaded; first-hit safe-ground arena ready")
