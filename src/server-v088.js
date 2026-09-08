const fs = require('fs');
const path = require('path');
const http = require('http');
const { DatabaseSync } = require('node:sqlite');

const APP_DIR = path.resolve(__dirname, '..');
const defaults = JSON.parse(fs.readFileSync(path.join(APP_DIR, 'config', 'default.json'), 'utf8'));
const DB_FILE = path.join(defaults.paths.data, 'palpanel.db');
const AVATAR_CACHE_DIR = path.join(defaults.paths.data, 'steam-avatars');
const AVATAR_TTL_MS = 12 * 60 * 60 * 1000;
const OFFICIAL_BANNER_URL = 'https://cdn.akamai.steamstatic.com/steam/apps/1623730/library_hero.jpg';

fs.mkdirSync(AVATAR_CACHE_DIR, { recursive: true });

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

function publicLeaderboard() {
  return db().prepare(`SELECT u.id AS userId,u.steam_id AS steamId,
      COALESCE(l.palworld_name,'Entdecker #'||u.id) AS name,
      COALESCE(s.playtime_seconds,0) AS playtimeSeconds,
      COALESCE(s.unique_pals,0) AS uniquePals,
      COALESCE((SELECT SUM(e.amount) FROM event_score_ledger e WHERE e.user_id=u.id),0) AS eventScore
    FROM users u
    LEFT JOIN player_links l ON l.user_id=u.id
    LEFT JOIN player_stats s ON s.user_id=u.id
    ORDER BY eventScore DESC,playtimeSeconds DESC,u.id ASC LIMIT 20`).all().map(row => ({
      userId: row.userId,
      name: row.name,
      playtimeSeconds: Number(row.playtimeSeconds || 0),
      uniquePals: Number(row.uniquePals || 0),
      eventScore: Number(row.eventScore || 0),
      avatarUrl: /^\d{17}$/.test(String(row.steamId || '')) ? `/api/steam/avatar/user/${row.userId}` : null
    }));
}

function cacheFiles(steamId) {
  return {
    image: path.join(AVATAR_CACHE_DIR, `${steamId}.img`),
    meta: path.join(AVATAR_CACHE_DIR, `${steamId}.json`)
  };
}

function readMeta(file) {
  try { return JSON.parse(fs.readFileSync(file, 'utf8')); } catch { return null; }
}

