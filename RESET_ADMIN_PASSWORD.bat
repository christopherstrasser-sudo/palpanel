@echo off
setlocal
cd /d "%~dp0"
title PalPanel - Admin Passwort Reset

echo.
echo ============================================================
echo  PalPanel - Admin Passwort Reset
echo ============================================================
echo.

where node >nul 2>&1
if errorlevel 1 (
    echo [FEHLER] Node.js wurde nicht gefunden.
    echo Bitte Node.js installieren bzw. PATH pruefen.
    echo.
    pause
    exit /b 1
)

node "%~dp0scripts\reset-admin-password.js"
set "EXITCODE=%ERRORLEVEL%"

echo.
if not "%EXITCODE%"=="0" (
    echo Reset fehlgeschlagen. Siehe Fehlermeldung oben.
)

echo Dieses Fenster offen lassen, bis du das neue Passwort notiert hast.
echo.
pause
exit /b %EXITCODE%
