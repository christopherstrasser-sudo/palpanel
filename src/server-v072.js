const fs = require('fs');
const path = require('path');

const APP_DIR = path.resolve(__dirname, '..');
const defaults = JSON.parse(fs.readFileSync(path.join(APP_DIR, 'config', 'default.json'), 'utf8'));
const USER_CONFIG = path.join(defaults.paths.data, 'config.json');

function loadJson(file, fallback = null) {
  try { return JSON.parse(fs.readFileSync(file, 'utf8')); } catch { return fallback; }
}

function config() {
  const current = loadJson(USER_CONFIG, {});
  return {
    ...defaults,
    ...current,
    paths: { ...defaults.paths, ...(current.paths || {}) }
  };
}

function resolveBridgeDir() {
  const cfg = config();
  const win64 = path.join(cfg.paths.server, 'Pal', 'Binaries', 'Win64');
  const direct = path.join(win64, 'Mods', 'PalPanelBridge');
  const nested = path.join(win64, 'ue4ss', 'Mods', 'PalPanelBridge');

  if (fs.existsSync(path.join(direct, 'Scripts', 'main.lua'))) return direct;
  if (fs.existsSync(path.join(nested, 'Scripts', 'main.lua'))) return nested;
  return direct;
}

function repairBridgeIpcPath() {
  try {
    const cfg = config();
    const bridgeDir = resolveBridgeDir();
    const mainLua = path.join(bridgeDir, 'Scripts', 'main.lua');
    if (!fs.existsSync(mainLua)) return;

    const ipcDir = path.join(cfg.paths.data, 'bridge-ipc');
    const ipcFile = path.join(bridgeDir, 'ipc_path.txt');

    fs.mkdirSync(ipcDir, { recursive: true });
    fs.mkdirSync(path.join(ipcDir, 'processed'), { recursive: true });

    const expected = `${ipcDir}\r\n`;
    let current = '';
    try { current = fs.readFileSync(ipcFile, 'utf8'); } catch {}

    if (current !== expected) {
      fs.writeFileSync(ipcFile, expected, 'utf8');
      console.log(`[PalPanelBridge] ipc_path.txt repariert: ${ipcFile}`);
      console.log(`[PalPanelBridge] IPC-Ziel: ${ipcDir}`);
    } else {
      console.log(`[PalPanelBridge] ipc_path.txt OK: ${ipcFile}`);
    }
  } catch (err) {
    console.error('[PalPanelBridge] IPC-Pfad Reparatur fehlgeschlagen:', err.message);
  }
}

repairBridgeIpcPath();
const repairTimer = setInterval(repairBridgeIpcPath, 2000);
repairTimer.unref();

console.log('PalPanel v0.7.2 Bridge Self-Heal geladen.');
require('./server-v071.js');
