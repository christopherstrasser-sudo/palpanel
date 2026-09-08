# PalPanelGameplay

Isolierter UE4SS-Lua-Sidecar für echte Gameplay-Events. Er ist absichtlich getrennt von `PalPanelBridge` (Heartbeat/Items) und `PalPanelCapture` (Fänge), damit experimentelle Gameplay-Hooks die funktionierenden Pfade nicht destabilisieren.

## Events

- Spielertod über `/Script/Pal.PalPlayerCharacter:OnDeadPlayer_Server`
- Vom Spieler besiegte Boss-/Alpha-Charaktere über `OnDefeatCharacterDelegate`

Die Events werden atomar nach `C:\PalPanel\data\bridge-ipc\game-events` geschrieben und von PalPanel verarbeitet.

Kein Savegame-Parsing, kein UObject-Polling, keine Item-Zustellung.
