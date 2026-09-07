param(
  [Parameter(Mandatory=$true)][string]$ServerDir,
  [Parameter(Mandatory=$true)][string]$BackupFile,
  [Parameter(Mandatory=$true)][string]$BackupDir
)
$ErrorActionPreference = "Stop"
$resolvedBackupRoot = [IO.Path]::GetFullPath($BackupDir)
$resolvedFile = [IO.Path]::GetFullPath($BackupFile)
if (!$resolvedFile.StartsWith($resolvedBackupRoot,[StringComparison]::OrdinalIgnoreCase)) { throw "Backup liegt außerhalb des Backup-Ordners." }
if (!(Test-Path $resolvedFile)) { throw "Backup wurde nicht gefunden." }
$saveDir = Join-Path $ServerDir "Pal\Saved"
if (!(Test-Path $saveDir)) { throw "Saved-Ordner wurde nicht gefunden." }
$stamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
$safety = Join-Path $BackupDir ("palworld_{0}_pre-restore.zip" -f $stamp)
Write-Output "Erstelle Sicherheitsbackup vor Restore..."
Compress-Archive -Path (Join-Path $saveDir '*') -DestinationPath $safety -CompressionLevel Optimal -Force
$temp = Join-Path $env:TEMP ("palpanel_restore_" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $temp | Out-Null
try {
  Write-Output "Entpacke Backup..."
  Expand-Archive -Path $resolvedFile -DestinationPath $temp -Force
  Write-Output "Ersetze Saved-Daten..."
  Get-ChildItem -Force $saveDir | Remove-Item -Recurse -Force
  Copy-Item -Path (Join-Path $temp '*') -Destination $saveDir -Recurse -Force
  Write-Output "Restore erfolgreich. Sicherheitsbackup: $safety"
} finally {
  Remove-Item -Recurse -Force $temp -ErrorAction SilentlyContinue
}
