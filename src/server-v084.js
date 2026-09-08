const fs = require('fs');
const path = require('path');

const APP_DIR = path.resolve(__dirname, '..');
const defaults = JSON.parse(fs.readFileSync(path.join(APP_DIR, 'config', 'default.json'), 'utf8'));
const USER_CONFIG = path.join(defaults.paths.data, 'config.json');
const CAPTURE_SOURCE = path.join(APP_DIR, 'bridge', 'PalPanelCapture');

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
    captureMod: path.join(root, 'Mods', 'PalPanelCapture'),
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
    if (/^\s*PalPanelCapture\s*:/i.test(line)) {
      found = true;
      return 'PalPanelCapture : 1';
    }
    return line;
  }).filter((line, index, all) => line !== '' || index < all.length - 1);

  if (!found) lines.push('PalPanelCapture : 1');
  fs.writeFileSync(file, `${lines.join('\r\n').replace(/(?:\r?\n)+$/, '')}\r\n`, 'utf8');
}

function sourceVersion() {
  return loadJson(path.join(CAPTURE_SOURCE, 'manifest.json'), { version: 'unknown' })?.version || 'unknown';
}

function installedVersion(destination) {
  return loadJson(path.join(destination, 'manifest.json'), null)?.version || null;
}

function syncCaptureObserver() {
  const p = ue4ssPaths();
  const sourceMain = path.join(CAPTURE_SOURCE, 'Scripts', 'main.lua');
  const stableMain = path.join(p.stableBridge, 'Scripts', 'main.lua');

  if (!fs.existsSync(sourceMain)) {
    console.warn('[PalPanelCapture] Source fehlt; Capture-Sidecar wurde nicht installiert.');
    return;
  }

  // Do not install an experimental observer on systems where the proven base
  // bridge is not installed. This keeps bridge uninstall semantics predictable.
  if (!fs.existsSync(stableMain)) {
    console.log('[PalPanelCapture] PalPanelBridge nicht installiert; Sidecar bleibt deaktiviert.');
    return;
  }

  const wanted = sourceVersion();
  const current = installedVersion(p.captureMod);
  const needsCopy = current !== wanted || !fs.existsSync(path.join(p.captureMod, 'Scripts', 'main.lua'));

  if (needsCopy) {
    fs.mkdirSync(p.modsDir, { recursive: true });
    fs.mkdirSync(p.ipcDir, { recursive: true });
    fs.mkdirSync(path.join(p.ipcDir, 'events'), { recursive: true });
    fs.rmSync(p.captureMod, { recursive: true, force: true });
    fs.cpSync(CAPTURE_SOURCE, p.captureMod, { recursive: true });
    fs.writeFileSync(path.join(p.captureMod, 'ipc_path.txt'), `${p.ipcDir}\r\n`, 'utf8');
    console.log(`[PalPanelCapture] Sidecar ${wanted} installiert: ${p.captureMod}`);
  } else {
    // Self-heal ipc_path.txt even when no package update was needed.
    fs.mkdirSync(p.ipcDir, { recursive: true });
    fs.writeFileSync(path.join(p.captureMod, 'ipc_path.txt'), `${p.ipcDir}\r\n`, 'utf8');
    console.log(`[PalPanelCapture] Sidecar ${wanted} bereit.`);
  }

  ensureModsTxt(p.modsDir);
  console.log('[PalPanelCapture] mods.txt: PalPanelCapture : 1');
}

try {
  syncCaptureObserver();
} catch (err) {
  // Capture tracking must never prevent PalPanel, the shop or item delivery
  // from starting.
  console.error('[PalPanelCapture] Sidecar-Sync fehlgeschlagen:', err.message);
}

console.log('PalPanel v0.8.4 Capture-Sidecar Loader geladen.');
require('./server-v083.js');
