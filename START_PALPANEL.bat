@echo off
setlocal
cd /d "%~dp0"
title PalPanel v0.9.2
where node >nul 2>&1
if errorlevel 1 (
 echo [FEHLER] Node.js 24 oder neuer wird fuer User-System und SQLite benoetigt.
 pause
 exit /b 1
)
echo.
echo Starte PalPanel v0.9.2...
echo Frontend: http://localhost:8787
echo Profil:   http://localhost:8787/profile
echo Shop:     http://localhost:8787/shop
echo Spieler:  http://localhost:8787/player/ID
echo Admin:    http://localhost:8787/admin/
echo Bridge:   http://localhost:8787/admin/bridge
echo UI:       Frontend + Admin Visual Overhaul aktiv
echo Banner:   Preload + ETag + Langzeitcache aktiv
echo Erfolge:  Badges + Trophy-Wert + Community-Seltenheit aktiv
echo Duelle:   Paldex + Alpha + Bosse + Spielzeit + Trophäen aktiv
echo Frontend: Dynamische Node-Views ohne statische Public-HTML-Seiten
echo Capture:  Live-Faenge + Alpha-Bonus aktiv
echo Gameplay: Stufenaufstiege + Bosse + Spielertode aktiv
echo Tower:    Tower-Boss-Erfolge aktiv
echo Profil:   Abenteueransicht + Meilensteine + Aktivitaeten aktiv
echo Community: Oeffentliche Spielerprofile aus der Rangliste aktiv
echo Steam:    Profilbilder + Ranglisten-Avatare aktiv
echo Status:   Fast-Cache + Async-Prozesscache aktiv
echo.
node -r ./src/frontend-routeguard.js -r ./src/fast-process-shim.js src\server-v092.js
echo.
echo PalPanel wurde beendet.
pause
endlocal
