-- PalPanelServerMods Arena v2 baseline 0.0.1
-- SERVER-ONLY / NO CLIENT MOD.
--
-- Clean restart. This module deliberately performs NO gameplay or world mutation.
-- It only mirrors the current raid state and frozen ACTIVE center into a dedicated
-- diagnostics file so all future Arena v2 work starts from a known-safe baseline.
--
-- NO actor spawning
-- NO NPC spawning
-- NO barrier spawning
-- NO collision changes
-- NO teleports
-- NO AI changes
-- NO RPC / multicast calls
-- NO visual effects

local MOD = "PalPanelArenaV2"
local VERSION = "0.0.1"
local TICK_MS = 250

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

local scriptsDir = scriptDir()
if not scriptsDir then
    log("Scripts directory unavailable; Arena v2 baseline disabled")
    return
end

local modDir = scriptsDir:match("^(.+)\\Scripts$") or scriptsDir
local ipcDir = readAll(modDir .. "\\ipc_path.txt")
if ipcDir then ipcDir = ipcDir:gsub("[\r\n]+$", "") end
if not ipcDir or ipcDir == "" then
    log("ipc_path.txt unavailable; Arena v2 baseline disabled")
    return
end

local raidStatusFile = ipcDir .. "\\raid-status.txt"
local arenaStatusFile = ipcDir .. "\\raid-arena-v2-status.txt"

local currentRaidId = ""
local active = false
local center = nil
local centerFrozenAt = 0
local lastState = "IDLE"
local lastError = ""
local scheduled = false

local function resetForRaid(raidId)
    currentRaidId = tostring(raidId or "")
    active = false
    center = nil
    centerFrozenAt = 0
    lastState = "IDLE"
    lastError = ""
end

local function writeStatus(raid)
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
        "backend=arena_v2_clean_observer_baseline",
        "world_mutation=0",
        "actor_spawn=0",
        "npc_spawn=0",
        "teleport=0",
        "collision_mutation=0",
        "ai_mutation=0",
        "rpc_calls=0",
        "visual_effects=0",
        "client_install_required=0",
        "last_error=" .. urlEncode(lastError)
    }
    writeAll(arenaStatusFile, table.concat(lines, "\n") .. "\n")
end

local function tick()
    local raw = readAll(raidStatusFile)
    local raid = raw and parseKv(raw) or { state = "IDLE", active = "0", raid_id = "" }
    local raidId = tostring(raid.raid_id or "")

    if raidId ~= currentRaidId then
        resetForRaid(raidId)
    end

    lastState = tostring(raid.state or "IDLE")
    local nowActive = raid.active == "1" and lastState == "ACTIVE" and raidId ~= ""

    if nowActive and not center then
        center = {
            X = tonumber(raid.x) or 0,
            Y = tonumber(raid.y) or 0,
            Z = tonumber(raid.z) or 0
        }
        centerFrozenAt = os.time()
        log(string.format("ACTIVE center observed: X=%.1f Y=%.1f Z=%.1f", center.X, center.Y, center.Z))
    end

    active = nowActive
    if not nowActive and (lastState == "CANCELLED" or lastState == "COMPLETED" or lastState == "FAILED") then
        -- Keep the frozen center in diagnostics until the next raid id arrives.
    elseif raidId == "" then
        center = nil
        centerFrozenAt = 0
    end

    writeStatus(raid)
end

local function schedule()
    if scheduled then return end
    scheduled = true
    local function loop()
        local ok, err = xpcall(tick, debug.traceback)
        if not ok then
            lastError = tostring(err)
            log("baseline tick failed: " .. lastError)
        end
        ExecuteWithDelay(TICK_MS, loop)
    end
    ExecuteWithDelay(TICK_MS, loop)
end

resetForRaid("")
writeStatus({ state = "IDLE" })
schedule()
log("v" .. VERSION .. " loaded; clean Arena v2 observer baseline active")
