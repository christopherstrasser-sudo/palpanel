const http = require('http');
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

const APP_DIR = path.resolve(__dirname, '..');
const defaults = JSON.parse(fs.readFileSync(path.join(APP_DIR, 'config', 'default.json'), 'utf8'));
const USER_CONFIG = path.join(defaults.paths.data, 'config.json');
const BRIDGE_SOURCE = path.join(APP_DIR, 'bridge', 'PalPanelBridge');
const SOURCE_MANIFEST = path.join(BRIDGE_SOURCE, 'manifest.json');

function loadJson(file, fallback = null) {
  try { return JSON.parse(fs.readFileSync(file, 'utf8')); } catch { return fallback; }
}
function config() {
  const current = loadJson(USER_CONFIG, {});
  return {
    ...defaults,
    ...current,
    panel: { ...defaults.panel, ...(current.panel || {}) },
    paths: { ...defaults.paths, ...(current.paths || {}) },
    palworld: { ...defaults.palworld, ...(current.palworld || {}), rest: { ...defaults.palworld.rest, ...(current.palworld?.rest || {}) } }
  };
}
function paths() {
  const cfg = config();
  const win64 = path.join(cfg.paths.server, 'Pal', 'Binaries', 'Win64');

  // Current Palworld-specific UE4SS builds use:
  //   Win64\\dwmapi.dll
  //   Win64\\ue4ss\\UE4SS.dll
  //   Win64\\ue4ss\\UE4SS-settings.ini
  //   Win64\\ue4ss\\MemberVariableLayout.ini
  //   Win64\\ue4ss\\Mods\\...
  // A direct Win64 layout is kept only as a legacy fallback.
  const nestedRoot = path.join(win64, 'ue4ss');
  const directRoot = win64;
  const nestedDll = path.join(nestedRoot, 'UE4SS.dll');
  const directDll = path.join(directRoot, 'UE4SS.dll');
  const proxyDll = path.join(win64, 'dwmapi.dll');

  let ue4ssRoot = nestedRoot;
  let layout = 'nested';
  if (!fs.existsSync(nestedDll) && fs.existsSync(directDll)) {
    ue4ssRoot = directRoot;
    layout = 'direct';
  }

  return {
    win64,
    ue4ssRoot,
    layout,
    ue4ssDll: path.join(ue4ssRoot, 'UE4SS.dll'),
    proxyDll,
    settingsIni: path.join(ue4ssRoot, 'UE4SS-settings.ini'),
    memberVariableLayout: path.join(ue4ssRoot, 'MemberVariableLayout.ini'),
    modsDir: path.join(ue4ssRoot, 'Mods'),
    modDir: path.join(ue4ssRoot, 'Mods', 'PalPanelBridge'),
    ipcDir: path.join(cfg.paths.data, 'bridge-ipc')
  };
}
function sourceManifest() { return loadJson(SOURCE_MANIFEST, { version: '0.0.0', capabilities: [] }); }
function installedManifest() { return loadJson(path.join(paths().modDir, 'manifest.json'), null); }

function parseKv(raw) {
  const out = {};
  String(raw || '').split(/\r?\n/).forEach(line => {
    const i = line.indexOf('=');
    if (i < 1) return;
    const key = line.slice(0, i);
    const value = line.slice(i + 1);
    try { out[key] = decodeURIComponent(value.replace(/\+/g, '%20')); }
    catch { out[key] = value; }
  });
  return out;
}
function enc(value) { return encodeURIComponent(String(value ?? '')); }
function sendJson(res, status, body) {
  const data = Buffer.from(JSON.stringify(body));
  res.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8', 'Content-Length': data.length, 'Cache-Control': 'no-store' });
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
      try { resolve(raw ? JSON.parse(raw) : {}); } catch (err) { reject(err); }
    });
    req.on('error', reject);
  });
}
async function coreRequest(req, pathname) {
  const cfg = config();
  const response = await fetch(`http://127.0.0.1:${cfg.panel.port}${pathname}`, {
    headers: { Cookie: String(req.headers.cookie || ''), Accept: 'application/json' },
    signal: AbortSignal.timeout(5000)
  });
  const body = await response.json().catch(() => ({}));
  return { response, body };
}
async function requireAdmin(req, res) {
  const { response, body } = await coreRequest(req, '/api/admin/session');
  if (!response.ok || !body.authenticated) {
    sendJson(res, 401, { error: 'Nicht angemeldet.' });
    return false;
  }
  return true;
}
async function coreStatus(req) {
  const { response, body } = await coreRequest(req, '/api/admin/status');
  if (!response.ok) throw new Error(body.error || `Admin status HTTP ${response.status}`);
  return body;
}

