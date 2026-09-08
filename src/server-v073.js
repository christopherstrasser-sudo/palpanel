const http = require('http');
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

function palworldUe4ssCompatibility() {
  const cfg = config();
  const win64 = path.join(cfg.paths.server, 'Pal', 'Binaries', 'Win64');
  const candidates = [
    path.join(win64, 'MemberVariableLayout.ini'),
    path.join(win64, 'ue4ss', 'MemberVariableLayout.ini')
  ];
  const marker = candidates.find(file => fs.existsSync(file)) || null;
  return { compatible: !!marker, marker, candidates };
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

const previousCreateServer = http.createServer.bind(http);
http.createServer = function bridgeSafetyCreateServer(options, requestListener) {
  const hasOptions = typeof options !== 'function';
  const listener = hasOptions ? requestListener : options;

  const wrapped = (req, res) => {
    try {
      const url = new URL(req.url, 'http://localhost');
      if (req.method === 'POST' && url.pathname === '/api/admin/bridge/give-item') {
        const runtime = palworldUe4ssCompatibility();
        if (!runtime.compatible) {
          return sendJson(res, 409, {
            error: 'Live-Item-Zustellung aus Sicherheitsgründen blockiert: Es ist keine Palworld-spezifische UE4SS-Runtime erkannt (MemberVariableLayout.ini fehlt). Installiere zuerst Okaetsu/RE-UE4SS experimental-palworld.',
            code: 'UNSAFE_UE4SS_RUNTIME'
          });
        }
      }
    } catch {}
    return listener(req, res);
  };

  return hasOptions ? previousCreateServer(options, wrapped) : previousCreateServer(wrapped);
};

const runtime = palworldUe4ssCompatibility();
console.log('PalPanel v0.7.3 Bridge Crash Guard geladen.');
console.log(runtime.compatible
  ? `[PalPanelBridge] Palworld UE4SS Runtime erkannt: ${runtime.marker}`
  : '[PalPanelBridge] WARNUNG: Standard-UE4SS erkannt/Palworld-Marker fehlt. give_item ist blockiert.');

require('./server-v072.js');
