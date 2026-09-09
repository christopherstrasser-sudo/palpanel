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
const ASSET_VERSION = '0930';

let database = null;
function db() {
  if (!database) {
    database = new DatabaseSync(DB_FILE, { timeout: 5000 });
    try {
      database.exec('PRAGMA journal_mode = WAL;');
      database.exec(`CREATE TABLE IF NOT EXISTS season_claims (
        user_id INTEGER NOT NULL,
        season_id TEXT NOT NULL,
        reward_key TEXT NOT NULL,
        claimed_at TEXT NOT NULL,
        PRIMARY KEY(user_id,season_id,reward_key)
      ) STRICT;`);
    } catch {}
  }
  return database;
}
function nowIso(){ return new Date().toISOString(); }
function num(v){ return Number(v || 0); }
function clampInt(v,min,max,fallback){ const n=Math.trunc(Number(v)); return Number.isFinite(n)?Math.max(min,Math.min(max,n)):fallback; }
function safeGet(sql,...params){ try{return db().prepare(sql).get(...params)||null;}catch{return null;} }
function safeAll(sql,...params){ try{return db().prepare(sql).all(...params);}catch{return [];} }
function sendJson(res,status,body){ const data=Buffer.from(JSON.stringify(body)); res.writeHead(status,{'Content-Type':'application/json; charset=utf-8','Content-Length':data.length,'Cache-Control':'no-store'}); res.end(data); }
function sendHtml(res,html){ const data=Buffer.from(html); res.writeHead(200,{'Content-Type':'text/html; charset=utf-8','Content-Length':data.length,'Cache-Control':'no-cache'}); res.end(data); }
function readBody(req){ return new Promise((resolve,reject)=>{let raw=''; req.on('data',c=>{raw+=c;if(raw.length>256*1024)reject(new Error('Request too large'));}); req.on('end',()=>{try{resolve(raw?JSON.parse(raw):{});}catch(e){reject(e);}}); req.on('error',reject);}); }
function parseCookies(req){ const out={}; String(req.headers.cookie||'').split(';').forEach(part=>{const i=part.indexOf('=');if(i>0)out[part.slice(0,i).trim()]=decodeURIComponent(part.slice(i+1).trim());}); return out; }
function hashToken(token){ return crypto.createHash('sha256').update(String(token||'')).digest('hex'); }
function sessionUserId(req){ const token=parseCookies(req)[SESSION_COOKIE]; if(!token)return null; const row=safeGet('SELECT user_id AS userId,expires_at AS expiresAt FROM user_sessions WHERE token_hash=?',hashToken(token)); if(!row||Date.parse(row.expiresAt)<=Date.now())return null; return Number(row.userId)||null; }

