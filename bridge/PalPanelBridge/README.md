# PalPanelBridge v0.2

Server-side UE4SS Lua bridge for PalPanel.

## Runtime path

Current Palworld-specific UE4SS builds are detected under:

`<Palworld server>\Pal\Binaries\Win64\ue4ss\Mods\PalPanelBridge`

A direct `Win64\Mods` layout remains a legacy fallback. PalPanel chooses the runtime from the installed `UE4SS.dll`.

PalPanel writes `ipc_path.txt` during installation. Runtime IPC lives outside the Git app folder in the persistent PalPanel data directory.

## Transport

No TCP/HTTP listener is opened by the Lua mod. Commands, responses and gameplay events use local atomic files:

- `command.txt`
- `response.txt`
- `heartbeat.txt`
- `processed\<command-id>.ok`
- `events\*.evt`

Successful commands keep processed markers for restart-safe idempotency. Capture events use a stable event id derived from the player UID and captured Pal instance id; the PalPanel progression backend also deduplicates them.

## v0.2 capabilities

- heartbeat / ping
- `give_item` to an online player
- live Pal capture events

For captures, the bridge listens to native `/Script/Pal` capture delegate signatures, resolves the captured Pal's `CharacterID`, Pal instance id and capturing player's `PlayerUId`, normalizes `BOSS_` variants to their base species and queues the event for PalPanel.

PalPanel then applies the progression economy centrally: new species, repeat captures, hourly repeat cap, Alpha bonus and Paldex milestones. The Lua mod never calculates or stores point balances itself.

## Dependency

UE4SS is intentionally not bundled. PalPanel detects the runtime and only installs PalPanelBridge when the Palworld-specific UE4SS runtime is already present.
