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
const REST_FILE = path.join(DATA_DIR, 'palworld-rest.json');
const PROGRESSION_FILE = path.join(DATA_DIR, 'progression.json');
const SESSION_COOKIE = 'palpanel_user';

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
  CREATE TABLE IF NOT EXISTS event_score_ledger (
    id INTEGER PRIMARY KEY,
    user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    amount INTEGER NOT NULL,
    reason TEXT NOT NULL,
    ref_type TEXT,
    ref_id TEXT,
    created_at TEXT NOT NULL
  ) STRICT;
  CREATE TABLE IF NOT EXISTS player_stats (
    user_id INTEGER PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
    playtime_seconds INTEGER NOT NULL DEFAULT 0,
    playtime_rewarded_chunks INTEGER NOT NULL DEFAULT 0,
    unique_pals INTEGER NOT NULL DEFAULT 0,
    total_captures INTEGER NOT NULL DEFAULT 0,
    alpha_captures INTEGER NOT NULL DEFAULT 0,
    boss_kills INTEGER NOT NULL DEFAULT 0,
    updated_at TEXT NOT NULL
  ) STRICT;
  CREATE TABLE IF NOT EXISTS playtime_presence (
    user_id INTEGER PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
    last_seen_ms INTEGER NOT NULL
  ) STRICT;
  CREATE TABLE IF NOT EXISTS progression_events (
    id INTEGER PRIMARY KEY,
    source TEXT NOT NULL,
    event_id TEXT NOT NULL,
    user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    event_type TEXT NOT NULL,
    payload_json TEXT NOT NULL DEFAULT '{}',
    created_at TEXT NOT NULL,
    UNIQUE(source,event_id)
  ) STRICT;
  CREATE TABLE IF NOT EXISTS pal_captures (
    id INTEGER PRIMARY KEY,
    user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    species_key TEXT NOT NULL,
    event_id TEXT NOT NULL,
    is_alpha INTEGER NOT NULL DEFAULT 0,
    captured_at TEXT NOT NULL,
    UNIQUE(user_id,event_id)
  ) STRICT;
  CREATE TABLE IF NOT EXISTS paldex_milestones (
    user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    milestone INTEGER NOT NULL,
    awarded_at TEXT NOT NULL,
    PRIMARY KEY(user_id,milestone)
  ) STRICT;
  CREATE TABLE IF NOT EXISTS boss_completions (
    user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    boss_key TEXT NOT NULL,
    event_id TEXT NOT NULL,
    completed_at TEXT NOT NULL,
    PRIMARY KEY(user_id,boss_key)
  ) STRICT;
  CREATE UNIQUE INDEX IF NOT EXISTS ux_points_ref ON points_ledger(user_id,ref_type,ref_id) WHERE ref_id IS NOT NULL;
  CREATE UNIQUE INDEX IF NOT EXISTS ux_score_ref ON event_score_ledger(user_id,ref_type,ref_id) WHERE ref_id IS NOT NULL;
