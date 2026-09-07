const fs = require('fs');
const path = require('path');
const http = require('http');
const childProcess = require('child_process');

const APP_DIR = path.resolve(__dirname, '..');
const defaults = JSON.parse(fs.readFileSync(path.join(APP_DIR, 'config', 'default.json'), 'utf8'));
const DATA_DIR = defaults.paths.data;
const SERVER_DIR = defaults.paths.server;
const SETTINGS_FILE = path.join(SERVER_DIR, 'Pal', 'Saved', 'Config', 'WindowsServer', 'PalWorldSettings.ini');
const PAL_LOG_DIR = path.join(SERVER_DIR, 'Pal', 'Saved', 'Logs');
const PANEL_LOG_DIR = defaults.paths.logs;
const CONSOLE_LOG = path.join(PANEL_LOG_DIR, 'palworld-console.log');

fs.mkdirSync(PANEL_LOG_DIR, { recursive: true });

const originalCreateServer = http.createServer.bind(http);
const originalSpawn = childProcess.spawn;

// server-v032.js destructures spawn after this extension is loaded. Intercept PalServer
// starts so stdout/stderr are persisted instead of discarded via stdio:'ignore'.
childProcess.spawn = function patchedSpawn(command, args, options = {}) {
  try {
    const base = path.basename(String(command || '')).toLowerCase();
    if (base === 'palserver.exe') {
      const out = fs.openSync(CONSOLE_LOG, 'a');
      const err = fs.openSync(CONSOLE_LOG, 'a');
      fs.appendFileSync(CONSOLE_LOG, `\r\n===== PalServer Start ${new Date().toISOString()} =====\r\n`);
      return originalSpawn.call(childProcess, command, args, { ...options, stdio: ['ignore', out, err] });
    }
  } catch (err) {
    try { fs.appendFileSync(CONSOLE_LOG, `[PalPanel] Log-Capture Fehler: ${err.message}\r\n`); } catch {}
  }
  return originalSpawn.call(childProcess, command, args, options);
};

function sendJson(res, status, body) {
  const data = Buffer.from(JSON.stringify(body));
  res.writeHead(status, {
    'Content-Type': 'application/json; charset=utf-8',
    'Content-Length': data.length,
    'Cache-Control': 'no-store'
  });
  res.end(data);
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    let raw = '';
    req.on('data', chunk => {
      raw += chunk;
      if (raw.length > 1024 * 1024) reject(new Error('Request too large'));
    });
    req.on('end', () => {
      try { resolve(raw ? JSON.parse(raw) : {}); }
      catch (err) { reject(err); }
    });
    req.on('error', reject);
  });
}

async function sessionValid(req) {
  const cookie = req.headers.cookie || '';
  try {
    const response = await fetch('http://127.0.0.1:8787/api/admin/session', {
      headers: { Cookie: cookie },
      signal: AbortSignal.timeout(1500)
    });
    if (!response.ok) return false;
    const data = await response.json();
    return !!data.authenticated;
  } catch {
    return false;
  }
}

function iniText() {
  if (!fs.existsSync(SETTINGS_FILE)) throw new Error('PalWorldSettings.ini wurde nicht gefunden.');
  return fs.readFileSync(SETTINGS_FILE, 'utf8');
}

function extract(text, key) {
  const re = new RegExp(`${key}=(\\"(?:[^\\"\\\\]|\\\\.)*\\"|[^,)]*)`);
  const m = text.match(re);
  if (!m) return null;
  const raw = m[1].trim();
  if (raw.startsWith('"') && raw.endsWith('"')) {
    try { return JSON.parse(raw); } catch { return raw.slice(1, -1); }
  }
  if (/^(true|false)$/i.test(raw)) return /^true$/i.test(raw);
  if (/^-?\d+(\.\d+)?$/.test(raw)) return Number(raw);
  return raw;
}

