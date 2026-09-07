param(
    [string]$ServerDir = "C:\PalPanel\server",
    [string]$SteamCmdDir = "C:\PalPanel\steamcmd"
)

$ErrorActionPreference = "Stop"
$steamExe = Join-Path $SteamCmdDir "steamcmd.exe"
if (-not (Test-Path $steamExe)) { throw "SteamCMD fehlt: $steamExe" }

Write-Output "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] Prüfe und installiere Palworld-Serverupdates..."
& $steamExe +force_install_dir $ServerDir +login anonymous +app_update 2394010 validate +quit
if ($LASTEXITCODE -ne 0) { throw "SteamCMD wurde mit Exitcode $LASTEXITCODE beendet." }
Write-Output "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] Update/Validierung abgeschlossen."