`);
// Presence is deliberately ephemeral: a PalPanel restart must never grant stale playtime.
db.exec('DELETE FROM playtime_presence;');

const economyDefaults = {
  bridgeKey: crypto.randomBytes(32).toString('base64url'),
  playtimeChunkMinutes: 30,
  playtimePoints: 10,
  newSpeciesPoints: 25,
  repeatCapturePoints: 2,
  repeatCaptureHourlyCap: 20,
  alphaBonus: 20,
  milestones: { '25': 100, '50': 200, '100': 500, '150': 750, '200': 1000 },
  bossDefault: 150,
  bossMin: 100,
  bossMax: 250
};

function loadJson(file, fallback = {}) { try { return JSON.parse(fs.readFileSync(file, 'utf8')); } catch { return fallback; } }
function saveJson(file, value) { fs.mkdirSync(path.dirname(file), { recursive: true }); fs.writeFileSync(file, JSON.stringify(value, null, 2), 'utf8'); }
if (!fs.existsSync(PROGRESSION_FILE)) saveJson(PROGRESSION_FILE, economyDefaults);
function economy() {
  const current = loadJson(PROGRESSION_FILE, {});
  return { ...economyDefaults, ...current, milestones: { ...economyDefaults.milestones, ...(current.milestones || {}) } };
}
function config() {
  const current = loadJson(USER_CONFIG, defaults);
  const p = current.palworld || {};
  return { ...defaults, ...current, paths: { ...defaults.paths, ...(current.paths || {}) }, palworld: { ...defaults.palworld, ...p, rest: { ...defaults.palworld.rest, ...(p.rest || {}) } } };
}
function nowIso() { return new Date().toISOString(); }
function parseCookies(req) {
  const out = {};
  String(req.headers.cookie || '').split(';').forEach(part => { const i = part.indexOf('='); if (i > 0) out[part.slice(0, i).trim()] = decodeURIComponent(part.slice(i + 1).trim()); });
  return out;
}
function hashToken(token) { return crypto.createHash('sha256').update(token).digest('hex'); }
function sessionFor(req) {
  const token = parseCookies(req)[SESSION_COOKIE];
  if (!token) return null;
  const row = db.prepare(`SELECT s.user_id,s.expires_at,u.steam_id,u.role FROM user_sessions s JOIN users u ON u.id=s.user_id WHERE s.token_hash=?`).get(hashToken(token));
  if (!row || Date.parse(row.expires_at) <= Date.now()) return null;
  return row;
}
function sendJson(res, status, body) {
  const data = Buffer.from(JSON.stringify(body));
  res.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8', 'Content-Length': data.length, 'Cache-Control': 'no-store' });
  res.end(data);
}
function readBody(req) {
  return new Promise((resolve, reject) => {
    let raw = '';
    req.on('data', c => { raw += c; if (raw.length > 256 * 1024) reject(new Error('Request too large')); });
    req.on('end', () => { try { resolve(raw ? JSON.parse(raw) : {}); } catch (e) { reject(e); } });
    req.on('error', reject);
  });
}
function timingSafeKey(got, expected) {
  const a = Buffer.from(String(got || ''));
  const b = Buffer.from(String(expected || ''));
  return a.length === b.length && crypto.timingSafeEqual(a, b);
}
function ensureStats(userId) {
  db.prepare(`INSERT INTO player_stats(user_id,updated_at) VALUES(?,?) ON CONFLICT(user_id) DO NOTHING`).run(userId, nowIso());
  return db.prepare('SELECT * FROM player_stats WHERE user_id=?').get(userId);
}
function pointsBalance(userId) { return Number(db.prepare('SELECT COALESCE(SUM(amount),0) AS n FROM points_ledger WHERE user_id=?').get(userId)?.n || 0); }
function scoreBalance(userId) { return Number(db.prepare('SELECT COALESCE(SUM(amount),0) AS n FROM event_score_ledger WHERE user_id=?').get(userId)?.n || 0); }
function insertAward(userId, points, score, reason, refType, refId, createdAt = nowIso()) {
  if (points) db.prepare('INSERT OR IGNORE INTO points_ledger(user_id,amount,reason,ref_type,ref_id,created_at) VALUES(?,?,?,?,?,?)').run(userId, Math.trunc(points), reason, refType, refId, createdAt);
  if (score) db.prepare('INSERT OR IGNORE INTO event_score_ledger(user_id,amount,reason,ref_type,ref_id,created_at) VALUES(?,?,?,?,?,?)').run(userId, Math.trunc(score), reason, refType, refId, createdAt);
}
function resolveUser(input) {
  if (Number.isInteger(Number(input.userId)) && Number(input.userId) > 0) return db.prepare('SELECT id,steam_id FROM users WHERE id=?').get(Number(input.userId)) || null;
  if (/^\d{17}$/.test(String(input.steamId || ''))) return db.prepare('SELECT id,steam_id FROM users WHERE steam_id=?').get(String(input.steamId)) || null;
  const palId = String(input.palworldUserId || input.playerUid || '').trim();
  if (palId) return db.prepare(`SELECT u.id,u.steam_id FROM users u JOIN player_links l ON l.user_id=u.id WHERE l.palworld_user_id=? OR l.player_uid=?`).get(palId, palId) || null;
  return null;
}
function uniqueCount(userId) { return Number(db.prepare('SELECT COUNT(DISTINCT species_key) AS n FROM pal_captures WHERE user_id=?').get(userId)?.n || 0); }

function processCapture(userId, eventId, input) {
  const cfg = economy();
  const species = String(input.speciesKey || input.species || '').trim().slice(0, 120);
  if (!species) throw new Error('speciesKey fehlt.');
  const alpha = !!input.alpha;
  const createdAt = nowIso();
  const wasKnown = !!db.prepare('SELECT 1 FROM pal_captures WHERE user_id=? AND species_key=? LIMIT 1').get(userId, species);
  db.prepare('INSERT INTO pal_captures(user_id,species_key,event_id,is_alpha,captured_at) VALUES(?,?,?,?,?)').run(userId, species, eventId, alpha ? 1 : 0, createdAt);

  let points = 0, score = 0;
  if (!wasKnown) {
    points += cfg.newSpeciesPoints; score += cfg.newSpeciesPoints;
    insertAward(userId, cfg.newSpeciesPoints, cfg.newSpeciesPoints, `Neue Pal-Art: ${species}`, 'capture-new', eventId, createdAt);
  } else {
    const since = new Date(Date.now() - 60 * 60 * 1000).toISOString();
    const used = Number(db.prepare(`SELECT COALESCE(SUM(amount),0) AS n FROM points_ledger WHERE user_id=? AND ref_type='capture-repeat' AND created_at>=?`).get(userId, since)?.n || 0);
    const repeat = Math.max(0, Math.min(cfg.repeatCapturePoints, cfg.repeatCaptureHourlyCap - used));
    if (repeat > 0) {
      points += repeat; score += repeat;
      insertAward(userId, repeat, repeat, `Pal gefangen: ${species}`, 'capture-repeat', eventId, createdAt);
    }
  }
  if (alpha) {
    points += cfg.alphaBonus; score += cfg.alphaBonus;
    insertAward(userId, cfg.alphaBonus, cfg.alphaBonus, `Alpha-Pal gefangen: ${species}`, 'capture-alpha', eventId, createdAt);
  }

  const uniques = uniqueCount(userId);
  db.prepare(`UPDATE player_stats SET unique_pals=?,total_captures=total_captures+1,alpha_captures=alpha_captures+?,updated_at=? WHERE user_id=?`).run(uniques, alpha ? 1 : 0, createdAt, userId);

  for (const [thresholdRaw, rewardRaw] of Object.entries(cfg.milestones)) {
    const threshold = Number(thresholdRaw), reward = Number(rewardRaw);
    if (uniques < threshold || !reward) continue;
    const exists = db.prepare('SELECT 1 FROM paldex_milestones WHERE user_id=? AND milestone=?').get(userId, threshold);
    if (exists) continue;
    db.prepare('INSERT INTO paldex_milestones(user_id,milestone,awarded_at) VALUES(?,?,?)').run(userId, threshold, createdAt);
    insertAward(userId, reward, reward, `Paldex-Meilenstein: ${threshold} Arten`, 'paldex-milestone', String(threshold), createdAt);
    points += reward; score += reward;
  }
  return { pointsAwarded: points, scoreAwarded: score, uniquePals: uniques, alpha };
}

function processBoss(userId, eventId, input) {
  const cfg = economy();
  const bossKey = String(input.bossKey || input.boss || '').trim().slice(0, 120);
  if (!bossKey) throw new Error('bossKey fehlt.');
  if (db.prepare('SELECT 1 FROM boss_completions WHERE user_id=? AND boss_key=?').get(userId, bossKey)) return { alreadyCompleted: true, pointsAwarded: 0, scoreAwarded: 0 };
  const amount = Math.max(cfg.bossMin, Math.min(cfg.bossMax, Number(input.amount) || cfg.bossDefault));
  const createdAt = nowIso();
  db.prepare('INSERT INTO boss_completions(user_id,boss_key,event_id,completed_at) VALUES(?,?,?,?)').run(userId, bossKey, eventId, createdAt);
  db.prepare('UPDATE player_stats SET boss_kills=boss_kills+1,updated_at=? WHERE user_id=?').run(createdAt, userId);
  insertAward(userId, amount, amount, `Boss besiegt: ${bossKey}`, 'boss', eventId, createdAt);
  return { alreadyCompleted: false, pointsAwarded: amount, scoreAwarded: amount };
}

function processBonus(userId, eventId, input, type) {
  const amount = Math.max(-10000, Math.min(10000, Math.trunc(Number(input.amount) || 0)));
  const scoreAmount = input.scoreAmount == null ? amount : Math.max(-10000, Math.min(10000, Math.trunc(Number(input.scoreAmount) || 0)));
  if (!amount && !scoreAmount) throw new Error('amount fehlt.');
  const reason = String(input.reason || (type === 'event_bonus' ? 'Event-Bonus' : 'Admin-Bonus')).slice(0, 180);
  insertAward(userId, amount, scoreAmount, reason, type, eventId);
  return { pointsAwarded: amount, scoreAwarded: scoreAmount };
}

function processProgressionEvent(input) {
  const source = String(input.source || 'bridge').slice(0, 60);
  const eventId = String(input.eventId || '').trim().slice(0, 160);
  const eventType = String(input.type || '').trim();
  if (!eventId) throw new Error('eventId fehlt.');
  if (!['capture','boss','event_bonus','admin_bonus'].includes(eventType)) throw new Error('Unbekannter Event-Typ.');
  const user = resolveUser(input);
  if (!user) throw new Error('Kein verknüpfter PalPanel-User gefunden.');
  ensureStats(user.id);
  const duplicate = db.prepare('SELECT id FROM progression_events WHERE source=? AND event_id=?').get(source, eventId);
  if (duplicate) return { duplicate: true, userId: user.id, points: pointsBalance(user.id), score: scoreBalance(user.id) };

  db.exec('BEGIN IMMEDIATE');
  try {
    db.prepare('INSERT INTO progression_events(source,event_id,user_id,event_type,payload_json,created_at) VALUES(?,?,?,?,?,?)').run(source, eventId, user.id, eventType, JSON.stringify(input), nowIso());
    let result;
    if (eventType === 'capture') result = processCapture(user.id, eventId, input);
    else if (eventType === 'boss') result = processBoss(user.id, eventId, input);
    else result = processBonus(user.id, eventId, input, eventType);
    db.exec('COMMIT');
    return { duplicate: false, userId: user.id, ...result, points: pointsBalance(user.id), score: scoreBalance(user.id) };
  } catch (err) {
    try { db.exec('ROLLBACK'); } catch {}
    throw err;
  }
}

function progressionPayload(userId) {
  const stats = ensureStats(userId);
  const scoreLedger = db.prepare('SELECT id,amount,reason,ref_type AS refType,ref_id AS refId,created_at AS createdAt FROM event_score_ledger WHERE user_id=? ORDER BY id DESC LIMIT 50').all(userId);
  return {
    points: pointsBalance(userId),
    eventScore: scoreBalance(userId),
    playtimeSeconds: Number(stats.playtime_seconds || 0),
    uniquePals: Number(stats.unique_pals || 0),
    totalCaptures: Number(stats.total_captures || 0),
    alphaCaptures: Number(stats.alpha_captures || 0),
    bossKills: Number(stats.boss_kills || 0),
    scoreLedger
  };
}
function publicLeaderboard() {
  return db.prepare(`SELECT u.id AS userId,COALESCE(l.palworld_name,'Explorer #'||u.id) AS name,
      COALESCE(s.playtime_seconds,0) AS playtimeSeconds,COALESCE(s.unique_pals,0) AS uniquePals,
      COALESCE((SELECT SUM(e.amount) FROM event_score_ledger e WHERE e.user_id=u.id),0) AS eventScore
    FROM users u LEFT JOIN player_links l ON l.user_id=u.id LEFT JOIN player_stats s ON s.user_id=u.id
    ORDER BY eventScore DESC,playtimeSeconds DESC,u.id ASC LIMIT 20`).all();
}

function restCredentials() { return loadJson(REST_FILE, null); }
async function livePlayers() {
  const cfg = config();
  const creds = restCredentials();
  if (!creds?.password) return null;
  const auth = Buffer.from(`${creds.username || 'admin'}:${creds.password}`).toString('base64');
  const response = await fetch(`http://${cfg.palworld.rest.host || '127.0.0.1'}:${cfg.palworld.rest.port || 8212}/v1/api/players`, {
    headers: { Accept: 'application/json', Authorization: `Basic ${auth}` },
    signal: AbortSignal.timeout(3500)
  });
  if (!response.ok) return null;
  const body = await response.json().catch(() => ({}));
  return Array.isArray(body.players) ? body.players : [];
}
function sameIdentity(value, expected) {
  const a = String(value || '').trim(), b = String(expected || '').trim();
  return a === b || (a.replace(/\D/g,'') && a.replace(/\D/g,'') === b.replace(/\D/g,''));
}
let tracking = false;
async function trackPlaytime() {
  if (tracking) return;
  tracking = true;
  try {
    const players = await livePlayers();
    if (!players) return;
    const links = db.prepare(`SELECT u.id AS userId,u.steam_id AS steamId,l.palworld_user_id AS palworldUserId,l.player_uid AS playerUid FROM users u JOIN player_links l ON l.user_id=u.id`).all();
    const now = Date.now();
    const online = new Set();
    const cfg = economy();
    const chunkSeconds = Math.max(60, Number(cfg.playtimeChunkMinutes) * 60);

    for (const link of links) {
      const player = players.find(p => sameIdentity(p.userId, link.palworldUserId) || sameIdentity(p.userId, link.steamId) || sameIdentity(p.playerId || p.playerUid, link.playerUid));
      if (!player) continue;
      online.add(link.userId);
      ensureStats(link.userId);
      const previous = db.prepare('SELECT last_seen_ms FROM playtime_presence WHERE user_id=?').get(link.userId);
      if (previous) {
        const delta = Math.max(0, Math.min(90, Math.round((now - Number(previous.last_seen_ms)) / 1000)));
        if (delta > 0) db.prepare('UPDATE player_stats SET playtime_seconds=playtime_seconds+?,updated_at=? WHERE user_id=?').run(delta, nowIso(), link.userId);
      }
      db.prepare(`INSERT INTO playtime_presence(user_id,last_seen_ms) VALUES(?,?) ON CONFLICT(user_id) DO UPDATE SET last_seen_ms=excluded.last_seen_ms`).run(link.userId, now);
      db.prepare(`UPDATE player_links SET palworld_name=?,account_name=?,level=?,last_seen_at=? WHERE user_id=?`).run(String(player.name || 'Palworld Player'), String(player.accountName || ''), Number(player.level) || null, nowIso(), link.userId);

      const stats = ensureStats(link.userId);
      const earnedChunks = Math.floor(Number(stats.playtime_seconds || 0) / chunkSeconds);
      const rewarded = Number(stats.playtime_rewarded_chunks || 0);
      if (earnedChunks > rewarded) {
        db.exec('BEGIN IMMEDIATE');
        try {
          for (let chunk = rewarded + 1; chunk <= earnedChunks; chunk++) {
            insertAward(link.userId, cfg.playtimePoints, cfg.playtimePoints, `${cfg.playtimeChunkMinutes} Minuten Spielzeit`, 'playtime', String(chunk));
          }
          db.prepare('UPDATE player_stats SET playtime_rewarded_chunks=?,updated_at=? WHERE user_id=?').run(earnedChunks, nowIso(), link.userId);
          db.exec('COMMIT');
        } catch (err) { try { db.exec('ROLLBACK'); } catch {} throw err; }
      }
    }
    for (const row of db.prepare('SELECT user_id FROM playtime_presence').all()) if (!online.has(row.user_id)) db.prepare('DELETE FROM playtime_presence WHERE user_id=?').run(row.user_id);
  } catch (err) {
    console.error('[Progression] Playtime tracking:', err.message);
  } finally { tracking = false; }
}

