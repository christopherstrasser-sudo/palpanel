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

function Run-SteamCmd([string[]]$Arguments) {
    & $steamExe @Arguments
    return $LASTEXITCODE
}

$steamZip = Join-Path $Root "steamcmd.zip"
$steamExe = Join-Path $SteamCmdDir "steamcmd.exe"
$serverExe = Join-Path $ServerDir "PalServer.exe"

New-Item -ItemType Directory -Force -Path $Root, $ServerDir, $SteamCmdDir, (Join-Path $Root "data"), (Join-Path $Root "logs"), (Join-Path $Root "backups") | Out-Null

$freshSteamCmd = -not (Test-Path $steamExe)

if ($freshSteamCmd) {
    Log "SteamCMD ist nicht installiert. Download wird gestartet..."
    Invoke-WebRequest -Uri "https://steamcdn-a.akamaihd.net/client/installer/steamcmd.zip" -OutFile $steamZip
    Log "SteamCMD wurde heruntergeladen. Entpacke..."
    Expand-Archive -Path $steamZip -DestinationPath $SteamCmdDir -Force
    Remove-Item $steamZip -Force -ErrorAction SilentlyContinue
    Log "SteamCMD wurde entpackt."

    # SteamCMD aktualisiert sich beim allerersten Start selbst. Dieser Bootstrap
    # läuft bewusst separat, damit ein Relaunch nicht den app_update-Auftrag verliert.
    Log "Initialisiere und aktualisiere SteamCMD..."
    $bootstrapExit = Run-SteamCmd @('+quit')
    if ($bootstrapExit -ne 0) {
        Log "SteamCMD-Bootstrap endete mit Exitcode $bootstrapExit. Fahre mit einem frischen Installationslauf fort."
    } else {
        Log "SteamCMD wurde initialisiert."
    }
} else {
    Log "SteamCMD ist bereits vorhanden."
}

$installArgs = @(
    '+force_install_dir', $ServerDir,
    '+login', 'anonymous',
    '+app_update', '2394010', 'validate',
    '+quit'
)

$maxAttempts = 3
$success = $false
for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
    Log "Installiere/validiere Palworld Dedicated Server (Steam App 2394010) - Versuch $attempt/$maxAttempts..."
    $exitCode = Run-SteamCmd $installArgs

    if ($exitCode -eq 0 -and (Test-Path $serverExe)) {
        $success = $true
        break
    }

    if (Test-Path $serverExe) {
        Log "PalServer.exe wurde trotz SteamCMD-Exitcode $exitCode gefunden. Installation wird als erfolgreich behandelt."
        $success = $true
        break
    }

    if ($attempt -lt $maxAttempts) {
        Log "SteamCMD wurde mit Exitcode $exitCode beendet. Warte kurz und versuche es erneut..."
        Start-Sleep -Seconds 3
    }
}

if (-not $success) {
    throw "Palworld-Installation fehlgeschlagen. PalServer.exe wurde nach $maxAttempts SteamCMD-Läufen nicht gefunden."
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
