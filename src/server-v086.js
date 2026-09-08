const fs = require('fs');
const path = require('path');

const APP_DIR = path.resolve(__dirname, '..');
const defaults = JSON.parse(fs.readFileSync(path.join(APP_DIR, 'config', 'default.json'), 'utf8'));
const USER_CONFIG = path.join(defaults.paths.data, 'config.json');
const TOWER_SOURCE = path.join(APP_DIR, 'bridge', 'PalPanelTower');

function loadJson(file, fallback = null) {
  try { return JSON.parse(fs.readFileSync(file, 'utf8')); } catch { return fallback; }
}

function config() {
  const current = loadJson(USER_CONFIG, {}) || {};
  return {
    ...defaults,
    ...current,
    paths: { ...defaults.paths, ...(current.paths || {}) }
  };
}

function ue4ssPaths() {
  const cfg = config();
  const win64 = path.join(cfg.paths.server, 'Pal', 'Binaries', 'Win64');
  const nested = path.join(win64, 'ue4ss');
  const nestedDll = path.join(nested, 'UE4SS.dll');
  const directDll = path.join(win64, 'UE4SS.dll');
  const root = fs.existsSync(nestedDll) || !fs.existsSync(directDll) ? nested : win64;
  return {
    root,
    modsDir: path.join(root, 'Mods'),
    stableBridge: path.join(root, 'Mods', 'PalPanelBridge'),
    towerMod: path.join(root, 'Mods', 'PalPanelTower'),
    ipcDir: path.join(cfg.paths.data, 'bridge-ipc')
  };
}

function ensureModsTxt(modsDir) {
  fs.mkdirSync(modsDir, { recursive: true });
  const file = path.join(modsDir, 'mods.txt');
  let lines = [];
  try { lines = fs.readFileSync(file, 'utf8').split(/\r?\n/); } catch {}

  let found = false;
  lines = lines.map(line => {
    if (/^\s*PalPanelTower\s*:/i.test(line)) {
      found = true;
      return 'PalPanelTower : 1';
    }
    return line;
  }).filter((line, index, all) => line !== '' || index < all.length - 1);

  if (!found) lines.push('PalPanelTower : 1');
  fs.writeFileSync(file, `${lines.join('\r\n').replace(/(?:\r?\n)+$/, '')}\r\n`, 'utf8');
}

function sourceVersion() {
  return loadJson(path.join(TOWER_SOURCE, 'manifest.json'), { version: 'unknown' })?.version || 'unknown';
}

function installedVersion(destination) {
  return loadJson(path.join(destination, 'manifest.json'), null)?.version || null;
}

function syncTowerObserver() {
  const p = ue4ssPaths();
  const sourceMain = path.join(TOWER_SOURCE, 'Scripts', 'main.lua');
  const stableMain = path.join(p.stableBridge, 'Scripts', 'main.lua');

  if (!fs.existsSync(sourceMain)) {
    console.warn('[PalPanelTower] Source fehlt; Tower-Sidecar wurde nicht installiert.');
    return;
  }

  if (!fs.existsSync(stableMain)) {
    console.log('[PalPanelTower] PalPanelBridge nicht installiert; Sidecar bleibt deaktiviert.');
    return;
  }

  const wanted = sourceVersion();
  const current = installedVersion(p.towerMod);
  const needsCopy = current !== wanted || !fs.existsSync(path.join(p.towerMod, 'Scripts', 'main.lua'));

  fs.mkdirSync(p.ipcDir, { recursive: true });
  fs.mkdirSync(path.join(p.ipcDir, 'game-events'), { recursive: true });

  if (needsCopy) {
    fs.mkdirSync(p.modsDir, { recursive: true });
    fs.rmSync(p.towerMod, { recursive: true, force: true });
    fs.cpSync(TOWER_SOURCE, p.towerMod, { recursive: true });
    fs.writeFileSync(path.join(p.towerMod, 'ipc_path.txt'), `${p.ipcDir}\r\n`, 'utf8');
    console.log(`[PalPanelTower] Sidecar ${wanted} installiert: ${p.towerMod}`);
  } else {
    fs.writeFileSync(path.join(p.towerMod, 'ipc_path.txt'), `${p.ipcDir}\r\n`, 'utf8');
    console.log(`[PalPanelTower] Sidecar ${wanted} bereit.`);
  }

  ensureModsTxt(p.modsDir);
  console.log('[PalPanelTower] mods.txt: PalPanelTower : 1');
}

try {
  syncTowerObserver();
} catch (err) {
  console.error('[PalPanelTower] Sidecar-Sync fehlgeschlagen:', err.message);
}

console.log('PalPanel v0.8.6 Tower-Boss-Tracking geladen.');
require('./server-v085.js');
