-- PalPanelServerMods live player avatar probe v0.1.2
-- SERVER-ONLY / NO SAVEGAME PARSER.
--
-- Reads each online player's live character creation data through UE4SS.
-- Preferred native path: player object -> GetPalPlayerCharacterMakeData() -> GetMakeData().
-- Several safe object-location fallbacks are included for SDK/build differences.
-- Writes one JSON snapshot per player plus a compact status file.
--
-- IMPORTANT: all Unreal UObject access runs on the game thread. ExecuteWithDelay is
-- used only as a timer and never touches UObjects directly.
-- This probe still DOES NOT instantiate or invoke Palworld's portrait renderer.

local MOD = "PalPanelAvatarProbe"
local VERSION = "0.1.2"
local TICK_MS = 10000
local INITIAL_DELAY_MS = 8000

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
    if value == nil then return "" end
    if type(value) == "string" then return value end
    local ok, text = pcall(function() return value:ToString() end)
    if ok and type(text) == "string" then return text end
    local s = tostring(value)
    if s == "nil" then return "" end
    return s
end

local function asNumber(value)
    value = unwrap(value)
    if type(value) == "number" then return value end
    return tonumber(value)
end

local ZERO_GUID = string.rep("0", 32)
local function hex32(word)
    return string.format("%08X", (tonumber(word) or 0) % 0x100000000)
end

local function guidHex(guid)
    guid = unwrap(guid)
    if guid == nil then return "" end
    local ok, text = pcall(function()
        return hex32(member(guid, "A")) .. hex32(member(guid, "B")) .. hex32(member(guid, "C")) .. hex32(member(guid, "D"))
    end)
    if ok and text and text ~= ZERO_GUID then return text end
    return ""
end

local function playerUid(ps)
    if not valid(ps) then return "" end
    return guidHex(member(ps, "PlayerUId"))
end

local function playerName(ps)
    if not valid(ps) then return "" end
    local value = toText(member(ps, "PlayerNamePrivate"))
    if value == "" then value = toText(member(ps, "SavedPlayerName")) end
    return value
end

local function playerController(ps)
    if not valid(ps) then return nil end
    local pc = nil
    pcall(function() pc = ps:GetPlayerController() end)
    pc = unwrap(pc)
    if valid(pc) then return pc end
    pc = member(ps, "Owner")
    return valid(pc) and pc or nil
end

local function playerPawn(ps)
    local pc = playerController(ps)
    if not valid(pc) then return nil end
    local pawn = member(pc, "Pawn")
    if valid(pawn) then return pawn end
    pcall(function() pawn = pc:GetPawn() end)
    pawn = unwrap(pawn)
    return valid(pawn) and pawn or nil
end

local function jsonEscape(value)
    local s = tostring(value or "")
    s = s:gsub("\\", "\\\\")
         :gsub('"', '\\"')
         :gsub("\b", "\\b")
         :gsub("\f", "\\f")
         :gsub("\n", "\\n")
         :gsub("\r", "\\r")
         :gsub("\t", "\\t")
    return s
end

local function jsonString(value)
    return '"' .. jsonEscape(value) .. '"'
end

local function jsonNumber(value)
    local n = asNumber(value)
    if n == nil or n ~= n or n == math.huge or n == -math.huge then return "null" end
    return tostring(n)
end

local function colorJson(value)
    value = unwrap(value)
    if value == nil then return "null" end
    return string.format(
        '{"r":%s,"g":%s,"b":%s,"a":%s}',
        jsonNumber(member(value, "R")),
        jsonNumber(member(value, "G")),
        jsonNumber(member(value, "B")),
        jsonNumber(member(value, "A"))
    )
end

local scriptsDir = scriptDir()
if not scriptsDir then log("Scripts directory unavailable; avatar probe disabled"); return end
local modDir = scriptsDir:match("^(.+)\\Scripts$") or scriptsDir
local ipcDir = readAll(modDir .. "\\ipc_path.txt")
if ipcDir then ipcDir = ipcDir:gsub("[\r\n]+$", "") end
if not ipcDir or ipcDir == "" then log("ipc_path.txt unavailable; avatar probe disabled"); return end

local avatarDir = ipcDir .. "\\avatars"
local statusFile = ipcDir .. "\\avatar-status.txt"
os.execute('mkdir "' .. avatarDir .. '" 2>nul')

