@echo off
setlocal
cd /d "%~dp0"
title PalPanel v0.8.6
where node >nul 2>&1
if errorlevel 1 (
 echo [FEHLER] Node.js 24 oder neuer wird fuer User-System und SQLite benoetigt.
 pause
 exit /b 1
)
echo.
echo Starte PalPanel v0.8.6...
echo Frontend: http://localhost:8787
echo Admin:    http://localhost:8787/admin/
echo Bridge:   http://localhost:8787/admin/bridge
echo Profil:   http://localhost:8787/profile.html
echo Shop:     http://localhost:8787/shop
echo Capture:  Live-Capture + Alpha-Bonus aktiv
echo Gameplay: Level-Ups + Bosse + Spielertode aktiv
echo Tower:    Tower-Boss-Success-Tracking aktiv
echo Status:   Fast-Cache + Async-Prozesscache aktiv
echo.
node -r ./src/fast-process-shim.js src\server-v086.js
echo.
echo PalPanel wurde beendet.
pause
endlocal