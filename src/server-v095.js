const fs = require('fs');
const path = require('path');
const http = require('http');
const crypto = require('crypto');
const { DatabaseSync } = require('node:sqlite');

const APP_DIR = path.resolve(__dirname, '..');
const defaults = JSON.parse(fs.readFileSync(path.join(APP_DIR, 'config', 'default.json'), 'utf8'));
const DATA_DIR = defaults.paths.data;
const DB_FILE = path.join(DATA_DIR, 'palpanel.db');
const CONFIG_FILE = path.join(DATA_DIR, 'missions.json');
const SESSION_COOKIE = 'palpanel_user';
const ASSET_VERSION = '0950';

let database = null;
function db() {
  if (!database) {
    database = new DatabaseSync(DB_FILE, { timeout: 5000 });
    try {
      database.exec('PRAGMA journal_mode = WAL;');
      database.exec(`
        CREATE TABLE IF NOT EXISTS weekly_mission_claims (
          user_id INTEGER NOT NULL,
          week_key TEXT NOT NULL,
          mission_id TEXT NOT NULL,
          points INTEGER NOT NULL DEFAULT 0,
          claimed_at TEXT NOT NULL,
          PRIMARY KEY(user_id,week_key,mission_id)
        ) STRICT;
        CREATE TABLE IF NOT EXISTS weekly_mission_titles (
          user_id INTEGER NOT NULL,
          week_key TEXT NOT NULL,
          title TEXT NOT NULL,
          bonus_points INTEGER NOT NULL DEFAULT 0,
          awarded_at TEXT NOT NULL,
          PRIMARY KEY(user_id,week_key)
        ) STRICT;
        CREATE INDEX IF NOT EXISTS ix_weekly_titles_user ON weekly_mission_titles(user_id,awarded_at DESC);
      `);
    } catch (err) { console.warn('[WeeklyMissions] DB init:', err.message); }
  }
  return database;
}
function num(v){ return Number(v || 0); }
function clamp(v,min,max,fallback){ const n=Number(v); return Number.isFinite(n)?Math.max(min,Math.min(max,n)):fallback; }
function safeGet(sql,...params){ try{return db().prepare(sql).get(...params)||null;}catch{return null;} }
function safeAll(sql,...params){ try{return db().prepare(sql).all(...params);}catch{return [];} }
function sendJson(res,status,body){ const data=Buffer.from(JSON.stringify(body)); res.writeHead(status,{'Content-Type':'application/json; charset=utf-8','Content-Length':data.length,'Cache-Control':'no-store'}); res.end(data); }
function sendHtml(res,html){ const data=Buffer.from(html); res.writeHead(200,{'Content-Type':'text/html; charset=utf-8','Content-Length':data.length,'Cache-Control':'no-cache'}); res.end(data); }
function readBody(req){ return new Promise((resolve,reject)=>{let raw='';req.on('data',c=>{raw+=c;if(raw.length>128*1024)reject(new Error('Request too large'));});req.on('end',()=>{try{resolve(raw?JSON.parse(raw):{});}catch(e){reject(e);}});req.on('error',reject);}); }
function parseCookies(req){ const out={};String(req.headers.cookie||'').split(';').forEach(part=>{const i=part.indexOf('=');if(i>0)out[part.slice(0,i).trim()]=decodeURIComponent(part.slice(i+1).trim());});return out; }
function hashToken(token){ return crypto.createHash('sha256').update(String(token||'')).digest('hex'); }
function sessionUserId(req){ const token=parseCookies(req)[SESSION_COOKIE];if(!token)return null;const row=safeGet('SELECT user_id AS userId,expires_at AS expiresAt FROM user_sessions WHERE token_hash=?',hashToken(token));if(!row||Date.parse(row.expiresAt)<=Date.now())return null;return Number(row.userId)||null; }
async function requireAdmin(req,res){
  try{let current={};try{current=JSON.parse(fs.readFileSync(path.join(DATA_DIR,'config.json'),'utf8'));}catch{}const port=current.panel?.port||defaults.panel?.port||8787;const r=await fetch(`http://127.0.0.1:${port}/api/admin/session`,{headers:{Cookie:String(req.headers.cookie||''),Accept:'application/json'},signal:AbortSignal.timeout(4000)});const b=await r.json().catch(()=>({}));if(!r.ok||!b.authenticated){sendJson(res,401,{error:'Nicht angemeldet.'});return false;}return true;}catch{sendJson(res,401,{error:'Admin-Sitzung konnte nicht geprüft werden.'});return false;}
}

