-- PalPanelServerMods event-driven avatar make-info probe v0.2.0
-- SERVER-ONLY / NO SAVEGAME PARSER / NO POLLING / NO RENDER INVOCATION.
--
-- Primary hooks:
--   APalPlayerController::FixedCharacterMakeData(FPalPlayerDataCharacterMakeInfo)
--   APalPlayerController::FixedCharacterName(FString)
-- Fallback hook:
--   UPalSkeletalMeshComponent::SetCharacterMakeInfo(FPalPlayerDataCharacterMakeInfo)
--
-- The probe only copies parameters Palworld already passes into these functions.
-- It does not call CharacterMake getters, scan UObjects, render portraits or mutate game state.

local MOD = "PalPanelAvatarHook"
local VERSION = "0.2.0"

local HOOK_MAKE = "/Script/Pal.PalPlayerController:FixedCharacterMakeData"
local HOOK_NAME = "/Script/Pal.PalPlayerController:FixedCharacterName"
local HOOK_MESH = "/Script/Pal.PalSkeletalMeshComponent:SetCharacterMakeInfo"

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
    return tostring(value or "")
end

local function asNumber(value)
    value = unwrap(value)
    if type(value) == "number" then return value end
    return tonumber(value)
end

local function jsonEscape(value)
    local s = tostring(value or "")
    s = s:gsub("\\", "\\\\")
         :gsub('"', '\\"')
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

local function objectAddress(obj)
    obj = unwrap(obj)
    if obj == nil then return "" end
    local ok, addr = pcall(function() return obj:GetAddress() end)
    local n = ok and tonumber(addr) or nil
    if not n or n == 0 then return "" end
    return string.format("%X", n)
end

local function fullName(obj)
    obj = unwrap(obj)
    if obj == nil then return "" end
    local ok, value = pcall(function() return obj:GetFullName() end)
    if ok and type(value) == "string" then return value end
    return ""
end

local scriptsDir = scriptDir()
if not scriptsDir then log("Scripts directory unavailable; hook disabled"); return end
local modDir = scriptsDir:match("^(.+)\\Scripts$") or scriptsDir
local ipcDir = readAll(modDir .. "\\ipc_path.txt")
if ipcDir then ipcDir = ipcDir:gsub("[\r\n]+$", "") end
if not ipcDir or ipcDir == "" then log("ipc_path.txt unavailable; hook disabled"); return end

local avatarDir = ipcDir .. "\\avatars"
local statusFile = ipcDir .. "\\avatar-hook-status.txt"
os.execute('mkdir "' .. avatarDir .. '" 2>nul')

local regMake = false
local regName = false
local regMesh = false
local makeEvents = 0
local nameEvents = 0
local meshEvents = 0
local writes = 0
local lastError = ""
local last = {
    source = "",
    address = "",
    fullName = "",
    playerName = "",
    head = "",
    hair = ""
}
local namesByAddress = {}

local function writeStatus()
    local lines = {
        "version=" .. VERSION,
        "time=" .. tostring(os.time()),
        "make_hook=" .. HOOK_MAKE,
        "make_hook_registered=" .. (regMake and "1" or "0"),
        "name_hook=" .. HOOK_NAME,
        "name_hook_registered=" .. (regName and "1" or "0"),
        "mesh_hook=" .. HOOK_MESH,
        "mesh_hook_registered=" .. (regMesh and "1" or "0"),
        "make_events=" .. tostring(makeEvents),
        "name_events=" .. tostring(nameEvents),
        "mesh_events=" .. tostring(meshEvents),
        "writes=" .. tostring(writes),
        "polling=0",
        "find_all_of=0",
        "character_make_getter_calls=0",
        "render_invoked=0",
        "savegame_parser_used=0",
        "client_install_required=0",
        "last_source=" .. tostring(last.source or ""),
        "last_object_address=" .. tostring(last.address or ""),
        "last_object_full_name=" .. tostring(last.fullName or ""),
        "last_player_name=" .. tostring(last.playerName or ""),
        "last_head_mesh=" .. tostring(last.head or ""),
        "last_hair_mesh=" .. tostring(last.hair or ""),
        "last_error=" .. tostring(lastError or "")
    }
    writeAll(statusFile, table.concat(lines, "\n") .. "\n")
end

local function snapshotJson(source, owner, info)
    local address = objectAddress(owner)
    local playerName = namesByAddress[address] or ""
    local parts = {
        '"version":' .. jsonString(VERSION),
        '"captured_at":' .. tostring(os.time()),
        '"source":' .. jsonString(source),
        '"object_address":' .. jsonString(address),
        '"object_full_name":' .. jsonString(fullName(owner)),
        '"player_name":' .. jsonString(playerName),
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

local function handleMake(source, context, infoParam)
    local owner = unwrap(context)
    local info = unwrap(infoParam)
    local address = objectAddress(owner)
    local objectName = fullName(owner)
    local head = toText(member(info, "HeadMeshName"))
    local hair = toText(member(info, "HairMeshName"))
    local playerName = namesByAddress[address] or ""

    last.source = source
    last.address = address
    last.fullName = objectName
    last.playerName = playerName
    last.head = head
    last.hair = hair

    if info == nil or (head == "" and hair == "") then
        lastError = source .. " fired but make-info struct could not be read"
        writeStatus()
        return
    end

    local prefix = source == "FixedCharacterMakeData" and "playercontroller_" or "mesh_"
    local key = address ~= "" and address or tostring(os.time())
    if writeAll(avatarDir .. "\\" .. prefix .. key .. ".json", snapshotJson(source, owner, info)) then
        writes = writes + 1
        lastError = ""
    else
        lastError = "avatar JSON write failed for " .. source
    end
    writeStatus()
end

local function onFixedMake(context, infoParam)
    makeEvents = makeEvents + 1
    handleMake("FixedCharacterMakeData", context, infoParam)
end

local function onFixedName(context, nameParam)
    nameEvents = nameEvents + 1
    local owner = unwrap(context)
    local address = objectAddress(owner)
    local name = toText(nameParam)
    if address ~= "" and name ~= "" then namesByAddress[address] = name end
    last.source = "FixedCharacterName"
    last.address = address
    last.fullName = fullName(owner)
    last.playerName = name
    lastError = ""
    writeStatus()
end

local function onMeshMake(context, infoParam)
    meshEvents = meshEvents + 1
    handleMake("SetCharacterMakeInfo", context, infoParam)
end

local function register(path, callback)
    local ok, err = pcall(function()
        RegisterHook(path, function(...)
            local args = { ... }
            local hookOk, hookErr = xpcall(function()
                callback(table.unpack(args))
            end, debug.traceback)
            if not hookOk then
                lastError = tostring(hookErr)
                log("callback failed for " .. path .. ": " .. lastError)
                writeStatus()
            end
        end)
    end)
    if not ok then
        lastError = "RegisterHook failed for " .. path .. ": " .. tostring(err)
        log(lastError)
        return false
    end
    return true
end

-- Initialization marker before hook registration.
writeStatus()

regMake = register(HOOK_MAKE, onFixedMake)
regName = register(HOOK_NAME, onFixedName)
regMesh = register(HOOK_MESH, onMeshMake)
writeStatus()

log(string.format(
    "v%s ready; FixedCharacterMakeData=%s FixedCharacterName=%s SetCharacterMakeInfo=%s",
    VERSION,
    regMake and "registered" or "failed",
    regName and "registered" or "failed",
    regMesh and "registered" or "failed"
))
