param(
  [Parameter(Mandatory=$true)][string]$ServerDir,
  [Parameter(Mandatory=$true)][string]$BackupDir,
  [string]$Reason = 'manual',
  [int]$Retention = 20
)
$ErrorActionPreference = 'Stop'
$saveDir = Join-Path $ServerDir 'Pal\Saved'
if (!(Test-Path $saveDir)) { throw "Palworld Saved-Ordner wurde nicht gefunden: $saveDir" }
New-Item -ItemType Directory -Force -Path $BackupDir | Out-Null
$stamp = Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'
$safeReason = ($Reason -replace '[^a-zA-Z0-9_-]','_')
$zip = Join-Path $BackupDir ("palworld_{0}_{1}.zip" -f $stamp,$safeReason)
Write-Output "Erstelle Backup: $zip"
Compress-Archive -Path (Join-Path $saveDir '*') -DestinationPath $zip -CompressionLevel Optimal -Force
$size = (Get-Item $zip).Length
Write-Output ("Backup fertig: {0:N2} MB" -f ($size / 1MB))
if ($Retention -gt 0) {
  $files = @(Get-ChildItem $BackupDir -Filter 'palworld_*.zip' -File | Sort-Object LastWriteTime -Descending)
  if ($files.Count -gt $Retention) {
    $files | Select-Object -Skip $Retention | ForEach-Object { Write-Output "Entferne altes Backup: $($_.Name)"; Remove-Item $_.FullName -Force }
  }
}
Write-Output $zip
