const fs=require('fs');
const path=require('path');
const http=require('http');
const crypto=require('crypto');
const {DatabaseSync}=require('node:sqlite');

const APP_DIR=path.resolve(__dirname,'..');
const defaults=JSON.parse(fs.readFileSync(path.join(APP_DIR,'config','default.json'),'utf8'));
const DB_FILE=path.join(defaults.paths.data,'palpanel.db');
const SESSION_COOKIE='palpanel_user';
const ASSET_VERSION='0960';
let database=null;

function db(){if(!database){database=new DatabaseSync(DB_FILE,{timeout:5000});try{database.exec('PRAGMA journal_mode = WAL;');database.exec(`
CREATE TABLE IF NOT EXISTS user_notifications(
 id INTEGER PRIMARY KEY AUTOINCREMENT,
 user_id INTEGER NOT NULL,
 dedupe_key TEXT NOT NULL,
 type TEXT NOT NULL,
 title TEXT NOT NULL,
 message TEXT NOT NULL,
 href TEXT,
 icon TEXT NOT NULL DEFAULT '✦',
 created_at TEXT NOT NULL,
 read_at TEXT,
 UNIQUE(user_id,dedupe_key)
) STRICT;
CREATE INDEX IF NOT EXISTS ix_notifications_user_created ON user_notifications(user_id,created_at DESC);
CREATE INDEX IF NOT EXISTS ix_notifications_user_unread ON user_notifications(user_id,read_at);
`);}catch(e){console.warn('[Notifications] DB init:',e.message);}}return database;}
const num=v=>Number(v||0);
function safeGet(sql,...p){try{return db().prepare(sql).get(...p)||null;}catch{return null;}}
function safeAll(sql,...p){try{return db().prepare(sql).all(...p);}catch{return [];}}
function sendJson(res,status,body){const data=Buffer.from(JSON.stringify(body));res.writeHead(status,{'Content-Type':'application/json; charset=utf-8','Content-Length':data.length,'Cache-Control':'no-store'});res.end(data);}
function readBody(req){return new Promise((resolve,reject)=>{let raw='';req.on('data',c=>{raw+=c;if(raw.length>65536)reject(new Error('Request too large'));});req.on('end',()=>{try{resolve(raw?JSON.parse(raw):{});}catch(e){reject(e);}});req.on('error',reject);});}
function cookies(req){const out={};String(req.headers.cookie||'').split(';').forEach(x=>{const i=x.indexOf('=');if(i>0)out[x.slice(0,i).trim()]=decodeURIComponent(x.slice(i+1).trim());});return out;}
const hashToken=t=>crypto.createHash('sha256').update(String(t||'')).digest('hex');
function sessionUserId(req){const token=cookies(req)[SESSION_COOKIE];if(!token)return null;const row=safeGet('SELECT user_id AS userId,expires_at AS expiresAt FROM user_sessions WHERE token_hash=?',hashToken(token));if(!row||Date.parse(row.expiresAt)<=Date.now())return null;return Number(row.userId)||null;}
function displayName(userId){const r=safeGet(`SELECT COALESCE(l.palworld_name,'Entdecker #'||u.id) AS name FROM users u LEFT JOIN player_links l ON l.user_id=u.id WHERE u.id=?`,Number(userId));return r?.name||`Entdecker #${userId}`;}
function cleanName(v){return String(v||'').replace(/^TowerType:/i,'Turm ').replace(/^Tower:/i,'').replace(/^BOSS_/i,'').replace(/^Boss_/i,'').replace(/_/g,' ').replace(/([a-zäöüß])([A-ZÄÖÜ])/g,'$1 $2').replace(/\s+/g,' ').trim()||'Unbekannt';}
function validTime(v){const t=Date.parse(v||'');return Number.isFinite(t)?new Date(t).toISOString():new Date().toISOString();}
function insertNotification(userId,key,type,title,message,href,icon,createdAt){try{db().prepare(`INSERT OR IGNORE INTO user_notifications(user_id,dedupe_key,type,title,message,href,icon,created_at) VALUES(?,?,?,?,?,?,?,?)`).run(Number(userId),String(key),String(type),String(title),String(message),href||null,icon||'✦',validTime(createdAt));}catch(e){console.warn('[Notifications] insert:',e.message);}}

