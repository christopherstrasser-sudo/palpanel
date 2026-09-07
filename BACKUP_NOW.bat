@echo off
setlocal
cd /d "%~dp0"
title PalPanel - Backup
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\backup-palworld.ps1" -ServerDir "C:\PalPanel\server" -BackupDir "C:\PalPanel\backups" -Reason "manual"
echo.
pause
