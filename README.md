# PalPanel 2.0 — v0.1

Erster Windows-Grundstand für PalPanel.

## Verzeichnisstruktur

PalPanel-Code (Git/Dev Bridge):

`C:\PalPanel\app`

Persistente Daten außerhalb des Git-Repositories:

- `C:\PalPanel\server` — Palworld Dedicated Server
- `C:\PalPanel\steamcmd` — SteamCMD
- `C:\PalPanel\data` — PalPanel-Konfiguration/Daten
- `C:\PalPanel\logs` — Logs
- `C:\PalPanel\backups` — Backups

## Voraussetzungen

- Windows 64-bit
- Node.js 20+
- Internetzugang für die erstmalige SteamCMD-/Palworld-Installation

## Start

`START_PALPANEL.bat` starten.

Danach im Browser öffnen:

`http://localhost:8787`

Im Netzwerk ist das Panel über Port 8787 erreichbar, sofern die Windows-Firewall dies zulässt.

## v0.1 Funktionen

- Windows-Backend ohne externe npm-Pakete
- modernes Dashboard
- Erkennung, ob SteamCMD/Palworld installiert sind
- automatische SteamCMD-Installation
- automatische Installation/Validierung von Palworld Dedicated Server App 2394010
- Start / Stop / Restart
- Update / Validate über SteamCMD
- Installations-/Update-Log im Browser
- Grundstruktur für Event-Countdown
- persistente Konfiguration unter `C:\PalPanel\data\config.json`

## Erstinstallation Palworld

Wenn Palworld noch fehlt, zeigt das Dashboard `Server installieren`.

Der Button führt automatisch aus:

1. Ordner unter `C:\PalPanel` anlegen
2. SteamCMD herunterladen und entpacken
3. `app_update 2394010 validate` ausführen
4. `PalServer.exe` nach `C:\PalPanel\server` installieren
5. wenn möglich Windows-Firewallregel für UDP 8211 anlegen

Die Firewallregel benötigt ggf. Administratorrechte. Fehlschlägt nur dieser Schritt, bleibt die Serverinstallation trotzdem gültig.

## Noch nicht Teil von v0.1

Spieler-/REST-Anbindung, Steam-Login, Save-Parser, Ranglisten, Live-Worldmap, Punkteshop, Backups/Restore, Restart-Scheduler und PalPanel Mod Bridge folgen in weiteren Versionen.
