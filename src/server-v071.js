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

function ue4ssModsDir() {
  const win64 = path.join(config().paths.server, 'Pal', 'Binaries', 'Win64');
  if (fs.existsSync(path.join(win64, 'UE4SS.dll'))) return path.join(win64, 'Mods');
  const nested = path.join(win64, 'ue4ss');
  if (fs.existsSync(path.join(nested, 'UE4SS.dll'))) return path.join(nested, 'Mods');
  return path.join(win64, 'Mods');
}

let lastState = null;

function ensureBridgeRegistered() {
  try {
    const modsDir = ue4ssModsDir();
    const modDir = path.join(modsDir, 'PalPanelBridge');
    const mainLua = path.join(modDir, 'Scripts', 'main.lua');
    const modsFile = path.join(modsDir, 'mods.txt');
    const installed = fs.existsSync(mainLua);

    if (!fs.existsSync(modsDir) || !fs.existsSync(modsFile)) return;

    let text = fs.readFileSync(modsFile, 'utf8');
    const lineRe = /^[ \t]*PalPanelBridge\s*:\s*[01][ \t]*\r?$/gmi;
    const registered = lineRe.test(text);
    lineRe.lastIndex = 0;

    if (installed) {
      if (registered) {
        const next = text.replace(lineRe, 'PalPanelBridge : 1');
        if (next !== text) fs.writeFileSync(modsFile, next, 'utf8');
      } else {
        if (text.length && !/\r?\n$/.test(text)) text += '\r\n';
        text += 'PalPanelBridge : 1\r\n';
        fs.writeFileSync(modsFile, text, 'utf8');
      }
    } else if (registered) {
      const next = text.replace(lineRe, '').replace(/\r?\n{3,}/g, '\r\n\r\n');
      fs.writeFileSync(modsFile, next, 'utf8');
    }

    const state = `${installed}:${fs.existsSync(modsFile)}`;
    if (state !== lastState) {
      lastState = state;
      console.log(installed
        ? `[PalPanelBridge] UE4SS mods.txt aktiviert: ${modsFile}`
        : `[PalPanelBridge] Noch keine installierte Bridge in ${modDir}`);
    }
  } catch (err) {
    console.error('[PalPanelBridge] mods.txt Registrierung fehlgeschlagen:', err.message);
  }
}

ensureBridgeRegistered();
const registrationTimer = setInterval(ensureBridgeRegistered, 1500);
registrationTimer.unref();

console.log('PalPanel v0.7.1 UE4SS v3 Mod-Registrar geladen.');
require('./server-v07.js');
