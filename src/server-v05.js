const fs = require('fs');
const path = require('path');
const http = require('http');
const crypto = require('crypto');
const { DatabaseSync } = require('node:sqlite');

const APP_DIR = path.resolve(__dirname, '..');
const defaults = JSON.parse(fs.readFileSync(path.join(APP_DIR, 'config', 'default.json'), 'utf8'));
const DATA_DIR = defaults.paths.data;
const USER_CONFIG = path.join(DATA_DIR, 'config.json');
const REST_FILE = path.join(DATA_DIR, 'palworld-rest.json');
const DB_FILE = path.join(DATA_DIR, 'palpanel.db');
const STEAM_OPENID = 'https://steamcommunity.com/openid/login';
const SESSION_COOKIE = 'palpanel_user';
const SESSION_SECONDS = 30 * 24 * 60 * 60;

fs.mkdirSync(DATA_DIR, { recursive: true });
const db = new DatabaseSync(DB_FILE, { timeout: 5000 });
db.exec(`
  PRAGMA journal_mode = WAL;
  PRAGMA foreign_keys = ON;
  CREATE TABLE IF NOT EXISTS users (
    id INTEGER PRIMARY KEY,
    steam_id TEXT NOT NULL UNIQUE,
    role TEXT NOT NULL DEFAULT 'player',
    created_at TEXT NOT NULL,
    last_login_at TEXT NOT NULL
  ) STRICT;
  CREATE TABLE IF NOT EXISTS user_sessions (
    id INTEGER PRIMARY KEY,
    user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    token_hash TEXT NOT NULL UNIQUE,
    created_at TEXT NOT NULL,
    expires_at TEXT NOT NULL
  ) STRICT;
  CREATE TABLE IF NOT EXISTS player_links (
    user_id INTEGER PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
    palworld_user_id TEXT,
    player_uid TEXT,
    palworld_name TEXT,
    account_name TEXT,
    level INTEGER,
    linked_at TEXT NOT NULL,
    last_seen_at TEXT NOT NULL
  ) STRICT;
  CREATE TABLE IF NOT EXISTS points_ledger (
    id INTEGER PRIMARY KEY,
    user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    amount INTEGER NOT NULL,
    reason TEXT NOT NULL,
    ref_type TEXT,
    ref_id TEXT,
    created_at TEXT NOT NULL
  ) STRICT;
  CREATE TABLE IF NOT EXISTS shop_items (
    id INTEGER PRIMARY KEY,
    slug TEXT NOT NULL UNIQUE,
    name TEXT NOT NULL,
    description TEXT NOT NULL DEFAULT '',
    price INTEGER NOT NULL DEFAULT 0,
    active INTEGER NOT NULL DEFAULT 1,
    payload_json TEXT NOT NULL DEFAULT '{}',
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
  ) STRICT;
  CREATE TABLE IF NOT EXISTS shop_orders (
    id INTEGER PRIMARY KEY,
    user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    item_id INTEGER REFERENCES shop_items(id),
    price INTEGER NOT NULL,
    status TEXT NOT NULL DEFAULT 'pending',
    created_at TEXT NOT NULL,
    fulfilled_at TEXT
  ) STRICT;
`);

const originalCreateServer = http.createServer.bind(http);

