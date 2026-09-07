@echo off
setlocal
cd /d "%~dp0"
title PalPanel v0.3.1
where node >nul 2>&1
if errorlevel 1 (
 echo [FEHLER] Node.js 20 oder neuer wird benoetigt.
 pause
 exit /b 1
)
echo.
echo Starte PalPanel v0.3.1...
echo Frontend: http://localhost:8787
echo Admin:    http://localhost:8787/admin
echo.
node src\server-v03-bootstrap.js
echo.
echo PalPanel wurde beendet.
pause
endlocal
