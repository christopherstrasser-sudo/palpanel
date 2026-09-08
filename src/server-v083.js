const fs = require('fs');
const path = require('path');
const http = require('http');
const { execFile } = require('child_process');

const APP_DIR = path.resolve(__dirname, '..');
const defaults = JSON.parse(fs.readFileSync(path.join(APP_DIR, 'config', 'default.json'), 'utf8'));
const DATA_DIR = defaults.paths.data;
const USER_CONFIG = path.join(DATA_DIR, 'config.json');
const REST_FILE = path.join(DATA_DIR, 'palworld-rest.json');
const VERSION = '0.8.3';

function loadJson(file, fallback = null) {
  try { return JSON.parse(fs.readFileSync(file, 'utf8')); } catch { return fallback; }
}

function config() {
  const current = loadJson(USER_CONFIG, {}) || {};
  const p = current.palworld || {};
  return {
    ...defaults,
    ...current,
    panel: { ...defaults.panel, ...(current.panel || {}) },
    paths: { ...defaults.paths, ...(current.paths || {}) },
    palworld: { ...defaults.palworld, ...p, rest: { ...defaults.palworld.rest, ...(p.rest || {}) } },
    maintenance: { ...defaults.maintenance, ...(current.maintenance || {}) },
    event: { ...defaults.event, ...(current.event || {}) }
  };
}

function sendJson(res, status, body) {
  const data = Buffer.from(JSON.stringify(body));
  res.writeHead(status, {
    'Content-Type': 'application/json; charset=utf-8',
    'Content-Length': data.length,
    'Cache-Control': 'no-store'
  });
  res.end(data);
}

