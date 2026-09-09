-- PalPanelServerMods raid arena v0.2.5
-- Arena lock is authoritative and independent from the visual effect.
-- The arena becomes active as soon as the raid reaches ACTIVE state.
-- A missing visual asset can never disable the gameplay boundary.

local MOD = "PalPanelRaidArena"
local VERSION = "0.2.5"
local RADIUS = 6000.0
local SEGMENTS = 32
local MIN_VISUAL_SEGMENTS = 20
local INNER_MARGIN = 400.0
local OUTER_MARGIN = 400.0
local TICK_MS = 250
local BARRIER_CLASS_NAME = "BP_LevelGimmick_AreaBarrier_C"

-- LoadAsset wants the blueprint asset path (without .Object_C).  StaticFindObject
-- then resolves the generated class after the package has been loaded.
local BARRIER_ASSETS = {
    "/Game/Pal/Blueprint/MapObject/LevelGimmick/AreaBarrier/BP_LevelGimmick_AreaBarrier",
    "/Game/Pal/Blueprint/MapObject/LevelGimmick/BP_LevelGimmick_AreaBarrier",
    "/Game/Pal/Blueprint/LevelObject/LevelGimmick/AreaBarrier/BP_LevelGimmick_AreaBarrier",
    "/Game/Pal/Blueprint/LevelObject/LevelGimmick/BP_LevelGimmick_AreaBarrier",
    "/Game/Pal/Blueprint/LevelGimmick/AreaBarrier/BP_LevelGimmick_AreaBarrier",
    "/Game/Pal/Blueprint/LevelGimmick/BP_LevelGimmick_AreaBarrier"
}

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

local function shortName(obj)
    obj = unwrap(obj)
    if not valid(obj) then return "" end
    local value = nil
    pcall(function() value = obj:GetFName() end)
    return toText(value) or ""
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
    for _, ps in ipairs(states) do
        ps = unwrap(ps)
        if valid(ps) then
            local uid = playerUid(ps)
            local pawn = playerPawn(ps)
            local key = uid ~= "" and uid or string.lower(playerName(ps))
            if key ~= "" and not seen[key] and valid(pawn) then
                local at = actorLocation(pawn)
                if at then
                    seen[key] = true
                    rows[#rows + 1] = {
                        uid = uid ~= "" and uid or key,
                        name = playerName(ps),
                        pawn = pawn,
                        at = at
                    }
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

local visualReady = false
local visualAttempted = false
local visualStatus = "waiting"
local classSource = "none"
local barrierActors = {}
local cachedBarrierClass = nil

local function participantCount()
    local n = 0
    for _ in pairs(participants) do n = n + 1 end
    return n
end

