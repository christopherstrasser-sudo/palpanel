const http = require('http');
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const { spawn, execFileSync } = require('child_process');

const VERSION = '0.3.2';
const APP_DIR = path.resolve(__dirname, '..');
const PUBLIC_DIR = path.join(APP_DIR, 'public');
const ADMIN_DIR = path.join(APP_DIR, 'admin');
const DEFAULT_CONFIG = path.join(APP_DIR, 'config', 'default.json');
const defaults = JSON.parse(fs.readFileSync(DEFAULT_CONFIG, 'utf8'));

for (const dir of Object.values(defaults.paths)) fs.mkdirSync(dir, { recursive: true });

const USER_CONFIG = path.join(defaults.paths.data, 'config.json');
const ADMIN_FILE = path.join(defaults.paths.data, 'admin.json');
const REST_FILE = path.join(defaults.paths.data, 'palworld-rest.json');

if (!fs.existsSync(USER_CONFIG)) fs.writeFileSync(USER_CONFIG, JSON.stringify(defaults, null, 2), 'utf8');

function loadJson(file) { return JSON.parse(fs.readFileSync(file, 'utf8')); }
function saveJson(file, value) { fs.writeFileSync(file, JSON.stringify(value, null, 2), 'utf8'); }

function config() {
  try {
    const current = loadJson(USER_CONFIG);
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
  } catch {
    return defaults;
  }
}

function hashPassword(password, salt) { return crypto.scryptSync(password, salt, 64).toString('hex'); }
function ensureAdmin() {
  if (fs.existsSync(ADMIN_FILE)) return;
  const password = crypto.randomBytes(9).toString('base64url');
  const salt = crypto.randomBytes(16).toString('hex');
  saveJson(ADMIN_FILE, { username: 'admin', salt, hash: hashPassword(password, salt) });
  console.log('');
  console.log('ADMIN-ZUGANG ERSTELLT');
  console.log('Benutzer: admin');
  console.log(`Passwort: ${password}`);
  console.log('');
}
ensureAdmin();

const sessions = new Map();
const state = { startedAt: Date.now(), job: null, live: { at: 0, data: null }, lastRestart: null };

