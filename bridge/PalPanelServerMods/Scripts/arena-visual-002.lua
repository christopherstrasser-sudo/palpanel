-- PalPanelServerMods arena visual fallback v0.2.0
--
-- Safe visual-only experiment for the static raid arena.
-- Uses ONE Palworld partner-skill barrier actor instead of build objects.
-- BP_UniqueSkillEffect_LegendDeer_CoopBarrier_Barrier_C is an ordinary
-- SkillEffect actor with a Sphere + Niagara component. It is intended to be
-- presented to players during gameplay and does not participate in the build
-- persistence/subsystem path that made arena-visual-001 unsafe.
--
-- IMPORTANT:
--   * visual only; arena-027 remains authoritative
--   * one actor only
--   * collision disabled
--   * no damage hooks / no AI calls
--   * all UObject work runs on the game thread

local MOD = "PalPanelRaidArenaSphere"
local VERSION = "0.2.0"
local TICK_MS = 500
local RADIUS = 6000.0
local FALLBACK_BASE_RADIUS = 500.0
local ASSET_NAME = "BP_UniqueSkillEffect_LegendDeer_CoopBarrier_Barrier"
local CLASS_NAME = "BP_UniqueSkillEffect_LegendDeer_CoopBarrier_Barrier_C"

local SEARCH_ROOTS = {
    "/Game/Pal/Blueprint/Skill",
    "/Game/Pal/Blueprint/Character",
    "/Game/Pal/Blueprint"
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
    local addressOk, address = pcall(function() return obj:GetAddress() end)
    if addressOk and tonumber(address) == 0 then return false end
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

local scriptsDir = scriptDir()
if not scriptsDir then
    log("Scripts directory unavailable; sphere visual disabled")
    return
end

local modDir = scriptsDir:match("^(.+)\\Scripts$") or scriptsDir
local ipcDir = readAll(modDir .. "\\ipc_path.txt")
if ipcDir then ipcDir = ipcDir:gsub("[\r\n]+$", "") end
if not ipcDir or ipcDir == "" then
    log("ipc_path.txt unavailable; sphere visual disabled")
    return
end

local raidStatusFile = ipcDir .. "\\raid-status.txt"
local statusFile = ipcDir .. "\\raid-arena-sphere-status.txt"

local currentRaidId = ""
local sphereActor = nil
local sphereClass = nil
local scheduled = false
local attempted = false
local spawned = false
local visualStatus = "waiting"
local classSource = "none"
local resolvedClassName = ""
local visualPackage = ""
local registryStatus = "not_attempted"
local lastError = ""
local center = nil
local baseRadius = 0
local appliedScale = 0
local niagaraReady = false
local barrierFlagSet = false
local collisionDisabled = false
local lastActiveStatus = "none"
local lastActiveSpawned = false
local lastActiveError = ""

local function writeStatus(raid)
    local c = center or { X = 0, Y = 0, Z = 0 }
    local lines = {
        "version=" .. VERSION,
        "time=" .. tostring(os.time()),
        "raid_id=" .. urlEncode(currentRaidId),
        "raid_state=" .. urlEncode(raid and raid.state or "IDLE"),
        "backend=legenddeer_skill_barrier",
        "attempted=" .. (attempted and "1" or "0"),
        "spawned=" .. (spawned and "1" or "0"),
        "visual_status=" .. urlEncode(visualStatus),
        "class_source=" .. urlEncode(classSource),
        "resolved_class_name=" .. urlEncode(resolvedClassName),
        "visual_package=" .. urlEncode(visualPackage),
        "registry_status=" .. urlEncode(registryStatus),
        "center_x=" .. tostring(c.X or 0),
        "center_y=" .. tostring(c.Y or 0),
        "center_z=" .. tostring(c.Z or 0),
        "target_radius=" .. tostring(math.floor(RADIUS)),
        "base_radius=" .. tostring(baseRadius),
        "applied_scale=" .. tostring(appliedScale),
        "niagara_ready=" .. (niagaraReady and "1" or "0"),
        "barrier_flag_set=" .. (barrierFlagSet and "1" or "0"),
        "collision_disabled=" .. (collisionDisabled and "1" or "0"),
        "last_error=" .. urlEncode(lastError),
        "last_active_spawned=" .. (lastActiveSpawned and "1" or "0"),
        "last_active_status=" .. urlEncode(lastActiveStatus),
        "last_active_error=" .. urlEncode(lastActiveError)
    }
    writeAll(statusFile, table.concat(lines, "\n") .. "\n")
end

local function cleanup()
    if valid(sphereActor) then
        pcall(function() sphereActor:K2_DestroyActor() end)
    end
    sphereActor = nil
    spawned = false
end

local function reset(raidId)
    currentRaidId = tostring(raidId or "")
    sphereActor = nil
    sphereClass = nil
    attempted = false
    spawned = false
    visualStatus = "waiting_active_raid"
    classSource = "none"
    resolvedClassName = ""
    visualPackage = ""
    registryStatus = "not_attempted"
    lastError = ""
    center = nil
    baseRadius = 0
    appliedScale = 0
    niagaraReady = false
    barrierFlagSet = false
    collisionDisabled = false
    lastActiveStatus = "none"
    lastActiveSpawned = false
    lastActiveError = ""
end

local function acceptClass(obj, source, packageName)
    obj = unwrap(obj)
    if not valid(obj) or shortName(obj) ~= CLASS_NAME then return nil end
    classSource = source
    resolvedClassName = CLASS_NAME
    visualPackage = packageName or ""
    return obj
end

local function classFromLoadedObjects()
    local ok, classes = pcall(FindAllOf, "BlueprintGeneratedClass")
    if ok and type(classes) == "table" then
        for _, class in ipairs(classes) do
            local accepted = acceptClass(class, "loaded_exact_class_scan", "already_loaded")
            if accepted then return accepted end
        end
    end
    return nil
end

local function getAssetRegistry()
    local helpers = nil
    pcall(function()
        helpers = StaticFindObject("/Script/AssetRegistry.Default__AssetRegistryHelpers")
    end)
    helpers = unwrap(helpers)
    if not valid(helpers) then
        registryStatus = "helpers_unavailable"
        return nil, nil
    end

    local registry = nil
    local ok, result = pcall(function() return helpers:GetAssetRegistry() end)
    if ok then registry = unwrap(result) end
    if not valid(registry) then
        registryStatus = "registry_unavailable"
        return helpers, nil
    end
    registryStatus = "ready"
    return helpers, registry
end

local function resolveAssetClass(helpers, data, packageName)
    local asset = nil
    local ok, result = pcall(function() return helpers:GetAsset(data) end)
    if ok then asset = unwrap(result) end

    if valid(asset) then
        local generated = member(asset, "GeneratedClass")
        local accepted = acceptClass(generated, "asset_registry_generated_class", packageName)
        if accepted then return accepted end
    end

    local paths = {
        packageName .. "." .. CLASS_NAME,
        "BlueprintGeneratedClass " .. packageName .. "." .. CLASS_NAME,
        "/Script/Engine.BlueprintGeneratedClass'" .. packageName .. "." .. CLASS_NAME .. "'"
    }
    for _, path in ipairs(paths) do
        local found = nil
        pcall(function() found = StaticFindObject(path) end)
        local accepted = acceptClass(found, "asset_registry_static_find", packageName)
        if accepted then return accepted end
    end
    return nil
end

local function classFromRegistry()
    local helpers, registry = getAssetRegistry()
    if not valid(helpers) or not valid(registry) then return nil end

    for _, root in ipairs(SEARCH_ROOTS) do
        local assets = {}
        local ok, err = pcall(function()
            registry:GetAssetsByPath(FName(root), assets, true, true)
        end)
        if ok then
            local count = 0
            pcall(function() count = #assets end)
            log(string.format("AssetRegistry scan %s -> %d assets", root, count))
            for i = 1, count do
                local data = unwrap(assets[i])
                if data ~= nil then
                    local assetName = toText(member(data, "AssetName")) or ""
                    if assetName == ASSET_NAME or assetName == CLASS_NAME then
                        local packageName = toText(member(data, "PackageName")) or ""
                        log(string.format("EXACT LegendDeer barrier asset: %s -> %s", assetName, packageName))
                        local class = resolveAssetClass(helpers, data, packageName)
                        if class then
                            registryStatus = "found_exact"
                            return class
                        end
                        registryStatus = "exact_asset_class_unresolved"
                    end
                end
            end
        else
            log("AssetRegistry scan failed for " .. root .. ": " .. tostring(err))
        end
    end

    if registryStatus == "ready" then registryStatus = "exact_asset_not_found" end
    return nil
end

local function resolveClass()
    if valid(sphereClass) and shortName(sphereClass) == CLASS_NAME then return sphereClass end
    local class = classFromLoadedObjects()
    if not class then class = classFromRegistry() end
    if class then sphereClass = class; return class end
    classSource = "unavailable"
    resolvedClassName = ""
    return nil
end

local function worldFromPlayers()
    local states = nil
    pcall(function() states = FindAllOf("PalPlayerState") end)
    if type(states) ~= "table" then return nil end
    for _, ps in ipairs(states) do
        ps = unwrap(ps)
        if valid(ps) then
            local pc = nil
            pcall(function() pc = ps:GetPlayerController() end)
            pc = unwrap(pc)
            if valid(pc) then
                local pawn = member(pc, "Pawn")
                if not valid(pawn) then pcall(function() pawn = pc:GetPawn() end); pawn = unwrap(pawn) end
                if valid(pawn) then
                    local world = nil
                    pcall(function() world = pawn:GetWorld() end)
                    world = unwrap(world)
                    if valid(world) then return world end
                end
            end
        end
    end
    return nil
end

local function configureActor(actor)
    if not valid(actor) then return false end

    -- Keep this visual actor inert.
    pcall(function() actor:SetReplicates(true) end)
    pcall(function() actor:SetReplicateMovement(false) end)
    pcall(function() actor:SetActorHiddenInGame(false) end)
    local collisionOk = pcall(function() actor:SetActorEnableCollision(false) end)
    local skillCollisionOk = pcall(function() actor:SetActorCollision(true) end) -- parameter is named isDisable
    collisionDisabled = collisionOk or skillCollisionOk

    local sphere = member(actor, "Sphere")
    local reportedRadius = nil
    if valid(sphere) then
        pcall(function() reportedRadius = sphere:GetUnscaledSphereRadius() end)
        reportedRadius = tonumber(reportedRadius)
    end
    if not reportedRadius or reportedRadius < 1 then reportedRadius = FALLBACK_BASE_RADIUS end
    baseRadius = reportedRadius

    local scale = math.max(0.1, math.min(100.0, RADIUS / reportedRadius))
    appliedScale = scale
    pcall(function() actor:SetActorScale3D({ X = scale, Y = scale, Z = scale }) end)

    -- The actor exposes an explicit runtime activation flag. Setting it directly
    -- avoids invoking its damage/lifetime behaviour with guessed parameters.
    barrierFlagSet = pcall(function() actor.BarrierActivated = true end)

    local niagara = member(actor, "Niagara")
    if valid(niagara) then
        local visOk = pcall(function() niagara:SetVisibility(true, true) end)
        local activeOk = pcall(function() niagara:Activate(true) end)
        niagaraReady = visOk or activeOk
    end

    pcall(function() actor:ForceNetUpdate() end)
    return true
end

local function spawnSphere(raid)
    attempted = true
    visualStatus = "resolving_skill_barrier"
    center = {
        X = tonumber(raid.x) or 0,
        Y = tonumber(raid.y) or 0,
        Z = tonumber(raid.z) or 0
    }

    local class = resolveClass()
    if not class then
        visualStatus = "class_unavailable"
        lastError = "LegendDeer barrier class could not be resolved"
        lastActiveStatus = visualStatus
        lastActiveError = lastError
        writeStatus(raid)
        return false
    end

    local world = worldFromPlayers()
    if not valid(world) then
        visualStatus = "world_unavailable"
        lastError = "UWorld unavailable for LegendDeer arena visual"
        lastActiveStatus = visualStatus
        lastActiveError = lastError
        writeStatus(raid)
        return false
    end

    visualStatus = "spawning_single_skill_barrier"
    local ok, result = pcall(function()
        return world:SpawnActor(class, center, { Pitch = 0, Yaw = 0, Roll = 0 })
    end)
    local actor = unwrap(result)
    if not ok or not valid(actor) then
        visualStatus = "spawn_failed"
        lastError = "LegendDeer barrier SpawnActor failed: " .. tostring(result)
        lastActiveStatus = visualStatus
        lastActiveError = lastError
        writeStatus(raid)
        return false
    end

    sphereActor = actor
    configureActor(actor)
    spawned = true
    visualStatus = niagaraReady and "single_skill_barrier_ready" or "spawned_niagara_not_ready"
    lastError = niagaraReady and "" or "Barrier actor spawned, but Niagara component could not be activated"
    lastActiveSpawned = true
    lastActiveStatus = visualStatus
    lastActiveError = lastError
    writeStatus(raid)
    log(string.format(
        "single LegendDeer arena visual ready; radius=%.1f base=%.1f scale=%.3f niagara=%s package=%s",
        RADIUS, baseRadius, appliedScale, tostring(niagaraReady), visualPackage
    ))
    return true
end

LoopAsync(TICK_MS, function()
    local raid = parseKv(readAll(raidStatusFile) or "active=0\nstate=IDLE\n")
    local raidId = tostring(raid.raid_id or "")

    if raidId ~= currentRaidId then
        if scheduled then return false end
        scheduled = true
        ExecuteInGameThread(function()
            cleanup()
            reset(raidId)
            writeStatus(raid)
            scheduled = false
        end)
        return false
    end

    if raid.active ~= "1" or raid.state ~= "ACTIVE" then
        if valid(sphereActor) and not scheduled then
            scheduled = true
            ExecuteInGameThread(function()
                cleanup()
                visualStatus = "released"
                writeStatus(raid)
                scheduled = false
            end)
        else
            writeStatus(raid)
        end
        return false
    end

    if not attempted and not scheduled then
        scheduled = true
        ExecuteInGameThread(function()
            local ok, err = xpcall(function() spawnSphere(raid) end, debug.traceback)
            if not ok then
                visualStatus = "exception"
                lastError = tostring(err)
                lastActiveStatus = visualStatus
                lastActiveError = lastError
                log("sphere visual failed: " .. lastError)
                writeStatus(raid)
            end
            scheduled = false
        end)
    end
    return false
end)

reset("")
writeStatus({ state = "IDLE" })
log("v" .. VERSION .. " loaded; one inert LegendDeer SkillEffect barrier; no build objects")