function upsert(text, key, rawValue) {
  const re = new RegExp(`${key}=(\\"(?:[^\\"\\\\]|\\\\.)*\\"|[^,)]*)`);
  if (re.test(text)) return text.replace(re, `${key}=${rawValue}`);
  return text.replace(/OptionSettings=\(([^\r\n]*)\)/, (m, inner) =>
    `OptionSettings=(${inner}${inner.trim() ? ',' : ''}${key}=${rawValue})`
  );
}

const SETTING_SCHEMA = {
  ServerName: { type: 'string', label: 'Servername', max: 100 },
  ServerDescription: { type: 'string', label: 'Beschreibung', max: 200 },
  ServerPassword: { type: 'string', label: 'Serverpasswort', max: 100 },
  PublicPort: { type: 'number', label: 'Game Port', min: 1, max: 65535 },
  ServerPlayerMaxNum: { type: 'number', label: 'Max. Spieler', min: 1, max: 128 },
  ExpRate: { type: 'number', label: 'XP Rate', min: 0.1, max: 20 },
  PalCaptureRate: { type: 'number', label: 'Capture Rate', min: 0.1, max: 20 },
  PalSpawnNumRate: { type: 'number', label: 'Pal Spawn Rate', min: 0.1, max: 20 },
  CollectionDropRate: { type: 'number', label: 'Gathering Drop Rate', min: 0.1, max: 20 },
  CollectionObjectHpRate: { type: 'number', label: 'Gatherable HP Rate', min: 0.1, max: 20 },
  CollectionObjectRespawnSpeedRate: { type: 'number', label: 'Respawn Rate', min: 0.1, max: 20 },
  DayTimeSpeedRate: { type: 'number', label: 'Tag-Geschwindigkeit', min: 0.1, max: 20 },
  NightTimeSpeedRate: { type: 'number', label: 'Nacht-Geschwindigkeit', min: 0.1, max: 20 },
  DeathPenalty: { type: 'string', label: 'Death Penalty', max: 40 },
  bEnablePlayerToPlayerDamage: { type: 'boolean', label: 'PvP' },
  bEnableFriendlyFire: { type: 'boolean', label: 'Friendly Fire' }
};

function getSettings() {
  const text = iniText();
  const values = {};
  for (const key of Object.keys(SETTING_SCHEMA)) values[key] = extract(text, key);
  return { values, schema: SETTING_SCHEMA, file: SETTINGS_FILE };
}

function normalizeValue(key, value) {
  const spec = SETTING_SCHEMA[key];
  if (!spec) throw new Error(`Unbekannte Einstellung: ${key}`);
  if (spec.type === 'boolean') return value === true || value === 'true';
  if (spec.type === 'number') {
    const n = Number(value);
    if (!Number.isFinite(n)) throw new Error(`${spec.label}: ungültige Zahl.`);
    if (spec.min != null && n < spec.min) throw new Error(`${spec.label}: Minimum ${spec.min}.`);
    if (spec.max != null && n > spec.max) throw new Error(`${spec.label}: Maximum ${spec.max}.`);
    return n;
  }
  const s = String(value ?? '');
  if (spec.max && s.length > spec.max) throw new Error(`${spec.label}: maximal ${spec.max} Zeichen.`);
  return s;
}

function saveSettings(input) {
  let text = iniText();
  const changed = [];
  const values = input.values || input;
  for (const [key, value] of Object.entries(values)) {
    if (!SETTING_SCHEMA[key]) continue;
    const normalized = normalizeValue(key, value);
    const raw = SETTING_SCHEMA[key].type === 'string' ? JSON.stringify(normalized)
      : SETTING_SCHEMA[key].type === 'boolean' ? (normalized ? 'True' : 'False')
      : String(normalized);
    const old = extract(text, key);
    if (String(old) !== String(normalized)) {
      text = upsert(text, key, raw);
      changed.push(key);
    }
  }
  if (!changed.length) return { changed: [], restartRequired: false };
  const backup = `${SETTINGS_FILE}.palpanel-${new Date().toISOString().replace(/[:.]/g, '-')}.bak`;
  fs.copyFileSync(SETTINGS_FILE, backup);
  fs.writeFileSync(SETTINGS_FILE, text, 'utf8');
  return { changed, restartRequired: true, backup };
}

