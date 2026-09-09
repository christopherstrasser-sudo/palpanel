const fs = require('fs');
const path = require('path');
const http = require('http');
const crypto = require('crypto');
const { DatabaseSync } = require('node:sqlite');

const APP_DIR = path.resolve(__dirname, '..');
const defaults = JSON.parse(fs.readFileSync(path.join(APP_DIR, 'config', 'default.json'), 'utf8'));
const DB_FILE = path.join(defaults.paths.data, 'palpanel.db');
const SESSION_COOKIE = 'palpanel_user';

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
function num(value) { return Number(value || 0); }
function safeAll(sql, ...params) { try { return db().prepare(sql).all(...params); } catch { return []; } }
function safeGet(sql, ...params) { try { return db().prepare(sql).get(...params) || null; } catch { return null; } }
function parseCookies(req) {
  const out = {};
  String(req.headers.cookie || '').split(';').forEach(part => {
    const i = part.indexOf('=');
    if (i > 0) out[part.slice(0, i).trim()] = decodeURIComponent(part.slice(i + 1).trim());
  });
  return out;
}
function hashToken(token) { return crypto.createHash('sha256').update(String(token || '')).digest('hex'); }
function sessionUserId(req) {
  const token = parseCookies(req)[SESSION_COOKIE];
  if (!token) return null;
  const row = safeGet(`SELECT s.user_id AS userId,s.expires_at AS expiresAt
    FROM user_sessions s WHERE s.token_hash=?`, hashToken(token));
  if (!row || Date.parse(row.expiresAt) <= Date.now()) return null;
  return Number(row.userId) || null;
}

function isPublicDocument(pathname) {
  return pathname === '/' || pathname === '/profile' || pathname === '/profile/' || pathname === '/shop' || pathname === '/shop/' || /^\/player\/\d+\/?$/.test(pathname);
}

function enhanceAchievementHtml(html) {
  const assets = [
    '<link rel="stylesheet" href="/achievements.css?v=0920">',
    '<script src="/achievements.js?v=0920"></script>',
    '<script src="/achievement-bootstrap.js?v=0920"></script>'
  ].join('');
  const source = String(html || '');
  if (source.includes('/achievement-bootstrap.js?v=0920')) return source;
  return source.includes('</head>') ? source.replace('</head>', `${assets}</head>`) : source;
}

function captureAchievementHtml(req, res, listener) {
  const originalWriteHead = res.writeHead.bind(res);
  const originalEnd = res.end.bind(res);
  let pendingStatus = null;
  let pendingMessage = null;
  let pendingHeaders = null;

  res.writeHead = function patchedWriteHead(statusCode, statusMessage, headers) {
    pendingStatus = statusCode;
    if (typeof statusMessage === 'string') {
      pendingMessage = statusMessage;
      pendingHeaders = { ...(headers || {}) };
    } else {
      pendingHeaders = { ...(statusMessage || {}) };
    }
    return res;
  };

  res.end = function patchedEnd(chunk, encoding, callback) {
    if (pendingStatus != null) {
      const headers = { ...(pendingHeaders || {}) };
      const contentType = String(headers['Content-Type'] || headers['content-type'] || '');
      if (pendingStatus === 200 && contentType.toLowerCase().includes('text/html') && chunk != null) {
        const html = enhanceAchievementHtml(Buffer.isBuffer(chunk) ? chunk.toString('utf8') : String(chunk));
        const data = Buffer.from(html);
        delete headers['content-length'];
        headers['Content-Length'] = data.length;
        if (pendingMessage) originalWriteHead(pendingStatus, pendingMessage, headers);
        else originalWriteHead(pendingStatus, headers);
        return originalEnd(data, undefined, callback);
      }
      if (pendingMessage) originalWriteHead(pendingStatus, pendingMessage, headers);
      else originalWriteHead(pendingStatus, headers);
    }
    return originalEnd(chunk, encoding, callback);
  };
  return listener(req, res);
}

function rankFor(score) {
  const ahead = safeGet(`SELECT COUNT(*) AS n FROM (
    SELECT user_id,SUM(amount) AS total
    FROM event_score_ledger GROUP BY user_id HAVING SUM(amount) > ?
  )`, Number(score || 0));
  return num(ahead?.n) + 1;
}