function json(res, status, body, headers = {}) {
  const data = Buffer.from(JSON.stringify(body));
  res.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8', 'Content-Length': data.length, 'Cache-Control': 'no-store', ...headers });
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

function parseCookies(req) {
  const out = {};
  String(req.headers.cookie || '').split(';').forEach(part => {
    const i = part.indexOf('=');
    if (i > 0) out[part.slice(0, i).trim()] = decodeURIComponent(part.slice(i + 1).trim());
  });
  return out;
}

function getSession(req) {
  const token = parseCookies(req).palpanel_admin;
  if (!token) return null;
  const item = sessions.get(token);
  if (!item || item.expires < Date.now()) { sessions.delete(token); return null; }
  item.expires = Date.now() + 12 * 60 * 60 * 1000;
  return item;
}

function requireAdmin(req, res) {
  if (!getSession(req)) { json(res, 401, { error: 'Nicht angemeldet.' }); return false; }
  return true;
}

function psEscape(value) { return String(value).replace(/'/g, "''"); }

function serverProcesses() {
  const root = psEscape(path.resolve(config().paths.server));
  const cmd = `$r='${root}'; @(Get-CimInstance Win32_Process | Where-Object { $_.ExecutablePath -and $_.ExecutablePath.StartsWith($r,[StringComparison]::OrdinalIgnoreCase) -and $_.Name -like 'PalServer*' } | Select-Object ProcessId,Name) | ConvertTo-Json -Compress`;
  try {
    const out = execFileSync('powershell.exe', ['-NoProfile', '-Command', cmd], { encoding: 'utf8', timeout: 5000, windowsHide: true }).trim();
    if (!out) return [];
    const parsed = JSON.parse(out);
    return Array.isArray(parsed) ? parsed : [parsed];
  } catch { return []; }
}

function serverStatus() {
  const cfg = config();
  const processes = serverProcesses();
  return {
    installed: fs.existsSync(path.join(cfg.paths.server, 'PalServer.exe')),
    steamcmdInstalled: fs.existsSync(path.join(cfg.paths.steamcmd, 'steamcmd.exe')),
    running: processes.length > 0,
    pid: processes[0] ? Number(processes[0].ProcessId) : null,
    processName: processes[0]?.Name || null,
    serverPath: cfg.paths.server
  };
}

function appendJob(data) {
  if (!state.job) return;
  String(data).replace(/\r/g, '').split('\n').filter(Boolean).forEach(line => state.job.log.push(line));
  if (state.job.log.length > 500) state.job.log.splice(0, state.job.log.length - 500);
}

function runJob(type, scriptName, args = []) {
  if (state.job?.running) throw new Error(`Es läuft bereits ein Job: ${state.job.type}`);
  state.job = { type, running: true, success: null, startedAt: new Date().toISOString(), finishedAt: null, exitCode: null, log: [] };
  const child = spawn('powershell.exe', ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', path.join(APP_DIR, 'scripts', scriptName), ...args], { cwd: APP_DIR, windowsHide: true });
  child.stdout.on('data', appendJob);
  child.stderr.on('data', appendJob);
  child.on('error', err => { appendJob(`FEHLER: ${err.message}`); state.job.running = false; state.job.success = false; state.job.finishedAt = new Date().toISOString(); });
  child.on('close', code => { state.job.running = false; state.job.success = code === 0; state.job.exitCode = code; state.job.finishedAt = new Date().toISOString(); appendJob(code === 0 ? 'Job erfolgreich abgeschlossen.' : `Job fehlgeschlagen (${code}).`); });
  return state.job;
}

function startPalworld() {
  const cfg = config();
  if (!serverStatus().installed) throw new Error('Palworld Dedicated Server ist nicht installiert.');
  if (serverStatus().running) throw new Error('Server läuft bereits.');
  const exe = path.join(cfg.paths.server, 'PalServer.exe');
  const args = [`-port=${cfg.palworld.port}`, `-players=${cfg.palworld.maxPlayers}`, ...(cfg.palworld.startupArgs || [])];
  const child = spawn(exe, args, { cwd: cfg.paths.server, detached: true, stdio: 'ignore', windowsHide: false });
  child.unref();
  state.live = { at: 0, data: null };
  return { pid: child.pid };
}

function stopPalworld() {
  const root = psEscape(path.resolve(config().paths.server));
  const cmd = `$r='${root}'; Get-CimInstance Win32_Process | Where-Object { $_.ExecutablePath -and $_.ExecutablePath.StartsWith($r,[StringComparison]::OrdinalIgnoreCase) -and $_.Name -like 'PalServer*' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }`;
  execFileSync('powershell.exe', ['-NoProfile', '-Command', cmd], { windowsHide: true, timeout: 10000 });
  state.live = { at: 0, data: null };
  return { ok: true };
}

function restCredentials() { try { return loadJson(REST_FILE); } catch { return null; } }
function settingsPath() { return path.join(config().paths.server, 'Pal', 'Saved', 'Config', 'WindowsServer', 'PalWorldSettings.ini'); }
function upsertSetting(text, key, rawValue) {
  const re = new RegExp(`${key}=(\\"[^\\"]*\\"|[^,)]*)`);
  if (re.test(text)) return text.replace(re, `${key}=${rawValue}`);
  return text.replace(/OptionSettings=\(([^\r\n]*)\)/, (m, inner) => `OptionSettings=(${inner}${inner.trim() ? ',' : ''}${key}=${rawValue})`);
}
function configureRest() {
  const cfg = config();
  const file = settingsPath();
  const def = path.join(cfg.paths.server, 'DefaultPalWorldSettings.ini');
  fs.mkdirSync(path.dirname(file), { recursive: true });
  if (!fs.existsSync(file)) fs.copyFileSync(def, file);
  let creds = restCredentials();
  if (!creds) { creds = { username: 'admin', password: crypto.randomBytes(24).toString('base64url') }; saveJson(REST_FILE, creds); }
  let text = fs.readFileSync(file, 'utf8');
  text = upsertSetting(text, 'RESTAPIEnabled', 'True');
  text = upsertSetting(text, 'RESTAPIPort', String(cfg.palworld.rest.port || 8212));
  text = upsertSetting(text, 'AdminPassword', JSON.stringify(creds.password));
  fs.writeFileSync(file, text, 'utf8');
}
function restConfigured() {
  try { return !!restCredentials() && /RESTAPIEnabled=True/i.test(fs.readFileSync(settingsPath(), 'utf8')); } catch { return false; }
}

async function rest(endpoint, options = {}) {
  const cfg = config();
  const creds = restCredentials();
  if (!creds) throw new Error('REST API ist nicht eingerichtet.');
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), cfg.palworld.rest.timeoutMs || 2500);
  try {
    const auth = Buffer.from(`${creds.username}:${creds.password}`).toString('base64');
    const response = await fetch(`http://${cfg.palworld.rest.host}:${cfg.palworld.rest.port}/v1/api${endpoint}`, { ...options, signal: controller.signal, headers: { Accept: 'application/json', Authorization: `Basic ${auth}`, ...(options.headers || {}) } });
    const raw = await response.text();
    let data = {};
    try { data = raw ? JSON.parse(raw) : {}; } catch { data = { raw }; }
    if (!response.ok) throw new Error(`Palworld REST HTTP ${response.status}`);
    return data;
  } finally { clearTimeout(timer); }
}

async function liveData(force = false) {
  if (!serverStatus().running || !restConfigured()) return { connected: false, players: [] };
  if (!force && state.live.data && Date.now() - state.live.at < 3000) return state.live.data;
  try {
    const [info, metrics, playersEnvelope] = await Promise.all([rest('/info'), rest('/metrics'), rest('/players')]);
    const data = { connected: true, info, metrics, players: Array.isArray(playersEnvelope.players) ? playersEnvelope.players : [], updatedAt: new Date().toISOString() };
    state.live = { at: Date.now(), data };
    return data;
  } catch (err) {
    return { connected: false, error: err.message, players: [], updatedAt: new Date().toISOString() };
  }
}

function listBackups() {
  const dir = config().paths.backups;
  fs.mkdirSync(dir, { recursive: true });
  return fs.readdirSync(dir).filter(name => /^palworld_.*\.zip$/i.test(name)).map(name => {
    const stat = fs.statSync(path.join(dir, name));
    return { name, size: stat.size, createdAt: stat.mtime.toISOString() };
  }).sort((a, b) => b.createdAt.localeCompare(a.createdAt));
}

function backup(reason = 'manual') {
  const cfg = config();
  return runJob('Backup', 'backup-palworld.ps1', ['-ServerDir', cfg.paths.server, '-BackupDir', cfg.paths.backups, '-Reason', reason, '-Retention', String(cfg.maintenance.backupRetention || 20)]);
}

function restoreBackup(name) {
  const cfg = config();
  if (serverStatus().running) throw new Error('Server vor Restore stoppen.');
  if (!/^palworld_[\w.-]+\.zip$/i.test(name)) throw new Error('Ungültiger Backupname.');
  const file = path.join(cfg.paths.backups, name);
  if (!fs.existsSync(file)) throw new Error('Backup nicht gefunden.');
  return runJob('Restore', 'restore-palworld.ps1', ['-ServerDir', cfg.paths.server, '-BackupFile', file, '-BackupDir', cfg.paths.backups]);
}

setInterval(() => {
  try {
    const cfg = config();
    const m = cfg.maintenance || {};
    if (serverStatus().running && m.backupEnabled && Number(m.backupIntervalHours) > 0 && !state.job?.running) {
      const latest = listBackups()[0];
      const last = latest ? new Date(latest.createdAt).getTime() : 0;
      if (Date.now() - last >= Number(m.backupIntervalHours) * 3600000) backup('automatic');
    }
    const now = new Date();
    const hm = `${String(now.getHours()).padStart(2, '0')}:${String(now.getMinutes()).padStart(2, '0')}`;
    const key = `${now.toDateString()}-${hm}`;
    if (serverStatus().running && m.restartEnabled && hm === m.restartTime && state.lastRestart !== key) {
      state.lastRestart = key;
      if (!state.job?.running) backup('scheduled-restart');
      setTimeout(() => { try { stopPalworld(); setTimeout(() => startPalworld(), 2500); } catch {} }, 7000);
    }
  } catch {}
}, 60000);

function contentType(file) {
  return ({
    '.html': 'text/html; charset=utf-8',
    '.css': 'text/css; charset=utf-8',
    '.js': 'application/javascript; charset=utf-8',
    '.svg': 'image/svg+xml',
    '.webp': 'image/webp',
    '.png': 'image/png',
    '.jpg': 'image/jpeg',
    '.jpeg': 'image/jpeg',
    '.gif': 'image/gif',
    '.ico': 'image/x-icon'
  })[path.extname(file).toLowerCase()] || 'application/octet-stream';
}
function serveStatic(res, base, pathname) {
  const target = path.normalize(path.join(base, pathname));
  if (!target.startsWith(base)) return json(res, 403, { error: 'Forbidden' });
  fs.readFile(target, (err, data) => {
    if (err) return json(res, 404, { error: 'Not found' });
    res.writeHead(200, { 'Content-Type': contentType(target), 'Cache-Control': 'no-cache' });
    res.end(data);
  });
}

async function api(req, res, url) {
  const cfg = config();

  if (req.method === 'POST' && url.pathname === '/api/admin/login') {
    const input = await readBody(req);
    const admin = loadJson(ADMIN_FILE);
    const got = Buffer.from(hashPassword(String(input.password || ''), admin.salt), 'hex');
    const want = Buffer.from(admin.hash, 'hex');
    if (input.username !== admin.username || got.length !== want.length || !crypto.timingSafeEqual(got, want)) return json(res, 401, { error: 'Ungültige Zugangsdaten.' });
    const token = crypto.randomBytes(32).toString('hex');
    sessions.set(token, { expires: Date.now() + 12 * 60 * 60 * 1000 });
    return json(res, 200, { ok: true }, { 'Set-Cookie': `palpanel_admin=${token}; HttpOnly; SameSite=Strict; Path=/; Max-Age=43200` });
  }
  if (req.method === 'POST' && url.pathname === '/api/admin/logout') {
    sessions.delete(parseCookies(req).palpanel_admin);
    return json(res, 200, { ok: true }, { 'Set-Cookie': 'palpanel_admin=; Path=/; Max-Age=0' });
  }
  if (req.method === 'GET' && url.pathname === '/api/admin/session') return json(res, 200, { authenticated: !!getSession(req) });

  if (req.method === 'GET' && url.pathname === '/api/public/status') {
    const s = serverStatus();
    const live = await liveData();
    return json(res, 200, {
      version: VERSION,
      server: { running: s.running, installed: s.installed },
      event: cfg.event,
      palworld: {
        port: cfg.palworld.port,
        maxPlayers: live.metrics?.maxplayernum ?? cfg.palworld.maxPlayers,
        name: live.info?.servername || null,
        description: live.info?.description || null,
        version: live.info?.version || null,
        fps: live.metrics?.serverfps ?? null,
        frameTime: live.metrics?.serverframetime ?? null,
        uptime: live.metrics?.uptime ?? null,
        currentPlayers: live.metrics?.currentplayernum ?? live.players.length,
        apiConnected: live.connected
      },
      players: live.players.map(p => ({ name: p.name, level: p.level, ping: p.ping, location_x: p.location_x, location_y: p.location_y })),
      live: { connected: live.connected, updatedAt: live.updatedAt }
    });
  }

  if (url.pathname.startsWith('/api/admin/') && !requireAdmin(req, res)) return;

  if (req.method === 'GET' && url.pathname === '/api/admin/status') {
    const live = await liveData();
    return json(res, 200, { version: VERSION, server: serverStatus(), palworld: cfg.palworld, job: state.job ? { type: state.job.type, running: state.job.running, success: state.job.success } : null, rest: { configured: restConfigured(), connected: live.connected, error: live.error || null }, live, maintenance: cfg.maintenance });
  }
  if (req.method === 'GET' && url.pathname === '/api/admin/job') return json(res, 200, { job: state.job });
  if (req.method === 'GET' && url.pathname === '/api/admin/backups') return json(res, 200, { backups: listBackups() });
  if (req.method === 'POST' && url.pathname === '/api/admin/backups') { try { return json(res, 202, { job: backup('manual') }); } catch (e) { return json(res, 409, { error: e.message }); } }
  if (req.method === 'POST' && url.pathname === '/api/admin/backups/restore') { try { const input = await readBody(req); return json(res, 202, { job: restoreBackup(input.name) }); } catch (e) { return json(res, 409, { error: e.message }); } }

  if (req.method === 'POST' && url.pathname === '/api/admin/rest/setup') {
    try { const wasRunning = serverStatus().running; configureRest(); if (wasRunning) { stopPalworld(); await new Promise(r => setTimeout(r, 1800)); startPalworld(); } return json(res, 200, { ok: true, restarted: wasRunning }); } catch (e) { return json(res, 500, { error: e.message }); }
  }
  if (req.method === 'POST' && url.pathname === '/api/admin/server/install') { try { return json(res, 202, { job: runJob('Installation', 'install-palworld.ps1', ['-Root', cfg.paths.root, '-ServerDir', cfg.paths.server, '-SteamCmdDir', cfg.paths.steamcmd]) }); } catch (e) { return json(res, 409, { error: e.message }); } }
  if (req.method === 'POST' && url.pathname === '/api/admin/server/update') { if (serverStatus().running) return json(res, 409, { error: 'Server vor Update stoppen.' }); try { return json(res, 202, { job: runJob('Update', 'update-palworld.ps1', ['-ServerDir', cfg.paths.server, '-SteamCmdDir', cfg.paths.steamcmd]) }); } catch (e) { return json(res, 409, { error: e.message }); } }
  if (req.method === 'POST' && url.pathname === '/api/admin/server/start') { try { return json(res, 200, startPalworld()); } catch (e) { return json(res, 409, { error: e.message }); } }
  if (req.method === 'POST' && url.pathname === '/api/admin/server/stop') { try { return json(res, 200, stopPalworld()); } catch (e) { return json(res, 500, { error: e.message }); } }
  if (req.method === 'POST' && url.pathname === '/api/admin/server/restart') { try { stopPalworld(); await new Promise(r => setTimeout(r, 1500)); return json(res, 200, startPalworld()); } catch (e) { return json(res, 500, { error: e.message }); } }

  if (req.method === 'POST' && url.pathname === '/api/admin/players/announce') { try { const input = await readBody(req); return json(res, 200, await rest('/announce', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ message: String(input.message || '').slice(0, 500) }) })); } catch (e) { return json(res, 400, { error: e.message }); } }
  if (req.method === 'POST' && url.pathname === '/api/admin/players/kick') { try { const input = await readBody(req); return json(res, 200, await rest('/kick', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ userid: input.userid, message: input.message || 'Vom Server getrennt.' }) })); } catch (e) { return json(res, 400, { error: e.message }); } }
  if (req.method === 'POST' && url.pathname === '/api/admin/players/ban') { try { const input = await readBody(req); return json(res, 200, await rest('/ban', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ userid: input.userid, message: input.message || 'Vom Server gebannt.' }) })); } catch (e) { return json(res, 400, { error: e.message }); } }
  if (req.method === 'POST' && url.pathname === '/api/admin/players/unban') { try { const input = await readBody(req); return json(res, 200, await rest('/unban', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ userid: input.userid }) })); } catch (e) { return json(res, 400, { error: e.message }); } }

  if (req.method === 'PUT' && url.pathname === '/api/admin/config/maintenance') {
    try {
      const input = await readBody(req);
      const current = config();
      current.maintenance = {
        ...current.maintenance,
        restartEnabled: !!input.restartEnabled,
        restartTime: /^\d\d:\d\d$/.test(input.restartTime || '') ? input.restartTime : current.maintenance.restartTime,
        backupEnabled: !!input.backupEnabled,
        backupIntervalHours: Math.max(1, Number(input.backupIntervalHours) || 6),
        backupRetention: Math.max(1, Number(input.backupRetention) || 20)
      };
      saveJson(USER_CONFIG, current);
      return json(res, 200, { ok: true, maintenance: current.maintenance });
    } catch (e) { return json(res, 400, { error: e.message }); }
  }

  return json(res, 404, { error: 'API route not found' });
}

const server = http.createServer(async (req, res) => {
  try {
    const url = new URL(req.url, 'http://localhost');
    if (url.pathname.startsWith('/api/')) return await api(req, res, url);
    if (url.pathname === '/admin') { res.writeHead(302, { Location: '/admin/' }); return res.end(); }
    if (url.pathname.startsWith('/admin/')) {
      let p = decodeURIComponent(url.pathname.slice('/admin'.length));
      if (!p || p === '/') p = '/index.html';
      return serveStatic(res, ADMIN_DIR, p);
    }
    let p = decodeURIComponent(url.pathname);
    if (p === '/') p = '/index.html';
    return serveStatic(res, PUBLIC_DIR, p);
  } catch (err) {
    console.error(err);
    return json(res, 500, { error: err.message || 'Internal server error' });
  }
});

const listenCfg = config();
server.listen(listenCfg.panel.port, listenCfg.panel.host, () => {
  console.log(`PalPanel v${VERSION} läuft auf http://localhost:${listenCfg.panel.port}`);
  console.log(`Admin: http://localhost:${listenCfg.panel.port}/admin/`);
});