function psEscape(value) {
  return String(value).replace(/'/g, "''");
}

const fast = {
  process: {
    running: false,
    pid: null,
    processName: null,
    at: 0,
    refreshing: false,
    error: null
  },
  live: {
    connected: false,
    info: {},
    metrics: {},
    players: [],
    updatedAt: null,
    at: 0,
    refreshing: false,
    error: null
  }
};

function parseProcessOutput(raw) {
  const text = String(raw || '').trim();
  if (!text) return [];
  try {
    const parsed = JSON.parse(text);
    return Array.isArray(parsed) ? parsed : parsed ? [parsed] : [];
  } catch {
    return [];
  }
}

function refreshProcessStatus() {
  if (fast.process.refreshing) return;
  fast.process.refreshing = true;

  const cfg = config();
  const root = psEscape(path.resolve(cfg.paths.server));
  // Get-Process is much lighter than the old synchronous Win32_Process WMI scan.
  // It runs fully in the background, so even a slow Windows process query can
  // never block HTTP requests or freeze the UI.
  const cmd = `$r='${root}'; @(` +
    `Get-Process -Name 'PalServer*' -ErrorAction SilentlyContinue | ForEach-Object { ` +
    `try { $p=$_.Path; if ($p -and $p.StartsWith($r,[StringComparison]::OrdinalIgnoreCase)) { ` +
    `[PSCustomObject]@{ProcessId=$_.Id;Name=$_.ProcessName} } } catch {} }` +
    `) | ConvertTo-Json -Compress`;

  execFile('powershell.exe', ['-NoProfile', '-Command', cmd], {
    encoding: 'utf8',
    timeout: 2500,
    windowsHide: true,
    maxBuffer: 256 * 1024
  }, (err, stdout) => {
    const rows = err ? [] : parseProcessOutput(stdout);
    fast.process.running = rows.length > 0;
    fast.process.pid = rows[0] ? Number(rows[0].ProcessId) || null : null;
    fast.process.processName = rows[0]?.Name || null;
    fast.process.error = err ? err.message : null;
    fast.process.at = Date.now();
    fast.process.refreshing = false;
  });
}

function restCredentials() {
  return loadJson(REST_FILE, null);
}

async function palRest(endpoint) {
  const cfg = config();
  const creds = restCredentials();
  if (!creds?.password) throw new Error('REST API ist nicht eingerichtet.');

  const auth = Buffer.from(`${creds.username || cfg.palworld.rest.username || 'admin'}:${creds.password}`).toString('base64');
  const response = await fetch(`http://${cfg.palworld.rest.host || '127.0.0.1'}:${cfg.palworld.rest.port || 8212}/v1/api${endpoint}`, {
    headers: { Accept: 'application/json', Authorization: `Basic ${auth}` },
    signal: AbortSignal.timeout(Math.min(1500, Number(cfg.palworld.rest.timeoutMs) || 1200))
  });
  if (!response.ok) throw new Error(`Palworld REST HTTP ${response.status}`);
  return response.json().catch(() => ({}));
}

async function refreshLiveStatus() {
  if (fast.live.refreshing) return;
  fast.live.refreshing = true;

  try {
    const [info, metrics, playersEnvelope] = await Promise.all([
      palRest('/info'),
      palRest('/metrics'),
      palRest('/players')
    ]);

    fast.live.connected = true;
    fast.live.info = info || {};
    fast.live.metrics = metrics || {};
    fast.live.players = Array.isArray(playersEnvelope?.players) ? playersEnvelope.players : [];
    fast.live.updatedAt = new Date().toISOString();
    fast.live.error = null;
    fast.live.at = Date.now();
  } catch (err) {
    fast.live.connected = false;
    fast.live.players = [];
    fast.live.updatedAt = new Date().toISOString();
    fast.live.error = err.message;
    fast.live.at = Date.now();
  } finally {
    fast.live.refreshing = false;
  }
}

function ensureFresh() {
  const now = Date.now();
  if (now - fast.process.at > 2000) refreshProcessStatus();
  if (now - fast.live.at > 2500) refreshLiveStatus();
}

function serverSnapshot() {
  const cfg = config();
  const running = fast.process.running || fast.live.connected;
  return {
    installed: fs.existsSync(path.join(cfg.paths.server, 'PalServer.exe')),
    steamcmdInstalled: fs.existsSync(path.join(cfg.paths.steamcmd, 'steamcmd.exe')),
    running,
    pid: fast.process.pid,
    processName: fast.process.processName,
    serverPath: cfg.paths.server
  };
}

function publicStatus() {
  const cfg = config();
  const s = serverSnapshot();
  const live = fast.live;
  const metrics = live.metrics || {};
  const info = live.info || {};

  return {
    version: VERSION,
    server: { running: s.running, installed: s.installed },
    event: cfg.event,
    palworld: {
      port: cfg.palworld.port,
      maxPlayers: metrics.maxplayernum ?? cfg.palworld.maxPlayers,
      name: info.servername || null,
      description: info.description || null,
      version: info.version || null,
      fps: metrics.serverfps ?? null,
      frameTime: metrics.serverframetime ?? null,
      uptime: metrics.uptime ?? null,
      currentPlayers: metrics.currentplayernum ?? live.players.length,
      apiConnected: live.connected
    },
    players: live.players.map(p => ({
      name: p.name,
      level: p.level,
      ping: p.ping,
      location_x: p.location_x,
      location_y: p.location_y
    })),
    live: { connected: live.connected, updatedAt: live.updatedAt }
  };
}

async function internalJson(pathname, cookie, timeout = 750) {
  const cfg = config();
  const response = await fetch(`http://127.0.0.1:${cfg.panel.port}${pathname}`, {
    headers: { Cookie: String(cookie || ''), Accept: 'application/json' },
    signal: AbortSignal.timeout(timeout)
  });
  const body = await response.json().catch(() => ({}));
  return { response, body };
}

async function adminStatus(req, res) {
  let session;
  try {
    session = await internalJson('/api/admin/session', req.headers.cookie, 750);
  } catch (err) {
    return sendJson(res, 503, { error: `Admin-Session konnte nicht geprüft werden: ${err.message}` });
  }
  if (!session.response.ok || !session.body.authenticated) {
    return sendJson(res, 401, { error: 'Nicht angemeldet.' });
  }

  let job = null;
  try {
    const result = await internalJson('/api/admin/job', req.headers.cookie, 750);
    if (result.response.ok) job = result.body.job || null;
  } catch {}

  const cfg = config();
  const live = fast.live;
  const creds = restCredentials();
  return sendJson(res, 200, {
    version: VERSION,
    server: serverSnapshot(),
    palworld: cfg.palworld,
    job: job ? { type: job.type, running: !!job.running, success: job.success } : null,
    rest: {
      configured: !!creds?.password,
      connected: live.connected,
      error: live.error || null
    },
    live: {
      connected: live.connected,
      info: live.info || {},
      metrics: live.metrics || {},
      players: live.players || [],
      updatedAt: live.updatedAt,
      error: live.error || null
    },
    maintenance: cfg.maintenance
  });
}

const previousCreateServer = http.createServer.bind(http);
http.createServer = function fastStatusCreateServer(options, requestListener) {
  const hasOptions = typeof options !== 'function';
  const listener = hasOptions ? requestListener : options;

  const wrapped = async (req, res) => {
    let url;
    try { url = new URL(req.url, 'http://localhost'); }
    catch { return listener(req, res); }

    if (req.method === 'GET' && url.pathname === '/api/public/status') {
      ensureFresh();
      return sendJson(res, 200, publicStatus());
    }

    if (req.method === 'GET' && url.pathname === '/api/admin/status') {
      ensureFresh();
      return adminStatus(req, res);
    }

    return listener(req, res);
  };

  return hasOptions ? previousCreateServer(options, wrapped) : previousCreateServer(wrapped);
};

// Prime caches before the first browser request. Requests never wait for these.
refreshProcessStatus();
refreshLiveStatus();
setInterval(refreshProcessStatus, 2000).unref();
setInterval(refreshLiveStatus, 2500).unref();

console.log('PalPanel v0.8.3 Fast-Status-Cache geladen. Statusabfragen blockieren Node nicht mehr.');
require('./server-v082.js');