const originalCreateServer = http.createServer.bind(http);
http.createServer = function progressionCreateServer(handler) {
  return originalCreateServer(async (req, res) => {
    const url = new URL(req.url, 'http://localhost');
    try {
      if (req.method === 'GET' && url.pathname === '/api/public/leaderboard') return sendJson(res, 200, { leaderboard: publicLeaderboard() });
      if (req.method === 'GET' && url.pathname === '/api/user/progression') {
        const session = sessionFor(req);
        if (!session) return sendJson(res, 401, { error: 'Nicht angemeldet.' });
        return sendJson(res, 200, progressionPayload(session.user_id));
      }
      if (req.method === 'POST' && url.pathname === '/api/internal/progression/event') {
        const cfg = economy();
        if (!timingSafeKey(req.headers['x-palpanel-bridge-key'], cfg.bridgeKey)) return sendJson(res, 401, { error: 'Ungültiger Bridge-Key.' });
        const input = await readBody(req);
        return sendJson(res, 200, { ok: true, ...processProgressionEvent(input) });
      }
      return handler(req, res);
    } catch (err) {
      console.error('[Progression]', err);
      if (!res.headersSent) return sendJson(res, 400, { error: err.message || 'Progression error' });
      try { res.end(); } catch {}
    }
  });
};

setTimeout(() => trackPlaytime(), 5000).unref();
setInterval(() => trackPlaytime(), 30000).unref();
console.log(`PalPanel v0.6 Progression geladen. Economy: ${PROGRESSION_FILE}`);
console.log('Spielzeit: 10 Punkte + 10 Event-Score pro 30 Minuten.');
require('./server-v05.js');