const ACHIEVEMENTS={
 'first-catch':['Erster Fang','Dein erster Pal wurde erfasst.','◎'],
 'collector-10':['Pal-Sammler','Du hast 10 unterschiedliche Pal-Arten entdeckt.','◇'],
 'paldex-25':['Paldex-Forscher','25 unterschiedliche Pal-Arten sind jetzt in deiner Sammlung.','◇'],
 'paldex-50':['Paldex-Experte','50 unterschiedliche Pal-Arten – starke Sammlung.','✦'],
 'paldex-100':['Paldex-Legende','100 unterschiedliche Pal-Arten erreicht.','✺'],
 'alpha-first':['Alpha-Spürnase','Dein erster Alpha-Pal wurde erfasst.','◆'],
 'alpha-10':['Alpha-Jäger','Du hast 10 Alpha-Pals gefangen.','◆'],
 'boss-first':['Bossbezwinger','Dein erster Boss-Abschluss wurde erfasst.','◈'],
 'boss-5':['Bossbrecher','Fünf Boss-Abschlüsse erreicht.','◈'],
 'veteran-10h':['Veteran','10 Stunden Spielzeit erreicht.','⌁'],
 'veteran-30h':['Weltenwanderer','30 Stunden Spielzeit erreicht.','⌁'],
 'level-50':['Stufe 50','Charakterstufe 50 erreicht.','↟'],
 'top-10':['Top 10','Du hast die Top 10 der Event-Rangliste erreicht.','★'],
 'top-3':['Podium','Du hast einen Podiumsplatz in der Event-Rangliste erreicht.','♛']
};
const MISSION_LABELS={captures:'Fangmission',uniqueSpecies:'Paldex-Mission',alphaCaptures:'Alpha-Mission',bosses:'Bossmission',expeditionScore:'Expeditionsmission'};

function syncNotifications(userId){
  const uid=Number(userId);
  for(const r of safeAll('SELECT achievement_id AS id,unlocked_at AS at FROM achievement_unlocks WHERE user_id=?',uid)){
    const meta=ACHIEVEMENTS[r.id]||['Erfolg freigeschaltet',`Achievement ${r.id} wurde freigeschaltet.`,'✦'];
    insertNotification(uid,`achievement:${r.id}`,'achievement',meta[0],meta[1],'/profile',meta[2],r.at);
  }
  for(const r of safeAll('SELECT week_key AS weekKey,mission_id AS missionId,points,claimed_at AS at FROM weekly_mission_claims WHERE user_id=?',uid)){
    const label=MISSION_LABELS[r.missionId]||'Wochenmission';
    insertNotification(uid,`weekly-claim:${r.weekKey}:${r.missionId}`,'mission',`${label} abgeschlossen`,`Belohnung abgeholt: +${num(r.points).toLocaleString('de-DE')} Shop-Punkte.`,'/missions','☷',r.at);
  }
  for(const r of safeAll('SELECT week_key AS weekKey,title,bonus_points AS points,awarded_at AS at FROM weekly_mission_titles WHERE user_id=?',uid)){
    insertNotification(uid,`weekly-title:${r.weekKey}`,'mission',r.title,`Alle Wochenmissionen erledigt. Abschlussbonus: +${num(r.points).toLocaleString('de-DE')} Punkte.`,'/missions','★',r.at);
  }
  for(const r of safeAll('SELECT season_id AS seasonId,honor_key AS honorKey,title,tier,awarded_at AS at FROM season_honors WHERE user_id=?',uid)){
    insertNotification(uid,`season-honor:${r.seasonId}:${r.honorKey}`,'season',r.title,`Dieser Saison-Titel wurde dauerhaft deinem Profil hinzugefügt.`,'/profile','♛',r.at);
  }
  for(const r of safeAll('SELECT season_id AS seasonId,reward_key AS rewardKey,claimed_at AS at FROM season_claims WHERE user_id=?',uid)){
    insertNotification(uid,`season-claim:${r.seasonId}:${r.rewardKey}`,'season','Saisonbelohnung abgeholt',`Belohnungsstufe „${String(r.rewardKey).replace(/-/g,' ')}“ wurde deinem Konto gutgeschrieben.`,'/event','✦',r.at);
  }

  const hunters=Math.max(0,num(safeGet('SELECT COUNT(DISTINCT user_id) AS n FROM pal_captures')?.n));
  if(hunters>=3){
    for(const r of safeAll('SELECT id,species_key AS speciesKey,is_alpha AS alpha,captured_at AS at FROM pal_captures WHERE user_id=? ORDER BY id DESC LIMIT 60',uid)){
      const holders=Math.max(1,num(safeGet('SELECT COUNT(DISTINCT user_id) AS n FROM pal_captures WHERE species_key=?',r.speciesKey)?.n));
      const ratio=holders/hunters;
      if(holders!==1&&ratio>.25)continue;
      const rarity=holders===1?'MYTHISCH':ratio<=.1?'LEGENDÄR':'SELTEN';
      insertNotification(uid,`rare-species:${r.speciesKey}`,'rare',`${rarity}: ${cleanName(r.speciesKey)}`,`${r.alpha?'Alpha-Pal · ':''}Nur ${holders} von ${hunters} Community-Jägern haben diese Art bisher gefangen.`,'/profile','◆',r.at);
    }
  }
}

