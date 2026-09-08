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
const GAME_EVENTS_DIR = path.join(DATA_DIR, 'bridge-ipc', 'game-events');
const GAME_FAILED_DIR = path.join(DATA_DIR, 'bridge-ipc', 'game-events-failed');
const GAMEPLAY_SOURCE = path.join(APP_DIR, 'bridge', 'PalPanelGameplay');
const SESSION_COOKIE = 'palpanel_user';

fs.mkdirSync(DATA_DIR, { recursive: true });
fs.mkdirSync(GAME_EVENTS_DIR, { recursive: true });
fs.mkdirSync(GAME_FAILED_DIR, { recursive: true });

const db = new DatabaseSync(DB_FILE, { timeout: 5000 });
try { db.exec('PRAGMA journal_mode = WAL;'); } catch {}

function loadJson(file, fallback = null) {
  try { return JSON.parse(fs.readFileSync(file, 'utf8')); } catch { return fallback; }
}
function saveJson(file, value) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, JSON.stringify(value, null, 2), 'utf8');
}
function config() {
  const current = loadJson(USER_CONFIG, {}) || {};
  const palworld = current.palworld || {};
  return {
    ...defaults,
    ...current,
    paths: { ...defaults.paths, ...(current.paths || {}) },
    palworld: {
      ...defaults.palworld,
      ...palworld,
      rest: { ...defaults.palworld.rest, ...(palworld.rest || {}) }
    }
  };
}
function panelPort() {
  const current = loadJson(USER_CONFIG, {}) || {};
  return Number(current.panel?.port || defaults.panel.port || 8787);
}
function nowIso() { return new Date().toISOString(); }
function ensureStats(userId) {
  try {
    db.prepare(`INSERT INTO player_stats(user_id,updated_at) VALUES(?,?) ON CONFLICT(user_id) DO NOTHING`).run(userId, nowIso());
  } catch {}
}

function ensureGameplaySchema() {
  db.exec(`
    CREATE TABLE IF NOT EXISTS gameplay_events (
      id INTEGER PRIMARY KEY,
      source TEXT NOT NULL,
      event_id TEXT NOT NULL,
      user_id INTEGER NOT NULL,
      event_type TEXT NOT NULL,
      payload_json TEXT NOT NULL DEFAULT '{}',
      created_at TEXT NOT NULL,
      UNIQUE(source,event_id)
    ) STRICT;
    CREATE TABLE IF NOT EXISTS gameplay_level_state (
      user_id INTEGER PRIMARY KEY,
      baseline_level INTEGER NOT NULL,
      last_level INTEGER NOT NULL,
      earned_levels INTEGER NOT NULL DEFAULT 0,
      generation INTEGER NOT NULL DEFAULT 0,
      updated_at TEXT NOT NULL
    ) STRICT;
  `);
  try { db.exec('ALTER TABLE player_stats ADD COLUMN deaths INTEGER NOT NULL DEFAULT 0;'); } catch {}
  try { db.exec('ALTER TABLE player_stats ADD COLUMN level_ups INTEGER NOT NULL DEFAULT 0;'); } catch {}
}

function ensureProgressionConfig() {
  const current = loadJson(PROGRESSION_FILE, null);
  if (!current || typeof current !== 'object') return;
  let changed = false;
  if (current.levelUpPoints == null) { current.levelUpPoints = 10; changed = true; }
  if (current.deathPenalty == null) { current.deathPenalty = 0; changed = true; }
  if (changed) saveJson(PROGRESSION_FILE, current);
}
function levelUpPoints() {
  const cfg = loadJson(PROGRESSION_FILE, {}) || {};
  return Math.max(0, Math.min(1000, Math.trunc(Number(cfg.levelUpPoints ?? 10) || 10)));
}