local lastError = ""
local scans = 0
local resolvedTotal = 0
local failedTotal = 0
local scheduled = false
local rendererLoadedCache = nil
local captureSetLoadedCache = nil

local function findLoadedClass(shortName)
    local cls = nil
    local ok = pcall(function()
        if FindObject ~= nil then cls = FindObject(nil, shortName) end
    end)
    cls = unwrap(cls)
    return ok and valid(cls), cls
end

local function infoLooksValid(info)
    info = unwrap(info)
    return info ~= nil and member(info, "HairMeshName") ~= nil and member(info, "HeadMeshName") ~= nil
end

local function makeInfoFromDataObject(dataObj, label)
    dataObj = unwrap(dataObj)
    if not valid(dataObj) then return nil end
    local info = nil
    local ok = pcall(function() info = dataObj:GetMakeData() end)
    info = unwrap(info)
    if ok and infoLooksValid(info) then
        return info, label .. ".GetMakeData"
    end
    return nil
end

local function getMakeInfo(ps)
    local pc = playerController(ps)
    local pawn = playerPawn(ps)
    local objects = {
        { ps, "PlayerState" },
        { pc, "PlayerController" },
        { pawn, "PlayerCharacter" }
    }
    local errors = {}

    for _, row in ipairs(objects) do
        local obj, label = row[1], row[2]
        if valid(obj) then
            local dataObj = nil
            local ok, err = pcall(function() dataObj = obj:GetPalPlayerCharacterMakeData() end)
            if ok then
                local info, source = makeInfoFromDataObject(dataObj, label .. ".GetPalPlayerCharacterMakeData")
                if info then return info, source end
            else
                errors[#errors + 1] = label .. ".GetPalPlayerCharacterMakeData=" .. tostring(err)
            end

            for _, propertyName in ipairs({ "CharacterMakeData", "PlayerCharacterMakeData" }) do
                local info, source = makeInfoFromDataObject(member(obj, propertyName), label .. "." .. propertyName)
                if info then return info, source end
            end
        end
    end

    for _, row in ipairs(objects) do
        local obj, label = row[1], row[2]
        if valid(obj) then
            local info = nil
            local ok, err = pcall(function() info = obj:GetCharacterMakeInfo() end)
            info = unwrap(info)
            if ok and infoLooksValid(info) then
                return info, label .. ".GetCharacterMakeInfo"
            elseif not ok then
                errors[#errors + 1] = label .. ".GetCharacterMakeInfo=" .. tostring(err)
            end
        end
    end

    if #errors > 0 then lastError = table.concat(errors, " | ") end
    return nil, "none"
end

local function snapshotJson(ps, info, source)
    local uid = playerUid(ps)
    local name = playerName(ps)
    local parts = {
        '"version":' .. jsonString(VERSION),
        '"captured_at":' .. tostring(os.time()),
        '"player_uid":' .. jsonString(uid),
        '"player_name":' .. jsonString(name),
        '"source":' .. jsonString(source),
        '"body_mesh":' .. jsonString(toText(member(info, "BodyMeshName"))),
        '"head_mesh":' .. jsonString(toText(member(info, "HeadMeshName"))),
        '"hair_mesh":' .. jsonString(toText(member(info, "HairMeshName"))),
        '"equipment_body_mesh":' .. jsonString(toText(member(info, "EquipmentBodyMeshName"))),
        '"equipment_head_mesh":' .. jsonString(toText(member(info, "EquipmentHeadMeshName"))),
        '"eye_material":' .. jsonString(toText(member(info, "EyeMaterialName"))),
        '"voice_id":' .. jsonNumber(member(info, "VoiceID")),
        '"arm_volume":' .. jsonNumber(member(info, "ArmVolume")),
        '"torso_volume":' .. jsonNumber(member(info, "TorsoVolume")),
        '"leg_volume":' .. jsonNumber(member(info, "LegVolume")),
        '"hair_color":' .. colorJson(member(info, "HairColor")),
        '"brow_color":' .. colorJson(member(info, "BrowColor")),
        '"body_color":' .. colorJson(member(info, "BodyColor")),
        '"body_subsurface_color":' .. colorJson(member(info, "BodySubsurfaceColor")),
        '"eye_color":' .. colorJson(member(info, "EyeColor"))
    }
    return "{" .. table.concat(parts, ",") .. "}\n"
end

local function scan()
    scans = scans + 1
    lastError = ""

    local states = nil
    local okStates, statesErr = pcall(function() states = FindAllOf("PalPlayerState") end)
    if not okStates or type(states) ~= "table" then
        lastError = "FindAllOf(PalPlayerState) failed: " .. tostring(statesErr)
        return
    end

    local seen = {}
    local rows = {}
    local onlineCount, resolvedCount, failedCount = 0, 0, 0

    for _, raw in ipairs(states) do
        local ps = unwrap(raw)
        if valid(ps) then
            local uid = playerUid(ps)
            local name = playerName(ps)
            local pawn = playerPawn(ps)
            if uid ~= "" and valid(pawn) and not seen[uid] then
                seen[uid] = true
                onlineCount = onlineCount + 1

                local info, source = getMakeInfo(ps)
                if info ~= nil then
                    resolvedCount = resolvedCount + 1
                    resolvedTotal = resolvedTotal + 1
                    local okWrite = writeAll(avatarDir .. "\\" .. uid .. ".json", snapshotJson(ps, info, source))
                    if not okWrite then lastError = "avatar JSON write failed for " .. uid end
                    rows[#rows + 1] = {
                        uid = uid,
                        name = name,
                        source = source,
                        hair = toText(member(info, "HairMeshName")),
                        head = toText(member(info, "HeadMeshName"))
                    }
                else
                    failedCount = failedCount + 1
                    failedTotal = failedTotal + 1
                    rows[#rows + 1] = { uid = uid, name = name, source = "unresolved", hair = "", head = "" }
                end
            end
        end
    end

    if rendererLoadedCache == nil then
        rendererLoadedCache = select(1, findLoadedClass("WBP_PalPlayerInframeRender_C"))
    end
    if captureSetLoadedCache == nil then
        captureSetLoadedCache = select(1, findLoadedClass("BP_PalPlayerCaptureSet_C"))
    end

    local status = {
        "version=" .. VERSION,
        "time=" .. tostring(os.time()),
        "scans=" .. tostring(scans),
        "online_players=" .. tostring(onlineCount),
        "resolved_make_info=" .. tostring(resolvedCount),
        "failed_make_info=" .. tostring(failedCount),
        "resolved_total=" .. tostring(resolvedTotal),
        "failed_total=" .. tostring(failedTotal),
        "portrait_renderer_class_loaded=" .. (rendererLoadedCache and "1" or "0"),
        "capture_set_class_loaded=" .. (captureSetLoadedCache and "1" or "0"),
        "uobject_work_on_game_thread=1",
        "render_invoked=0",
        "savegame_parser_used=0",
        "client_install_required=0",
        "last_error=" .. tostring(lastError or "")
    }

    for i, row in ipairs(rows) do
        status[#status + 1] = "player_" .. i .. "_uid=" .. tostring(row.uid or "")
        status[#status + 1] = "player_" .. i .. "_name=" .. tostring(row.name or "")
        status[#status + 1] = "player_" .. i .. "_source=" .. tostring(row.source or "")
        status[#status + 1] = "player_" .. i .. "_head_mesh=" .. tostring(row.head or "")
        status[#status + 1] = "player_" .. i .. "_hair_mesh=" .. tostring(row.hair or "")
    end

    writeAll(statusFile, table.concat(status, "\n") .. "\n")
end

local function runScanOnGameThread()
    ExecuteInGameThread(function()
        local ok, err = xpcall(scan, debug.traceback)
        if not ok then
            lastError = tostring(err)
            log("avatar scan failed: " .. lastError)
            writeAll(statusFile, table.concat({
                "version=" .. VERSION,
                "time=" .. tostring(os.time()),
                "uobject_work_on_game_thread=1",
                "render_invoked=0",
                "savegame_parser_used=0",
                "last_error=" .. tostring(lastError)
            }, "\n") .. "\n")
        end
    end)
end

local function schedule()
    if scheduled then return end
    scheduled = true
    local function loop()
        -- Timer callback only schedules work. It does not dereference any UObject.
        runScanOnGameThread()
        ExecuteWithDelay(TICK_MS, loop)
    end
    ExecuteWithDelay(INITIAL_DELAY_MS, loop)
end

schedule()
log("v" .. VERSION .. " loaded; game-thread-only live character-make probe active")