function notificationPayload(userId){syncNotifications(userId);const rows=safeAll(`SELECT id,type,title,message,href,icon,created_at AS createdAt,read_at AS readAt FROM user_notifications WHERE user_id=? ORDER BY datetime(created_at) DESC,id DESC LIMIT 40`,Number(userId)).map(r=>({...r,id:Number(r.id),read:!!r.readAt}));return{notifications:rows,unread:rows.filter(r=>!r.read).length,total:rows.length};}
function markRead(userId,body){const uid=Number(userId),stamp=new Date().toISOString();if(body?.all){db().prepare('UPDATE user_notifications SET read_at=COALESCE(read_at,?) WHERE user_id=?').run(stamp,uid);return;}const id=Number(body?.id);if(Number.isInteger(id)&&id>0)db().prepare('UPDATE user_notifications SET read_at=COALESCE(read_at,?) WHERE user_id=? AND id=?').run(stamp,uid,id);}

function feedItem(type,title,message,at,href,icon,userId){return{type,title,message,at:validTime(at),href:href||null,icon:icon||'✦',userId:userId?Number(userId):null};}
function communityFeed(){
  const items=[];
  for(const r of safeAll(`SELECT p.user_id AS userId,p.species_key AS speciesKey,p.captured_at AS at FROM pal_captures p WHERE p.is_alpha=1 ORDER BY p.id DESC LIMIT 12`))items.push(feedItem('alpha',`${displayName(r.userId)} fing einen Alpha`,cleanName(r.speciesKey),r.at,`/player/${r.userId}`,'◆',r.userId));
  for(const r of safeAll(`SELECT p.user_id AS userId,p.species_key AS speciesKey,p.captured_at AS at FROM pal_captures p WHERE p.id=(SELECT MIN(x.id) FROM pal_captures x WHERE x.user_id=p.user_id AND x.species_key=p.species_key) ORDER BY p.id DESC LIMIT 12`))items.push(feedItem('discovery',`${displayName(r.userId)} entdeckte eine neue Art`,cleanName(r.speciesKey),r.at,`/player/${r.userId}`,'◇',r.userId));
  for(const r of safeAll('SELECT user_id AS userId,boss_key AS bossKey,completed_at AS at FROM boss_completions ORDER BY completed_at DESC LIMIT 12'))items.push(feedItem('boss',`${displayName(r.userId)} besiegte einen Boss`,cleanName(r.bossKey),r.at,`/player/${r.userId}`,'◈',r.userId));
  for(const r of safeAll('SELECT user_id AS userId,title,awarded_at AS at FROM weekly_mission_titles ORDER BY awarded_at DESC LIMIT 8'))items.push(feedItem('weekly',`${displayName(r.userId)} wurde ${r.title}`,'Alle fünf Wochenmissionen wurden abgeschlossen.',r.at,`/player/${r.userId}`,'★',r.userId));
  for(const r of safeAll(`SELECT h.user_id AS userId,h.title,a.title AS seasonTitle,h.awarded_at AS at FROM season_honors h LEFT JOIN season_archives a ON a.season_id=h.season_id WHERE h.honor_key IN ('season-champion','community-legend') ORDER BY h.awarded_at DESC LIMIT 8`))items.push(feedItem('season',`${displayName(r.userId)} · ${r.title}`,r.seasonTitle||'Saison-Auszeichnung',r.at,`/player/${r.userId}`,'♛',r.userId));
  items.sort((a,b)=>Date.parse(b.at)-Date.parse(a.at));
  const seen=new Set();
  return items.filter(x=>{const k=`${x.type}:${x.userId}:${x.title}:${x.at}`;if(seen.has(k))return false;seen.add(k);return true;}).slice(0,24);
}