function ue4ssPaths() {
  const cfg = config();
  const win64 = path.join(cfg.paths.server, 'Pal', 'Binaries', 'Win64');
  const nested = path.join(win64, 'ue4ss');
  const root = fs.existsSync(path.join(nested, 'UE4SS.dll')) || !fs.existsSync(path.join(win64, 'UE4SS.dll')) ? nested : win64;
  return {
    root,
    modsDir: path.join(root, 'Mods'),
    stableBridge: path.join(root, 'Mods', 'PalPanelBridge'),
    gameplayMod: path.join(root, 'Mods', 'PalPanelGameplay'),
    ipcDir: path.join(cfg.paths.data, 'bridge-ipc')
  };
}
function sourceGameplayVersion() {
  return loadJson(path.join(GAMEPLAY_SOURCE, 'manifest.json'), { version: 'unknown' })?.version || 'unknown';
}
function installedGameplayVersion(destination) {
  return loadJson(path.join(destination, 'manifest.json'), null)?.version || null;
}
function ensureGameplayModsTxt(modsDir) {
  fs.mkdirSync(modsDir, { recursive: true });
  const file = path.join(modsDir, 'mods.txt');
  let lines = [];
  try { lines = fs.readFileSync(file, 'utf8').split(/\r?\n/); } catch {}
  let found = false;
  lines = lines.map(line => {
    if (/^\s*PalPanelGameplay\s*:/i.test(line)) {
      found = true;
      return 'PalPanelGameplay : 1';
    }
    return line;
  }).filter((line, index, all) => line !== '' || index < all.length - 1);
  if (!found) lines.push('PalPanelGameplay : 1');
  fs.writeFileSync(file, `${lines.join('\r\n').replace(/(?:\r?\n)+$/, '')}\r\n`, 'utf8');
}
function syncGameplayObserver() {
  const p = ue4ssPaths();
  const sourceMain = path.join(GAMEPLAY_SOURCE, 'Scripts', 'main.lua');
  const stableMain = path.join(p.stableBridge, 'Scripts', 'main.lua');
  if (!fs.existsSync(sourceMain)) {
    console.warn('[PalPanelGameplay] Source fehlt; Gameplay-Sidecar wurde nicht installiert.');
    return;
  }
  if (!fs.existsSync(stableMain)) {
    console.log('[PalPanelGameplay] PalPanelBridge nicht installiert; Sidecar bleibt deaktiviert.');
    return;
  }

  const wanted = sourceGameplayVersion();
  const current = installedGameplayVersion(p.gameplayMod);
  const needsCopy = current !== wanted || !fs.existsSync(path.join(p.gameplayMod, 'Scripts', 'main.lua'));
  fs.mkdirSync(p.ipcDir, { recursive: true });
  fs.mkdirSync(path.join(p.ipcDir, 'game-events'), { recursive: true });

  if (needsCopy) {
    fs.mkdirSync(p.modsDir, { recursive: true });
    fs.rmSync(p.gameplayMod, { recursive: true, force: true });
    fs.cpSync(GAMEPLAY_SOURCE, p.gameplayMod, { recursive: true });
    fs.writeFileSync(path.join(p.gameplayMod, 'ipc_path.txt'), `${p.ipcDir}\r\n`, 'utf8');
    console.log(`[PalPanelGameplay] Sidecar ${wanted} installiert: ${p.gameplayMod}`);
  } else {
    fs.writeFileSync(path.join(p.gameplayMod, 'ipc_path.txt'), `${p.ipcDir}\r\n`, 'utf8');
    console.log(`[PalPanelGameplay] Sidecar ${wanted} bereit.`);
  }
  ensureGameplayModsTxt(p.modsDir);
  console.log('[PalPanelGameplay] mods.txt: PalPanelGameplay : 1');
}

