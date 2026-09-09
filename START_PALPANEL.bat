@echo off
setlocal
cd /d "%~dp0"
title PalPanel v0.9.9
where node >nul 2>&1
if errorlevel 1 (
 echo [FEHLER] Node.js 24 oder neuer wird fuer User-System und SQLite benoetigt.
 pause
 exit /b 1
)
echo.
echo Starte PalPanel v0.9.9...
echo Frontend:  http://localhost:8787
echo Event:     http://localhost:8787/event
echo Missionen: http://localhost:8787/missions
echo Historie:  http://localhost:8787/hall-of-fame
echo Profil:    http://localhost:8787/profile
echo Shop:      http://localhost:8787/shop
echo Spieler:   http://localhost:8787/player/ID
echo Admin:     http://localhost:8787/admin/
echo Saison:    http://localhost:8787/admin/season
echo Missionen: http://localhost:8787/admin/missions
echo Bridge:    http://localhost:8787/admin/bridge
echo UI:        Frontend v0.9.9 Compact Redesign aktiv
echo Admin:     Auth-First Login + Control-Center Refinement aktiv
echo Banner:    Kompakter Hero + ETag + Langzeitcache aktiv
echo Erfolge:   Badges + Trophy-Wert + Community-Seltenheit aktiv
echo Duelle:    Paldex + Alpha + Bosse + Spielzeit + Trophäen aktiv
echo Saison:    Community-Ziele + Challenges + Belohnungen aktiv
echo Archiv:    Saison-Snapshots + Hall of Fame + Profil-Titel aktiv
echo Wochen:    Dynamische Missionen + Belohnungen + Wochenheld aktiv
echo Inbox:     Benachrichtigungen + Ungelesen-Status + Live-Feed aktiv
echo Dashboard: Persoenliche Startseiten-Zentrale aktiv
echo Frontend:  Dynamische Node-Views ohne statische Public-HTML-Seiten
echo Capture:   Live-Faenge + Alpha-Bonus aktiv
echo Gameplay:  Stufenaufstiege + Bosse + Spielertode aktiv
echo Tower:     Tower-Boss-Erfolge aktiv
echo Steam:     Profilbilder + Ranglisten-Avatare aktiv
echo Status:    Fast-Cache + Async-Prozesscache aktiv
echo.
node -r ./src/frontend-routeguard.js -r ./src/fast-process-shim.js src\server-v099.js
echo.
echo PalPanel wurde beendet.
pause
endlocal