function findLogFile() {
  const candidates = [];

  if (fs.existsSync(CONSOLE_LOG)) {
    const stat = fs.statSync(CONSOLE_LOG);
    if (stat.isFile()) candidates.push({ name: 'palworld-console.log', file: CONSOLE_LOG, stat, source: 'PalPanel Console Capture' });
  }

  if (fs.existsSync(PAL_LOG_DIR)) {
    for (const name of fs.readdirSync(PAL_LOG_DIR)) {
      if (!name.toLowerCase().endsWith('.log')) continue;
      const file = path.join(PAL_LOG_DIR, name);
      const stat = fs.statSync(file);
      if (stat.isFile()) candidates.push({ name, file, stat, source: 'Palworld Saved\\Logs' });
    }
  }

  candidates.sort((a, b) => b.stat.mtimeMs - a.stat.mtimeMs);
  return candidates[0] || null;
}

function tailFile(file, maxBytes = 160000, maxLines = 500) {
  const stat = fs.statSync(file);
  const start = Math.max(0, stat.size - maxBytes);
  const length = stat.size - start;
  if (length <= 0) return '';
  const fd = fs.openSync(file, 'r');
  try {
    const buffer = Buffer.alloc(length);
    fs.readSync(fd, buffer, 0, length, start);
    let text = buffer.toString('utf8');
    if (start > 0) {
      const firstNewline = text.indexOf('\n');
      if (firstNewline >= 0) text = text.slice(firstNewline + 1);
    }
    return text.split(/\r?\n/).slice(-maxLines).join('\n');
  } finally { fs.closeSync(fd); }
}

function getLogs() {
  const found = findLogFile();
  if (!found) {
    return {
      available: false,
      file: null,
      content: 'Noch keine Logausgabe erfasst. Starte den Gameserver einmal über PalPanel neu, damit die Konsolenausgabe ab diesem Start mitgeschnitten wird.',
      updatedAt: null,
      captureFile: CONSOLE_LOG
    };
  }
  return {
    available: true,
    file: found.name,
    source: found.source,
    content: tailFile(found.file),
    updatedAt: found.stat.mtime.toISOString(),
    size: found.stat.size,
    captureFile: CONSOLE_LOG
  };
}

http.createServer = function patchedCreateServer(handler) {
  return originalCreateServer(async (req, res) => {
    const url = new URL(req.url, 'http://localhost');
    const ours = url.pathname === '/api/admin/server-settings' || url.pathname === '/api/admin/server-logs';
    if (!ours) return handler(req, res);

    if (!(await sessionValid(req))) return sendJson(res, 401, { error: 'Nicht angemeldet.' });

    try {
      if (req.method === 'GET' && url.pathname === '/api/admin/server-settings') {
        return sendJson(res, 200, getSettings());
      }
      if (req.method === 'PUT' && url.pathname === '/api/admin/server-settings') {
        const input = await readBody(req);
        return sendJson(res, 200, { ok: true, ...saveSettings(input) });
      }
      if (req.method === 'GET' && url.pathname === '/api/admin/server-logs') {
        return sendJson(res, 200, getLogs());
      }
      return sendJson(res, 405, { error: 'Method not allowed' });
    } catch (err) {
      return sendJson(res, 400, { error: err.message });
    }
  });
};

console.log('PalPanel v0.3.3 Erweiterungen geladen: Servereinstellungen + Live-Logs');
console.log(`Palworld Console Capture: ${CONSOLE_LOG}`);
require('./server-v032.js');