function summaryFor(userId) {
  const row = safeGet(`SELECT u.id AS userId,u.steam_id AS steamId,
      COALESCE(l.palworld_name,'Entdecker #'||u.id) AS name,
      COALESCE(l.level,0) AS level,
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
    WHERE u.id=?`, Number(userId));
  if (!row) return null;
  const score = num(row.eventScore);
  return {
    userId: Number(row.userId),
    name: row.name,
    avatarUrl: /^\d{17}$/.test(String(row.steamId || '')) ? `/api/steam/avatar/user/${row.userId}` : null,
    level: num(row.level),
    playtimeSeconds: num(row.playtimeSeconds),
    uniquePals: num(row.uniquePals),
    totalCaptures: num(row.totalCaptures),
    alphaCaptures: num(row.alphaCaptures),
    bossKills: num(row.bossKills),
    deaths: num(row.deaths),
    levelUps: num(row.levelUps),
    eventScore: score,
    rank: rankFor(score)
  };
}

function rarityTier(holders, communityHunters) {
  const h = Math.max(1, num(holders));
  const total = Math.max(1, num(communityHunters));
  if (total <= 1) return { key: 'pioneer', label: 'PIONIER', weight: 3 };
  const ratio = h / total;
  if (h === 1) return { key: 'mythic', label: 'MYTHISCH', weight: 6 };
  if (ratio <= 0.10) return { key: 'legendary', label: 'LEGENDÄR', weight: 5 };
  if (ratio <= 0.25) return { key: 'epic', label: 'EPISCH', weight: 4 };
  if (ratio <= 0.50) return { key: 'rare', label: 'SELTEN', weight: 3 };
  if (ratio <= 0.75) return { key: 'uncommon', label: 'UNGEWÖHNLICH', weight: 2 };
  return { key: 'common', label: 'VERBREITET', weight: 1 };
}

function rareCapturesFor(userId, limit = 5) {
  const communityHunters = Math.max(1, num(safeGet('SELECT COUNT(DISTINCT user_id) AS n FROM pal_captures')?.n));
  const rows = safeAll(`WITH mine AS (
      SELECT species_key,COUNT(*) AS captures,MAX(is_alpha) AS hasAlpha,MIN(captured_at) AS firstAt
      FROM pal_captures WHERE user_id=? GROUP BY species_key
    )
    SELECT mine.species_key AS speciesKey,mine.captures AS captures,mine.hasAlpha AS hasAlpha,mine.firstAt AS firstAt,
      (SELECT COUNT(DISTINCT other.user_id) FROM pal_captures other WHERE other.species_key=mine.species_key) AS holders
    FROM mine
    ORDER BY holders ASC,hasAlpha DESC,captures ASC,firstAt ASC,speciesKey ASC
    LIMIT ?`, Number(userId), Math.max(1, Math.min(20, Number(limit) || 5)));
  return rows.map(row => {
    const holders = Math.max(1, num(row.holders));
    const tier = rarityTier(holders, communityHunters);
    return {
      speciesKey: row.speciesKey,
      captures: num(row.captures),
      alphaSeen: !!row.hasAlpha,
      firstAt: row.firstAt,
      holders,
      communityHunters,
      sharePercent: Math.round(holders / communityHunters * 1000) / 10,
      rarity: tier
    };
  });
}

const TIER_POINTS = { bronze: 10, silver: 25, gold: 50, legendary: 100 };
function achievement(id, title, description, icon, tier, current, target, unlockedOverride = null) {
  const numericTarget = Math.max(1, Number(target) || 1);
  const numericCurrent = Math.max(0, Number(current) || 0);
  const unlocked = unlockedOverride == null ? numericCurrent >= numericTarget : !!unlockedOverride;
  return {
    id, title, description, icon, tier,
    current: numericCurrent,
    target: numericTarget,
    unlocked,
    progress: unlocked ? 100 : Math.max(0, Math.min(100, numericCurrent / numericTarget * 100)),
    trophyValue: unlocked ? (TIER_POINTS[tier] || 0) : 0
  };
}

