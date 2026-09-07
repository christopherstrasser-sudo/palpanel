const fs = require('fs');
const path = require('path');
const http = require('http');
const childProcess = require('child_process');

const APP_DIR = path.resolve(__dirname, '..');
const defaults = JSON.parse(fs.readFileSync(path.join(APP_DIR, 'config', 'default.json'), 'utf8'));
const USER_CONFIG = path.join(defaults.paths.data, 'config.json');
const AUTOMATION_FILE = path.join(defaults.paths.data, 'automation.json');
const REST_FILE = path.join(defaults.paths.data, 'palworld-rest.json');
const BACKUP_SCRIPT = path.join(APP_DIR, 'scripts', 'backup-palworld.ps1');
const originalCreateServer = http.createServer.bind(http);

const automationDefaults = {
  restartEnabled: false,
  restartTime: '04:00',
  warningMinutes: [30, 10, 5, 1],
  warningMessage: 'Server-Neustart in {minutes} Minute(n).',
  shutdownMessage: 'Server wird für einen geplanten Neustart heruntergefahren.',
  backupBeforeRestart: true
};

function loadJson(file, fallback = {}) {
  try { return JSON.parse(fs.readFileSync(file, 'utf8')); } catch { return fallback; }
}
function saveJson(file, value) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, JSON.stringify(value, null, 2), 'utf8');
}
function getUserConfig() {
  const current = loadJson(USER_CONFIG, defaults);
  return {
    ...defaults,
    ...current,
    maintenance: { ...defaults.maintenance, ...(current.maintenance || {}) },
    palworld: { ...defaults.palworld, ...(current.palworld || {}), rest: { ...defaults.palworld.rest, ...(current.palworld?.rest || {}) } }
  };
}
function getAutomation() {
  return { ...automationDefaults, ...loadJson(AUTOMATION_FILE, {}) };
}
function normalizeWarnings(value) {
  const list = Array.isArray(value) ? value : String(value || '').split(',');
  return [...new Set(list.map(Number).filter(n => Number.isInteger(n) && n >= 1 && n <= 1440))].sort((a, b) => b - a).slice(0, 12);
}
function saveAutomation(input) {
  const cfg = getUserConfig();
  cfg.maintenance = {
    ...cfg.maintenance,
    restartEnabled: false,
    backupEnabled: !!input.backupEnabled,
    backupIntervalHours: Math.max(1, Math.min(168, Number(input.backupIntervalHours) || 6)),
    backupRetention: Math.max(1, Math.min(500, Number(input.backupRetention) || 20))
  };
  saveJson(USER_CONFIG, cfg);

  const current = getAutomation();
  const next = {
    ...current,
    restartEnabled: !!input.restartEnabled,
    restartTime: /^([01]\d|2[0-3]):[0-5]\d$/.test(String(input.restartTime || '')) ? String(input.restartTime) : current.restartTime,
    warningMinutes: normalizeWarnings(input.warningMinutes).length ? normalizeWarnings(input.warningMinutes) : [30, 10, 5, 1],
    warningMessage: String(input.warningMessage || automationDefaults.warningMessage).slice(0, 300),
    shutdownMessage: String(input.shutdownMessage || automationDefaults.shutdownMessage).slice(0, 300),
    backupBeforeRestart: input.backupBeforeRestart !== false
  };
  saveJson(AUTOMATION_FILE, next);
  return { maintenance: cfg.maintenance, restart: next };
}

// Disable the legacy v0.3.2 restart scheduler. v0.3.4 owns planned restarts.
(function disableLegacyRestart() {
  const cfg = getUserConfig();
  if (cfg.maintenance?.restartEnabled) {
    cfg.maintenance.restartEnabled = false;
    saveJson(USER_CONFIG, cfg);
  }
})();

async function sessionValid(req) {
  try {
    const response = await fetch('http://127.0.0.1:8787/api/admin/session', {
      headers: { Cookie: req.headers.cookie || '' },
      signal: AbortSignal.timeout(1500)
    });
    if (!response.ok) return false;
    return !!(await response.json()).authenticated;
  } catch { return false; }
}
function sendJson(res, status, body) {
  const data = Buffer.from(JSON.stringify(body));
  res.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8', 'Content-Length': data.length, 'Cache-Control': 'no-store' });
  res.end(data);
}
function readBody(req) {
  return new Promise((resolve, reject) => {
    let raw = '';
    req.on('data', chunk => { raw += chunk; if (raw.length > 1024 * 1024) reject(new Error('Request too large')); });
    req.on('end', () => { try { resolve(raw ? JSON.parse(raw) : {}); } catch (e) { reject(e); } });
    req.on('error', reject);
  });
}

http.createServer = function patchedCreateServer(handler) {
  return originalCreateServer(async (req, res) => {
    const url = new URL(req.url, 'http://localhost');
    if (url.pathname !== '/api/admin/automation') return handler(req, res);
    if (!(await sessionValid(req))) return sendJson(res, 401, { error: 'Nicht angemeldet.' });
    try {
      if (req.method === 'GET') {
        const cfg = getUserConfig();
        return sendJson(res, 200, {
          backupEnabled: !!cfg.maintenance.backupEnabled,
          backupIntervalHours: Number(cfg.maintenance.backupIntervalHours) || 6,
          backupRetention: Number(cfg.maintenance.backupRetention) || 20,
          ...getAutomation()
        });
      }
      if (req.method === 'PUT') {
        const input = await readBody(req);
        return sendJson(res, 200, { ok: true, ...saveAutomation(input) });
      }
      return sendJson(res, 405, { error: 'Method not allowed' });
    } catch (err) {
      return sendJson(res, 400, { error: err.message });
    }
  });
};

