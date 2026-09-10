-- PalPanelServerMods v0.2.25 loader
-- Stable server-only Community Raid runtime plus the safer 32-character crowd arena.
--
-- controller-023 gives the raid Pal the real wild controller while it is spawned.
-- runtime-021 remains the proven raid/reward/damage runtime.
-- combat-025 is observer-only and performs no forced AI/target calls.
-- arena-027 keeps the proven static authoritative 6000-unit keep-in/keep-out boundary.
-- arena-crowd-002 adds 32 visible, non-interactive crowd characters:
--   16 generic villagers + 16 proven GrassMammoths, alternating around a 6750 ring.
--   The crowd uses the proven UPalNPCManager::SpawnNPCForServer path and only
--   previously proven neutralization primitives. No direct cosmetic/network RPCs.
--   Crowd motion is a small replicated K2_TeleportTo sway/bounce.
--
-- IMPORTANT:
--   * NO PalNetworkTransmitter
--   * NO direct NetMulticast from Lua
--   * NO PlayCosmeticMontage_ToAll
--   * NO free visual actors
--   * NO BuildObject visual walls
--   * NO SkillEffect barrier actors
--   * NO client installation
--
-- Deliberately NOT loaded:
--   * arena-locksync-001.lua (native AreaBarrier state sync stable but invisible)
--   * arena-marker-001.lua (visible proof, but attackable marker Pals)
--   * arena-marker-002.lua (stable neutral Pal-only proof; replaced by crowd boundary)
--   * arena-boundary-001.lua (hidden carriers + FireCondition; VFX invisible)
--   * arena-crowd-001.lua (unproven human mix + direct cosmetic multicast; crashy)
--   * arena-visual-001.lua (Pal BuildObject wall -> combat-start crash)
--   * arena-visual-002.lua (LegendDeer SkillEffect barrier -> raid-start crash)
--   * arena-visual-003.lua (post-spawn replication invisible)
--   * arena-visual-004.lua (actor-return bug)
--   * arena-visual-005.lua (32/32 server actors, client invisible)
--   * arena-visual-006.lua (SpawnNonReliableActorBroadcast -> native crash)
--   * arena-visual-007.lua (direct SpawnedNonReliableActor_ToALL -> native crash)

local function scriptDir()
    local src = debug.getinfo(1, "S").source
    src = src:match("^@(.+)$") or src
    return src:match("^(.+)\\[^\\]+$")
end

local scriptsDir = scriptDir()
if not scriptsDir then
    print("[PalPanelServerMods] ERROR: Scripts directory unavailable\n")
    return
end

local function loadModule(file, label)
    local path = scriptsDir .. "\\" .. file
    local ok, err = pcall(dofile, path)
    if ok then
        print(string.format("[PalPanelServerMods] %s loaded\n", label))
        return true
    end
    print(string.format("[PalPanelServerMods] %s FAILED: %s\n", label, tostring(err)))
    return false
end

loadModule("controller-023.lua", "wild raid controller adapter 0.2.3")

local runtimeOk = loadModule("runtime-021.lua", "stable raid runtime 0.2.1")
if not runtimeOk then
    print("[PalPanelServerMods] Combat/arena modules skipped because the stable runtime did not load.\n")
    return
end

loadModule("combat-025.lua", "safe native-wild-AI observer 0.2.5")
local arenaOk = loadModule("arena-027.lua", "static authoritative raid arena 0.2.7")
if arenaOk then
    loadModule("arena-crowd-002.lua", "safe 32-character non-interactive crowd arena 1.1.0")
else
    print("[PalPanelServerMods] Crowd boundary skipped because arena-027 failed to load.\n")
end

print("[PalPanelServerMods] v0.2.25 loader ready; SAFE 32-character crowd arena ENABLED\n")