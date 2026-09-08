const fs = require('fs');
const path = require('path');
const http = require('http');
const crypto = require('crypto');
const { DatabaseSync } = require('node:sqlite');

const APP_DIR = path.resolve(__dirname, '..');
const defaults = JSON.parse(fs.readFileSync(path.join(APP_DIR, 'config', 'default.json'), 'utf8'));
const DATA_DIR = defaults.paths.data;
const DB_FILE = path.join(DATA_DIR, 'palpanel.db');
const PROGRESSION_FILE = path.join(DATA_DIR, 'progression.json');
const SESSION_COOKIE = 'palpanel_user';

let database = null;
function db() {
  if (!database) {
    database = new DatabaseSync(DB_FILE, { timeout: 5000 });
    try { database.exec('PRAGMA journal_mode = WAL;'); } catch {}
  }
  return database;
}
function loadJson(file, fallback = {}) {
  try { return JSON.parse(fs.readFileSync(file, 'utf8')); } catch { return fallback; }
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
function sessionFor(req) {
  const token = parseCookies(req)[SESSION_COOKIE];
  if (!token) return null;
  try {
    const row = db().prepare(`SELECT s.user_id,s.expires_at,u.steam_id,u.role
      FROM user_sessions s JOIN users u ON u.id=s.user_id WHERE s.token_hash=?`).get(hashToken(token));
    if (!row || Date.parse(row.expires_at) <= Date.now()) return null;
    return row;
  } catch {
    return null;
  }
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
function number(value) { return Number(value || 0); }
function safeAll(sql, ...params) {
  try { return db().prepare(sql).all(...params); } catch { return []; }
}
function safeGet(sql, ...params) {
  try { return db().prepare(sql).get(...params) || null; } catch { return null; }
}
function eventKind(refType, reason) {
  const ref = String(refType || '').toLowerCase();
  const text = String(reason || '').toLowerCase();
  if (ref.includes('shop')) return 'shop';
  if (ref === 'capture-alpha') return 'alpha';
  if (ref === 'capture-new') return 'entdeckung';
  if (ref === 'capture-repeat') return 'fang';
  if (ref === 'paldex-milestone') return 'meilenstein';
  if (ref === 'boss') return 'boss';
  if (ref === 'playtime') return 'spielzeit';
  if (ref === 'event_bonus' && text.startsWith('level ')) return 'stufe';
  if (ref.includes('bonus')) return 'bonus';
  return 'fortschritt';
}
function sourceBucket(refType, reason) {
  const ref = String(refType || '').toLowerCase();
  const text = String(reason || '').toLowerCase();
  if (ref.includes('shop')) return 'Punkteshop';
  if (ref === 'capture-alpha') return 'Alpha-Fänge';
  if (ref === 'capture-new' || ref === 'capture-repeat') return 'Pal-Fänge';
  if (ref === 'paldex-milestone') return 'Paldex-Meilensteine';
  if (ref === 'boss') return 'Boss-Abschlüsse';
  if (ref === 'playtime') return 'Spielzeit';
  if (ref === 'event_bonus' && text.startsWith('level ')) return 'Stufenaufstiege';
  if (ref.includes('bonus')) return 'Boni';
  return 'Sonstiger Fortschritt';
}
function rankInfo(userId, score) {
  const ahead = safeGet(`SELECT COUNT(*) AS n FROM (
    SELECT user_id,SUM(amount) AS total FROM event_score_ledger GROUP BY user_id HAVING SUM(amount) > ?
  )`, score);
  const next = safeGet(`SELECT user_id,total FROM (
    SELECT user_id,SUM(amount) AS total FROM event_score_ledger GROUP BY user_id HAVING SUM(amount) > ?
  ) ORDER BY total ASC LIMIT 1`, score);
  return {
    rank: number(ahead?.n) + 1,
    nextScore: next ? number(next.total) + 1 : null,
    pointsToNextRank: next ? Math.max(1, number(next.total) - score + 1) : 0
  };
}
function adventurePayload(userId) {
  const stats = safeGet('SELECT * FROM player_stats WHERE user_id=?', userId) || {};
  const link = safeGet('SELECT palworld_name,level,last_seen_at FROM player_links WHERE user_id=?', userId) || {};
  const points = number(safeGet('SELECT COALESCE(SUM(amount),0) AS n FROM points_ledger WHERE user_id=?', userId)?.n);
  const score = number(safeGet('SELECT COALESCE(SUM(amount),0) AS n FROM event_score_ledger WHERE user_id=?', userId)?.n);
  const ranking = rankInfo(userId, score);
  const cfg = {
    playtimeChunkMinutes: 30,
    playtimePoints: 10,
    milestones: { '25': 100, '50': 200, '100': 500, '150': 750, '200': 1000 },
    ...loadJson(PROGRESSION_FILE, {})
  };

  const uniquePals = number(stats.unique_pals);
  const playtimeSeconds = number(stats.playtime_seconds);
  const milestoneEntries = Object.entries(cfg.milestones || {})
    .map(([target, reward]) => ({ target: Number(target), reward: Number(reward) }))
    .filter(x => Number.isFinite(x.target) && x.target > 0 && Number.isFinite(x.reward))
    .sort((a, b) => a.target - b.target);
  const nextPaldex = milestoneEntries.find(x => uniquePals < x.target) || milestoneEntries[milestoneEntries.length - 1] || { target: Math.max(25, uniquePals), reward: 0 };
  const paldexComplete = milestoneEntries.length > 0 && uniquePals >= milestoneEntries[milestoneEntries.length - 1].target;
  const playtimeTarget = Math.max(60, Number(cfg.playtimeChunkMinutes || 30) * 60);
  const playtimeCurrent = playtimeSeconds % playtimeTarget;

  const milestones = [
    {
      type: 'paldex',
      title: paldexComplete ? 'Paldex-Meilensteine abgeschlossen' : `Nächster Paldex-Meilenstein: ${nextPaldex.target} Arten`,
      current: paldexComplete ? nextPaldex.target : uniquePals,
      target: nextPaldex.target,
      rewardPoints: paldexComplete ? 0 : nextPaldex.reward,
      rewardScore: paldexComplete ? 0 : nextPaldex.reward,
      complete: paldexComplete
    },
    {
      type: 'spielzeit',
      title: 'Nächste Spielzeit-Belohnung',
      current: playtimeCurrent,
      target: playtimeTarget,
      rewardPoints: Number(cfg.playtimePoints || 10),
      rewardScore: Number(cfg.playtimePoints || 10),
      complete: false
    },
    {
      type: 'rang',
      title: ranking.rank === 1 ? 'Du führst die Rangliste an' : `Auf dem Weg zu Rang ${Math.max(1, ranking.rank - 1)}`,
      current: score,
      target: ranking.nextScore || Math.max(1, score),
      rewardPoints: 0,
      rewardScore: 0,
      complete: ranking.rank === 1,
      pointsToNextRank: ranking.pointsToNextRank
    }
  ];

  const pointRows = safeAll(`SELECT amount,reason,ref_type,ref_id,created_at
    FROM points_ledger WHERE user_id=? ORDER BY id DESC LIMIT 32`, userId);
  const deathRows = safeAll(`SELECT event_id,payload_json,created_at FROM gameplay_events
    WHERE user_id=? AND event_type='death' ORDER BY id DESC LIMIT 12`, userId);
  const recentEvents = [
    ...pointRows.map(row => ({
      kind: eventKind(row.ref_type, row.reason),
      label: String(row.reason || 'Fortschritt'),
      amount: number(row.amount),
      at: row.created_at
    })),
    ...deathRows.map(row => ({
      kind: 'tod',
      label: 'Spielertod',
      amount: 0,
      at: row.created_at
    }))
  ].sort((a, b) => Date.parse(b.at || 0) - Date.parse(a.at || 0)).slice(0, 14);

  const discoveries = safeAll(`SELECT species_key,MIN(captured_at) AS discovered_at,MAX(is_alpha) AS has_alpha,COUNT(*) AS captures
    FROM pal_captures WHERE user_id=? GROUP BY species_key ORDER BY MIN(captured_at) DESC LIMIT 8`, userId)
    .map(row => ({ speciesKey: row.species_key, discoveredAt: row.discovered_at, alphaSeen: !!row.has_alpha, captures: number(row.captures) }));
  const recentAlphas = safeAll(`SELECT species_key,captured_at FROM pal_captures
    WHERE user_id=? AND is_alpha=1 ORDER BY id DESC LIMIT 5`, userId)
    .map(row => ({ speciesKey: row.species_key, capturedAt: row.captured_at }));
  const recentBosses = safeAll(`SELECT boss_key,completed_at FROM boss_completions
    WHERE user_id=? ORDER BY completed_at DESC LIMIT 5`, userId)
    .map(row => ({ bossKey: row.boss_key, completedAt: row.completed_at }));

  const sourceMap = new Map();
  for (const row of safeAll('SELECT amount,reason,ref_type FROM points_ledger WHERE user_id=?', userId)) {
    const label = sourceBucket(row.ref_type, row.reason);
    sourceMap.set(label, number(sourceMap.get(label)) + number(row.amount));
  }
  const pointSources = [...sourceMap.entries()]
    .map(([label, amount]) => ({ label, amount }))
    .sort((a, b) => Math.abs(b.amount) - Math.abs(a.amount));

  return {
    summary: {
      points,
      eventScore: score,
      rank: ranking.rank,
      level: number(link.level) || null,
      characterName: link.palworld_name || null,
      playtimeSeconds,
      uniquePals,
      totalCaptures: number(stats.total_captures),
      alphaCaptures: number(stats.alpha_captures),
      bossKills: number(stats.boss_kills),
      deaths: number(stats.deaths),
      levelUps: number(stats.level_ups),
      lastSeenAt: link.last_seen_at || null
    },
    milestones,
    recentEvents,
    discoveries,
    recentAlphas,
    recentBosses,
    pointSources
  };
}

const previousCreateServer = http.createServer.bind(http);
http.createServer = function adventureCreateServer(handler) {
  return previousCreateServer(async (req, res) => {
    try {
      const url = new URL(req.url, 'http://localhost');
      if (req.method === 'GET' && url.pathname === '/api/user/adventure') {
        const session = sessionFor(req);
        if (!session) return sendJson(res, 401, { error: 'Nicht angemeldet.' });
        return sendJson(res, 200, adventurePayload(session.user_id));
      }
    } catch (err) {
      if (!res.headersSent) return sendJson(res, 500, { error: `Profil konnte nicht geladen werden: ${err.message}` });
    }
    return handler(req, res);
  });
};

console.log('PalPanel v0.8.7 Abenteuerprofil-API geladen.');
require('./server-v086.js');