const DEFAULT_SEASON = {
  id:'palpagos-s1',
  title:'Palpagos Saison I',
  subtitle:'Gemeinsam entdecken. Gemeinsam jagen. Gemeinsam Geschichte schreiben.',
  active:true,
  startAt:defaults.event?.startAt || null,
  endAt:defaults.event?.endAt || null,
  communityGoals:{ captures:500, uniqueSpecies:120, alphaCaptures:40, bosses:20 },
  personalGoals:{ captures:30, uniqueSpecies:15, alphaCaptures:3, bosses:2 },
  rewards:[
    { key:'community-25', threshold:25, points:50, label:'Vorratspaket I' },
    { key:'community-50', threshold:50, points:100, label:'Vorratspaket II' },
    { key:'community-75', threshold:75, points:150, label:'Vorratspaket III' },
    { key:'community-100', threshold:100, points:250, label:'Saisonabschluss' },
    { key:'personal-100', threshold:100, points:200, label:'Persönlicher Abschluss', personal:true }
  ]
};
function normalizeSeason(raw={}){
  const rewards=Array.isArray(raw.rewards)?raw.rewards:DEFAULT_SEASON.rewards;
  return {
    id:String(raw.id||DEFAULT_SEASON.id).trim().slice(0,80)||DEFAULT_SEASON.id,
    title:String(raw.title||DEFAULT_SEASON.title).trim().slice(0,120)||DEFAULT_SEASON.title,
    subtitle:String(raw.subtitle||DEFAULT_SEASON.subtitle).trim().slice(0,260)||DEFAULT_SEASON.subtitle,
    active:raw.active!==false,
    startAt:raw.startAt||null,
    endAt:raw.endAt||null,
    communityGoals:{
      captures:clampInt(raw.communityGoals?.captures,1,1000000,DEFAULT_SEASON.communityGoals.captures),
      uniqueSpecies:clampInt(raw.communityGoals?.uniqueSpecies,1,10000,DEFAULT_SEASON.communityGoals.uniqueSpecies),
      alphaCaptures:clampInt(raw.communityGoals?.alphaCaptures,1,100000,DEFAULT_SEASON.communityGoals.alphaCaptures),
      bosses:clampInt(raw.communityGoals?.bosses,1,100000,DEFAULT_SEASON.communityGoals.bosses)
    },
    personalGoals:{
      captures:clampInt(raw.personalGoals?.captures,1,100000,DEFAULT_SEASON.personalGoals.captures),
      uniqueSpecies:clampInt(raw.personalGoals?.uniqueSpecies,1,10000,DEFAULT_SEASON.personalGoals.uniqueSpecies),
      alphaCaptures:clampInt(raw.personalGoals?.alphaCaptures,1,10000,DEFAULT_SEASON.personalGoals.alphaCaptures),
      bosses:clampInt(raw.personalGoals?.bosses,1,10000,DEFAULT_SEASON.personalGoals.bosses)
    },
    rewards:rewards.slice(0,12).map((r,i)=>({
      key:String(r.key||`reward-${i+1}`).replace(/[^a-z0-9_-]/gi,'-').slice(0,80),
      threshold:clampInt(r.threshold,1,100,25),
      points:clampInt(r.points,0,100000,0),
      label:String(r.label||`Belohnung ${i+1}`).trim().slice(0,120),
      personal:!!r.personal
    }))
  };
}
function seasonConfig(){
  try { return normalizeSeason(JSON.parse(fs.readFileSync(SEASON_FILE,'utf8'))); }
  catch {
    const s=normalizeSeason(DEFAULT_SEASON); fs.mkdirSync(DATA_DIR,{recursive:true}); fs.writeFileSync(SEASON_FILE,JSON.stringify(s,null,2),'utf8'); return s;
  }
}
function saveSeason(input){ const s=normalizeSeason(input); fs.mkdirSync(DATA_DIR,{recursive:true}); fs.writeFileSync(SEASON_FILE,JSON.stringify(s,null,2),'utf8'); return s; }
function rangeClause(column,s){
  const parts=[]; const params=[];
  if(s.startAt){parts.push(`${column}>=?`);params.push(new Date(s.startAt).toISOString());}
  if(s.endAt){parts.push(`${column}<=?`);params.push(new Date(s.endAt).toISOString());}
  return { sql:parts.length?` AND ${parts.join(' AND ')}`:'', params };
}
function metric(type,userId=null,s=seasonConfig()){
  const user=userId?Number(userId):null;
  if(type==='captures'||type==='alphaCaptures'||type==='uniqueSpecies'){
    const r=rangeClause('captured_at',s); const where=`WHERE 1=1${user?' AND user_id=?':''}${r.sql}`; const params=[...(user?[user]:[]),...r.params];
    const expr=type==='captures'?'COUNT(*)':type==='alphaCaptures'?'SUM(CASE WHEN is_alpha=1 THEN 1 ELSE 0 END)':'COUNT(DISTINCT species_key)';
    return num(safeGet(`SELECT COALESCE(${expr},0) AS n FROM pal_captures ${where}`,...params)?.n);
  }
  if(type==='bosses'){
    const r=rangeClause('completed_at',s); const where=`WHERE 1=1${user?' AND user_id=?':''}${r.sql}`; const params=[...(user?[user]:[]),...r.params];
    return num(safeGet(`SELECT COUNT(*) AS n FROM boss_completions ${where}`,...params)?.n);
  }
  return 0;
}
function goalRows(goals,userId,s){
  const defs=[['captures','Fänge','◎'],['uniqueSpecies','Pal-Arten','◇'],['alphaCaptures','Alpha-Fänge','◆'],['bosses','Bosse','◈']];
  return defs.map(([key,label,icon])=>{ const current=metric(key,userId,s); const target=Math.max(1,num(goals[key])); const progress=Math.max(0,Math.min(100,current/target*100)); return {key,label,icon,current,target,progress,complete:current>=target}; });
}
function aggregateProgress(rows){ return rows.length?Math.min(...rows.map(r=>r.progress)):0; }
function seasonState(s){
  const now=Date.now(), start=s.startAt?Date.parse(s.startAt):null, end=s.endAt?Date.parse(s.endAt):null;
  if(!s.active)return 'inactive'; if(start&&now<start)return 'upcoming'; if(end&&now>end)return 'ended'; return 'active';
}
function participant(userId,s){ return metric('captures',userId,s)+metric('alphaCaptures',userId,s)+metric('bosses',userId,s)>0; }
function publicName(userId){ const row=safeGet(`SELECT COALESCE(l.palworld_name,'Entdecker #'||u.id) AS name,u.steam_id AS steamId FROM users u LEFT JOIN player_links l ON l.user_id=u.id WHERE u.id=?`,Number(userId)); return row?{name:row.name,avatarUrl:/^\d{17}$/.test(String(row.steamId||''))?`/api/steam/avatar/user/${userId}`:null}:null; }
function contributors(s){
  const start=s.startAt?new Date(s.startAt).toISOString():null,end=s.endAt?new Date(s.endAt).toISOString():null;
  const capWhere=[start?'captured_at>=?':null,end?'captured_at<=?':null].filter(Boolean).join(' AND '); const capParams=[...(start?[start]:[]),...(end?[end]:[])];
  const bossWhere=[start?'completed_at>=?':null,end?'completed_at<=?':null].filter(Boolean).join(' AND '); const bossParams=[...(start?[start]:[]),...(end?[end]:[])];
  const ids=new Set(); safeAll(`SELECT DISTINCT user_id AS id FROM pal_captures${capWhere?' WHERE '+capWhere:''}`,...capParams).forEach(r=>ids.add(Number(r.id))); safeAll(`SELECT DISTINCT user_id AS id FROM boss_completions${bossWhere?' WHERE '+bossWhere:''}`,...bossParams).forEach(r=>ids.add(Number(r.id)));
  return [...ids].map(id=>{const info=publicName(id)||{name:`Entdecker #${id}`,avatarUrl:null}; const captures=metric('captures',id,s),uniqueSpecies=metric('uniqueSpecies',id,s),alphaCaptures=metric('alphaCaptures',id,s),bosses=metric('bosses',id,s); return {userId:id,...info,captures,uniqueSpecies,alphaCaptures,bosses,seasonScore:captures+uniqueSpecies*5+alphaCaptures*10+bosses*25};}).sort((a,b)=>b.seasonScore-a.seasonScore||b.uniqueSpecies-a.uniqueSpecies||a.userId-b.userId).slice(0,10);
}
function claimedKeys(userId,s){ return new Set(safeAll('SELECT reward_key AS key FROM season_claims WHERE user_id=? AND season_id=?',Number(userId),s.id).map(r=>r.key)); }
function seasonPayload(userId=null){
  const s=seasonConfig(); const community=goalRows(s.communityGoals,null,s); const personal=userId?goalRows(s.personalGoals,userId,s):[]; const communityProgress=aggregateProgress(community); const personalProgress=userId?aggregateProgress(personal):0; const claimed=userId?claimedKeys(userId,s):new Set(); const joined=userId?participant(userId,s):false;
  const rewards=s.rewards.map(r=>{const progress=r.personal?personalProgress:communityProgress; return {...r,unlocked:progress>=r.threshold,claimed:claimed.has(r.key),claimable:!!userId&&joined&&progress>=r.threshold&&!claimed.has(r.key)};});
  return {season:{id:s.id,title:s.title,subtitle:s.subtitle,active:s.active,startAt:s.startAt,endAt:s.endAt,state:seasonState(s)},community:{goals:community,progress:communityProgress,contributors:contributors(s)},personal:userId?{goals:personal,progress:personalProgress,participating:joined}:null,rewards};
}
function claimReward(userId,key){
  const s=seasonConfig(); const payload=seasonPayload(userId); const reward=payload.rewards.find(r=>r.key===key); if(!reward)throw Object.assign(new Error('Belohnung nicht gefunden.'),{status:404}); if(!payload.personal?.participating)throw Object.assign(new Error('Nimm zuerst aktiv an der Saison teil.'),{status:409}); if(!reward.unlocked)throw Object.assign(new Error('Diese Belohnung ist noch nicht freigeschaltet.'),{status:409}); if(reward.claimed)throw Object.assign(new Error('Diese Belohnung wurde bereits abgeholt.'),{status:409});
  const stamp=nowIso(); db().exec('BEGIN IMMEDIATE'); try { db().prepare('INSERT INTO season_claims(user_id,season_id,reward_key,claimed_at) VALUES(?,?,?,?)').run(Number(userId),s.id,reward.key,stamp); if(reward.points>0) db().prepare('INSERT OR IGNORE INTO points_ledger(user_id,amount,reason,ref_type,ref_id,created_at) VALUES(?,?,?,?,?,?)').run(Number(userId),reward.points,`Saison: ${reward.label}`,'season-reward',`${s.id}:${reward.key}`,stamp); db().exec('COMMIT'); } catch(e){try{db().exec('ROLLBACK');}catch{} throw e;}
  return {ok:true,reward,pointsAwarded:reward.points};
}
async function requireAdmin(req,res){
  try { const cfg={...defaults,...(()=>{try{return JSON.parse(fs.readFileSync(path.join(DATA_DIR,'config.json'),'utf8'));}catch{return {};}})()}; const response=await fetch(`http://127.0.0.1:${cfg.panel?.port||8787}/api/admin/session`,{headers:{Cookie:String(req.headers.cookie||''),Accept:'application/json'},signal:AbortSignal.timeout(4000)}); const body=await response.json().catch(()=>({})); if(!response.ok||!body.authenticated){sendJson(res,401,{error:'Nicht angemeldet.'});return false;} return true; } catch { sendJson(res,401,{error:'Admin-Sitzung konnte nicht geprüft werden.'}); return false; }
}
function eventPage(){
  return `<!doctype html><html lang="de"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="theme-color" content="#061724"><title>PalPanel // Saison-Event</title><link rel="preload" as="image" href="/palpanel-banner.png?v=0910"><link rel="stylesheet" href="/styles.css"><link rel="stylesheet" href="/progression.css"><link rel="stylesheet" href="/palworld-theme.css"><link rel="stylesheet" href="/wow.css?v=0910"><link rel="stylesheet" href="/season.css?v=${ASSET_VERSION}"></head><body><div class="ambient ambient-a"></div><div class="ambient ambient-b"></div><header class="topnav"><a class="brand" href="/"><span class="brand-orb">P</span><div><strong>PalPanel</strong><small>SAISON-EVENT</small></div></a><nav class="mainnav"><a href="/">Start</a><a class="active" href="/event">Event</a><a href="/#ranking">Rangliste</a><a href="/profile">Profil</a><a href="/shop">Punkteshop</a></nav><div class="nav-actions"><button id="accountTrigger" class="account-trigger"><i></i><span><small>SPIELERKONTO</small><b id="accountTriggerText">Mit Steam anmelden</b></span><em id="accountPoints"></em></button></div></header><div id="accountShade" class="account-shade"></div><aside id="accountDrawer" class="account-drawer" aria-hidden="true"><div class="drawer-head"><div><small>PALPANEL-IDENTITÄT</small><strong>Dein Abenteuer</strong></div><button id="accountClose">×</button></div><div class="identity-mark"><i id="accountInitial">?</i><div><small>VERBUNDENER SPIELER</small><h2 id="accountName">—</h2><code id="accountSteamId">—</code></div></div><div class="identity-status"><div><small>CHARAKTER</small><strong id="accountLinkState">PRÜFE</strong></div><div><small>PUNKTE</small><strong id="drawerPoints">0</strong></div><div><small>STUFE</small><strong id="accountLevel">—</strong></div></div><div id="accountLinkNotice" class="link-notice"><b>Charakter noch nicht gefunden</b><p>Betritt den Palworld-Server mit diesem Steam-Konto und prüfe danach erneut.</p><button id="relinkBtn">Erneut suchen</button></div><nav class="identity-nav"><a href="/profile">Mein Profil <b>→</b></a><a href="/shop">Punkteshop <b>→</b></a><a id="steamProfileLink" target="_blank" rel="noopener">Steam-Profil <b>↗</b></a></nav><button id="userLogout" class="drawer-logout">Steam-Sitzung trennen</button></aside><main class="season-shell"><section class="season-hero"><div><span class="season-kicker">LIVE COMMUNITY EVENT</span><h1 id="seasonTitle">Saison wird geladen…</h1><p id="seasonSubtitle">Gemeinsam Fortschritt erspielen und Belohnungsstufen freischalten.</p><div class="season-meta"><span id="seasonState">—</span><b id="seasonTime">—</b></div></div><div class="season-ring" style="--progress:0"><strong id="communityPercent">0%</strong><span>COMMUNITY</span></div></section><section class="season-section"><div class="season-heading"><div><span>GEMEINSCHAFTSZIELE</span><h2>Alle ziehen am selben Strang.</h2></div><p>Eine Belohnungsstufe zählt erst als erreicht, wenn alle vier Community-Ziele mindestens diesen Fortschritt haben.</p></div><div id="communityGoals" class="season-goal-grid"></div></section><section class="season-grid"><div><section class="season-panel"><div class="season-panel-head"><div><span>DEINE CHALLENGES</span><h3>Persönlicher Saisonfortschritt</h3></div><b id="personalPercent">—</b></div><div id="personalGate" class="season-empty">Mit Steam anmelden, um deine Challenges zu sehen.</div><div id="personalGoals" class="season-personal-list hidden"></div></section><section class="season-panel rewards-panel"><div class="season-panel-head"><div><span>BELONUNGEN</span><h3>Freischalten & abholen</h3></div></div><div id="seasonRewards" class="season-rewards"></div></section></div><section class="season-panel contributors-panel"><div class="season-panel-head"><div><span>SAISON-RANGLISTE</span><h3>Top-Beiträge</h3></div><b>LIVE</b></div><div id="seasonContributors" class="season-contributors"></div></section></section></main><footer><div class="brand footer-brand"><span class="brand-orb">P</span><div><strong>PalPanel</strong><small>SAISON-EVENT</small></div></div><span>Gemeinsam spielen. Gemeinsam freischalten.</span><i>© 2026</i></footer><div id="seasonToast" class="season-toast"></div><script src="/account.js?v=0900"></script><script src="/season.js?v=${ASSET_VERSION}"></script></body></html>`;
}
function enhanceHtml(html){ let out=String(html||''); if(!out.includes('href="/event"')) out=out.replace('<a href="/#ranking">Rangliste</a>', '<a href="/event">Event</a><a href="/#ranking">Rangliste</a>'); return out; }
function captureHtml(req,res,listener){ const ow=res.writeHead.bind(res),oe=res.end.bind(res); let status=null,msg=null,headers=null; res.writeHead=function(sc,sm,h){status=sc;if(typeof sm==='string'){msg=sm;headers={...(h||{})};}else headers={...(sm||{})};return res;}; res.end=function(chunk,enc,cb){if(status!=null){const hs={...(headers||{})},ct=String(hs['Content-Type']||hs['content-type']||'');if(status===200&&ct.toLowerCase().includes('text/html')&&chunk!=null){const data=Buffer.from(enhanceHtml(Buffer.isBuffer(chunk)?chunk.toString('utf8'):String(chunk)));delete hs['content-length'];hs['Content-Length']=data.length;if(msg)ow(status,msg,hs);else ow(status,hs);return oe(data,undefined,cb);}if(msg)ow(status,msg,hs);else ow(status,hs);}return oe(chunk,enc,cb);}; return listener(req,res); }