const DEFAULT_CONFIG={enabled:true,completionBonus:250,targetMultiplier:1,rewardMultiplier:1};
function config(){try{const x=JSON.parse(fs.readFileSync(CONFIG_FILE,'utf8'));return {enabled:x.enabled!==false,completionBonus:Math.round(clamp(x.completionBonus,0,100000,250)),targetMultiplier:clamp(x.targetMultiplier,.25,5,1),rewardMultiplier:clamp(x.rewardMultiplier,0,5,1)};}catch{fs.mkdirSync(DATA_DIR,{recursive:true});fs.writeFileSync(CONFIG_FILE,JSON.stringify(DEFAULT_CONFIG,null,2),'utf8');return {...DEFAULT_CONFIG};}}
function saveConfig(raw={}){const c={enabled:raw.enabled!==false,completionBonus:Math.round(clamp(raw.completionBonus,0,100000,250)),targetMultiplier:clamp(raw.targetMultiplier,.25,5,1),rewardMultiplier:clamp(raw.rewardMultiplier,0,5,1)};fs.mkdirSync(DATA_DIR,{recursive:true});fs.writeFileSync(CONFIG_FILE,JSON.stringify(c,null,2),'utf8');return c;}

function isoWeekParts(date=new Date()){
  const local=new Date(date.getFullYear(),date.getMonth(),date.getDate());
  const day=(local.getDay()+6)%7;
  const monday=new Date(local);monday.setDate(local.getDate()-day);monday.setHours(0,0,0,0);
  const end=new Date(monday);end.setDate(monday.getDate()+7);
  const thursday=new Date(monday);thursday.setDate(monday.getDate()+3);
  const firstThursday=new Date(thursday.getFullYear(),0,4);
  const firstDay=(firstThursday.getDay()+6)%7;firstThursday.setDate(firstThursday.getDate()-firstDay+3);firstThursday.setHours(0,0,0,0);
  const week=1+Math.round((thursday-firstThursday)/604800000);
  return {year:thursday.getFullYear(),week,key:`${thursday.getFullYear()}-W${String(week).padStart(2,'0')}`,label:`KW ${String(week).padStart(2,'0')}`,start:monday.toISOString(),end:end.toISOString()};
}