function restCredentials() { return loadJson(REST_FILE, null); }
async function rest(endpoint, body) {
  const cfg = getUserConfig();
  const creds = restCredentials();
  if (!creds?.password) throw new Error('REST API ist nicht eingerichtet.');
  const auth = Buffer.from(`${creds.username || 'admin'}:${creds.password}`).toString('base64');
  const response = await fetch(`http://${cfg.palworld.rest.host || '127.0.0.1'}:${cfg.palworld.rest.port || 8212}/v1/api${endpoint}`, {
    method: 'POST',
    headers: { Accept: 'application/json', 'Content-Type': 'application/json', Authorization: `Basic ${auth}` },
    body: JSON.stringify(body || {}),
    signal: AbortSignal.timeout(5000)
  });
  if (!response.ok) throw new Error(`Palworld REST HTTP ${response.status}`);
  return true;
}
function psEscape(value) { return String(value).replace(/'/g, "''"); }
function serverRunning() {
  const root = psEscape(path.resolve(getUserConfig().paths.server));
  const cmd = `$r='${root}'; @(Get-CimInstance Win32_Process | Where-Object { $_.ExecutablePath -and $_.ExecutablePath.StartsWith($r,[StringComparison]::OrdinalIgnoreCase) -and $_.Name -like 'PalServer*' }).Count`;
  try { return Number(childProcess.execFileSync('powershell.exe', ['-NoProfile', '-Command', cmd], { encoding: 'utf8', timeout: 4000, windowsHide: true }).trim()) > 0; }
  catch { return false; }
}
function startServer() {
  const cfg = getUserConfig();
  if (serverRunning()) return;
  const exe = path.join(cfg.paths.server, 'PalServer.exe');
  if (!fs.existsSync(exe)) return;
  const args = [`-port=${cfg.palworld.port}`, `-players=${cfg.palworld.maxPlayers}`, ...(cfg.palworld.startupArgs || [])];
  const child = childProcess.spawn(exe, args, { cwd: cfg.paths.server, detached: true, stdio: 'ignore', windowsHide: false });
  child.unref();
}
function backupBeforeRestart(callback) {
  const cfg = getUserConfig();
  const auto = getAutomation();
  if (!auto.backupBeforeRestart) return callback();
  const child = childProcess.spawn('powershell.exe', [
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', BACKUP_SCRIPT,
    '-ServerDir', cfg.paths.server,
    '-BackupDir', cfg.paths.backups,
    '-Reason', 'scheduled-restart',
    '-Retention', String(cfg.maintenance.backupRetention || 20)
  ], { cwd: APP_DIR, windowsHide: true, stdio: 'ignore' });
  child.once('close', () => callback());
  child.once('error', () => callback());
}

const sentWarnings = new Set();
let restartInProgress = false;
function localMinutes(now) { return now.getHours() * 60 + now.getMinutes(); }
function restartMinutes(time) { const [h, m] = time.split(':').map(Number); return h * 60 + m; }
function keyFor(now, suffix) { return `${now.getFullYear()}-${now.getMonth()+1}-${now.getDate()}:${suffix}`; }

async function schedulerTick() {
  const auto = getAutomation();
  if (!auto.restartEnabled || restartInProgress || !serverRunning()) return;
  const now = new Date();
  const target = restartMinutes(auto.restartTime);
  let diff = target - localMinutes(now);
  if (diff < 0) diff += 1440;

  for (const minutes of auto.warningMinutes) {
    if (diff === minutes) {
      const key = keyFor(now, `warn-${auto.restartTime}-${minutes}`);
      if (!sentWarnings.has(key)) {
        sentWarnings.add(key);
        const message = auto.warningMessage.replace(/\{minutes\}/g, String(minutes));
        try { await rest('/announce', { message }); } catch (err) { console.error('[Automation] Warnung fehlgeschlagen:', err.message); }
      }
    }
  }

  if (diff === 0) {
    const key = keyFor(now, `restart-${auto.restartTime}`);
    if (sentWarnings.has(key)) return;
    sentWarnings.add(key);
    restartInProgress = true;
    try { await rest('/save', {}); } catch {}
    backupBeforeRestart(async () => {
      try {
        await rest('/shutdown', { waittime: 10, message: auto.shutdownMessage });
      } catch (err) {
        console.error('[Automation] REST-Shutdown fehlgeschlagen:', err.message);
        restartInProgress = false;
        return;
      }
      const deadline = Date.now() + 120000;
      const timer = setInterval(() => {
        if (!serverRunning()) {
          clearInterval(timer);
          setTimeout(() => { try { startServer(); } finally { restartInProgress = false; } }, 5000);
        } else if (Date.now() > deadline) {
          clearInterval(timer);
          restartInProgress = false;
          console.error('[Automation] Server wurde innerhalb von 120 Sekunden nicht beendet.');
        }
      }, 2000);
    });
  }
}
setInterval(() => schedulerTick().catch(err => console.error('[Automation]', err)), 15000);

console.log('PalPanel v0.3.4 Automatisierungen geladen.');
require('./server-v033.js');