const previousCreateServer=http.createServer.bind(http);
http.createServer=function seasonCreateServer(options,requestListener){ const hasOptions=typeof options!=='function'; const listener=hasOptions?requestListener:options; const wrapped=async(req,res)=>{ let url; try{url=new URL(req.url,'http://localhost');}catch{return listener(req,res);} try{
  if((req.method==='GET'||req.method==='HEAD')&&url.pathname==='/event') return sendHtml(res,eventPage());
  if(req.method==='GET'&&url.pathname==='/api/public/season') return sendJson(res,200,seasonPayload(null));
  if(req.method==='GET'&&url.pathname==='/api/user/season'){const uid=sessionUserId(req);if(!uid)return sendJson(res,401,{error:'Nicht angemeldet.'});return sendJson(res,200,seasonPayload(uid));}
  if(req.method==='POST'&&url.pathname==='/api/user/season/claim'){const uid=sessionUserId(req);if(!uid)return sendJson(res,401,{error:'Nicht angemeldet.'});const body=await readBody(req);try{return sendJson(res,200,claimReward(uid,String(body.rewardKey||'')));}catch(e){return sendJson(res,e.status||500,{error:e.message});}}
  if(url.pathname==='/api/admin/season'){if(!(await requireAdmin(req,res)))return;if(req.method==='GET')return sendJson(res,200,{config:seasonConfig(),snapshot:seasonPayload(null)});if(req.method==='POST'){const body=await readBody(req);const config=saveSeason(body.config||body);return sendJson(res,200,{ok:true,config,snapshot:seasonPayload(null)});}}
  if((req.method==='GET'||req.method==='HEAD')&&url.pathname==='/admin/season.html'){res.writeHead(308,{Location:'/admin/season','Cache-Control':'no-store'});return res.end();}
  if((req.method==='GET'||req.method==='HEAD')&&url.pathname==='/admin/season'){const file=path.join(APP_DIR,'admin','season.html');try{const data=fs.readFileSync(file);res.writeHead(200,{'Content-Type':'text/html; charset=utf-8','Content-Length':data.length,'Cache-Control':'no-cache'});return res.end(data);}catch{return sendJson(res,404,{error:'Event-Verwaltung fehlt.'});}}
 }catch(err){console.warn('[Season]',err.message);if(!res.headersSent)return sendJson(res,500,{error:'Saison konnte nicht verarbeitet werden.'});}
  if((req.method==='GET'||req.method==='HEAD')&&['/','/profile','/profile/','/shop','/shop/'].includes(url.pathname)) return captureHtml(req,res,listener);
  return listener(req,res);
 }; return hasOptions?previousCreateServer(options,wrapped):previousCreateServer(wrapped); };
console.log(`PalPanel v0.9.3 Saison-Events geladen. Konfiguration: ${SEASON_FILE}`);
require('./server-v092.js');