function bridgeStatus(core = null) {
  const p = paths();
  const source = sourceManifest();
  const installed = installedManifest();
  const heartbeatPath = path.join(p.ipcDir, 'heartbeat.txt');
  let heartbeat = null;
  let heartbeatAgeMs = null;
  if (fs.existsSync(heartbeatPath)) {
    try {
      heartbeat = parseKv(fs.readFileSync(heartbeatPath, 'utf8'));
      heartbeatAgeMs = Date.now() - fs.statSync(heartbeatPath).mtimeMs;
    } catch {}
  }
  const ue4ssInstalled = fs.existsSync(p.ue4ssDll) && fs.existsSync(p.proxyDll);
  const palworldRuntime = ue4ssInstalled && fs.existsSync(p.memberVariableLayout);
  const bridgeInstalled = !!installed && fs.existsSync(path.join(p.modDir, 'Scripts', 'main.lua'));
  const heartbeatLive = bridgeInstalled && heartbeatAgeMs != null && heartbeatAgeMs < 7000;
  const players = (core?.live?.players || []).map(player => ({
    name: player.name || '',
    userId: player.userId || '',
    level: player.level ?? null
  })).filter(player => player.name);

  return {
    sourceVersion: source.version,
    capabilities: source.capabilities || [],
    ue4ss: {
      installed: ue4ssInstalled,
      palworldCompatible: palworldRuntime,
      layout: p.layout,
      root: p.ue4ssRoot,
      dll: p.ue4ssDll,
      proxy: p.proxyDll,
      settings: p.settingsIni,
      memberVariableLayout: p.memberVariableLayout,
      mods: p.modsDir
    },
    bridge: {
      installed: bridgeInstalled,
      installedVersion: installed?.version || null,
      updateAvailable: bridgeInstalled && installed?.version !== source.version,
      destination: p.modDir,
      ipcDir: p.ipcDir
    },
    heartbeat: {
      live: heartbeatLive,
      ageMs: heartbeatAgeMs,
      version: heartbeat?.version || null,
      state: heartbeat?.state || null,
      updatedAt: heartbeatAgeMs == null ? null : new Date(Date.now() - heartbeatAgeMs).toISOString()
    },
    serverRunning: !!core?.server?.running,
    players
  };
}

function installBridge() {
  const p = paths();
  const source = sourceManifest();
  if (!fs.existsSync(SOURCE_MANIFEST)) throw new Error('Bridge-Paket fehlt im app-Verzeichnis.');
  if (!fs.existsSync(p.ue4ssDll) || !fs.existsSync(p.proxyDll)) {
    throw new Error(`UE4SS fehlt. Erwartet: ${p.ue4ssDll} und ${p.proxyDll}`);
  }

  fs.mkdirSync(p.modsDir, { recursive: true });
  fs.mkdirSync(p.ipcDir, { recursive: true });
  fs.mkdirSync(path.join(p.ipcDir, 'processed'), { recursive: true });
  fs.rmSync(p.modDir, { recursive: true, force: true });
  fs.cpSync(BRIDGE_SOURCE, p.modDir, { recursive: true });
  fs.writeFileSync(path.join(p.modDir, 'ipc_path.txt'), `${p.ipcDir}\r\n`, 'utf8');

  for (const name of ['command.txt', 'response.txt', 'heartbeat.txt']) {
    try { fs.rmSync(path.join(p.ipcDir, name), { force: true }); } catch {}
  }

  return { ok: true, version: source.version, destination: p.modDir, ue4ssLayout: p.layout, restartRequired: true };
}
function uninstallBridge() {
  const p = paths();
  fs.rmSync(p.modDir, { recursive: true, force: true });
  for (const name of ['command.txt', 'response.txt', 'heartbeat.txt']) {
    try { fs.rmSync(path.join(p.ipcDir, name), { force: true }); } catch {}
  }
  return { ok: true, restartRequired: true };
}

