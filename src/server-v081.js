const fs = require('fs');
const path = require('path');
const http = require('http');
const crypto = require('crypto');
const { DatabaseSync } = require('node:sqlite');

const APP_DIR = path.resolve(__dirname, '..');
const defaults = JSON.parse(fs.readFileSync(path.join(APP_DIR, 'config', 'default.json'), 'utf8'));
const DATA_DIR = defaults.paths.data;
const DB_FILE = path.join(DATA_DIR, 'palpanel.db');
const USER_CONFIG = path.join(DATA_DIR, 'config.json');
const SESSION_COOKIE = 'palpanel_user';

const db = new DatabaseSync(DB_FILE, { timeout: 5000 });

function loadJson(file, fallback = {}) {
  try { return JSON.parse(fs.readFileSync(file, 'utf8')); } catch { return fallback; }
}
function config() {
  const current = loadJson(USER_CONFIG, {});
  return {
    ...defaults,
    ...current,
    panel: { ...defaults.panel, ...(current.panel || {}) },
    paths: { ...defaults.paths, ...(current.paths || {}) }
  };
}
function parseCookies(req) {
  const out = {};
  String(req.headers.cookie || '').split(';').forEach(part => {
    const i = part.indexOf('=');
    if (i > 0) out[part.slice(0, i).trim()] = decodeURIComponent(part.slice(i + 1).trim());
  });
  return out;
}
function hashToken(token) {
  return crypto.createHash('sha256').update(token).digest('hex');
}
function userSession(req) {
  const token = parseCookies(req)[SESSION_COOKIE];
  if (!token) return null;
  const row = db.prepare(`SELECT s.user_id,s.expires_at,u.steam_id,u.role
    FROM user_sessions s JOIN users u ON u.id=s.user_id
    WHERE s.token_hash=?`).get(hashToken(token));
  if (!row || Date.parse(row.expires_at) <= Date.now()) return null;
  return row;
}
function pointsBalance(userId) {
  return Number(db.prepare('SELECT COALESCE(SUM(amount),0) AS n FROM points_ledger WHERE user_id=?').get(userId)?.n || 0);
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
function readBody(req) {
  return new Promise((resolve, reject) => {
    let raw = '';
    req.on('data', chunk => {
      raw += chunk;
      if (raw.length > 64 * 1024) reject(new Error('Request too large'));
    });
    req.on('end', () => {
      try { resolve(raw ? JSON.parse(raw) : {}); } catch (err) { reject(err); }
    });
    req.on('error', reject);
  });
}
async function requireAdmin(req, res) {
  const cfg = config();
  try {
    const response = await fetch(`http://127.0.0.1:${cfg.panel.port}/api/admin/session`, {
      headers: { Cookie: String(req.headers.cookie || ''), Accept: 'application/json' },
      signal: AbortSignal.timeout(4000)
    });
    const body = await response.json().catch(() => ({}));
    if (!response.ok || !body.authenticated) {
      sendJson(res, 401, { error: 'Nicht angemeldet.' });
      return false;
    }
    return true;
  } catch (err) {
    sendJson(res, 503, { error: `Admin-Session konnte nicht geprüft werden: ${err.message}` });
    return false;
  }
}
function currentUserPayload(session) {
  if (!session) return null;
  const link = db.prepare('SELECT palworld_name,level FROM player_links WHERE user_id=?').get(session.user_id) || null;
  return {
    userId: session.user_id,
    steamId: session.steam_id,
    name: link?.palworld_name || `Steam ${String(session.steam_id).slice(-6)}`,
    level: link?.level ?? null,
    points: pointsBalance(session.user_id)
  };
}

const previousCreateServer = http.createServer.bind(http);
http.createServer = function testCreditsCreateServer(options, requestListener) {
  const hasOptions = typeof options !== 'function';
  const listener = hasOptions ? requestListener : options;

  const wrapped = async (req, res) => {
    let url;
    try { url = new URL(req.url, 'http://localhost'); }
    catch { return listener(req, res); }

    try {
      if (url.pathname === '/api/admin/test-points') {
        if (!(await requireAdmin(req, res))) return;
        const session = userSession(req);
        if (!session) {
          return sendJson(res, 409, {
            error: 'Kein eingeloggtes Steam-Spielerkonto in diesem Browser gefunden. Öffne zuerst /shop und melde dich dort mit Steam an.'
          });
        }

        if (req.method === 'GET') {
          return sendJson(res, 200, { user: currentUserPayload(session) });
        }

        if (req.method === 'POST') {
          const input = await readBody(req);
          const amount = Math.trunc(Number(input.amount));
          if (!Number.isInteger(amount) || amount < 1 || amount > 100000) {
            return sendJson(res, 400, { error: 'Testgutschrift muss zwischen 1 und 100.000 PTS liegen.' });
          }
          const refId = crypto.randomUUID();
          const createdAt = new Date().toISOString();
          db.prepare(`INSERT INTO points_ledger(user_id,amount,reason,ref_type,ref_id,created_at)
            VALUES(?,?,?,?,?,?)`).run(session.user_id, amount, 'Admin-Testgutschrift', 'admin-test-credit', refId, createdAt);
          return sendJson(res, 200, {
            ok: true,
            credited: amount,
            user: currentUserPayload(session)
          });
        }

        return sendJson(res, 405, { error: 'Method not allowed' });
      }

      return listener(req, res);
    } catch (err) {
      console.error('[TestCredits]', err);
      if (!res.headersSent) return sendJson(res, 500, { error: err.message || 'Testgutschrift fehlgeschlagen.' });
      try { res.end(); } catch {}
    }
  };

  return hasOptions ? previousCreateServer(options, wrapped) : previousCreateServer(wrapped);
};

console.log('PalPanel v0.8.1 Admin-Testgutschriften geladen.');
require('./server-v08.js');