local function writeStatus(raid)
    local lines = {
        "version=" .. VERSION,
        "time=" .. tostring(os.time()),
        "raid_id=" .. urlEncode(currentRaidId),
        "raid_state=" .. urlEncode(raid and raid.state or "IDLE"),
        "locked=" .. (locked and "1" or "0"),
        "visible=" .. (visualReady and "1" or "0"),
        "visual_attempted=" .. (visualAttempted and "1" or "0"),
        "visual_status=" .. urlEncode(visualStatus),
        "class_source=" .. urlEncode(classSource),
        "radius=" .. tostring(math.floor(RADIUS)),
        "segments_requested=" .. tostring(SEGMENTS),
        "segments_spawned=" .. tostring(#barrierActors),
        "participant_count=" .. tostring(participantCount()),
        "locked_at=" .. tostring(lockedAt),
        "bounce_in=" .. tostring(bounceIn),
        "bounce_out=" .. tostring(bounceOut),
        "last_error=" .. urlEncode(lastError)
    }

    local i = 0
    for uid, name in pairs(participantNames) do
        i = i + 1
        lines[#lines + 1] = string.format("participant_%d_uid=%s", i, urlEncode(uid))
        lines[#lines + 1] = string.format("participant_%d_name=%s", i, urlEncode(name))
    end

    writeAll(arenaStatusFile, table.concat(lines, "\n") .. "\n")
end

local function cleanupVisual()
    for _, actor in ipairs(barrierActors) do
        if valid(actor) then
            pcall(function() actor:K2_DestroyActor() end)
        end
    end
    barrierActors = {}
    visualReady = false
end

local function reset(raidId)
    currentRaidId = tostring(raidId or "")
    locked = false
    lockedAt = 0
    participants = {}
    participantNames = {}
    bounceIn = 0
    bounceOut = 0
    lastError = ""

    visualReady = false
    visualAttempted = false
    visualStatus = "waiting_active_raid"
    classSource = "none"
    barrierActors = {}
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
    local nx, ny = 1, 0
    if dist and dist > 0.001 then
        nx, ny = dx / dist, dy / dist
    end

    local z = current.Z
    if dist and dist > RADIUS * 2 then
        z = (center.Z or current.Z) + 120
    end

    return {
        X = (center.X or 0) + nx * radius,
        Y = (center.Y or 0) + ny * radius,
        Z = z
    }
end

local function classFromLoadedObjects()
    local found, instance = pcall(FindFirstOf, BARRIER_CLASS_NAME)
    instance = unwrap(instance)
    if found and valid(instance) then
        local ok, class = pcall(function() return instance:GetClass() end)
        class = unwrap(class)
        if ok and valid(class) then
            classSource = "live_instance"
            return class
        end
    end

    local ok, classes = pcall(FindAllOf, "BlueprintGeneratedClass")
    if ok and type(classes) == "table" then
        for _, class in ipairs(classes) do
            class = unwrap(class)
            if valid(class) then
                local name = shortName(class)
                if name == BARRIER_CLASS_NAME or name:find("LevelGimmick_AreaBarrier", 1, true) then
                    classSource = "loaded_class_scan"
                    return class
                end
            end
        end
    end

    return nil
end

local function barrierClass()
    if valid(cachedBarrierClass) then return cachedBarrierClass end

    local class = classFromLoadedObjects()
    if valid(class) then
        cachedBarrierClass = class
        return class
    end

    -- startArena is executed on the game thread, which is required by LoadAsset.
    for _, assetPath in ipairs(BARRIER_ASSETS) do
        local loadedOk, asset = pcall(function() return LoadAsset(assetPath) end)
        asset = unwrap(asset)

        if loadedOk then
            local generated = member(asset, "GeneratedClass")
            if valid(generated) then
                cachedBarrierClass = generated
                classSource = "loadasset_generated_class"
                return generated
            end

            local objectPath = assetPath .. ".BP_LevelGimmick_AreaBarrier_C"
            local findOk, foundClass = pcall(StaticFindObject, objectPath)
            foundClass = unwrap(foundClass)
            if findOk and valid(foundClass) then
                cachedBarrierClass = foundClass
                classSource = "loadasset_static_path"
                return foundClass
            end
        end
    end

    class = classFromLoadedObjects()
    if valid(class) then
        cachedBarrierClass = class
        return class
    end

    classSource = "unavailable"
    return nil
end

local function worldFromPlayers(players)
    for _, p in ipairs(players or {}) do
        if valid(p.pawn) then
            local world = nil
            pcall(function() world = p.pawn:GetWorld() end)
            world = unwrap(world)
            if valid(world) then return world end
        end
    end
    return nil
end

local function prepareVisualActor(actor)
    if not valid(actor) then return end
    pcall(function() actor:SetReplicates(true) end)
    pcall(function() actor:SetActorEnableCollision(false) end)
    pcall(function() actor:SetActorScale3D({ X = 2.4, Y = 2.4, Z = 3.0 }) end)
    pcall(function() actor:ResetNiagara() end)

    local niagara = member(actor, "Niagara")
    if valid(niagara) then
        pcall(function() niagara:SetVisibility(true, true) end)
        pcall(function() niagara:Activate(true) end)
    end

    pcall(function() actor:ForceNetUpdate() end)
end

local function spawnVisualRing(center, players)
    visualAttempted = true
    visualStatus = "resolving_barrier"

    local class = barrierClass()
    if not valid(class) then
        visualStatus = "class_unavailable_locked"
        lastError = "Arena-Lock aktiv, aber BP_LevelGimmick_AreaBarrier_C konnte nicht geladen werden"
        log(lastError)
        return false
    end

    local world = worldFromPlayers(players)
    if not valid(world) then
        visualStatus = "world_unavailable_locked"
        lastError = "Arena-Lock aktiv, aber UWorld ist fuer die sichtbare Barriere nicht verfuegbar"
        log(lastError)
        return false
    end

    visualStatus = "spawning"
    local created = {}

    for i = 0, SEGMENTS - 1 do
        local angle = (math.pi * 2 * i) / SEGMENTS
        local location = {
            X = center.X + math.cos(angle) * RADIUS,
            Y = center.Y + math.sin(angle) * RADIUS,
            Z = center.Z
        }
        local rotation = {
            Pitch = 0,
            Yaw = math.deg(angle) + 90,
            Roll = 0
        }

        local ok, result = pcall(function()
            return world:SpawnActor(class, location, rotation)
        end)
        local actor = unwrap(result)

        if ok and valid(actor) then
            prepareVisualActor(actor)
            created[#created + 1] = actor
        else
            log("barrier segment " .. tostring(i + 1) .. " could not be spawned")
        end
    end

    barrierActors = created
    if #barrierActors < MIN_VISUAL_SEGMENTS then
        visualStatus = "spawn_incomplete_locked"
        lastError = string.format(
            "Arena-Lock aktiv, sichtbare Barriere unvollstaendig: %d/%d Segmente",
            #barrierActors,
            SEGMENTS
        )
        log(lastError)
        cleanupVisual()
        return false
    end

    visualReady = true
    visualStatus = "visible_locked"
    lastError = ""
    log(string.format(
        "visible raid barrier ready: %d/%d segments (%s)",
        #barrierActors,
        SEGMENTS,
        classSource
    ))
    return true
end

local function captureParticipants(raid, players, center)
    participants = {}
    participantNames = {}

    for _, p in ipairs(players) do
        local dist = distance2d(p.at, center)
        if dist <= RADIUS then
            participants[p.uid] = true
            participantNames[p.uid] = p.name
        end
    end

    -- The selected anchor is always a participant, even if terrain or spawn
    -- correction briefly puts the pawn just outside the radius.
    local anchor = string.lower(tostring(raid.anchor_name or ""))
    if anchor ~= "" then
        for _, p in ipairs(players) do
            if string.lower(tostring(p.name or "")) == anchor then
                participants[p.uid] = true
                participantNames[p.uid] = p.name
            end
        end
    end
end

local function mergeRecordedParticipants(raid)
    local count = math.max(0, math.min(100, tonumber(raid.participants) or 0))
    for i = 1, count do
        local uid = tostring(raid["participant_" .. i .. "_uid"] or "")
        local name = tostring(raid["participant_" .. i .. "_name"] or uid)
        if uid ~= "" then
            participants[uid] = true
            participantNames[uid] = name
        end
    end
end

local function startArena(raid)
    local center = {
        X = tonumber(raid.x) or 0,
        Y = tonumber(raid.y) or 0,
        Z = tonumber(raid.z) or 0
    }
    local players = onlinePlayers()

    captureParticipants(raid, players, center)
    mergeRecordedParticipants(raid)

    -- Gameplay boundary first. Visuals are optional and may never turn this off.
    locked = true
    lockedAt = os.time()
    visualStatus = "lock_active_visual_pending"
    log(string.format(
        "arena LOCKED immediately; radius=%d; participants=%d",
        RADIUS,
        participantCount()
    ))

    spawnVisualRing(center, players)
    writeStatus(raid)
end

local function enforceArena(raid)
    if not locked then return end

    mergeRecordedParticipants(raid)

    local center = {
        X = tonumber(raid.x) or 0,
        Y = tonumber(raid.y) or 0,
        Z = tonumber(raid.z) or 0
    }

    for _, p in ipairs(onlinePlayers()) do
        local dist, dx, dy = distance2d(p.at, center)

        if participants[p.uid] then
            participantNames[p.uid] = p.name
            if dist > RADIUS then
                local target = boundaryPoint(
                    center,
                    p.at,
                    RADIUS - INNER_MARGIN,
                    dx,
                    dy,
                    dist
                )
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
            local target = boundaryPoint(
                center,
                p.at,
                RADIUS + OUTER_MARGIN,
                dx,
                dy,
                dist
            )
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

LoopAsync(TICK_MS, function()
    local raid = parseKv(readAll(raidStatusFile) or "active=0\nstate=IDLE\n")
    local raidId = tostring(raid.raid_id or "")

    if raidId ~= currentRaidId and currentRaidId == "" then
        reset(raidId)
    end

    if scheduled then return false end

    if raidId ~= currentRaidId and currentRaidId ~= "" then
        scheduled = true
        ExecuteInGameThread(function()
            cleanupVisual()
            reset(raidId)
            writeStatus(raid)
            scheduled = false
        end)
        return false
    end

    if raid.active ~= "1" or raid.state ~= "ACTIVE" then
        if locked or #barrierActors > 0 then
            scheduled = true
            ExecuteInGameThread(function()
                cleanupVisual()
                locked = false
                lockedAt = 0
                participants = {}
                participantNames = {}
                visualStatus = "released"
                writeStatus(raid)
                scheduled = false
            end)
        else
            writeStatus(raid)
        end
        return false
    end

    scheduled = true
    ExecuteInGameThread(function()
        local ok, err = xpcall(function()
            if not locked then
                startArena(raid)
            end
            enforceArena(raid)
        end, debug.traceback)

        if not ok then
            lastError = tostring(err)
            log("arena tick failed: " .. lastError)
            -- Keep the lock state; a visual/runtime error must not silently open
            -- the arena. The next tick retries enforcement.
            writeStatus(raid)
        end

        scheduled = false
    end)
    return false
end)

reset("")
writeStatus({ state = "IDLE", participants = "0" })
log("v" .. VERSION .. " loaded; radius=" .. tostring(math.floor(RADIUS)) .. " units")
log("Arena lock starts immediately on ACTIVE and is independent from visual barrier")
