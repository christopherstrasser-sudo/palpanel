-- PalPanelServerMods v0.2.26 loader
-- Stable server-only Community Raid runtime plus compact grounded 32-character crowd arena.
--
-- controller-023 gives the raid Pal the real wild controller while it is spawned.
-- runtime-021 remains the proven raid/reward/damage runtime.
-- combat-025 is observer-only and performs no forced AI/target calls.
-- arena-028 is the lean authoritative 4000-unit keep-in/keep-out boundary.
-- arena-crowd-003 adds 32 visible non-interactive crowd characters at radius 4500:
--   16 generic villagers + 16 proven GrassMammoths, alternating around the ring.
--   Characters settle on terrain first, then their final ground transforms are locked.
--   Gravity/physics/collision/movement/AI are disabled after grounding.
--   NO vertical teleport-bobbing remains.
--
-- IMPORTANT:
--   * NO PalNetworkTransmitter
--   * NO direct NetMulticast from Lua
--   * NO PlayCosmeticMontage_ToAll
--   * NO free visual actors
--   * NO invisible AreaBarrier actor ring
--   * NO BuildObject visual walls
--   * NO SkillEffect barrier actors
--   * NO client installation
--
-- Deliberately NOT loaded:
--   * arena-027.lua (old 6000-unit arena plus invisible visual actor ring; replaced by arena-028)
--   * arena-locksync-001.lua (native AreaBarrier state sync stable but invisible)
--   * arena-marker-001.lua (visible proof, but attackable marker Pals)
--   * arena-marker-002.lua (stable neutral Pal-only proof; replaced by crowd boundary)
--   * arena-boundary-001.lua (hidden carriers + FireCondition; VFX invisible)
--   * arena-crowd-001.lua (unproven human mix + direct cosmetic multicast; crashy)
--   * arena-crowd-002.lua (visible/stable, but vertical teleport sway caused ground falling)
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
local arenaOk = loadModule("arena-028.lua", "compact authoritative raid arena 0.2.8")
if arenaOk then
    loadModule("arena-crowd-003.lua", "ground-locked compact 32-character crowd arena 1.2.0")
else
    print("[PalPanelServerMods] Crowd boundary skipped because arena-028 failed to load.\n")
end

print("[PalPanelServerMods] v0.2.26 loader ready; compact 4000/4500 grounded crowd arena ENABLED\n")
