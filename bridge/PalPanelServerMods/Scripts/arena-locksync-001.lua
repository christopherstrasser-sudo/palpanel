-- PalPanelServerMods raid arena lock-state sync v0.1.0
-- SERVER-ONLY / NO CLIENT MOD.
--
-- This module does NOT spawn any visual actor.
-- arena-027.lua remains authoritative and already creates the exact
-- BP_LevelGimmick_AreaBarrier_C ring + technical keep-in/keep-out boundary.
--
-- The missing piece tested here is Palworld's own AreaBarrier state/sync path:
--   HandleLockStateChanged(FName, bool)
--   HandleCompleteSyncPlayer(APalPlayerState*)
--
-- We invoke those functions only on the exact AreaBarrier actors belonging
-- to the current raid ring. No PalNetworkTransmitter, no direct NetMulticast,
-- no BuildObject and no SkillEffect is used.

local MOD = "PalPanelRaidArenaLockSync"
local VERSION = "0.1.0"
local TICK_MS = 250
local ARM_TICKS = 8
local RADIUS = 6000.0
local RING_TOLERANCE = 1400.0
local Z_TOLERANCE = 3500.0
local MIN_BARRIERS = 20
local BARRIER_CLASS_NAME = "BP_LevelGimmick_AreaBarrier_C"
local LOCK_NAME = "PalPanelRaidArena"
local NET_CULL_DISTANCE_SQUARED = 2500000000.0

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

local function toText(value)
    value = unwrap(value)
    if value == nil then return nil end
    if type(value) == "string" then return value end
    local ok, text = pcall(function() return value:ToString() end)
    if ok and type(text) == "string" and text ~= "" then return text end
    local ok2, text2 = pcall(tostring, value)
    if ok2 and type(text2) == "string" and text2 ~= "" then return text2 end
    return nil
end

local function shortName(obj)
    obj = unwrap(obj)
    if not valid(obj) then return "" end
    local name = nil
    pcall(function() name = obj:GetFName() end)
    return toText(name) or ""
end

local function objectAddress(obj)
    obj = unwrap(obj)
    if not valid(obj) then return "" end
    local ok, addr = pcall(function() return obj:GetAddress() end)
    if not ok then return "" end
    return tostring(addr or "")
end

local function actorLocation(actor)
    actor = unwrap(actor)
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

local scriptsDir = scriptDir()
if not scriptsDir then
    log("Scripts directory unavailable; lock sync disabled")
    return
end

local modDir = scriptsDir:match("^(.+)\\Scripts$") or scriptsDir
local ipcDir = readAll(modDir .. "\\ipc_path.txt")
if ipcDir then ipcDir = ipcDir:gsub("[\r\n]+$", "") end
if not ipcDir or ipcDir == "" then
    log("ipc_path.txt unavailable; lock sync disabled")
    return
end

local raidStatusFile = ipcDir .. "\\raid-status.txt"
local arenaStatusFile = ipcDir .. "\\raid-arena-status.txt"
local syncStatusFile = ipcDir .. "\\raid-arena-locksync-status.txt"

local currentRaidId = ""
local activeTicks = 0
local syncAttempted = 0
local syncFinished = 0
local barrierCandidates = 0
local barriersMatched = 0
local playerStatesFound = 0
local lockStateCallsOk = 0
local lockStateCallsFailed = 0
local playerSyncCallsOk = 0
local playerSyncCallsFailed = 0
local forceNetUpdates = 0
local visualStatus = "idle"
local callInflight = "none"
local lastError = ""
local scheduled = false
local center = nil

local lastActive = {
    valid = 0,
    attempted = 0,
    finished = 0,
    matched = 0,
    players = 0,
    lockOk = 0,
    lockFailed = 0,
    playerSyncOk = 0,
    playerSyncFailed = 0,
    forceNetUpdates = 0,
    status = "",
    inflight = "none",
    error = ""
}

