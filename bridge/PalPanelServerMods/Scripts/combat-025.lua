-- PalPanelServerMods Raid Combat v0.2.5
-- Stability build.
--
-- IMPORTANT: This module deliberately performs ZERO UObject/AI mutations.
-- The spawned raid Pal already receives BP_MonsterAIController_Wild_C from
-- controller-023.lua. We therefore let Palworld's own wild-Pal AI decide
-- aggro/combat naturally instead of calling SetActiveAI, AddTargetPlayer_ForEnemy
-- or ForceBattleStartToTarget from Lua. Those experimental calls were activated
-- at first hit and could hard-crash the dedicated server outside Lua's pcall.
--
-- This file only mirrors plain-text raid state into raid-combat-status.txt so
-- we keep useful diagnostics without touching live Unreal objects.

local MOD_NAME = "PalPanelRaidCombat"
local MOD_VERSION = "0.2.5"
local TICK_MS = 250

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

local scriptsDir = scriptDir()
if not scriptsDir then
    log("ERROR: script directory unavailable")
    return
end

local modDir = scriptsDir:match("^(.+)\\Scripts$") or scriptsDir
local ipcDir = readAll(modDir .. "\\ipc_path.txt")
if ipcDir then ipcDir = ipcDir:gsub("[\r\n]+$", "") end
if not ipcDir or ipcDir == "" then
    log("ERROR: ipc_path.txt unavailable")
    return
end

local raidStatusFile = ipcDir .. "\\raid-status.txt"
local combatStatusFile = ipcDir .. "\\raid-combat-status.txt"

local currentRaidId = ""
local firstHitUid = ""
local firstHitName = ""
local firstHitAt = 0

local function firstHit(status)
    local count = math.max(0, math.min(100, tonumber(status.participants) or 0))
    local best = nil
    for i = 1, count do
        local uid = tostring(status["participant_" .. i .. "_uid"] or "")
        local at = tonumber(status["participant_" .. i .. "_first_hit"] or 0) or 0
        if uid ~= "" and at > 0 then
            local row = {
                uid = uid,
                name = tostring(status["participant_" .. i .. "_name"] or uid),
                at = at,
                index = i
            }
            if not best or row.at < best.at or (row.at == best.at and row.index < best.index) then
                best = row
            end
        end
    end
    return best
end

local function writeStatus(status)
    writeAll(combatStatusFile, table.concat({
        "version=" .. MOD_VERSION,
        "time=" .. tostring(os.time()),
        "raid_id=" .. urlEncode(currentRaidId),
        "raid_state=" .. urlEncode(status and status.state or "IDLE"),
        "mode=natural_wild_ai",
        "uobject_mutations=0",
        "first_hit_uid=" .. urlEncode(firstHitUid),
        "first_hit_name=" .. urlEncode(firstHitName),
        "first_hit_at=" .. tostring(firstHitAt),
        "waiting_first_hit=0",
        "ai_suppressed=0",
        "ai_active=palworld_native",
        "engaged=palworld_native",
        "last_error="
    }, "\n") .. "\n")
end

LoopAsync(TICK_MS, function()
    local status = parseKv(readAll(raidStatusFile) or "active=0\nstate=IDLE\n")
    local raidId = tostring(status.raid_id or "")

    if raidId ~= currentRaidId then
        currentRaidId = raidId
        firstHitUid = ""
        firstHitName = ""
        firstHitAt = 0
    end

    if status.active == "1" and status.state == "ACTIVE" and firstHitUid == "" then
        local hit = firstHit(status)
        if hit then
            firstHitUid = hit.uid
            firstHitName = hit.name
            firstHitAt = hit.at
            log("first hit observed safely -> " .. tostring(firstHitName))
        end
    end

    writeStatus(status)
    return false
end)

writeStatus({ state = "IDLE" })
log("v" .. MOD_VERSION .. " loaded")
log("Mode: native wild AI only; no first-hit UObject/AI calls")
log("Crash-prone SetActiveAI/AddTargetPlayer/ForceBattleStart calls are disabled")
