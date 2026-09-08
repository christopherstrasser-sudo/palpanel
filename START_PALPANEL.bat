@echo off
setlocal
cd /d "%~dp0"
title PalPanel v0.7.2
where node >nul 2>&1
if errorlevel 1 (
 echo [FEHLER] Node.js 24 oder neuer wird fuer User-System und SQLite benoetigt.
 pause
 exit /b 1
)
echo.
echo Starte PalPanel v0.7.2...
echo Frontend: http://localhost:8787
echo Admin:    http://localhost:8787/admin/
echo Bridge:   http://localhost:8787/admin/bridge
echo Profil:   http://localhost:8787/profile.html
echo.
node src\server-v072.js
echo.
echo PalPanel wurde beendet.
pause
endlocal