local function snapshotActive()
    if not center then return end
    lastActive.valid = 1
    lastActive.attempted = syncAttempted
    lastActive.finished = syncFinished
    lastActive.matched = barriersMatched
    lastActive.players = playerStatesFound
    lastActive.lockOk = lockStateCallsOk
    lastActive.lockFailed = lockStateCallsFailed
    lastActive.playerSyncOk = playerSyncCallsOk
    lastActive.playerSyncFailed = playerSyncCallsFailed
    lastActive.forceNetUpdates = forceNetUpdates
    lastActive.status = visualStatus
    lastActive.inflight = callInflight
    lastActive.error = lastError
end

local function writeStatus(raid)
    local c = center or { X = 0, Y = 0, Z = 0 }
    local lines = {
        "version=" .. VERSION,
        "time=" .. tostring(os.time()),
        "raid_id=" .. urlEncode(currentRaidId),
        "raid_state=" .. urlEncode(raid and raid.state or "IDLE"),
        "backend=area_barrier_native_lockstate_player_sync",
        "client_install_required=0",
        "active_ticks=" .. tostring(activeTicks),
        "arm_ticks=" .. tostring(ARM_TICKS),
        "center_x=" .. tostring(c.X or 0),
        "center_y=" .. tostring(c.Y or 0),
        "center_z=" .. tostring(c.Z or 0),
        "radius=" .. tostring(math.floor(RADIUS)),
        "sync_attempted=" .. tostring(syncAttempted),
        "sync_finished=" .. tostring(syncFinished),
        "barrier_candidates=" .. tostring(barrierCandidates),
        "barriers_matched=" .. tostring(barriersMatched),
        "minimum_barriers=" .. tostring(MIN_BARRIERS),
        "player_states_found=" .. tostring(playerStatesFound),
        "lockstate_calls_ok=" .. tostring(lockStateCallsOk),
        "lockstate_calls_failed=" .. tostring(lockStateCallsFailed),
        "player_sync_calls_ok=" .. tostring(playerSyncCallsOk),
        "player_sync_calls_failed=" .. tostring(playerSyncCallsFailed),
        "force_net_updates=" .. tostring(forceNetUpdates),
        "lock_name=" .. urlEncode(LOCK_NAME),
        "visual_status=" .. urlEncode(visualStatus),
        "call_inflight=" .. urlEncode(callInflight),
        "last_error=" .. urlEncode(lastError),
        "last_active_valid=" .. tostring(lastActive.valid),
        "last_active_sync_attempted=" .. tostring(lastActive.attempted),
        "last_active_sync_finished=" .. tostring(lastActive.finished),
        "last_active_barriers_matched=" .. tostring(lastActive.matched),
        "last_active_player_states=" .. tostring(lastActive.players),
        "last_active_lockstate_ok=" .. tostring(lastActive.lockOk),
        "last_active_lockstate_failed=" .. tostring(lastActive.lockFailed),
        "last_active_player_sync_ok=" .. tostring(lastActive.playerSyncOk),
        "last_active_player_sync_failed=" .. tostring(lastActive.playerSyncFailed),
        "last_active_force_net_updates=" .. tostring(lastActive.forceNetUpdates),
        "last_active_visual_status=" .. urlEncode(lastActive.status),
        "last_active_call_inflight=" .. urlEncode(lastActive.inflight),
        "last_active_error=" .. urlEncode(lastActive.error)
    }
    writeAll(syncStatusFile, table.concat(lines, "\n") .. "\n")
end

local function resetRaid(raidId)
    currentRaidId = tostring(raidId or "")
    activeTicks = 0
    syncAttempted = 0
    syncFinished = 0
    barrierCandidates = 0
    barriersMatched = 0
    playerStatesFound = 0
    lockStateCallsOk = 0
    lockStateCallsFailed = 0
    playerSyncCallsOk = 0
    playerSyncCallsFailed = 0
    forceNetUpdates = 0
    visualStatus = "waiting_active_raid"
    callInflight = "none"
    lastError = ""
    center = nil
    lastActive = {
        valid = 0, attempted = 0, finished = 0, matched = 0, players = 0,
        lockOk = 0, lockFailed = 0, playerSyncOk = 0, playerSyncFailed = 0,
        forceNetUpdates = 0, status = "", inflight = "none", error = ""
    }