function enhanceHtml(html){let out=String(html||'');if(!out.includes('/notifications.css?v=0960'))out=out.replace('</head>',`<link rel="stylesheet" href="/notifications.css?v=${ASSET_VERSION}"><script src="/notifications.js?v=${ASSET_VERSION}"></script></head>`);return out;}
function captureHtml(req,res,listener){const ow=res.writeHead.bind(res),oe=res.end.bind(res);let status=null,msg=null,headers=null;res.writeHead=function(sc,sm,h){status=sc;if(typeof sm==='string'){msg=sm;headers={...(h||{})};}else headers={...(sm||{})};return res;};res.end=function(chunk,enc,cb){if(status!=null){const hs={...(headers||{})},ct=String(hs['Content-Type']||hs['content-type']||'');if(status===200&&ct.toLowerCase().includes('text/html')&&chunk!=null){const data=Buffer.from(enhanceHtml(Buffer.isBuffer(chunk)?chunk.toString('utf8'):String(chunk)));delete hs['content-length'];hs['Content-Length']=data.length;if(msg)ow(status,msg,hs);else ow(status,hs);return oe(data,undefined,cb);}if(msg)ow(status,msg,hs);else ow(status,hs);}return oe(chunk,enc,cb);};return listener(req,res);}

const previousCreateServer=http.createServer.bind(http);
http.createServer=function notificationCreateServer(options,requestListener){const hasOptions=typeof options!=='function',listener=hasOptions?requestListener:options;const wrapped=async(req,res)=>{let url;try{url=new URL(req.url,'http://localhost');}catch{return listener(req,res);}try{
 if(req.method==='GET'&&url.pathname==='/api/public/activity-feed')return sendJson(res,200,{feed:communityFeed()});
 if(req.method==='GET'&&url.pathname==='/api/user/notifications'){const uid=sessionUserId(req);if(!uid)return sendJson(res,401,{error:'Nicht angemeldet.'});return sendJson(res,200,notificationPayload(uid));}
 if(req.method==='POST'&&url.pathname==='/api/user/notifications/read'){const uid=sessionUserId(req);if(!uid)return sendJson(res,401,{error:'Nicht angemeldet.'});const body=await readBody(req);markRead(uid,body);return sendJson(res,200,notificationPayload(uid));}
}catch(err){console.warn('[Notifications]',err.message);if(!res.headersSent)return sendJson(res,500,{error:'Benachrichtigungen konnten nicht verarbeitet werden.'});}
 if((req.method==='GET'||req.method==='HEAD')&&(['','/','/profile','/profile/','/shop','/shop/','/event','/missions','/hall-of-fame'].includes(url.pathname)||/^\/player\/\d+\/?$/.test(url.pathname)))return captureHtml(req,res,listener);
 return listener(req,res);};return hasOptions?previousCreateServer(options,wrapped):previousCreateServer(wrapped);};
console.log('PalPanel v0.9.6 Notification Center + Community Live-Feed geladen.');
require('./server-v095.js');
