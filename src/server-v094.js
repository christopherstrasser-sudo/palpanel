const fs = require('fs');
const path = require('path');
const http = require('http');
const crypto = require('crypto');
const { DatabaseSync } = require('node:sqlite');

const APP_DIR = path.resolve(__dirname, '..');
const defaults = JSON.parse(fs.readFileSync(path.join(APP_DIR, 'config', 'default.json'), 'utf8'));
const DATA_DIR = defaults.paths.data;
const DB_FILE = path.join(DATA_DIR, 'palpanel.db');
const SEASON_FILE = path.join(DATA_DIR, 'season.json');
const SESSION_COOKIE = 'palpanel_user';
const ASSET_VERSION = '0940';

let database = null;
function db() {
  if (!database) {
    database = new DatabaseSync(DB_FILE, { timeout: 5000 });
    try {
      database.exec('PRAGMA journal_mode = WAL;');
      database.exec(`
        CREATE TABLE IF NOT EXISTS season_archives (
          season_id TEXT PRIMARY KEY,
          title TEXT NOT NULL,
          subtitle TEXT NOT NULL DEFAULT '',
          start_at TEXT,
          end_at TEXT,
          archived_at TEXT NOT NULL,
          community_progress REAL NOT NULL DEFAULT 0,
          participant_count INTEGER NOT NULL DEFAULT 0,
          snapshot_json TEXT NOT NULL DEFAULT '{}'
        ) STRICT;
        CREATE TABLE IF NOT EXISTS season_archive_players (
          season_id TEXT NOT NULL,
          user_id INTEGER NOT NULL,
          player_name TEXT NOT NULL,
          rank INTEGER NOT NULL,
          season_score INTEGER NOT NULL DEFAULT 0,
          captures INTEGER NOT NULL DEFAULT 0,
          unique_species INTEGER NOT NULL DEFAULT 0,
          alpha_captures INTEGER NOT NULL DEFAULT 0,
          bosses INTEGER NOT NULL DEFAULT 0,
          personal_progress REAL NOT NULL DEFAULT 0,
          PRIMARY KEY(season_id,user_id)
        ) STRICT;
        CREATE TABLE IF NOT EXISTS season_honors (
          season_id TEXT NOT NULL,
          user_id INTEGER NOT NULL,
          honor_key TEXT NOT NULL,
          title TEXT NOT NULL,
          tier TEXT NOT NULL DEFAULT 'gold',
          awarded_at TEXT NOT NULL,
          PRIMARY KEY(season_id,user_id,honor_key)
        ) STRICT;
        CREATE INDEX IF NOT EXISTS ix_season_honors_user ON season_honors(user_id,awarded_at DESC);
      `);
    } catch (err) {
      console.warn('[HallOfFame] DB init:', err.message);
    }
  }
  return database;
}
function nowIso() { return new Date().toISOString(); }
function num(v) { return Number(v || 0); }
function safeGet(sql, ...params) { try { return db().prepare(sql).get(...params) || null; } catch { return null; } }
function safeAll(sql, ...params) { try { return db().prepare(sql).all(...params); } catch { return []; } }
function sendJson(res, status, body) { const data = Buffer.from(JSON.stringify(body)); res.writeHead(status, { 'Content-Type':'application/json; charset=utf-8', 'Content-Length':data.length, 'Cache-Control':'no-store' }); res.end(data); }
function sendHtml(res, html) { const data = Buffer.from(html); res.writeHead(200, { 'Content-Type':'text/html; charset=utf-8', 'Content-Length':data.length, 'Cache-Control':'no-cache' }); res.end(data); }
function parseCookies(req) { const out = {}; String(req.headers.cookie || '').split(';').forEach(part => { const i = part.indexOf('='); if (i > 0) out[part.slice(0,i).trim()] = decodeURIComponent(part.slice(i+1).trim()); }); return out; }
function hashToken(token) { return crypto.createHash('sha256').update(String(token || '')).digest('hex'); }
function sessionUserId(req) { const token = parseCookies(req)[SESSION_COOKIE]; if (!token) return null; const row = safeGet('SELECT user_id AS userId,expires_at AS expiresAt FROM user_sessions WHERE token_hash=?', hashToken(token)); if (!row || Date.parse(row.expiresAt) <= Date.now()) return null; return Number(row.userId) || null; }
async function requireAdmin(req, res) {
  try {
    let current = {};
    try { current = JSON.parse(fs.readFileSync(path.join(DATA_DIR, 'config.json'), 'utf8')); } catch {}
    const port = current.panel?.port || defaults.panel?.port || 8787;
    const response = await fetch(`http://127.0.0.1:${port}/api/admin/session`, { headers:{ Cookie:String(req.headers.cookie || ''), Accept:'application/json' }, signal:AbortSignal.timeout(4000) });
    const body = await response.json().catch(() => ({}));
    if (!response.ok || !body.authenticated) { sendJson(res, 401, { error:'Nicht angemeldet.' }); return false; }
    return true;
  } catch { sendJson(res, 401, { error:'Admin-Sitzung konnte nicht geprüft werden.' }); return false; }
}
function seasonConfig() { try { return JSON.parse(fs.readFileSync(SEASON_FILE, 'utf8')); } catch { return null; } }
function isoOrNull(v) { if (!v) return null; const t = Date.parse(v); return Number.isFinite(t) ? new Date(t).toISOString() : null; }
function range(column, season) {
  const parts = [], params = [];
  const start = isoOrNull(season?.startAt), end = isoOrNull(season?.endAt);
  if (start) { parts.push(`${column}>=?`); params.push(start); }
  if (end) { parts.push(`${column}<=?`); params.push(end); }
  return { sql: parts.length ? ` AND ${parts.join(' AND ')}` : '', params };
}
function metric(type, userId, season) {
  const user = Number(userId) > 0 ? Number(userId) : null;
  if (['captures','alphaCaptures','uniqueSpecies'].includes(type)) {
    const r = range('captured_at', season);
    const expr = type === 'captures' ? 'COUNT(*)' : type === 'alphaCaptures' ? 'SUM(CASE WHEN is_alpha=1 THEN 1 ELSE 0 END)' : 'COUNT(DISTINCT species_key)';
    const where = `WHERE 1=1${user ? ' AND user_id=?' : ''}${r.sql}`;
    const params = [...(user ? [user] : []), ...r.params];
    return num(safeGet(`SELECT COALESCE(${expr},0) AS n FROM pal_captures ${where}`, ...params)?.n);
  }
  if (type === 'bosses') {
    const r = range('completed_at', season);
    const where = `WHERE 1=1${user ? ' AND user_id=?' : ''}${r.sql}`;
    const params = [...(user ? [user] : []), ...r.params];
    return num(safeGet(`SELECT COUNT(*) AS n FROM boss_completions ${where}`, ...params)?.n);
  }
  return 0;
}
function goalRows(goals, userId, season) {
  const defs = [['captures','Fänge'],['uniqueSpecies','Pal-Arten'],['alphaCaptures','Alpha-Fänge'],['bosses','Bosse']];
  return defs.map(([key,label]) => { const current = metric(key,userId,season), target = Math.max(1,num(goals?.[key])); return { key,label,current,target,progress:Math.max(0,Math.min(100,current/target*100)),complete:current>=target }; });
}
function aggregateProgress(rows) { return rows.length ? Math.min(...rows.map(r => r.progress)) : 0; }
function participantIds(season) {
  const ids = new Set();
  const cap = range('captured_at', season), boss = range('completed_at', season);
  safeAll(`SELECT DISTINCT user_id AS id FROM pal_captures WHERE 1=1${cap.sql}`, ...cap.params).forEach(r => ids.add(Number(r.id)));
  safeAll(`SELECT DISTINCT user_id AS id FROM boss_completions WHERE 1=1${boss.sql}`, ...boss.params).forEach(r => ids.add(Number(r.id)));
  return [...ids].filter(id => id > 0);
}
function publicName(userId) {
  const row = safeGet(`SELECT COALESCE(l.palworld_name,'Entdecker #'||u.id) AS name,u.steam_id AS steamId FROM users u LEFT JOIN player_links l ON l.user_id=u.id WHERE u.id=?`, Number(userId));
  if (!row) return { name:`Entdecker #${userId}`, avatarUrl:null };
  return { name:row.name, avatarUrl:/^\d{17}$/.test(String(row.steamId || '')) ? `/api/steam/avatar/user/${userId}` : null };
}
function seasonPlayers(season) {
  const personalGoals = season.personalGoals || {};
  return participantIds(season).map(userId => {
    const info = publicName(userId);
    const captures = metric('captures',userId,season), uniqueSpecies = metric('uniqueSpecies',userId,season), alphaCaptures = metric('alphaCaptures',userId,season), bosses = metric('bosses',userId,season);
    const personalRows = goalRows(personalGoals,userId,season);
    const personalProgress = aggregateProgress(personalRows);
    return { userId, ...info, captures, uniqueSpecies, alphaCaptures, bosses, personalProgress, seasonScore:captures + uniqueSpecies*5 + alphaCaptures*10 + bosses*25 };
  }).sort((a,b) => b.seasonScore-a.seasonScore || b.uniqueSpecies-a.uniqueSpecies || b.alphaCaptures-a.alphaCaptures || a.userId-b.userId)
    .map((row,index) => ({ ...row, rank:index+1 }));
}
function honorPush(map, userId, key, title, tier='gold') {
  if (!userId) return;
  const id = Number(userId);
  if (!map.has(id)) map.set(id, []);
  if (!map.get(id).some(x => x.key === key)) map.get(id).push({ key,title,tier });
}
function buildHonors(players, communityProgress) {
  const honors = new Map();
  if (players[0]) honorPush(honors,players[0].userId,'season-champion','Saison-Champion','legendary');
  players.slice(1,3).forEach(p => honorPush(honors,p.userId,'season-podium','Saison-Podium','gold'));
  players.slice(3,10).forEach(p => honorPush(honors,p.userId,'season-top10','Saison Top 10','silver'));
  players.filter(p => p.personalProgress >= 100).forEach(p => honorPush(honors,p.userId,'season-completionist','Saison-Vollender','gold'));
  if (communityProgress >= 100) players.forEach(p => honorPush(honors,p.userId,'community-legend','Gemeinschaftslegende','legendary'));
  const specialists = [
    ['captures','capture-master','Fangmeister'],
    ['uniqueSpecies','paldex-master','Paldex-Meister'],
    ['alphaCaptures','alpha-master','Alpha-König'],
    ['bosses','boss-master','Bossjäger']
  ];
  specialists.forEach(([metricKey,key,title]) => {
    const max = Math.max(0,...players.map(p => num(p[metricKey])));
    if (!max) return;
    players.filter(p => num(p[metricKey]) === max).forEach(p => honorPush(honors,p.userId,key,title,'gold'));
  });
  return honors;
}
function archiveCurrentSeason() {
  const season = seasonConfig();
  if (!season?.id) throw Object.assign(new Error('Keine gültige Saison-Konfiguration gefunden.'), { status:400 });
  const seasonId = String(season.id).trim();
  if (safeGet('SELECT season_id FROM season_archives WHERE season_id=?', seasonId)) throw Object.assign(new Error('Diese Saison wurde bereits archiviert.'), { status:409 });
  const communityGoals = goalRows(season.communityGoals || {}, null, season);
  const communityProgress = aggregateProgress(communityGoals);
  const players = seasonPlayers(season);
  const honors = buildHonors(players, communityProgress);
  const stamp = nowIso();
  const snapshot = {
    season:{ id:seasonId,title:String(season.title || seasonId),subtitle:String(season.subtitle || ''),startAt:isoOrNull(season.startAt),endAt:isoOrNull(season.endAt),archivedAt:stamp },
    community:{ progress:communityProgress, goals:communityGoals, participantCount:players.length },
    contributors:players.slice(0,10).map(p => ({ userId:p.userId,name:p.name,avatarUrl:p.avatarUrl,rank:p.rank,seasonScore:p.seasonScore,captures:p.captures,uniqueSpecies:p.uniqueSpecies,alphaCaptures:p.alphaCaptures,bosses:p.bosses,personalProgress:p.personalProgress }))
  };
  db().exec('BEGIN IMMEDIATE');
  try {
    db().prepare(`INSERT INTO season_archives(season_id,title,subtitle,start_at,end_at,archived_at,community_progress,participant_count,snapshot_json) VALUES(?,?,?,?,?,?,?,?,?)`)
      .run(seasonId,snapshot.season.title,snapshot.season.subtitle,snapshot.season.startAt,snapshot.season.endAt,stamp,communityProgress,players.length,JSON.stringify(snapshot));
    const playerStmt = db().prepare(`INSERT INTO season_archive_players(season_id,user_id,player_name,rank,season_score,captures,unique_species,alpha_captures,bosses,personal_progress) VALUES(?,?,?,?,?,?,?,?,?,?)`);
    for (const p of players) playerStmt.run(seasonId,p.userId,p.name,p.rank,p.seasonScore,p.captures,p.uniqueSpecies,p.alphaCaptures,p.bosses,p.personalProgress);
    const honorStmt = db().prepare(`INSERT INTO season_honors(season_id,user_id,honor_key,title,tier,awarded_at) VALUES(?,?,?,?,?,?)`);
    for (const [userId,list] of honors.entries()) for (const h of list) honorStmt.run(seasonId,userId,h.key,h.title,h.tier,stamp);
    db().exec('COMMIT');
  } catch (err) { try { db().exec('ROLLBACK'); } catch {} throw err; }
  return { ok:true, archive:snapshot, honorsAwarded:[...honors.values()].reduce((n,list)=>n+list.length,0) };
}
function archivesPublic() {
  return safeAll(`SELECT season_id AS seasonId,title,subtitle,start_at AS startAt,end_at AS endAt,archived_at AS archivedAt,community_progress AS communityProgress,participant_count AS participantCount,snapshot_json AS snapshotJson FROM season_archives ORDER BY archived_at DESC`).map(row => {
    let snapshot = {};
    try { snapshot = JSON.parse(row.snapshotJson || '{}'); } catch {}
    return { seasonId:row.seasonId,title:row.title,subtitle:row.subtitle,startAt:row.startAt,endAt:row.endAt,archivedAt:row.archivedAt,communityProgress:num(row.communityProgress),participantCount:num(row.participantCount),community:snapshot.community || null,contributors:Array.isArray(snapshot.contributors)?snapshot.contributors:[] };
  });
}
function honorLeaders() {
  return safeAll(`SELECT h.user_id AS userId,COALESCE(l.palworld_name,'Entdecker #'||h.user_id) AS name,COUNT(*) AS honors FROM season_honors h LEFT JOIN player_links l ON l.user_id=h.user_id GROUP BY h.user_id ORDER BY honors DESC,name ASC LIMIT 10`).map(r => ({ userId:Number(r.userId),name:r.name,honors:num(r.honors) }));
}
function hallPayload() {
  const archives = archivesPublic();
  return { archives, totalSeasons:archives.length, champions:safeAll(`SELECT h.season_id AS seasonId,h.user_id AS userId,h.title,COALESCE(l.palworld_name,'Entdecker #'||h.user_id) AS name FROM season_honors h LEFT JOIN player_links l ON l.user_id=h.user_id WHERE h.honor_key='season-champion' ORDER BY h.awarded_at DESC`).map(r=>({...r,userId:Number(r.userId)})), honorLeaders:honorLeaders() };
}
function seasonHistoryFor(userId) {
  const id = Number(userId);
  if (!Number.isInteger(id) || id <= 0) return [];
  const rows = safeAll(`SELECT p.season_id AS seasonId,p.player_name AS playerName,p.rank,p.season_score AS seasonScore,p.captures,p.unique_species AS uniqueSpecies,p.alpha_captures AS alphaCaptures,p.bosses,p.personal_progress AS personalProgress,a.title,a.subtitle,a.start_at AS startAt,a.end_at AS endAt,a.archived_at AS archivedAt FROM season_archive_players p JOIN season_archives a ON a.season_id=p.season_id WHERE p.user_id=? ORDER BY a.archived_at DESC`, id);
  return rows.map(row => ({ ...row,rank:num(row.rank),seasonScore:num(row.seasonScore),captures:num(row.captures),uniqueSpecies:num(row.uniqueSpecies),alphaCaptures:num(row.alphaCaptures),bosses:num(row.bosses),personalProgress:num(row.personalProgress),honors:safeAll('SELECT honor_key AS key,title,tier FROM season_honors WHERE season_id=? AND user_id=? ORDER BY title ASC',row.seasonId,id) }));
}
function hallPage() {
  return `<!doctype html><html lang="de"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="theme-color" content="#061724"><title>PalPanel // Hall of Fame</title><link rel="preload" as="image" href="/palpanel-banner.png?v=0910"><link rel="stylesheet" href="/styles.css"><link rel="stylesheet" href="/progression.css"><link rel="stylesheet" href="/palworld-theme.css"><link rel="stylesheet" href="/wow.css?v=0910"><link rel="stylesheet" href="/hall-of-fame.css?v=${ASSET_VERSION}"></head><body><div class="ambient ambient-a"></div><div class="ambient ambient-b"></div><header class="topnav"><a class="brand" href="/"><span class="brand-orb">P</span><div><strong>PalPanel</strong><small>HALL OF FAME</small></div></a><nav class="mainnav"><a href="/">Start</a><a href="/event">Event</a><a class="active" href="/hall-of-fame">Hall of Fame</a><a href="/#ranking">Rangliste</a><a href="/profile">Profil</a><a href="/shop">Punkteshop</a></nav><div class="nav-actions"><button id="accountTrigger" class="account-trigger"><i></i><span><small>SPIELERKONTO</small><b id="accountTriggerText">Mit Steam anmelden</b></span><em id="accountPoints"></em></button></div></header><div id="accountShade" class="account-shade"></div><aside id="accountDrawer" class="account-drawer" aria-hidden="true"><div class="drawer-head"><div><small>PALPANEL-IDENTITÄT</small><strong>Dein Abenteuer</strong></div><button id="accountClose">×</button></div><div class="identity-mark"><i id="accountInitial">?</i><div><small>VERBUNDENER SPIELER</small><h2 id="accountName">—</h2><code id="accountSteamId">—</code></div></div><div class="identity-status"><div><small>CHARAKTER</small><strong id="accountLinkState">PRÜFE</strong></div><div><small>PUNKTE</small><strong id="drawerPoints">0</strong></div><div><small>STUFE</small><strong id="accountLevel">—</strong></div></div><div id="accountLinkNotice" class="link-notice"><b>Charakter noch nicht gefunden</b><p>Betritt den Palworld-Server mit diesem Steam-Konto und prüfe danach erneut.</p><button id="relinkBtn">Erneut suchen</button></div><nav class="identity-nav"><a href="/profile">Mein Profil <b>→</b></a><a href="/shop">Punkteshop <b>→</b></a><a id="steamProfileLink" target="_blank" rel="noopener">Steam-Profil <b>↗</b></a></nav><button id="userLogout" class="drawer-logout">Steam-Sitzung trennen</button></aside><main class="hof-shell"><section class="hof-hero"><div><span>PALPAGOS ARCHIV</span><h1>Hall of Fame</h1><p>Vergangene Saisons verschwinden nicht. Gewinner, Rekorde und die Spieler, die eine Saison geprägt haben, bleiben hier dauerhaft verewigt.</p></div><div class="hof-hero-stats"><article><strong id="hofSeasonCount">0</strong><span>SAISONS</span></article><article><strong id="hofChampionCount">0</strong><span>CHAMPIONS</span></article><article><strong id="hofHonorLeader">—</strong><span>MEISTE TITEL</span></article></div></section><section id="hofLatest" class="hof-latest"></section><section class="hof-section"><div class="hof-heading"><div><span>SAISONARCHIV</span><h2>Geschichte, die stehen bleibt.</h2></div><p>Jeder Snapshot zeigt den Stand exakt im Moment der Archivierung.</p></div><div id="hofArchives" class="hof-archives"></div></section></main><footer><div class="brand footer-brand"><span class="brand-orb">P</span><div><strong>PalPanel</strong><small>HALL OF FAME</small></div></div><span>Wer Geschichte schreibt, bleibt sichtbar.</span><i>© 2026</i></footer><script src="/account.js?v=0900"></script><script src="/hall-of-fame.js?v=${ASSET_VERSION}"></script></body></html>`;
}
function enhanceHtml(html, pathname) {
  let out = String(html || '');
  if (!out.includes('href="/hall-of-fame"')) {
    if (out.includes('<a href="/event">Event</a>')) out = out.replace('<a href="/event">Event</a>', '<a href="/event">Event</a><a href="/hall-of-fame">Hall of Fame</a>');
    else if (out.includes('<a href="/#ranking">Rangliste</a>')) out = out.replace('<a href="/#ranking">Rangliste</a>', '<a href="/hall-of-fame">Hall of Fame</a><a href="/#ranking">Rangliste</a>');
  }
  if ((pathname === '/profile' || pathname === '/profile/' || /^\/player\/\d+\/?$/.test(pathname)) && !out.includes('/profile-honors.js')) {
    out = out.replace('</head>', `<link rel="stylesheet" href="/hall-of-fame.css?v=${ASSET_VERSION}"><script src="/profile-honors.js?v=${ASSET_VERSION}"></script></head>`);
  }
  return out;
}
function captureHtml(req,res,listener,pathname) {
  const ow=res.writeHead.bind(res), oe=res.end.bind(res); let status=null,msg=null,headers=null;
  res.writeHead=function(sc,sm,h){status=sc;if(typeof sm==='string'){msg=sm;headers={...(h||{})};}else headers={...(sm||{})};return res;};
  res.end=function(chunk,enc,cb){if(status!=null){const hs={...(headers||{})},ct=String(hs['Content-Type']||hs['content-type']||'');if(status===200&&ct.toLowerCase().includes('text/html')&&chunk!=null){const data=Buffer.from(enhanceHtml(Buffer.isBuffer(chunk)?chunk.toString('utf8'):String(chunk),pathname));delete hs['content-length'];hs['Content-Length']=data.length;if(msg)ow(status,msg,hs);else ow(status,hs);return oe(data,undefined,cb);}if(msg)ow(status,msg,hs);else ow(status,hs);}return oe(chunk,enc,cb);};
  return listener(req,res);
}