end

local function currentPlayerStates()
    local states = nil
    local ok, result = pcall(function() return FindAllOf("PalPlayerState") end)
    if ok then states = result end
    if type(states) ~= "table" then return {} end

    local out, seen = {}, {}
    for _, raw in ipairs(states) do
        local ps = unwrap(raw)
        if valid(ps) then
            local addr = objectAddress(ps)
            if addr ~= "" and not seen[addr] then
                seen[addr] = true
                out[#out + 1] = ps
            end
        end
    end
    return out
end

local function findRaidBarriers()
    local actors = nil
    local ok, result = pcall(function() return FindAllOf(BARRIER_CLASS_NAME) end)
    if ok then actors = result end
    if type(actors) ~= "table" then return {} end

    barrierCandidates = #actors
    local out = {}
    for _, raw in ipairs(actors) do
        local actor = unwrap(raw)
        if valid(actor) and shortName(actor:GetClass()) == BARRIER_CLASS_NAME then
            local at = actorLocation(actor)
            if at and center then
                local dx = at.X - center.X
                local dy = at.Y - center.Y
                local dist = math.sqrt(dx * dx + dy * dy)
                local dz = math.abs((at.Z or 0) - (center.Z or 0))
                if math.abs(dist - RADIUS) <= RING_TOLERANCE and dz <= Z_TOLERANCE then
                    out[#out + 1] = actor
                end
            end
        end
    end
    barriersMatched = #out
    return out
end

local function prepareNetworkRelevance(actor)
    if not valid(actor) then return end
    pcall(function() actor:SetReplicates(true) end)
    pcall(function() actor:SetReplicateMovement(false) end)
    pcall(function() actor.bAlwaysRelevant = true end)
    pcall(function() actor.NetCullDistanceSquared = NET_CULL_DISTANCE_SQUARED end)
    pcall(function() actor:FlushNetDormancy() end)
    local ok = pcall(function() actor:ForceNetUpdate() end)
    if ok then forceNetUpdates = forceNetUpdates + 1 end
end

local function performSync(raid)
    if syncAttempted ~= 0 then return end
    syncAttempted = 1
    visualStatus = "collecting_area_barriers"
    callInflight = "none"
    snapshotActive(); writeStatus(raid)

    local barriers = findRaidBarriers()
    local players = currentPlayerStates()
    playerStatesFound = #players

    if #barriers < MIN_BARRIERS then
        visualStatus = "not_enough_raid_barriers"
        lastError = string.format("matched %d/%d required AreaBarrier actors", #barriers, MIN_BARRIERS)
        snapshotActive(); writeStatus(raid)
        log(lastError)
        return
    end
    if #players == 0 then
        visualStatus = "no_player_states"
        lastError = "no valid PalPlayerState found"
        snapshotActive(); writeStatus(raid)
        log(lastError)
        return
    end

    log(string.format("native AreaBarrier lock-state sync start: barriers=%d players=%d", #barriers, #players))

    -- Stage 1: drive the native barrier lock-state handler. This is the path
    -- Palworld itself exposes on APalLevelGimmick_AreaBarrier when a lock
    -- state changes. Persist before every native call so a native crash leaves
    -- an exact breadcrumb.
    for i, actor in ipairs(barriers) do
        prepareNetworkRelevance(actor)
        callInflight = string.format("HandleLockStateChanged_%d", i)
        visualStatus = "applying_native_lock_state"
        snapshotActive(); writeStatus(raid)

        local ok, err = pcall(function()
            actor:HandleLockStateChanged(FName(LOCK_NAME), true)
        end)
        if ok then
            lockStateCallsOk = lockStateCallsOk + 1
        else
            lockStateCallsFailed = lockStateCallsFailed + 1
            lastError = tostring(err)
        end
    end

    -- Stage 2: ask each AreaBarrier to run Palworld's own complete-player-sync
    -- handler for every connected player. This is deliberately NOT a direct
    -- RPC/NetMulticast from Lua; Palworld owns whatever sync this handler does.
    for i, actor in ipairs(barriers) do
        for p, ps in ipairs(players) do
            callInflight = string.format("HandleCompleteSyncPlayer_%d_%d", i, p)
            visualStatus = "syncing_barrier_to_players"
            snapshotActive(); writeStatus(raid)

            local ok, err = pcall(function()
                actor:HandleCompleteSyncPlayer(ps)
            end)
            if ok then
                playerSyncCallsOk = playerSyncCallsOk + 1
            else
                playerSyncCallsFailed = playerSyncCallsFailed + 1
                lastError = tostring(err)
            end
        end
        pcall(function() actor:ForceNetUpdate() end)
    end

    callInflight = "none"
    syncFinished = 1
    if lockStateCallsOk == #barriers and playerSyncCallsOk == (#barriers * #players) then
        visualStatus = "native_lockstate_player_sync_completed"
    else
        visualStatus = "native_lockstate_player_sync_partial"
    end
    snapshotActive(); writeStatus(raid)
    log(string.format(
        "native AreaBarrier lock-state sync done: lock=%d/%d playerSync=%d/%d",
        lockStateCallsOk, #barriers,
        playerSyncCallsOk, #barriers * #players
    ))
end

LoopAsync(TICK_MS, function()
    local raid = parseKv(readAll(raidStatusFile) or "active=0\nstate=IDLE\n")
    local arena = parseKv(readAll(arenaStatusFile) or "locked=0\nsegments_spawned=0\n")
    local raidId = tostring(raid.raid_id or "")
    local isActive = raid.active == "1" and raid.state == "ACTIVE"

    if scheduled then return false end

    if raidId ~= currentRaidId then
        scheduled = true
        ExecuteInGameThread(function()
            local ok, err = xpcall(function()
                resetRaid(raidId)
                writeStatus(raid)
            end, debug.traceback)
            if not ok then log("raid reset failed: " .. tostring(err)) end
            scheduled = false
        end)
        return false
    end

    if not isActive then
        if center ~= nil then snapshotActive() end
        activeTicks = 0
        center = nil
        visualStatus = "released"
        callInflight = "none"
        writeStatus(raid)
        return false
    end

    activeTicks = activeTicks + 1
    if not center then
        center = {
            X = tonumber(raid.x) or tonumber(arena.center_x) or 0,
            Y = tonumber(raid.y) or tonumber(arena.center_y) or 0,
            Z = tonumber(raid.z) or tonumber(arena.center_z) or 0
        }
        visualStatus = "arming_native_lockstate_sync"
        snapshotActive(); writeStatus(raid)
    end

    local arenaReady = arena.locked == "1" and (tonumber(arena.segments_spawned) or 0) >= MIN_BARRIERS
    if syncAttempted == 0 and activeTicks >= ARM_TICKS and arenaReady then
        scheduled = true
        ExecuteInGameThread(function()
            local ok, err = xpcall(function() performSync(raid) end, debug.traceback)
            if not ok then
                lastError = tostring(err)
                visualStatus = "lua_exception"
                callInflight = "none"
                snapshotActive(); writeStatus(raid)
                log("sync exception: " .. tostring(err))
            end
            scheduled = false
        end)
    elseif syncAttempted == 0 and activeTicks >= ARM_TICKS then
        visualStatus = "waiting_for_arena_027_segments"
        snapshotActive(); writeStatus(raid)
    end

    return false
end)

log("v" .. VERSION .. " loaded; native AreaBarrier HandleLockStateChanged + HandleCompleteSyncPlayer path")
log("SERVER-ONLY; reuses arena-027 actors; no PalNetworkTransmitter / BuildObject / SkillEffect")