const VARIANTS={
  captures:[
    {title:'Fangrunde',description:'Fange diese Woche 12 Pals.',target:12,reward:60,icon:'◎'},
    {title:'Große Fangtour',description:'Fange diese Woche 20 Pals.',target:20,reward:85,icon:'◎'},
    {title:'Fangmarathon',description:'Fange diese Woche 30 Pals.',target:30,reward:120,icon:'◎'}
  ],
  uniqueSpecies:[
    {title:'Paldex-Streifzug',description:'Fange 6 unterschiedliche Pal-Arten.',target:6,reward:75,icon:'◇'},
    {title:'Artenforscher',description:'Fange 10 unterschiedliche Pal-Arten.',target:10,reward:110,icon:'◇'},
    {title:'Paldex-Woche',description:'Fange 15 unterschiedliche Pal-Arten.',target:15,reward:150,icon:'◇'}
  ],
  alphaCaptures:[
    {title:'Alpha-Kontakt',description:'Fange 1 Alpha-Pal.',target:1,reward:90,icon:'◆'},
    {title:'Alpha-Jagd',description:'Fange 3 Alpha-Pals.',target:3,reward:135,icon:'◆'},
    {title:'Alpha-Elite',description:'Fange 5 Alpha-Pals.',target:5,reward:190,icon:'◆'}
  ],
  bosses:[
    {title:'Bossprobe',description:'Besiege 1 erfassten Boss.',target:1,reward:110,icon:'◈'},
    {title:'Bossjäger',description:'Besiege 2 erfasste Bosse.',target:2,reward:160,icon:'◈'},
    {title:'Bossbrecher',description:'Besiege 3 erfasste Bosse.',target:3,reward:220,icon:'◈'}
  ],
  expeditionScore:[
    {title:'Expeditionsdrang',description:'Sammle 45 Expeditionspunkte durch Fänge, Arten, Alphas und Bosse.',target:45,reward:90,icon:'✦'},
    {title:'Große Expedition',description:'Sammle 80 Expeditionspunkte durch deine Wochenaktivitäten.',target:80,reward:140,icon:'✦'},
    {title:'Palpagos-Intensiv',description:'Sammle 130 Expeditionspunkte in dieser Woche.',target:130,reward:210,icon:'✦'}
  ]
};
function missionSet(week=isoWeekParts(),cfg=config()){
  const keys=Object.keys(VARIANTS);
  return keys.map((metric,index)=>{
    const variants=VARIANTS[metric];
    const base=variants[(week.week+index*2)%variants.length];
    const target=Math.max(1,Math.round(base.target*cfg.targetMultiplier));
    const reward=Math.max(0,Math.round(base.reward*cfg.rewardMultiplier));
    return {id:`${metric}-${target}`,metric,title:base.title,description:base.description.replace(/\d+/,String(target)),icon:base.icon,target,reward};
  });
}
function metricValue(metric,userId,week){
  const uid=Number(userId),start=week.start,end=week.end;
  const captures=()=>num(safeGet('SELECT COUNT(*) AS n FROM pal_captures WHERE user_id=? AND captured_at>=? AND captured_at<?',uid,start,end)?.n);
  const unique=()=>num(safeGet('SELECT COUNT(DISTINCT species_key) AS n FROM pal_captures WHERE user_id=? AND captured_at>=? AND captured_at<?',uid,start,end)?.n);
  const alphas=()=>num(safeGet('SELECT SUM(CASE WHEN is_alpha=1 THEN 1 ELSE 0 END) AS n FROM pal_captures WHERE user_id=? AND captured_at>=? AND captured_at<?',uid,start,end)?.n);
  const bosses=()=>num(safeGet('SELECT COUNT(*) AS n FROM boss_completions WHERE user_id=? AND completed_at>=? AND completed_at<?',uid,start,end)?.n);
  if(metric==='captures')return captures();if(metric==='uniqueSpecies')return unique();if(metric==='alphaCaptures')return alphas();if(metric==='bosses')return bosses();
  if(metric==='expeditionScore')return captures()+unique()*3+alphas()*6+bosses()*12;
  return 0;
}
function claimedSet(userId,weekKey){return new Set(safeAll('SELECT mission_id AS id FROM weekly_mission_claims WHERE user_id=? AND week_key=?',Number(userId),weekKey).map(r=>r.id));}
function publicName(userId){const row=safeGet(`SELECT COALESCE(l.palworld_name,'Entdecker #'||u.id) AS name,u.steam_id AS steamId FROM users u LEFT JOIN player_links l ON l.user_id=u.id WHERE u.id=?`,Number(userId));return row?{name:row.name,avatarUrl:/^\d{17}$/.test(String(row.steamId||''))?`/api/steam/avatar/user/${userId}`:null}:{name:`Entdecker #${userId}`,avatarUrl:null};}
function missionRows(userId,week,cfg){
  const claimed=userId?claimedSet(userId,week.key):new Set();
  return missionSet(week,cfg).map(m=>{const current=userId?metricValue(m.metric,userId,week):0;const complete=current>=m.target;return {...m,current,progress:userId?Math.max(0,Math.min(100,current/m.target*100)):0,complete,claimed:claimed.has(m.id),claimable:!!userId&&cfg.enabled&&complete&&!claimed.has(m.id)};});
}
function participantIds(week){const ids=new Set();safeAll('SELECT DISTINCT user_id AS id FROM pal_captures WHERE captured_at>=? AND captured_at<?',week.start,week.end).forEach(r=>ids.add(Number(r.id)));safeAll('SELECT DISTINCT user_id AS id FROM boss_completions WHERE completed_at>=? AND completed_at<?',week.start,week.end).forEach(r=>ids.add(Number(r.id)));return [...ids].filter(id=>id>0);}
function leaderboard(week,cfg){return participantIds(week).map(userId=>{const rows=missionRows(userId,week,cfg);const info=publicName(userId);const completed=rows.filter(r=>r.complete).length;const claimed=rows.filter(r=>r.claimed).length;const avg=rows.length?rows.reduce((s,r)=>s+r.progress,0)/rows.length:0;return {userId,...info,completed,claimed,progress:avg};}).sort((a,b)=>b.completed-a.completed||b.progress-a.progress||a.userId-b.userId).slice(0,10);}
function titleFor(userId,weekKey){return safeGet('SELECT title,bonus_points AS bonusPoints,awarded_at AS awardedAt FROM weekly_mission_titles WHERE user_id=? AND week_key=?',Number(userId),weekKey);}
function payload(userId=null){const cfg=config(),week=isoWeekParts(),missions=missionRows(userId,week,cfg),title=userId?titleFor(userId,week.key):null;return {config:{enabled:cfg.enabled,completionBonus:cfg.completionBonus},week,missions,summary:userId?{completed:missions.filter(m=>m.complete).length,claimed:missions.filter(m=>m.claimed).length,total:missions.length,title}:null,leaderboard:leaderboard(week,cfg)};}
function claimMission(userId,missionId){
  const cfg=config();if(!cfg.enabled)throw Object.assign(new Error('Wochenmissionen sind deaktiviert.'),{status:409});
  const week=isoWeekParts(),missions=missionRows(userId,week,cfg),mission=missions.find(m=>m.id===missionId);if(!mission)throw Object.assign(new Error('Mission nicht gefunden.'),{status:404});if(mission.claimed)throw Object.assign(new Error('Mission bereits abgeholt.'),{status:409});if(!mission.complete)throw Object.assign(new Error('Mission noch nicht abgeschlossen.'),{status:409});
  const stamp=new Date().toISOString();let weeklyBonus=null;
  db().exec('BEGIN IMMEDIATE');
  try{
    db().prepare('INSERT INTO weekly_mission_claims(user_id,week_key,mission_id,points,claimed_at) VALUES(?,?,?,?,?)').run(Number(userId),week.key,mission.id,mission.reward,stamp);
    if(mission.reward>0)db().prepare('INSERT OR IGNORE INTO points_ledger(user_id,amount,reason,ref_type,ref_id,created_at) VALUES(?,?,?,?,?,?)').run(Number(userId),mission.reward,`Wochenmission: ${mission.title}`,'weekly-mission',`${week.key}:${mission.id}`,stamp);
    const claimCount=num(safeGet('SELECT COUNT(*) AS n FROM weekly_mission_claims WHERE user_id=? AND week_key=?',Number(userId),week.key)?.n);
    if(claimCount>=missions.length){const title=`Wochenheld ${week.label}`;const r=db().prepare('INSERT OR IGNORE INTO weekly_mission_titles(user_id,week_key,title,bonus_points,awarded_at) VALUES(?,?,?,?,?)').run(Number(userId),week.key,title,cfg.completionBonus,stamp);if(Number(r.changes||0)>0){if(cfg.completionBonus>0)db().prepare('INSERT OR IGNORE INTO points_ledger(user_id,amount,reason,ref_type,ref_id,created_at) VALUES(?,?,?,?,?,?)').run(Number(userId),cfg.completionBonus,`Wochenabschluss: ${title}`,'weekly-bonus',week.key,stamp);weeklyBonus={title,points:cfg.completionBonus};}}
    db().exec('COMMIT');
  }catch(err){try{db().exec('ROLLBACK');}catch{}throw err;}
  return {ok:true,mission:{id:mission.id,title:mission.title,points:mission.reward},weeklyBonus,payload:payload(userId)};
}
function honorsFor(userId){return safeAll('SELECT week_key AS weekKey,title,bonus_points AS bonusPoints,awarded_at AS awardedAt FROM weekly_mission_titles WHERE user_id=? ORDER BY awarded_at DESC LIMIT 12',Number(userId)).map(r=>({...r,bonusPoints:num(r.bonusPoints)}));}

