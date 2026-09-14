# PalPanelServerMods

Isolierter UE4SS-Lua-Mod für serverseitige Raid- und Event-Aktionen aus PalPanel.

## Aktiver Umfang

- eigener IPC-Kanal unter `C:\PalPanel\data\bridge-ipc\server-mods`
- Heartbeat + Ping
- `event_pulse`: verteilt vorhandene Palworld-Gegenstände serverseitig
- Raid-Spawn, Status und Admin-Abbruch
- Damage-Tracking und Rewards
- serverseitiger Wild-Controller / native Combat-Beobachtung
- keine Client-Mod, keine zusätzlichen Assets und kein Download für Spieler

Der Mod bleibt bewusst von Capture-, Gameplay-, Tower- und Shop-Bridge getrennt, damit aktive Serveraktionen die bestehenden Tracking-Pfade nicht destabilisieren.