function achievementsFor(userId) {
  const s = summaryFor(userId);
  if (!s) return null;
  const list = [
    achievement('first-catch', 'Erster Fang', 'Fange deinen ersten Pal auf diesem Server.', '◎', 'bronze', s.totalCaptures, 1),
    achievement('collector-10', 'Pal-Sammler', 'Entdecke 10 unterschiedliche Pal-Arten.', '◇', 'bronze', s.uniquePals, 10),
    achievement('paldex-25', 'Paldex-Forscher', 'Entdecke 25 unterschiedliche Pal-Arten.', '◇', 'silver', s.uniquePals, 25),
    achievement('paldex-50', 'Paldex-Experte', 'Entdecke 50 unterschiedliche Pal-Arten.', '✦', 'gold', s.uniquePals, 50),
    achievement('paldex-100', 'Paldex-Legende', 'Entdecke 100 unterschiedliche Pal-Arten.', '✺', 'legendary', s.uniquePals, 100),
    achievement('alpha-first', 'Alpha-Spürnase', 'Fange deinen ersten Alpha-Pal.', '◆', 'bronze', s.alphaCaptures, 1),
    achievement('alpha-10', 'Alpha-Jäger', 'Fange 10 Alpha-Pals.', '◆', 'silver', s.alphaCaptures, 10),
    achievement('boss-first', 'Bossbezwinger', 'Besiege deinen ersten erfassten Boss.', '◈', 'bronze', s.bossKills, 1),
    achievement('boss-5', 'Bossbrecher', 'Besiege 5 unterschiedliche Bosse.', '◈', 'gold', s.bossKills, 5),
    achievement('veteran-10h', 'Veteran', 'Verbringe 10 Stunden in der Gemeinschaftswelt.', '⌁', 'silver', s.playtimeSeconds, 10 * 3600),
    achievement('veteran-30h', 'Weltenwanderer', 'Verbringe 30 Stunden in der Gemeinschaftswelt.', '⌁', 'gold', s.playtimeSeconds, 30 * 3600),
    achievement('level-50', 'Stufe 50', 'Erreiche Charakterstufe 50.', '↟', 'gold', s.level, 50),
    achievement('top-10', 'Top 10', 'Erreiche einen Platz unter den besten zehn der Event-Rangliste.', '★', 'gold', s.eventScore > 0 && s.rank <= 10 ? 1 : 0, 1, s.eventScore > 0 && s.rank <= 10),
    achievement('top-3', 'Podium', 'Erreiche einen Platz unter den besten drei der Event-Rangliste.', '♛', 'legendary', s.eventScore > 0 && s.rank <= 3 ? 1 : 0, 1, s.eventScore > 0 && s.rank <= 3)
  ];
  const unlocked = list.filter(item => item.unlocked);
  const rareCaptures = rareCapturesFor(userId, 5);
  return {
    summary: s,
    achievements: list,
    unlockedCount: unlocked.length,
    totalCount: list.length,
    trophyValue: unlocked.reduce((sum, item) => sum + num(item.trophyValue), 0),
    rarestCapture: rareCaptures[0] || null,
    rareCaptures
  };
}

function publicUserRows(orderSql, limit = 5) {
  return safeAll(`SELECT u.id AS userId,u.steam_id AS steamId,
      COALESCE(l.palworld_name,'Entdecker #'||u.id) AS name,
      COALESCE(s.playtime_seconds,0) AS playtimeSeconds,
      COALESCE(s.unique_pals,0) AS uniquePals,
      COALESCE(s.total_captures,0) AS totalCaptures,
      COALESCE(s.alpha_captures,0) AS alphaCaptures,
      COALESCE(s.boss_kills,0) AS bossKills,
      COALESCE((SELECT SUM(e.amount) FROM event_score_ledger e WHERE e.user_id=u.id),0) AS eventScore
    FROM users u
    LEFT JOIN player_links l ON l.user_id=u.id
    LEFT JOIN player_stats s ON s.user_id=u.id
    ${orderSql} LIMIT ?`, Math.max(1, Math.min(20, Number(limit) || 5))).map(row => ({
      userId: Number(row.userId), name: row.name,
      avatarUrl: /^\d{17}$/.test(String(row.steamId || '')) ? `/api/steam/avatar/user/${row.userId}` : null,
      playtimeSeconds: num(row.playtimeSeconds), uniquePals: num(row.uniquePals), totalCaptures: num(row.totalCaptures),
      alphaCaptures: num(row.alphaCaptures), bossKills: num(row.bossKills), eventScore: num(row.eventScore)
    }));
}

