param(
    [string]$Root = "C:\PalPanel",
    [string]$ServerDir = "C:\PalPanel\server",
    [string]$SteamCmdDir = "C:\PalPanel\steamcmd"
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

function Log($message) {
    Write-Output "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $message"
}

$steamZip = Join-Path $Root "steamcmd.zip"
$steamExe = Join-Path $SteamCmdDir "steamcmd.exe"
$serverExe = Join-Path $ServerDir "PalServer.exe"

New-Item -ItemType Directory -Force -Path $Root, $ServerDir, $SteamCmdDir, (Join-Path $Root "data"), (Join-Path $Root "logs"), (Join-Path $Root "backups") | Out-Null

if (-not (Test-Path $steamExe)) {
    Log "SteamCMD ist nicht installiert. Download wird gestartet..."
    Invoke-WebRequest -Uri "https://steamcdn-a.akamaihd.net/client/installer/steamcmd.zip" -OutFile $steamZip
    Log "SteamCMD wurde heruntergeladen. Entpacke..."
    Expand-Archive -Path $steamZip -DestinationPath $SteamCmdDir -Force
    Remove-Item $steamZip -Force -ErrorAction SilentlyContinue
    Log "SteamCMD wurde installiert."
} else {
    Log "SteamCMD ist bereits vorhanden."
}

Log "Installiere/validiere Palworld Dedicated Server (Steam App 2394010)..."
& $steamExe +force_install_dir $ServerDir +login anonymous +app_update 2394010 validate +quit
if ($LASTEXITCODE -ne 0) {
    throw "SteamCMD wurde mit Exitcode $LASTEXITCODE beendet."
}

if (-not (Test-Path $serverExe)) {
    throw "Installation wurde beendet, aber PalServer.exe wurde nicht gefunden: $serverExe"
}

# Firewall rule is helpful but requires elevation. Failure is intentionally non-fatal.
try {
    $rule = Get-NetFirewallRule -DisplayName "PalPanel - Palworld UDP 8211" -ErrorAction SilentlyContinue
    if (-not $rule) {
        New-NetFirewallRule -DisplayName "PalPanel - Palworld UDP 8211" -Direction Inbound -Protocol UDP -LocalPort 8211 -Action Allow | Out-Null
        Log "Windows-Firewallregel für UDP 8211 wurde angelegt."
    }
} catch {
    Log "Hinweis: Firewallregel konnte nicht automatisch angelegt werden. Starte PalPanel bei Bedarf als Administrator oder lege UDP 8211 manuell frei."
}

Log "Palworld Dedicated Server ist bereit: $serverExe"