function nowIso() { return new Date().toISOString(); }
function loadJson(file, fallback = {}) { try { return JSON.parse(fs.readFileSync(file, 'utf8')); } catch { return fallback; } }
function mergedConfig() {
  const current = loadJson(USER_CONFIG, defaults);
  return {
    ...defaults,
    ...current,
    paths: { ...defaults.paths, ...(current.paths || {}) },
    palworld: { ...defaults.palworld, ...(current.palworld || {}), rest: { ...defaults.palworld.rest, ...(current.palworld?.rest || {}) } }
  };
}
function sendJson(res, status, body, headers = {}) {
  const data = Buffer.from(JSON.stringify(body));
  res.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8', 'Content-Length': data.length, 'Cache-Control': 'no-store', ...headers });
  res.end(data);
}
function redirect(res, location, headers = {}) { res.writeHead(302, { Location: location, ...headers }); res.end(); }
function parseCookies(req) {
  const out = {};
  String(req.headers.cookie || '').split(';').forEach(part => {
    const i = part.indexOf('=');
    if (i > 0) out[part.slice(0, i).trim()] = decodeURIComponent(part.slice(i + 1).trim());
  });
  return out;
}
function hashToken(token) { return crypto.createHash('sha256').update(token).digest('hex'); }
function baseUrl(req) {
  const host = String(req.headers.host || 'localhost:8787');
  if (!/^[a-zA-Z0-9.\-:\[\]]+$/.test(host)) throw new Error('Ungültiger Host-Header.');
  const forwarded = String(req.headers['x-forwarded-proto'] || '').split(',')[0].trim();
  const protocol = forwarded === 'https' ? 'https' : 'http';
  return `${protocol}://${host}`;
}
function sessionFor(req) {
  const token = parseCookies(req)[SESSION_COOKIE];
  if (!token) return null;
  const row = db.prepare(`SELECT s.id AS session_id,s.user_id,s.expires_at,u.steam_id,u.role FROM user_sessions s JOIN users u ON u.id=s.user_id WHERE s.token_hash=?`).get(hashToken(token));
  if (!row) return null;
  if (Date.parse(row.expires_at) <= Date.now()) { db.prepare('DELETE FROM user_sessions WHERE id=?').run(row.session_id); return null; }
  return row;
}
function createSession(userId, secure) {
  const token = crypto.randomBytes(32).toString('base64url');
  const expires = new Date(Date.now() + SESSION_SECONDS * 1000).toISOString();
  db.prepare('INSERT INTO user_sessions(user_id,token_hash,created_at,expires_at) VALUES(?,?,?,?)').run(userId, hashToken(token), nowIso(), expires);
  return `${SESSION_COOKIE}=${encodeURIComponent(token)}; HttpOnly; SameSite=Lax; Path=/; Max-Age=${SESSION_SECONDS}${secure ? '; Secure' : ''}`;
}
function logoutCookie(secure) { return `${SESSION_COOKIE}=; HttpOnly; SameSite=Lax; Path=/; Max-Age=0${secure ? '; Secure' : ''}`; }
function pointsBalance(userId) {
  return Number(db.prepare('SELECT COALESCE(SUM(amount),0) AS balance FROM points_ledger WHERE user_id=?').get(userId)?.balance || 0);
}
function accountPayload(session) {
  const link = db.prepare('SELECT * FROM player_links WHERE user_id=?').get(session.user_id) || null;
  return {
    authenticated: true,
    user: {
      id: session.user_id,
      steamId: session.steam_id,
      role: session.role,
      displayName: link?.palworld_name || `Steam ${session.steam_id.slice(-6)}`,
      points: pointsBalance(session.user_id),
      linked: !!link,
      character: link ? {
        name: link.palworld_name,
        accountName: link.account_name,
        userId: link.palworld_user_id,
        playerUid: link.player_uid,
        level: link.level,
        lastSeenAt: link.last_seen_at
      } : null
    }
  };
}
function sameSteamIdentity(value, steamId) {
  const raw = String(value || '').trim();
  if (raw === steamId) return true;
  const digits = raw.replace(/\D/g, '');
  return digits === steamId;
}
function restCredentials() { return loadJson(REST_FILE, null); }
async function livePlayers() {
  const cfg = mergedConfig();
  const creds = restCredentials();
  if (!creds?.password) return [];
  const auth = Buffer.from(`${creds.username || 'admin'}:${creds.password}`).toString('base64');
  const response = await fetch(`http://${cfg.palworld.rest.host || '127.0.0.1'}:${cfg.palworld.rest.port || 8212}/v1/api/players`, {
    headers: { Accept: 'application/json', Authorization: `Basic ${auth}` },
    signal: AbortSignal.timeout(3000)
  });
  if (!response.ok) return [];
  const body = await response.json().catch(() => ({}));
  return Array.isArray(body.players) ? body.players : [];
}
async function tryLinkUser(session) {
  const players = await livePlayers().catch(() => []);
  const match = players.find(p => sameSteamIdentity(p.userId, session.steam_id));
  if (!match) return false;
  const timestamp = nowIso();
  db.prepare(`INSERT INTO player_links(user_id,palworld_user_id,player_uid,palworld_name,account_name,level,linked_at,last_seen_at)
    VALUES(?,?,?,?,?,?,?,?)
    ON CONFLICT(user_id) DO UPDATE SET palworld_user_id=excluded.palworld_user_id,player_uid=excluded.player_uid,palworld_name=excluded.palworld_name,account_name=excluded.account_name,level=excluded.level,last_seen_at=excluded.last_seen_at`)
    .run(session.user_id, String(match.userId || ''), String(match.playerId || match.playerUid || ''), String(match.name || 'Palworld Player'), String(match.accountName || ''), Number(match.level) || null, timestamp, timestamp);
  return true;
}
async function steamCallback(req, res, url) {
  const params = url.searchParams;
  if (params.get('openid.mode') !== 'id_res') return redirect(res, '/?login=cancelled');
  const verify = new URLSearchParams();
  for (const [key, value] of params.entries()) if (key.startsWith('openid.')) verify.set(key, value);
  verify.set('openid.mode', 'check_authentication');
  const response = await fetch(STEAM_OPENID, {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded', Accept: 'text/plain' },
    body: verify.toString(),
    signal: AbortSignal.timeout(8000)
  });
  const result = await response.text();
  if (!response.ok || !/(^|\n)is_valid:true(\r?$|\n)/m.test(result)) return redirect(res, '/?login=invalid');
  const claimed = params.get('openid.claimed_id') || '';
  const match = claimed.match(/^https?:\/\/steamcommunity\.com\/openid\/id\/(\d{17})$/i);
  if (!match) return redirect(res, '/?login=invalid');
  const steamId = match[1];
  const timestamp = nowIso();
  db.prepare(`INSERT INTO users(steam_id,role,created_at,last_login_at) VALUES(?,'player',?,?) ON CONFLICT(steam_id) DO UPDATE SET last_login_at=excluded.last_login_at`).run(steamId, timestamp, timestamp);
  const user = db.prepare('SELECT id,steam_id,role FROM users WHERE steam_id=?').get(steamId);
  db.prepare('DELETE FROM user_sessions WHERE user_id=? OR expires_at<=?').run(user.id, timestamp);
  const secure = baseUrl(req).startsWith('https://');
  const cookie = createSession(user.id, secure);
  const session = { user_id: user.id, steam_id: user.steam_id, role: user.role };
  await tryLinkUser(session).catch(() => false);
  return redirect(res, '/?login=success', { 'Set-Cookie': cookie });
}