function competition() {
  const collectors = publicUserRows('ORDER BY uniquePals DESC,totalCaptures DESC,playtimeSeconds DESC,u.id ASC');
  const alphaHunters = publicUserRows('ORDER BY alphaCaptures DESC,totalCaptures DESC,uniquePals DESC,u.id ASC');
  const bossHunters = publicUserRows('ORDER BY bossKills DESC,eventScore DESC,playtimeSeconds DESC,u.id ASC');
  const veterans = publicUserRows('ORDER BY playtimeSeconds DESC,eventScore DESC,u.id ASC');

  const trophyCandidates = publicUserRows('ORDER BY eventScore DESC,playtimeSeconds DESC,u.id ASC', 20)
    .map(row => {
      const a = achievementsFor(row.userId);
      return { ...row, trophyValue: num(a?.trophyValue), achievementCount: num(a?.unlockedCount) };
    })
    .sort((a, b) => b.trophyValue - a.trophyValue || b.achievementCount - a.achievementCount || b.eventScore - a.eventScore)
    .slice(0, 5);

  const communityHunters = Math.max(0, num(safeGet('SELECT COUNT(DISTINCT user_id) AS n FROM pal_captures')?.n));
  const rareSpecies = safeAll(`SELECT species_key AS speciesKey,COUNT(DISTINCT user_id) AS holders,COUNT(*) AS captures,MAX(is_alpha) AS alphaSeen
    FROM pal_captures GROUP BY species_key
    ORDER BY holders ASC,captures ASC,speciesKey ASC LIMIT 8`).map(row => ({
      speciesKey: row.speciesKey,
      holders: num(row.holders),
      captures: num(row.captures),
      alphaSeen: !!row.alphaSeen,
      rarity: rarityTier(num(row.holders), Math.max(1, communityHunters))
    }));

  return { collectors, alphaHunters, bossHunters, veterans, trophyLeaders: trophyCandidates, rareSpecies, communityHunters };
}

const previousCreateServer = http.createServer.bind(http);
http.createServer = function achievementCreateServer(options, requestListener) {
  const hasOptions = typeof options !== 'function';
  const listener = hasOptions ? requestListener : options;
  const wrapped = async (req, res) => {
    try {
      const url = new URL(req.url, 'http://localhost');
      if (req.method === 'GET' && url.pathname === '/api/user/achievements') {
        const userId = sessionUserId(req);
        if (!userId) return sendJson(res, 401, { error: 'Nicht angemeldet.' });
        const data = achievementsFor(userId);
        if (!data) return sendJson(res, 404, { error: 'Spielerprofil nicht gefunden.' });
        return sendJson(res, 200, data);
      }
      const publicMatch = url.pathname.match(/^\/api\/public\/player\/(\d+)\/achievements$/);
      if (req.method === 'GET' && publicMatch) {
        const data = achievementsFor(Number(publicMatch[1]));
        if (!data) return sendJson(res, 404, { error: 'Spielerprofil nicht gefunden.' });
        return sendJson(res, 200, data);
      }
      if (req.method === 'GET' && url.pathname === '/api/public/community/competition') {
        return sendJson(res, 200, competition());
      }
    } catch (err) {
      console.warn('[Achievements]', err.message);
      if (!res.headersSent) return sendJson(res, 500, { error: 'Erfolge konnten nicht geladen werden.' });
    }
    const url = (() => { try { return new URL(req.url, 'http://localhost'); } catch { return null; } })();
    if (url && isPublicDocument(url.pathname) && (req.method === 'GET' || req.method === 'HEAD')) {
      return captureAchievementHtml(req, res, listener);
    }
    return listener(req, res);
  };
  return hasOptions ? previousCreateServer(options, wrapped) : previousCreateServer(wrapped);
};

console.log('PalPanel v0.9.2 Community-Erfolge, Seltenheit und Wettbewerbe geladen.');
require('./server-v091.js');
