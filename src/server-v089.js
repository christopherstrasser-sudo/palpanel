const fs = require('fs');
const path = require('path');
const http = require('http');
const { DatabaseSync } = require('node:sqlite');

const APP_DIR = path.resolve(__dirname, '..');
const defaults = JSON.parse(fs.readFileSync(path.join(APP_DIR, 'config', 'default.json'), 'utf8'));
const DB_FILE = path.join(defaults.paths.data, 'palpanel.db');

let database = null;
function db() {
  if (!database) {
    database = new DatabaseSync(DB_FILE, { timeout: 5000 });
    try { database.exec('PRAGMA journal_mode = WAL;'); } catch {}
  }
  return database;
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

function publicRank(score) {
  const ahead = safeGet(`SELECT COUNT(*) AS n FROM (
    SELECT user_id,SUM(amount) AS total
    FROM event_score_ledger
    GROUP BY user_id
    HAVING SUM(amount) > ?
  )`, score);
  return number(ahead?.n) + 1;
}

function publicPlayerProfile(userId) {
  const id = Number(userId);
  if (!Number.isInteger(id) || id <= 0) return null;

  const user = safeGet(`SELECT u.id AS userId,u.steam_id AS steamId,
      COALESCE(l.palworld_name,'Entdecker #'||u.id) AS name,
      l.level AS level,
      COALESCE(s.playtime_seconds,0) AS playtimeSeconds,
      COALESCE(s.unique_pals,0) AS uniquePals,
      COALESCE(s.total_captures,0) AS totalCaptures,
      COALESCE(s.alpha_captures,0) AS alphaCaptures,
      COALESCE(s.boss_kills,0) AS bossKills,
      COALESCE(s.deaths,0) AS deaths,
      COALESCE(s.level_ups,0) AS levelUps,
      COALESCE((SELECT SUM(e.amount) FROM event_score_ledger e WHERE e.user_id=u.id),0) AS eventScore
    FROM users u
    LEFT JOIN player_links l ON l.user_id=u.id
    LEFT JOIN player_stats s ON s.user_id=u.id
    WHERE u.id=?`, id);
  if (!user) return null;

  const score = number(user.eventScore);
  const discoveries = safeAll(`SELECT species_key,MAX(is_alpha) AS has_alpha,COUNT(*) AS captures
    FROM pal_captures
    WHERE user_id=?
    GROUP BY species_key
    ORDER BY MIN(captured_at) DESC
    LIMIT 8`, id).map(row => ({
      speciesKey: row.species_key,
      alphaSeen: !!row.has_alpha,
      captures: number(row.captures)
    }));

  const recentAlphas = safeAll(`SELECT species_key
    FROM pal_captures
    WHERE user_id=? AND is_alpha=1
    ORDER BY id DESC
    LIMIT 5`, id).map(row => ({ speciesKey: row.species_key }));

  const recentBosses = safeAll(`SELECT boss_key
    FROM boss_completions
    WHERE user_id=?
    ORDER BY completed_at DESC
    LIMIT 5`, id).map(row => ({ bossKey: row.boss_key }));

  return {
    userId: id,
    name: user.name,
    avatarUrl: /^\d{17}$/.test(String(user.steamId || '')) ? `/api/steam/avatar/user/${id}` : null,
    level: number(user.level) || null,
    rank: publicRank(score),
    eventScore: score,
    playtimeSeconds: number(user.playtimeSeconds),
    uniquePals: number(user.uniquePals),
    totalCaptures: number(user.totalCaptures),
    alphaCaptures: number(user.alphaCaptures),
    bossKills: number(user.bossKills),
    deaths: number(user.deaths),
    levelUps: number(user.levelUps),
    discoveries,
    recentAlphas,
    recentBosses
  };
}

const previousCreateServer = http.createServer.bind(http);
http.createServer = function publicProfileCreateServer(handler) {
  return previousCreateServer(async (req, res) => {
    try {
      const url = new URL(req.url, 'http://localhost');
      const match = url.pathname.match(/^\/api\/public\/player\/(\d+)$/);
      if (req.method === 'GET' && match) {
        const profile = publicPlayerProfile(match[1]);
        if (!profile) return sendJson(res, 404, { error: 'Spielerprofil nicht gefunden.' });
        return sendJson(res, 200, { profile });
      }
    } catch (err) {
      console.warn('[PublicProfile]', err.message);
      if (!res.headersSent) return sendJson(res, 500, { error: 'Öffentliches Spielerprofil konnte nicht geladen werden.' });
    }
    return handler(req, res);
  });
};

console.log('PalPanel v0.8.9 öffentliche Spielerprofile geladen.');
require('./server-v088.js');
