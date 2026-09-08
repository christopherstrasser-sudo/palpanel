@echo off
setlocal
cd /d "%~dp0"
title PalPanel v0.8.3
where node >nul 2>&1
if errorlevel 1 (
 echo [FEHLER] Node.js 24 oder neuer wird fuer User-System und SQLite benoetigt.
 pause
 exit /b 1
)
echo.
echo Starte PalPanel v0.8.3...
echo Frontend: http://localhost:8787
echo Admin:    http://localhost:8787/admin/
echo Bridge:   http://localhost:8787/admin/bridge
echo Profil:   http://localhost:8787/profile.html
echo Shop:     http://localhost:8787/shop
echo Capture:  Live-Events -> Progression aktiv
echo Status:   Fast-Cache aktiv
echo.
node src\server-v083.js
echo.
echo PalPanel wurde beendet.
pause
endlocal