function missionsPage(){return `<!doctype html><html lang="de"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="theme-color" content="#061724"><title>PalPanel // Wochenmissionen</title><link rel="stylesheet" href="/styles.css"><link rel="stylesheet" href="/progression.css"><link rel="stylesheet" href="/palworld-theme.css"><link rel="stylesheet" href="/wow.css?v=0910"><link rel="stylesheet" href="/missions.css?v=${ASSET_VERSION}"></head><body><div class="ambient ambient-a"></div><div class="ambient ambient-b"></div><header class="topnav"><a class="brand" href="/"><span class="brand-orb">P</span><div><strong>PalPanel</strong><small>WOCHENMISSIONEN</small></div></a><nav class="mainnav"><a href="/">Start</a><a href="/event">Event</a><a class="active" href="/missions">Missionen</a><a href="/hall-of-fame">Hall of Fame</a><a href="/profile">Profil</a></nav><div class="nav-actions"><a class="mission-login" href="/auth/steam">Mit Steam anmelden</a></div></header><main class="mission-shell"><section class="mission-hero"><div><span>WÖCHENTLICHE EXPEDITION</span><h1>Fünf Aufgaben. Sieben Tage.</h1><p>PalPanel stellt jede Kalenderwoche automatisch neue Missionen zusammen. Fortschritt entsteht direkt durch dein Spiel auf dem Server.</p><div class="mission-week"><b id="missionWeek">—</b><span id="missionTime">—</span></div></div><div class="mission-ring"><strong id="missionCompleteCount">0/5</strong><span>ERLEDIGT</span></div></section><section class="mission-section"><div class="mission-heading"><div><span>DEINE MISSIONEN</span><h2 id="missionHeading">Wochenziele werden geladen.</h2></div><p>Belohnungen sind Shop-Punkte. Ranglisten- und Event-Punkte bleiben unberührt.</p></div><div id="missionGate" class="mission-gate"><h3>Mit Steam anmelden</h3><p>Dein persönlicher Fortschritt und das Abholen der Belohnungen benötigen dein verbundenes Spielerkonto.</p><a href="/auth/steam">Steam verbinden →</a></div><div id="missionGrid" class="mission-grid"></div></section><section class="mission-lower"><article class="mission-panel"><div class="mission-panel-head"><div><span>WOCHENABSCHLUSS</span><h3>Wochenheld werden</h3></div><b id="missionBonus">—</b></div><p>Hole alle fünf abgeschlossenen Missionen ab. Danach erhältst du automatisch den permanenten Wochenheld-Titel und den Abschlussbonus.</p><div id="weeklyTitle" class="weekly-title">Noch nicht abgeschlossen</div></article><article class="mission-panel"><div class="mission-panel-head"><div><span>COMMUNITY</span><h3>Wochenjäger</h3></div><b>LIVE</b></div><div id="missionLeaderboard" class="mission-leaderboard"></div></article></section></main><div id="missionToast" class="mission-toast"></div><script src="/missions.js?v=${ASSET_VERSION}"></script></body></html>`;}
function enhanceHtml(html){let out=String(html||'');if(!out.includes('href="/missions"')){if(out.includes('<a href="/hall-of-fame">'))out=out.replace('<a href="/hall-of-fame">','<a href="/missions">Missionen</a><a href="/hall-of-fame">');else if(out.includes('<a href="/event">'))out=out.replace('<a href="/event">','<a href="/event">');}
  if(!out.includes('/missions.css?v=0950'))out=out.replace('</head>',`<link rel="stylesheet" href="/missions.css?v=${ASSET_VERSION}"><script src="/weekly-honors.js?v=${ASSET_VERSION}"></script></head>`);return out;}
