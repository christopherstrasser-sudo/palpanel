@echo off
setlocal
cd /d "%~dp0"
title PalPanel v0.1

where node >nul 2>&1
if errorlevel 1 (
  echo.
  echo ============================================================
  echo  PalPanel v0.1 - Node.js fehlt
  echo ============================================================
  echo.
  echo Bitte Node.js 20 oder neuer installieren und danach diese Datei
  echo erneut starten.
  echo.
  pause
  exit /b 1
)

echo.
echo Starte PalPanel...
echo Dashboard: http://localhost:8787
echo.
node src\server.js

echo.
echo PalPanel wurde beendet.
pause
endlocal