const previousCreateServer = http.createServer.bind(http);
http.createServer = function hallOfFameCreateServer(options, requestListener) {
  const hasOptions = typeof options !== 'function';
  const listener = hasOptions ? requestListener : options;
  const wrapped = async (req,res) => {
    let url; try { url = new URL(req.url,'http://localhost'); } catch { return listener(req,res); }
    try {
      if ((req.method === 'GET' || req.method === 'HEAD') && url.pathname === '/hall-of-fame') return sendHtml(res,hallPage());
      if (req.method === 'GET' && url.pathname === '/api/public/hall-of-fame') return sendJson(res,200,hallPayload());
      const publicHistory = url.pathname.match(/^\/api\/public\/player\/(\d+)\/season-history$/);
      if (req.method === 'GET' && publicHistory) return sendJson(res,200,{ seasons:seasonHistoryFor(publicHistory[1]) });
      if (req.method === 'GET' && url.pathname === '/api/user/season-history') { const uid=sessionUserId(req); if(!uid) return sendJson(res,401,{error:'Nicht angemeldet.'}); return sendJson(res,200,{seasons:seasonHistoryFor(uid)}); }
      if (url.pathname === '/api/admin/season/archive') {
        if (!(await requireAdmin(req,res))) return;
        if (req.method === 'POST') { try { return sendJson(res,200,archiveCurrentSeason()); } catch (err) { return sendJson(res,err.status||500,{error:err.message}); } }
      }
      if (url.pathname === '/api/admin/season/history') {
        if (!(await requireAdmin(req,res))) return;
        if (req.method === 'GET') return sendJson(res,200,{ archives:archivesPublic() });
      }
    } catch (err) {
      console.warn('[HallOfFame]',err.message);
      if (!res.headersSent) return sendJson(res,500,{error:'Hall of Fame konnte nicht verarbeitet werden.'});
    }
    if ((req.method==='GET'||req.method==='HEAD') && (['/','/profile','/profile/','/shop','/shop/','/event'].includes(url.pathname) || /^\/player\/\d+\/?$/.test(url.pathname))) return captureHtml(req,res,listener,url.pathname);
    return listener(req,res);
  };
  return hasOptions ? previousCreateServer(options,wrapped) : previousCreateServer(wrapped);
};
console.log('PalPanel v0.9.4 Saison-Historie + Hall of Fame geladen.');
require('./server-v093.js');