async function sendBridgeCommand(type, params = {}, timeoutMs = 9000) {
  const p = paths();
  const status = bridgeStatus();
  if (!status.bridge.installed) throw new Error('PalPanelBridge ist nicht installiert.');
  if (!status.heartbeat.live) throw new Error('PalPanelBridge ist nicht live. Gameserver/UE4SS neu starten und Heartbeat prüfen.');

  fs.mkdirSync(p.ipcDir, { recursive: true });
  const commandPath = path.join(p.ipcDir, 'command.txt');
  const responsePath = path.join(p.ipcDir, 'response.txt');
  if (fs.existsSync(commandPath)) throw new Error('Bridge ist beschäftigt. Bitte erneut versuchen.');

  const id = crypto.randomUUID();
  try { fs.rmSync(responsePath, { force: true }); } catch {}
  const lines = [`id=${enc(id)}`, `type=${enc(type)}`];
  Object.entries(params).forEach(([key, value]) => lines.push(`${key}=${enc(value)}`));
  const tmp = `${commandPath}.tmp`;
  fs.writeFileSync(tmp, `${lines.join('\n')}\n`, 'utf8');
  fs.renameSync(tmp, commandPath);

  const started = Date.now();
  while (Date.now() - started < timeoutMs) {
    await new Promise(resolve => setTimeout(resolve, 100));
    if (!fs.existsSync(responsePath)) continue;
    let response;
    try { response = parseKv(fs.readFileSync(responsePath, 'utf8')); }
    catch { continue; }
    if (response.id !== id) continue;
    try { fs.rmSync(responsePath, { force: true }); } catch {}
    return { id, ok: response.ok === '1', message: response.message || '' };
  }
  throw new Error('Bridge-Timeout: keine Antwort vom Gameserver.');
}

const previousCreateServer = http.createServer.bind(http);
http.createServer = function bridgeCreateServer(options, requestListener) {
  const hasOptions = typeof options !== 'function';
  const listener = hasOptions ? requestListener : options;

  const wrapped = async (req, res) => {
    let url;
    try { url = new URL(req.url, 'http://localhost'); }
    catch { return listener(req, res); }

    try {
      if ((req.method === 'GET' || req.method === 'HEAD') && url.pathname === '/admin/bridge.html') {
        res.writeHead(308, { Location: `/admin/bridge${url.search}`, 'Cache-Control': 'no-store' });
        return res.end();
      }
      if (url.pathname === '/admin/bridge') {
        req.url = `/admin/bridge.html${url.search}`;
        return listener(req, res);
      }

      if (!url.pathname.startsWith('/api/admin/bridge')) return listener(req, res);
      if (!(await requireAdmin(req, res))) return;

      if (req.method === 'GET' && url.pathname === '/api/admin/bridge/status') {
        const core = await coreStatus(req);
        return sendJson(res, 200, bridgeStatus(core));
      }

      if (req.method === 'POST' && url.pathname === '/api/admin/bridge/install') {
        const core = await coreStatus(req);
        if (core.server?.running) return sendJson(res, 409, { error: 'Gameserver vor Installation/Update stoppen.' });
        return sendJson(res, 200, installBridge());
      }

      if (req.method === 'POST' && url.pathname === '/api/admin/bridge/uninstall') {
        const core = await coreStatus(req);
        if (core.server?.running) return sendJson(res, 409, { error: 'Gameserver vor Deinstallation stoppen.' });
        return sendJson(res, 200, uninstallBridge());
      }

      if (req.method === 'POST' && url.pathname === '/api/admin/bridge/ping') {
        const result = await sendBridgeCommand('ping');
        return sendJson(res, result.ok ? 200 : 502, result.ok ? result : { error: result.message, ...result });
      }

      if (req.method === 'POST' && url.pathname === '/api/admin/bridge/give-item') {
        const input = await readBody(req);
        const target = String(input.playerName || '').trim();
        const item = String(input.itemId || '').trim();
        const count = Math.floor(Number(input.count));
        if (!target) return sendJson(res, 400, { error: 'Spieler fehlt.' });
        if (!/^[A-Za-z0-9_]+$/.test(item)) return sendJson(res, 400, { error: 'Ungültige Item-ID.' });
        if (!Number.isInteger(count) || count < 1 || count > 9999) return sendJson(res, 400, { error: 'Menge muss zwischen 1 und 9999 liegen.' });

        const core = await coreStatus(req);
        const live = (core.live?.players || []).find(player => String(player.name || '') === target);
        if (!live) return sendJson(res, 409, { error: 'Der Zielspieler ist aktuell nicht online.' });

        const result = await sendBridgeCommand('give_item', { target, item, count });
        return sendJson(res, result.ok ? 200 : 502, result.ok ? result : { error: result.message, ...result });
      }

      return sendJson(res, 404, { error: 'Bridge route not found' });
    } catch (err) {
      console.error('[PalPanelBridge]', err);
      if (!res.headersSent) return sendJson(res, 500, { error: err.message || 'Bridge error' });
      try { res.end(); } catch {}
    }
  };

  return hasOptions ? previousCreateServer(options, wrapped) : previousCreateServer(wrapped);
};

console.log(`PalPanel v0.7 Mod Bridge Manager geladen. Source: ${sourceManifest().version}`);
console.log(`UE4SS layout: ${paths().layout} (${paths().ue4ssRoot})`);
console.log(`Bridge IPC: ${paths().ipcDir}`);
require('./server-v061.js');