http.createServer = function userSystemCreateServer(handler) {
  return originalCreateServer(async (req, res) => {
    const url = new URL(req.url, 'http://localhost');
    try {
      if (req.method === 'GET' && url.pathname === '/auth/steam') {
        const base = baseUrl(req);
        const returnTo = `${base}/auth/steam/callback`;
        const params = new URLSearchParams({
          'openid.ns': 'http://specs.openid.net/auth/2.0',
          'openid.mode': 'checkid_setup',
          'openid.return_to': returnTo,
          'openid.realm': `${base}/`,
          'openid.identity': 'http://specs.openid.net/auth/2.0/identifier_select',
          'openid.claimed_id': 'http://specs.openid.net/auth/2.0/identifier_select'
        });
        return redirect(res, `${STEAM_OPENID}?${params}`);
      }
      if (req.method === 'GET' && url.pathname === '/auth/steam/callback') return await steamCallback(req, res, url);
      if (req.method === 'GET' && url.pathname === '/api/user/me') {
        const session = sessionFor(req);
        if (!session) return sendJson(res, 200, { authenticated: false });
        const existing = db.prepare('SELECT user_id FROM player_links WHERE user_id=?').get(session.user_id);
        if (!existing) await tryLinkUser(session).catch(() => false);
        return sendJson(res, 200, accountPayload(session));
      }
      if (req.method === 'POST' && url.pathname === '/api/user/relink') {
        const session = sessionFor(req);
        if (!session) return sendJson(res, 401, { error: 'Nicht angemeldet.' });
        const linked = await tryLinkUser(session);
        return sendJson(res, 200, { ok: true, linked, ...accountPayload(session) });
      }
      if (req.method === 'POST' && url.pathname === '/api/user/logout') {
        const token = parseCookies(req)[SESSION_COOKIE];
        if (token) db.prepare('DELETE FROM user_sessions WHERE token_hash=?').run(hashToken(token));
        return sendJson(res, 200, { ok: true }, { 'Set-Cookie': logoutCookie(baseUrl(req).startsWith('https://')) });
      }
      if (req.method === 'GET' && url.pathname === '/api/user/points') {
        const session = sessionFor(req);
        if (!session) return sendJson(res, 401, { error: 'Nicht angemeldet.' });
        const ledger = db.prepare('SELECT id,amount,reason,ref_type AS refType,ref_id AS refId,created_at AS createdAt FROM points_ledger WHERE user_id=? ORDER BY id DESC LIMIT 50').all(session.user_id);
        return sendJson(res, 200, { balance: pointsBalance(session.user_id), ledger });
      }
      return handler(req, res);
    } catch (err) {
      console.error('[UserSystem]', err);
      if (!res.headersSent) return sendJson(res, 500, { error: err.message || 'User-System Fehler' });
      try { res.end(); } catch {}
    }
  });
};

setInterval(() => {
  try { db.prepare('DELETE FROM user_sessions WHERE expires_at<=?').run(nowIso()); } catch {}
}, 60 * 60 * 1000).unref();

console.log(`PalPanel v0.5 User-System geladen. SQLite: ${DB_FILE}`);
require('./server-v034.js');
