# PalPanelBridge v0.1

Server-side UE4SS Lua bridge for PalPanel.

## Runtime path

Installed by PalPanel to:

`<Palworld server>\Pal\Binaries\Win64\ue4ss\Mods\PalPanelBridge`

PalPanel writes `ipc_path.txt` during installation. Runtime IPC lives outside the Git app folder in the persistent PalPanel data directory.

## Transport

No TCP/HTTP listener is opened. Commands and responses use atomic local files:

- `command.txt`
- `response.txt`
- `heartbeat.txt`
- `processed\<command-id>.ok`

The processed markers make successful commands idempotent across PalServer restarts.

## v0.1 capabilities

- heartbeat / ping
- `give_item` to an online player

`give_item` resolves the live `PalPlayerState`, gets its inventory data object and executes the server-side inventory add operation on the game thread.

## Dependency

UE4SS is intentionally not bundled. PalPanel detects the runtime and only installs PalPanelBridge when the Palworld UE4SS runtime is already present.
