// PalPanel process-status compatibility shim.
//
// Older PalPanel layers synchronously call PowerShell/Get-CimInstance to check
// whether PalServer is running. Those calls can block Node for several seconds.
// This preload keeps a tiny async process cache and answers *read-only* legacy
// status probes from memory. Destructive commands such as Stop-Process are never
// intercepted and still execute normally.

const fs = require('fs');
const path = require('path');
const childProcess = require('child_process');

const APP_DIR = path.resolve(__dirname, '..');
let defaults = null;
try { defaults = JSON.parse(fs.readFileSync(path.join(APP_DIR, 'config', 'default.json'), 'utf8')); }
catch { defaults = { paths: { server: 'C:\\PalPanel\\server', data: 'C:\\PalPanel\\data' } }; }

function loadConfig() {
  try {
    const current = JSON.parse(fs.readFileSync(path.join(defaults.paths.data, 'config.json'), 'utf8'));
    return { ...defaults, ...current, paths: { ...defaults.paths, ...(current.paths || {}) } };
  } catch {
    return defaults;
  }
}

function psEscape(value) {
  return String(value).replace(/'/g, "''");
}

const cache = {
  rows: [],
  refreshing: false,
  updatedAt: 0
};

function parseRows(raw) {
  const text = String(raw || '').trim();
  if (!text) return [];
  try {
    const parsed = JSON.parse(text);
    return Array.isArray(parsed) ? parsed : parsed ? [parsed] : [];
  } catch {
    return [];
  }
}

function refresh() {
  if (cache.refreshing) return;
  cache.refreshing = true;

  const root = psEscape(path.resolve(loadConfig().paths.server));
  const cmd = `$r='${root}'; @(` +
    `Get-Process -Name 'PalServer*' -ErrorAction SilentlyContinue | ForEach-Object { ` +
    `try { $p=$_.Path; if ($p -and $p.StartsWith($r,[StringComparison]::OrdinalIgnoreCase)) { ` +
    `[PSCustomObject]@{ProcessId=$_.Id;Name=$_.ProcessName} } } catch {} }` +
    `) | ConvertTo-Json -Compress`;

  childProcess.execFile('powershell.exe', ['-NoProfile', '-Command', cmd], {
    encoding: 'utf8',
    timeout: 2500,
    windowsHide: true,
    maxBuffer: 256 * 1024
  }, (err, stdout) => {
    if (!err) cache.rows = parseRows(stdout);
    cache.updatedAt = Date.now();
    cache.refreshing = false;
  });
}

const originalExecFileSync = childProcess.execFileSync.bind(childProcess);

childProcess.execFileSync = function palPanelFastExecFileSync(file, args = [], options = {}) {
  const exe = path.basename(String(file || '')).toLowerCase();
  const commandText = Array.isArray(args) ? args.join(' ') : String(args || '');

  const isPalStatusProbe =
    exe === 'powershell.exe' &&
    commandText.includes('Get-CimInstance Win32_Process') &&
    commandText.includes('PalServer') &&
    !commandText.includes('Stop-Process');

  if (!isPalStatusProbe) {
    return originalExecFileSync(file, args, options);
  }

  if (Date.now() - cache.updatedAt > 2000) refresh();

  let value;
  if (commandText.includes('ConvertTo-Json')) {
    value = JSON.stringify(cache.rows);
  } else if (commandText.includes('.Count')) {
    value = `${cache.rows.length}\r\n`;
  } else {
    return originalExecFileSync(file, args, options);
  }

  return options && options.encoding ? value : Buffer.from(value);
};

refresh();
setInterval(refresh, 1500).unref();

console.log('[FastProcess] Legacy PalServer-WMI-Statusabfragen laufen jetzt aus Async-Cache.');
