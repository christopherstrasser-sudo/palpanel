-- PalPanelServerMods event-driven avatar make-info probe v0.1.0
-- SERVER-ONLY / NO SAVEGAME PARSER / NO POLLING / NO RENDER INVOCATION.
--
-- Observes Palworld's own UPalSkeletalMeshComponent::SetCharacterMakeInfo call.
-- The game already passes the final FPalPlayerDataCharacterMakeInfo struct into
-- this function when it applies a player's appearance. We only copy that incoming
-- struct to IPC; no CharacterMake getter, FindAllOf scan, delayed UObject access,
-- or UObject mutation is performed.

local MOD = "PalPanelAvatarHook"
local VERSION = "0.1.0"
local HOOK = "/Script/Pal.PalSkeletalMeshComponent:SetCharacterMakeInfo"

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

local eventCount = 0
local writeCount = 0
local lastError = ""

local function writeStatus(extra)
    extra = extra or {}
    local lines = {
        "version=" .. VERSION,
        "time=" .. tostring(os.time()),
        "hook=" .. HOOK,
        "hook_registered=1",
        "events=" .. tostring(eventCount),
        "writes=" .. tostring(writeCount),
        "polling=0",
        "find_all_of=0",
        "character_make_getter_calls=0",
        "render_invoked=0",
        "savegame_parser_used=0",
        "client_install_required=0",
        "last_component_address=" .. tostring(extra.componentAddress or ""),
        "last_component_full_name=" .. tostring(extra.componentFullName or ""),
        "last_head_mesh=" .. tostring(extra.head or ""),
        "last_hair_mesh=" .. tostring(extra.hair or ""),
        "last_error=" .. tostring(lastError or "")
    }
    writeAll(statusFile, table.concat(lines, "\n") .. "\n")
end

local function snapshotJson(component, info)
    local address = objectAddress(component)
    local parts = {
        '"version":' .. jsonString(VERSION),
        '"captured_at":' .. tostring(os.time()),
        '"component_address":' .. jsonString(address),
        '"component_full_name":' .. jsonString(fullName(component)),
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

local function onSetCharacterMakeInfo(context, infoParam)
    eventCount = eventCount + 1

    local component = unwrap(context)
    local info = unwrap(infoParam)
    local head = toText(member(info, "HeadMeshName"))
    local hair = toText(member(info, "HairMeshName"))
    local address = objectAddress(component)
    local componentName = fullName(component)

    if info == nil or (head == "" and hair == "") then
        lastError = "hook fired but make-info struct could not be read"
        writeStatus({
            componentAddress = address,
            componentFullName = componentName,
            head = head,
            hair = hair
        })
        return
    end

    -- No owner/player traversal in this first event-driven test. A stable hook is
    -- proven first; UID association is added only after this survives player join.
    local key = address ~= "" and address or tostring(eventCount)
    local ok = writeAll(avatarDir .. "\\hook_" .. key .. ".json", snapshotJson(component, info))
    if ok then
        writeCount = writeCount + 1
        lastError = ""
    else
        lastError = "avatar hook JSON write failed"
    end

    writeStatus({
        componentAddress = address,
        componentFullName = componentName,
        head = head,
        hair = hair
    })
end

local ok, err = pcall(function()
    RegisterHook(HOOK, function(...)
        local hookOk, hookErr = xpcall(function() onSetCharacterMakeInfo(...) end, debug.traceback)
        if not hookOk then
            lastError = tostring(hookErr)
            log("hook callback failed: " .. lastError)
            writeStatus()
        end
    end)
end)

if not ok then
    lastError = "RegisterHook failed: " .. tostring(err)
    writeAll(statusFile, table.concat({
        "version=" .. VERSION,
        "time=" .. tostring(os.time()),
        "hook=" .. HOOK,
        "hook_registered=0",
        "polling=0",
        "find_all_of=0",
        "character_make_getter_calls=0",
        "render_invoked=0",
        "last_error=" .. lastError
    }, "\n") .. "\n")
    log(lastError)
    return
end

writeStatus()
log("v" .. VERSION .. " registered event-driven SetCharacterMakeInfo observer")