function decodeXml(value) {
  return String(value || '')
    .replace(/&amp;/g, '&')
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"')
    .replace(/&#39;|&apos;/g, "'")
    .trim();
}

function avatarUrlFromXml(xml) {
  const match = String(xml || '').match(/<avatarFull>\s*(?:<!\[CDATA\[)?([\s\S]*?)(?:\]\]>)?\s*<\/avatarFull>/i);
  return match ? decodeXml(match[1].replace(/^\s*<!\[CDATA\[/, '').replace(/\]\]>\s*$/, '')) : null;
}

function allowedAvatarUrl(value) {
  try {
    const url = new URL(value);
    const host = url.hostname.toLowerCase();
    if (url.protocol !== 'https:') return false;
    return host === 'avatars.steamstatic.com' ||
      host.endsWith('.steamstatic.com') ||
      host.endsWith('.akamaihd.net');
  } catch {
    return false;
  }
}

function serveBuffer(res, buffer, contentType, cacheState) {
  res.writeHead(200, {
    'Content-Type': /^image\//i.test(String(contentType || '')) ? contentType : 'image/jpeg',
    'Content-Length': buffer.length,
    'Cache-Control': 'public, max-age=3600, stale-while-revalidate=86400',
    'X-PalPanel-Steam-Avatar': cacheState
  });
  res.end(buffer);
}

function serveCachedAvatar(res, files, meta, state = 'cache') {
  const buffer = fs.readFileSync(files.image);
  serveBuffer(res, buffer, meta?.contentType || 'image/jpeg', state);
}

async function refreshAvatar(steamId, files) {
  const profileResponse = await fetch(`https://steamcommunity.com/profiles/${steamId}?xml=1`, {
    headers: {
      Accept: 'application/xml,text/xml;q=0.9,*/*;q=0.8',
      'User-Agent': 'PalPanel/0.8.8'
    },
    signal: AbortSignal.timeout(6000)
  });
  if (!profileResponse.ok) throw new Error(`Steam-Profil HTTP ${profileResponse.status}`);

  const xml = await profileResponse.text();
  const avatarUrl = avatarUrlFromXml(xml);
  if (!avatarUrl || !allowedAvatarUrl(avatarUrl)) throw new Error('Kein gültiges Steam-Profilbild gefunden.');

  const avatarResponse = await fetch(avatarUrl, {
    headers: { Accept: 'image/*', 'User-Agent': 'PalPanel/0.8.8' },
    signal: AbortSignal.timeout(6000)
  });
  if (!avatarResponse.ok) throw new Error(`Steam-Profilbild HTTP ${avatarResponse.status}`);

  const contentType = String(avatarResponse.headers.get('content-type') || 'image/jpeg').split(';')[0].trim();
  if (!contentType.startsWith('image/')) throw new Error('Steam lieferte kein Bild.');

  const buffer = Buffer.from(await avatarResponse.arrayBuffer());
  if (buffer.length < 128 || buffer.length > 2 * 1024 * 1024) throw new Error('Ungültige Profilbildgröße.');

  const tmpImage = `${files.image}.tmp`;
  const tmpMeta = `${files.meta}.tmp`;
  fs.writeFileSync(tmpImage, buffer);
  fs.writeFileSync(tmpMeta, JSON.stringify({
    steamId,
    avatarUrl,
    contentType,
    fetchedAt: new Date().toISOString()
  }, null, 2), 'utf8');
  fs.rmSync(files.image, { force: true });
  fs.rmSync(files.meta, { force: true });
  fs.renameSync(tmpImage, files.image);
  fs.renameSync(tmpMeta, files.meta);
  return { buffer, contentType };
}

async function serveSteamAvatar(steamId, res) {
  const files = cacheFiles(steamId);
  const meta = readMeta(files.meta);
  const hasCache = fs.existsSync(files.image);
  const fetchedAt = Date.parse(meta?.fetchedAt || '');
  const fresh = hasCache && Number.isFinite(fetchedAt) && Date.now() - fetchedAt < AVATAR_TTL_MS;

  if (fresh) {
    try { return serveCachedAvatar(res, files, meta, 'cache'); } catch {}
  }

  try {
    const freshAvatar = await refreshAvatar(steamId, files);
    return serveBuffer(res, freshAvatar.buffer, freshAvatar.contentType, 'frisch');
  } catch (err) {
    if (hasCache) {
      try { return serveCachedAvatar(res, files, meta, 'veraltet'); } catch {}
    }
    console.warn(`[SteamAvatar] ${steamId}: ${err.message}`);
    res.writeHead(404, { 'Cache-Control': 'no-store' });
    return res.end();
  }
}

async function servePublicUserAvatar(userId, res) {
  const row = db().prepare('SELECT steam_id AS steamId FROM users WHERE id=?').get(Number(userId));
  const steamId = String(row?.steamId || '');
  if (!/^\d{17}$/.test(steamId)) {
    res.writeHead(404, { 'Cache-Control': 'no-store' });
    return res.end();
  }
  return serveSteamAvatar(steamId, res);
}

function redirectBanner(res) {
  res.writeHead(307, {
    Location: OFFICIAL_BANNER_URL,
    'Cache-Control': 'public, max-age=86400',
    'X-PalPanel-Banner': 'official-original'
  });
  res.end();
}

const previousCreateServer = http.createServer.bind(http);
http.createServer = function steamAvatarCreateServer(handler) {
  return previousCreateServer(async (req, res) => {
    try {
      const url = new URL(req.url, 'http://localhost');
      if ((req.method === 'GET' || req.method === 'HEAD') && url.pathname === '/palpanel-banner.png') {
        return redirectBanner(res);
      }
      const avatarMatch = url.pathname.match(/^\/api\/steam\/avatar\/(\d{17})$/);
      if (req.method === 'GET' && avatarMatch) return await serveSteamAvatar(avatarMatch[1], res);
      const publicAvatarMatch = url.pathname.match(/^\/api\/steam\/avatar\/user\/(\d+)$/);
      if (req.method === 'GET' && publicAvatarMatch) return await servePublicUserAvatar(publicAvatarMatch[1], res);
      if (req.method === 'GET' && url.pathname === '/api/public/leaderboard') {
        return sendJson(res, 200, { leaderboard: publicLeaderboard() });
      }
    } catch (err) {
      console.warn('[SteamAvatar]', err.message);
      if (!res.headersSent) return sendJson(res, 500, { error: 'Steam-Profilbild konnte nicht geladen werden.' });
    }
    return handler(req, res);
  });
};

console.log(`PalPanel v0.8.8 Steam-Profilbilder geladen. Cache: ${AVATAR_CACHE_DIR}`);
console.log('PalPanel v0.8.8 Original-Banner-Fallback geladen.');
require('./server-v087.js');