function parseCookies(req) {
  const out = {};
  String(req.headers.cookie || '').split(';').forEach(part => {
    const i = part.indexOf('=');
    if (i > 0) out[part.slice(0, i).trim()] = decodeURIComponent(part.slice(i + 1).trim());
  });
  return out;
}
function hashToken(token) { return crypto.createHash('sha256').update(token).digest('hex'); }
function sessionFor(req) {
  const token = parseCookies(req)[SESSION_COOKIE];
  if (!token) return null;
  try {
    const row = db.prepare(`SELECT s.user_id,s.expires_at FROM user_sessions s WHERE s.token_hash=?`).get(hashToken(token));
    if (!row || Date.parse(row.expires_at) <= Date.now()) return null;
    return row;
  } catch { return null; }
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
function gameplayPayload(userId) {
  ensureGameplaySchema();
  ensureStats(userId);
  const stats = db.prepare('SELECT deaths,level_ups FROM player_stats WHERE user_id=?').get(userId) || {};
  const link = db.prepare('SELECT level FROM player_links WHERE user_id=?').get(userId) || {};
  const state = db.prepare('SELECT baseline_level,last_level,earned_levels,generation FROM gameplay_level_state WHERE user_id=?').get(userId) || {};
  return {
    deaths: Number(stats.deaths || 0),
    levelUps: Number(stats.level_ups || state.earned_levels || 0),
    currentLevel: Number(link.level || state.last_level || 0) || null,
    levelUpPoints: levelUpPoints(),
    deathPenalty: 0
  };
}

const previousCreateServer = http.createServer.bind(http);
http.createServer = function gameplayStatsCreateServer(handler) {
  return previousCreateServer(async (req, res) => {
    const url = new URL(req.url, 'http://localhost');
    if (req.method === 'GET' && url.pathname === '/api/user/gameplay-stats') {
      const session = sessionFor(req);
      if (!session) return sendJson(res, 401, { error: 'Nicht angemeldet.' });
      return sendJson(res, 200, gameplayPayload(session.user_id));
    }
    return handler(req, res);
  });
};

function restCredentials() { return loadJson(REST_FILE, null); }
async function livePlayers() {
  const cfg = config();
  const creds = restCredentials();
  if (!creds?.password) return null;
  const auth = Buffer.from(`${creds.username || 'admin'}:${creds.password}`).toString('base64');
  const response = await fetch(`http://${cfg.palworld.rest.host || '127.0.0.1'}:${cfg.palworld.rest.port || 8212}/v1/api/players`, {
    headers: { Accept: 'application/json', Authorization: `Basic ${auth}` },
    signal: AbortSignal.timeout(3000)
  });
  if (!response.ok) return null;
  const body = await response.json().catch(() => ({}));
  return Array.isArray(body.players) ? body.players : [];
}
function sameIdentity(value, expected) {
  const a = String(value || '').trim();
  const b = String(expected || '').trim();
  return a === b || (a.replace(/\D/g, '') && a.replace(/\D/g, '') === b.replace(/\D/g, ''));
}
function linkedRows() {
  try {
    return db.prepare(`SELECT u.id AS userId,u.steam_id AS steamId,l.palworld_user_id AS palworldUserId,l.player_uid AS playerUid FROM users u JOIN player_links l ON l.user_id=u.id`).all();
  } catch { return []; }
}
function linkedUserId(playerUid) {
  const wanted = String(playerUid || '').trim().replace(/[^0-9a-z]/gi, '').toUpperCase();
  if (!wanted) return null;
  const canon = value => String(value || '').trim().replace(/[^0-9a-z]/gi, '').toUpperCase();
  try {
    const rows = db.prepare('SELECT user_id,palworld_user_id,player_uid FROM player_links').all();
    const row = rows.find(link => canon(link.player_uid) === wanted || canon(link.palworld_user_id) === wanted);
    return row ? Number(row.user_id) : null;
  } catch { return null; }
}

async function postProgression(payload) {
  const progression = loadJson(PROGRESSION_FILE, null);
  if (!progression?.bridgeKey) throw new Error('Progression Bridge-Key noch nicht verfügbar');
  const response = await fetch(`http://127.0.0.1:${panelPort()}/api/internal/progression/event`, {
    method: 'POST',
    headers: {
      Accept: 'application/json',
      'Content-Type': 'application/json',
      'X-PalPanel-Bridge-Key': progression.bridgeKey
    },
    body: JSON.stringify(payload),
    signal: AbortSignal.timeout(4000)
  });
  const body = await response.json().catch(() => ({}));
  if (!response.ok) throw new Error(body.error || `HTTP ${response.status}`);
  return body;
}

let levelTracking = false;
async function trackLevels() {
  if (levelTracking) return;
  levelTracking = true;
  try {
    ensureGameplaySchema();
    const players = await livePlayers();
    if (!players) return;
    const reward = levelUpPoints();

    for (const link of linkedRows()) {
      const player = players.find(p =>
        sameIdentity(p.userId, link.palworldUserId) ||
        sameIdentity(p.userId, link.steamId) ||
        sameIdentity(p.playerId || p.playerUid, link.playerUid)
      );
      if (!player) continue;

      const rawLevel = Math.trunc(Number(player.level) || 0);
      if (rawLevel <= 0) continue;
      const level = rawLevel;
      ensureStats(link.userId);

      let state = db.prepare('SELECT * FROM gameplay_level_state WHERE user_id=?').get(link.userId);
      if (!state) {
        db.prepare(`INSERT INTO gameplay_level_state(user_id,baseline_level,last_level,earned_levels,generation,updated_at) VALUES(?,?,?,?,?,?)`).run(link.userId, level, level, 0, 0, nowIso());
        console.log(`[Gameplay] Level-Baseline: User ${link.userId} = Lv.${level}`);
        continue;
      }

      const last = Number(state.last_level || level);
      if (level < last) {
        const generation = Number(state.generation || 0) + 1;
        db.prepare('UPDATE gameplay_level_state SET baseline_level=?,last_level=?,generation=?,updated_at=? WHERE user_id=?').run(level, level, generation, nowIso(), link.userId);
        console.log(`[Gameplay] Level-Reset erkannt: User ${link.userId} -> Lv.${level} (Generation ${generation})`);
        continue;
      }
      if (level <= last) continue;

      const generation = Number(state.generation || 0);
      for (let reached = last + 1; reached <= level; reached++) {
        const result = await postProgression({
          source: 'PalPanelGameplay',
          eventId: `level:${link.userId}:g${generation}:${reached}`,
          type: 'event_bonus',
          userId: link.userId,
          amount: reward,
          scoreAmount: reward,
          reason: `Level ${reached} erreicht`
        });
        if (!result.duplicate) console.log(`[Gameplay] LEVEL UP: User ${link.userId} -> Lv.${reached} | +${reward} PTS / +${reward} Score`);
      }

      const delta = level - last;
      const earned = Number(state.earned_levels || 0) + delta;
      db.prepare('UPDATE gameplay_level_state SET last_level=?,earned_levels=?,updated_at=? WHERE user_id=?').run(level, earned, nowIso(), link.userId);
      db.prepare('UPDATE player_stats SET level_ups=?,updated_at=? WHERE user_id=?').run(earned, nowIso(), link.userId);
    }
  } catch (err) {
    console.warn('[Gameplay] Level-Tracking:', err.message);
  } finally {
    levelTracking = false;
  }
}

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
function readGameEvent(file) {
  const full = path.join(GAME_EVENTS_DIR, file);
  const event = parseKv(fs.readFileSync(full, 'utf8'));
  if (!['death', 'boss'].includes(event.type)) throw new Error(`unsupported event type: ${event.type || 'missing'}`);
  if (!event.event_id) throw new Error('event_id missing');
  if (!event.player_uid) throw new Error('player_uid missing');
  if (event.type === 'boss' && !event.boss_key) throw new Error('boss_key missing');
  return { full, event };
}
function moveGameFailed(file, reason) {
  const from = path.join(GAME_EVENTS_DIR, file);
  const stamp = new Date().toISOString().replace(/[:.]/g, '-');
  const to = path.join(GAME_FAILED_DIR, `${stamp}_${file}`);
  try { fs.renameSync(from, to); }
  catch {
    try { fs.copyFileSync(from, to); fs.rmSync(from, { force: true }); } catch {}
  }
  try { fs.writeFileSync(`${to}.error.txt`, String(reason || 'unknown error'), 'utf8'); } catch {}
}

const gameplayProcessing = new Set();
const gameplayLastAttempt = new Map();
const gameplayLastError = new Map();
function gameplayShouldRetry(file) { return Date.now() - Number(gameplayLastAttempt.get(file) || 0) >= 3000; }
function gameplayLogOnce(file, message) {
  if (gameplayLastError.get(file) === message) return;
  gameplayLastError.set(file, message);
  console.warn(`[GameplayEvents] ${file}: ${message}`);
}

function recordDeath(userId, event) {
  ensureGameplaySchema();
  ensureStats(userId);
  const duplicate = db.prepare(`SELECT 1 FROM gameplay_events WHERE source='PalPanelGameplay' AND event_id=?`).get(event.event_id);
  if (duplicate) return true;
  db.exec('BEGIN IMMEDIATE');
  try {
    db.prepare(`INSERT INTO gameplay_events(source,event_id,user_id,event_type,payload_json,created_at) VALUES('PalPanelGameplay',?,?,?,?,?)`).run(event.event_id, userId, 'death', JSON.stringify(event), nowIso());
    db.prepare('UPDATE player_stats SET deaths=deaths+1,updated_at=? WHERE user_id=?').run(nowIso(), userId);
    db.exec('COMMIT');
    return false;
  } catch (err) {
    try { db.exec('ROLLBACK'); } catch {}
    throw err;
  }
}

async function dispatchGameEvent(file) {
  if (gameplayProcessing.has(file) || !gameplayShouldRetry(file)) return;
  gameplayProcessing.add(file);
  gameplayLastAttempt.set(file, Date.now());
  try {
    let parsed;
    try { parsed = readGameEvent(file); }
    catch (err) {
      moveGameFailed(file, err.message);
      console.warn(`[GameplayEvents] Ungültiges Event verschoben: ${file} (${err.message})`);
      return;
    }

    const e = parsed.event;
    const userId = linkedUserId(e.player_uid);
    if (!userId) {
      gameplayLogOnce(file, 'Spieler noch nicht mit PalPanel verknüpft — wird erneut versucht.');
      return;
    }

    if (e.type === 'death') {
      const duplicate = recordDeath(userId, e);
      fs.rmSync(parsed.full, { force: true });
      console.log(duplicate ? `[GameplayEvents] Duplicate Tod ignoriert: User ${userId}` : `[GameplayEvents] DEATH: User ${userId} | keine Punktstrafe`);
    } else if (e.type === 'boss') {
      let result;
      try {
        result = await postProgression({
          source: 'PalPanelGameplay',
          eventId: e.event_id,
          type: 'boss',
          userId,
          playerUid: e.player_uid,
          bossKey: e.boss_key,
          boss: e.boss_key,
          level: Number(e.level) || null,
          palId: e.pal_id || null,
          species: e.species || e.boss_key
        });
      } catch (err) {
        gameplayLogOnce(file, `${err.message} — wird erneut versucht.`);
        return;
      }
      fs.rmSync(parsed.full, { force: true });
      if (result.alreadyCompleted) console.log(`[GameplayEvents] Boss bereits gewertet: ${e.boss_key}`);
      else console.log(`[GameplayEvents] BOSS: ${e.boss_key} -> +${Number(result.pointsAwarded || 0)} PTS / +${Number(result.scoreAwarded || 0)} Score`);
    }

    gameplayLastAttempt.delete(file);
    gameplayLastError.delete(file);
  } finally {
    gameplayProcessing.delete(file);
  }
}

let gameScanBusy = false;
async function scanGameEvents() {
  if (gameScanBusy) return;
  gameScanBusy = true;
  try {
    const files = fs.readdirSync(GAME_EVENTS_DIR).filter(name => name.toLowerCase().endsWith('.evt')).sort().slice(0, 25);
    for (const file of files) await dispatchGameEvent(file);
  } catch (err) {
    console.error('[GameplayEvents] Queue scan:', err.message);
  } finally {
    gameScanBusy = false;
  }
}

try { syncGameplayObserver(); }
catch (err) { console.error('[PalPanelGameplay] Sidecar-Sync fehlgeschlagen:', err.message); }

// v0.8.4 installs the proven capture sidecar and then loads the stable backend chain.
require('./server-v084.js');

ensureGameplaySchema();
ensureProgressionConfig();
setTimeout(trackLevels, 7000).unref();
setInterval(trackLevels, 15000).unref();
setTimeout(scanGameEvents, 2500).unref();
setInterval(scanGameEvents, 1000).unref();
console.log(`PalPanel v0.8.5 Gameplay-Events geladen. Queue: ${GAME_EVENTS_DIR}`);
console.log(`Level-Ups: +${levelUpPoints()} PTS / +${levelUpPoints()} Score pro erreichtem Level. Spielertode: Statistik, keine Punktstrafe.`);
