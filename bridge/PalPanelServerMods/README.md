# PalPanelServerMods

Isolierter UE4SS-Lua-Mod für aktive serverseitige Ingame-Aktionen aus PalPanel.

## v0.1.0 Proof of Concept

- eigener IPC-Kanal unter `C:\PalPanel\data\bridge-ipc\server-mods`
- Heartbeat + Ping
- `event_pulse`: verteilt einen vorhandenen Palworld-Gegenstand direkt serverseitig an alle aktuell geladenen Spieler
- keine Client-Mod, keine zusätzlichen Assets, kein Download für Spieler

Der Mod ist bewusst von Capture-, Gameplay-, Tower- und Shop-Bridge getrennt. Experimentelle aktive Serveraktionen können dadurch nicht die bestehenden Tracking-Pfade destabilisieren.
