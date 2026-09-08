// PalPanel process-status compatibility shim.
//
// Older PalPanel layers synchronously call PowerShell/Get-CimInstance to check
// whether PalServer is running. Those calls can block Node for several seconds.
// This preload keeps one shared async process cache and answers both the old
// synchronous probes and the newer async Get-Process probe from memory.
// Destructive commands such as Stop-Process are never intercepted.

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
global.__PALPANEL_PROCESS_CACHE__ = cache;

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

const originalExecFile = childProcess.execFile.bind(childProcess);
const originalExecFileSync = childProcess.execFileSync.bind(childProcess);

function refresh() {
  if (cache.refreshing) return;
  cache.refreshing = true;

  const root = psEscape(path.resolve(loadConfig().paths.server));
  const cmd = `$r='${root}'; @(` +
    `Get-Process -Name 'PalServer*' -ErrorAction SilentlyContinue | ForEach-Object { ` +
    `try { $p=$_.Path; if ($p -and $p.StartsWith($r,[StringComparison]::OrdinalIgnoreCase)) { ` +
    `[PSCustomObject]@{ProcessId=$_.Id;Name=$_.ProcessName} } } catch {} }` +
    `) | ConvertTo-Json -Compress`;

  originalExecFile('powershell.exe', ['-NoProfile', '-Command', cmd], {
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

function isPowerShell(file) {
  return path.basename(String(file || '')).toLowerCase() === 'powershell.exe';
}
function commandText(args) {
  return Array.isArray(args) ? args.join(' ') : String(args || '');
}
function cachedJson() {
  return JSON.stringify(cache.rows);
}
function refreshIfStale() {
  if (Date.now() - cache.updatedAt > 3000) refresh();
}

childProcess.execFileSync = function palPanelFastExecFileSync(file, args = [], options = {}) {
  const command = commandText(args);
  const isLegacyStatusProbe =
    isPowerShell(file) &&
    command.includes('Get-CimInstance Win32_Process') &&
    command.includes('PalServer') &&
    !command.includes('Stop-Process');

  if (!isLegacyStatusProbe) {
    return originalExecFileSync(file, args, options);
  }

  refreshIfStale();

  let value;
  if (command.includes('ConvertTo-Json')) value = cachedJson();
  else if (command.includes('.Count')) value = `${cache.rows.length}\r\n`;
  else return originalExecFileSync(file, args, options);

  return options && options.encoding ? value : Buffer.from(value);
};

// server-v083 also asks PowerShell asynchronously with Get-Process. Since this
// shim is preloaded first, serve that exact read-only probe from the same cache
// instead of launching a second PowerShell process every few seconds.
childProcess.execFile = function palPanelFastExecFile(file, args = [], options, callback) {
  if (typeof options === 'function') {
    callback = options;
    options = {};
  }
  options = options || {};

  const command = commandText(args);
  const isFastStatusProbe =
    isPowerShell(file) &&
    command.includes("Get-Process -Name 'PalServer*'") &&
    command.includes('ConvertTo-Json') &&
    !command.includes('Stop-Process');

  if (!isFastStatusProbe) {
    return originalExecFile(file, args, options, callback);
  }

  refreshIfStale();
  const value = options.encoding ? cachedJson() : Buffer.from(cachedJson());
  process.nextTick(() => callback?.(null, value, options.encoding ? '' : Buffer.alloc(0)));

  // The callers only use callback semantics. Return a minimal EventEmitter-like
  // object so accidental listener attachment does not explode.
  return {
    on() { return this; },
    once() { return this; },
    unref() { return this; }
  };
};

refresh();
setInterval(refresh, 3000).unref();

console.log('[FastProcess] PalServer-Prozessstatus läuft über einen gemeinsamen Async-Cache.');