function captureHtml(req,res,listener){const ow=res.writeHead.bind(res),oe=res.end.bind(res);let status=null,msg=null,headers=null;res.writeHead=function(sc,sm,h){status=sc;if(typeof sm==='string'){msg=sm;headers={...(h||{})};}else headers={...(sm||{})};return res;};res.end=function(chunk,enc,cb){if(status!=null){const hs={...(headers||{})},ct=String(hs['Content-Type']||hs['content-type']||'');if(status===200&&ct.toLowerCase().includes('text/html')&&chunk!=null){const data=Buffer.from(enhanceHtml(Buffer.isBuffer(chunk)?chunk.toString('utf8'):String(chunk)));delete hs['content-length'];hs['Content-Length']=data.length;if(msg)ow(status,msg,hs);else ow(status,hs);return oe(data,undefined,cb);}if(msg)ow(status,msg,hs);else ow(status,hs);}return oe(chunk,enc,cb);};return listener(req,res);}

const previousCreateServer=http.createServer.bind(http);
http.createServer=function weeklyMissionCreateServer(options,requestListener){const hasOptions=typeof options!=='function';const listener=hasOptions?requestListener:options;const wrapped=async(req,res)=>{let url;try{url=new URL(req.url,'http://localhost');}catch{return listener(req,res);}try{
  if((req.method==='GET'||req.method==='HEAD')&&url.pathname==='/missions')return sendHtml(res,missionsPage());
  if(req.method==='GET'&&url.pathname==='/api/public/missions')return sendJson(res,200,payload(null));
  if(req.method==='GET'&&url.pathname==='/api/user/missions'){const uid=sessionUserId(req);if(!uid)return sendJson(res,401,{error:'Nicht angemeldet.'});return sendJson(res,200,payload(uid));}
  if(req.method==='POST'&&url.pathname==='/api/user/missions/claim'){const uid=sessionUserId(req);if(!uid)return sendJson(res,401,{error:'Nicht angemeldet.'});const body=await readBody(req);try{return sendJson(res,200,claimMission(uid,String(body.missionId||'')));}catch(e){return sendJson(res,e.status||500,{error:e.message});}}
  if(req.method==='GET'&&url.pathname==='/api/user/weekly-honors'){const uid=sessionUserId(req);if(!uid)return sendJson(res,401,{error:'Nicht angemeldet.'});return sendJson(res,200,{honors:honorsFor(uid)});}
  const honorMatch=url.pathname.match(/^\/api\/public\/player\/(\d+)\/weekly-honors$/);if(req.method==='GET'&&honorMatch)return sendJson(res,200,{honors:honorsFor(Number(honorMatch[1]))});
  if(url.pathname==='/api/admin/missions'){if(!(await requireAdmin(req,res)))return;if(req.method==='GET')return sendJson(res,200,{config:config(),current:payload(null)});if(req.method==='POST'){const body=await readBody(req);const c=saveConfig(body.config||body);return sendJson(res,200,{ok:true,config:c,current:payload(null)});}}
  if((req.method==='GET'||req.method==='HEAD')&&url.pathname==='/admin/missions.html'){res.writeHead(308,{Location:'/admin/missions','Cache-Control':'no-store'});return res.end();}
  if((req.method==='GET'||req.method==='HEAD')&&url.pathname==='/admin/missions'){try{const data=fs.readFileSync(path.join(APP_DIR,'admin','missions.html'));res.writeHead(200,{'Content-Type':'text/html; charset=utf-8','Content-Length':data.length,'Cache-Control':'no-cache'});return res.end(data);}catch{return sendJson(res,404,{error:'Missionsverwaltung fehlt.'});}}
}catch(err){console.warn('[WeeklyMissions]',err.message);if(!res.headersSent)return sendJson(res,500,{error:'Wochenmissionen konnten nicht verarbeitet werden.'});}
  if((req.method==='GET'||req.method==='HEAD')&&(['','/','/profile','/profile/','/shop','/shop/','/event','/hall-of-fame'].includes(url.pathname)||/^\/player\/\d+\/?$/.test(url.pathname)))return captureHtml(req,res,listener);
  return listener(req,res);};return hasOptions?previousCreateServer(options,wrapped):previousCreateServer(wrapped);};
console.log(`PalPanel v0.9.5 Wochenmissionen geladen. Konfiguration: ${CONFIG_FILE}`);
require('./server-v094.js');
