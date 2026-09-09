const fs=require('fs');
const path=require('path');
const http=require('http');
const crypto=require('crypto');
const {DatabaseSync}=require('node:sqlite');

const APP_DIR=path.resolve(__dirname,'..');
const defaults=JSON.parse(fs.readFileSync(path.join(APP_DIR,'config','default.json'),'utf8'));
const DATA_DIR=defaults.paths.data;
const USER_CONFIG=path.join(DATA_DIR,'config.json');
const REST_FILE=path.join(DATA_DIR,'palworld-rest.json');
const RAID_CONFIG_FILE=path.join(APP_DIR,'config','raid-config.json');
const DB_FILE=path.join(DATA_DIR,'palpanel.db');
const IPC_DIR=path.join(DATA_DIR,'bridge-ipc','server-mods');
const RAID_STATUS_FILE=path.join(IPC_DIR,'raid-status.txt');
const HEARTBEAT_FILE=path.join(IPC_DIR,'heartbeat.txt');
let PalNames=null;
try{PalNames=require(path.join(APP_DIR,'public','pal-names.js'));}catch{}

fs.mkdirSync(DATA_DIR,{recursive:true});
fs.mkdirSync(IPC_DIR,{recursive:true});
const db=new DatabaseSync(DB_FILE,{timeout:5000});
try{db.exec('PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON;');}catch{}
db.exec(`
CREATE TABLE IF NOT EXISTS raid_runs (
  id INTEGER PRIMARY KEY,
  raid_key TEXT NOT NULL UNIQUE,
  species_key TEXT NOT NULL,
  display_name TEXT NOT NULL,
  boss_level INTEGER NOT NULL,
  boss_power INTEGER NOT NULL,
  boss_scale REAL NOT NULL,
  online_players INTEGER NOT NULL,
  anchor_name TEXT,
  state TEXT NOT NULL,
  x REAL,
  y REAL,
  z REAL,
  marker_count INTEGER NOT NULL DEFAULT 0,
  participant_count INTEGER NOT NULL DEFAULT 0,
  started_at TEXT NOT NULL,
  ended_at TEXT,
  last_error TEXT
) STRICT;
CREATE TABLE IF NOT EXISTS raid_participants (
  raid_key TEXT NOT NULL,
  player_uid TEXT NOT NULL,
  player_name TEXT NOT NULL,
  damage INTEGER NOT NULL DEFAULT 0,
  item_reward TEXT NOT NULL DEFAULT 'none',
  pal_reward TEXT NOT NULL DEFAULT 'none',
  reward_error TEXT,
  first_hit_at TEXT,
  last_hit_at TEXT,
  PRIMARY KEY(raid_key,player_uid)
) STRICT;
CREATE INDEX IF NOT EXISTS ix_raid_runs_started ON raid_runs(started_at DESC);
CREATE INDEX IF NOT EXISTS ix_raid_participants_raid ON raid_participants(raid_key,damage DESC);
`);

function loadJson(file,fallback={}){try{return JSON.parse(fs.readFileSync(file,'utf8'));}catch{return fallback;}}
function config(){const current=loadJson(USER_CONFIG,{})||{},p=current.palworld||{};return{...defaults,...current,panel:{...defaults.panel,...(current.panel||{})},paths:{...defaults.paths,...(current.paths||{})},palworld:{...defaults.palworld,...p,rest:{...defaults.palworld.rest,...(p.rest||{})}}};}
function raidConfig(){return loadJson(RAID_CONFIG_FILE,{defaults:{baseLevel:35,levelPerPlayer:5,maxLevel:65,basePower:55,powerPerPlayer:8,baseScale:2.8,scalePerPlayer:.12,maxScale:4,spawnDistance:1800},bosses:[],rewards:[]});}
function parseKv(raw){const out={};String(raw||'').split(/\r?\n/).forEach(line=>{const i=line.indexOf('=');if(i<1)return;const k=line.slice(0,i),v=line.slice(i+1);try{out[k]=decodeURIComponent(v.replace(/\+/g,'%20'));}catch{out[k]=v;}});return out;}
function enc(value){return encodeURIComponent(String(value??''));}
function clamp(v,min,max){v=Number(v);return Math.max(min,Math.min(max,Number.isFinite(v)?v:min));}
function displayName(species){try{return PalNames?.display?.(species)||species;}catch{return species;}}
function isoFromEpoch(v){const n=Number(v);return Number.isFinite(n)&&n>0?new Date(n*1000).toISOString():null;}
function sendJson(res,status,body){const data=Buffer.from(JSON.stringify(body));res.writeHead(status,{'Content-Type':'application/json; charset=utf-8','Content-Length':data.length,'Cache-Control':'no-store'});res.end(data);}
function readBody(req){return new Promise((resolve,reject)=>{let raw='';req.on('data',c=>{raw+=c;if(raw.length>128*1024)reject(new Error('Request too large'));});req.on('end',()=>{try{resolve(raw?JSON.parse(raw):{});}catch(e){reject(e);}});req.on('error',reject);});}

async function internal(req,pathname,timeout=5000){const cfg=config();const response=await fetch(`http://127.0.0.1:${cfg.panel.port||8787}${pathname}`,{headers:{Cookie:String(req?.headers?.cookie||''),Accept:'application/json'},signal:AbortSignal.timeout(timeout)});const body=await response.json().catch(()=>({}));return{response,body};}
async function requireAdmin(req,res){try{const x=await internal(req,'/api/admin/session',4000);if(!x.response.ok||!x.body.authenticated){sendJson(res,401,{error:'Nicht angemeldet.'});return false;}return true;}catch(e){sendJson(res,503,{error:`Admin-Session konnte nicht geprüft werden: ${e.message}`});return false;}}
async function coreStatus(req){const x=await internal(req,'/api/admin/status',5000);if(!x.response.ok)throw new Error(x.body.error||`Admin status HTTP ${x.response.status}`);return x.body;}

function heartbeat(){let data=null,ageMs=null;try{data=parseKv(fs.readFileSync(HEARTBEAT_FILE,'utf8'));ageMs=Date.now()-fs.statSync(HEARTBEAT_FILE).mtimeMs;}catch{}const capabilities=String(data?.capabilities||'').split(',').filter(Boolean);return{live:ageMs!=null&&ageMs<7000,ageMs,version:data?.version||null,state:data?.state||null,raidState:data?.raid_state||null,capabilities,raidCapable:capabilities.includes('start_raid')&&capabilities.includes('raid_rewards')};}
function readRaidRaw(){try{return parseKv(fs.readFileSync(RAID_STATUS_FILE,'utf8'));}catch{return{active:'0',state:'IDLE'};}}
function parseParticipants(raw){const n=Math.max(0,Math.min(100,Number(raw.participants)||0)),rows=[];for(let i=1;i<=n;i++){const uid=String(raw[`participant_${i}_uid`]||'').trim();if(!uid)continue;rows.push({uid,name:String(raw[`participant_${i}_name`]||uid),damage:Number(raw[`participant_${i}_damage`]||0),firstHitAt:isoFromEpoch(raw[`participant_${i}_first_hit`]),lastHitAt:isoFromEpoch(raw[`participant_${i}_last_hit`]),itemReward:String(raw[`participant_${i}_item_reward`]||'none'),palReward:String(raw[`participant_${i}_pal_reward`]||'none'),rewardError:String(raw[`participant_${i}_reward_error`]||'')||null});}return rows.sort((a,b)=>b.damage-a.damage);}
function raidFromRaw(raw=readRaidRaw()){const species=String(raw.species||'');return{active:raw.active==='1',state:String(raw.state||'IDLE'),raidId:String(raw.raid_id||''),species,displayName:species?displayName(species):null,level:Number(raw.level||0),power:Number(raw.power||0),scale:Number(raw.scale||1),onlineAtStart:Number(raw.online_at_start||0),anchorName:String(raw.anchor_name||''),location:{x:Number(raw.x||0),y:Number(raw.y||0),z:Number(raw.z||0)},startedAt:isoFromEpoch(raw.started_at),endedAt:isoFromEpoch(raw.ended_at),bossInstanceId:String(raw.boss_instance_id||''),markerCount:Number(raw.marker_count||0),participantCount:Number(raw.participants||0),participants:parseParticipants(raw),lastError:String(raw.last_error||'')||null};}
function activeRaid(r=raidFromRaw()){return r.active||['SPAWNING','ACTIVE','REWARDING'].includes(r.state);}

async function sendCommand(type,params={},timeoutMs=14000){const hb=heartbeat();if(!hb.live)throw new Error('PalPanelServerMods ist nicht live. Gameserver bzw. UE4SS prüfen.');if(!hb.raidCapable&&type!=='ping'&&type!=='event_pulse')throw new Error('PalPanelServerMods muss für das Raid-System auf v0.2.0 aktualisiert und der Gameserver neu gestartet werden.');const commandPath=path.join(IPC_DIR,'command.txt'),responsePath=path.join(IPC_DIR,'response.txt');if(fs.existsSync(commandPath))throw new Error('Server-Mod ist beschäftigt. Bitte erneut versuchen.');const id=crypto.randomUUID();try{fs.rmSync(responsePath,{force:true});}catch{}const lines=[`id=${enc(id)}`,`type=${enc(type)}`];for(const[k,v]of Object.entries(params))lines.push(`${k}=${enc(v)}`);const tmp=`${commandPath}.tmp`;fs.writeFileSync(tmp,`${lines.join('\n')}\n`,'utf8');fs.renameSync(tmp,commandPath);const started=Date.now();while(Date.now()-started<timeoutMs){await new Promise(r=>setTimeout(r,100));if(!fs.existsSync(responsePath))continue;let reply;try{reply=parseKv(fs.readFileSync(responsePath,'utf8'));}catch{continue;}if(reply.id!==id)continue;try{fs.rmSync(responsePath,{force:true});}catch{}return{...reply,id,ok:reply.ok==='1'};}throw new Error('Raid-Command Timeout: keine Antwort vom Gameserver.');}

async function announce(message){const cfg=config(),creds=loadJson(REST_FILE,null);if(!creds?.password)return false;const auth=Buffer.from(`${creds.username||cfg.palworld.rest.username||'admin'}:${creds.password}`).toString('base64');const response=await fetch(`http://${cfg.palworld.rest.host||'127.0.0.1'}:${cfg.palworld.rest.port||8212}/v1/api/announce`,{method:'POST',headers:{Accept:'application/json','Content-Type':'application/json',Authorization:`Basic ${auth}`},body:JSON.stringify({message:String(message).slice(0,500)}),signal:AbortSignal.timeout(4000)});return response.ok;}

function guidParts(){const hex=crypto.randomUUID().replace(/-/g,'').toUpperCase();return{a:parseInt(hex.slice(0,8),16),b:parseInt(hex.slice(8,16),16),c:parseInt(hex.slice(16,24),16),d:parseInt(hex.slice(24,32),16)};}
function raidKey(){return `raid-${Date.now()}-${crypto.randomBytes(3).toString('hex')}`;}
function history(limit=20){return db.prepare(`SELECT raid_key AS raidId,species_key AS species,display_name AS displayName,boss_level AS level,boss_power AS power,boss_scale AS scale,online_players AS onlineAtStart,anchor_name AS anchorName,state,x,y,z,marker_count AS markerCount,participant_count AS participantCount,started_at AS startedAt,ended_at AS endedAt,last_error AS lastError FROM raid_runs ORDER BY id DESC LIMIT ?`).all(Math.max(1,Math.min(100,limit))).map(row=>({...row,level:Number(row.level),power:Number(row.power),scale:Number(row.scale),onlineAtStart:Number(row.onlineAtStart),markerCount:Number(row.markerCount),participantCount:Number(row.participantCount)}));}

function upsertRaidStatus(current){if(!current?.raidId)return;const existing=db.prepare('SELECT raid_key FROM raid_runs WHERE raid_key=?').get(current.raidId);if(!existing){db.prepare(`INSERT INTO raid_runs(raid_key,species_key,display_name,boss_level,boss_power,boss_scale,online_players,anchor_name,state,x,y,z,marker_count,participant_count,started_at,ended_at,last_error) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)`).run(current.raidId,current.species||'unknown',current.displayName||displayName(current.species||'unknown'),Math.trunc(current.level||0),Math.trunc(current.power||0),Number(current.scale||1),Math.trunc(current.onlineAtStart||0),current.anchorName||null,current.state||'UNKNOWN',current.location?.x??null,current.location?.y??null,current.location?.z??null,Math.trunc(current.markerCount||0),Math.trunc(current.participantCount||0),current.startedAt||new Date().toISOString(),current.endedAt||null,current.lastError||null);}else{db.prepare(`UPDATE raid_runs SET state=?,x=?,y=?,z=?,marker_count=?,participant_count=?,ended_at=?,last_error=? WHERE raid_key=?`).run(current.state,current.location?.x??null,current.location?.y??null,current.location?.z??null,Math.trunc(current.markerCount||0),Math.trunc(current.participantCount||0),current.endedAt||null,current.lastError||null,current.raidId);}for(const p of current.participants||[]){db.prepare(`INSERT INTO raid_participants(raid_key,player_uid,player_name,damage,item_reward,pal_reward,reward_error,first_hit_at,last_hit_at) VALUES(?,?,?,?,?,?,?,?,?) ON CONFLICT(raid_key,player_uid) DO UPDATE SET player_name=excluded.player_name,damage=excluded.damage,item_reward=excluded.item_reward,pal_reward=excluded.pal_reward,reward_error=excluded.reward_error,first_hit_at=COALESCE(raid_participants.first_hit_at,excluded.first_hit_at),last_hit_at=excluded.last_hit_at`).run(current.raidId,p.uid,p.name,Math.trunc(p.damage||0),p.itemReward||'none',p.palReward||'none',p.rewardError||null,p.firstHitAt||null,p.lastHitAt||null);}}

const transitionSeen=new Set();
async function syncRaid(){try{const current=raidFromRaw();if(!current.raidId)return;upsertRaidStatus(current);const key=`${current.raidId}:${current.state}`;if(transitionSeen.has(key))return;transitionSeen.add(key);const freshEnd=current.endedAt&&Date.now()-Date.parse(current.endedAt)<45000;if(current.state==='COMPLETED'&&freshEnd){const pending=current.participants.filter(p=>p.itemReward==='pending'||p.palReward==='pending').length;await announce(`RAID BESIEGT! ${current.displayName} wurde von ${current.participantCount} Teilnehmer${current.participantCount===1?'':'n'} bezwungen.${pending?` ${pending} Belohnung${pending===1?'':'en'} wartet wegen Offline-Spielern noch auf Zustellung.`:''}`);}else if(current.state==='FAILED'&&freshEnd){await announce(`Raid abgebrochen: ${current.displayName||current.species||'Boss'} konnte nicht korrekt gestartet werden.`);}}catch(e){console.warn('[Raids] Sync:',e.message);}}

const previousCreateServer=http.createServer.bind(http);
http.createServer=function raidCreateServer(options,requestListener){const hasOptions=typeof options!=='function',listener=hasOptions?requestListener:options;const wrapped=async(req,res)=>{let url;try{url=new URL(req.url,'http://localhost');}catch{return listener(req,res);}try{
  if((req.method==='GET'||req.method==='HEAD')&&url.pathname==='/admin/raids.html'){res.writeHead(308,{Location:`/admin/raids${url.search}`,'Cache-Control':'no-store'});return res.end();}
  if((req.method==='GET'||req.method==='HEAD')&&url.pathname==='/admin/raids'){req.url=`/admin/raids.html${url.search}`;return listener(req,res);}
  if(req.method==='GET'&&url.pathname==='/api/public/raid'){const current=raidFromRaw();return sendJson(res,200,{active:activeRaid(current),state:current.state,raidId:current.raidId||null,boss:current.species?{species:current.species,name:current.displayName,level:current.level}:null,location:activeRaid(current)?current.location:null,participantCount:current.participantCount});}
  if(!url.pathname.startsWith('/api/admin/raids'))return listener(req,res);
  if(!await requireAdmin(req,res))return;

  if(req.method==='GET'&&url.pathname==='/api/admin/raids/options'){
    const rc=raidConfig();return sendJson(res,200,{version:'0.9.14',defaults:rc.defaults||{},bosses:(rc.bosses||[]).map(b=>({...b,name:b.name||displayName(b.species)})),rewards:rc.rewards||[]});
  }
  if(req.method==='GET'&&url.pathname==='/api/admin/raids/status'){
    const core=await coreStatus(req),current=raidFromRaw();upsertRaidStatus(current);return sendJson(res,200,{version:'0.9.14',serverRunning:!!core.server?.running,onlinePlayers:(core.live?.players||[]).map(p=>({name:p.name||'',level:p.level??null,userId:p.userId||''})).filter(p=>p.name),serverMod:heartbeat(),current,history:history(20)});
  }
  if(req.method==='POST'&&url.pathname==='/api/admin/raids/start'){
    const core=await coreStatus(req);if(!core.server?.running)return sendJson(res,409,{error:'Gameserver läuft nicht.'});const players=(core.live?.players||[]).filter(p=>p.name);if(!players.length)return sendJson(res,409,{error:'Mindestens ein Spieler muss online sein, damit ein Raid sicher in einer geladenen Weltregion starten kann.'});const hb=heartbeat();if(!hb.live||!hb.raidCapable)return sendJson(res,409,{error:'PalPanelServerMods v0.2.0 ist noch nicht aktiv. Gameserver stoppen, unter Ingame-Mods aktualisieren und anschließend neu starten.'});const existing=raidFromRaw();if(activeRaid(existing))return sendJson(res,409,{error:`Es läuft bereits ein Raid (${existing.displayName||existing.species||existing.raidId}).`});
    const input=await readBody(req),rc=raidConfig(),defs=rc.defaults||{},bosses=Array.isArray(rc.bosses)?rc.bosses:[];const species=String(input.species||bosses[0]?.species||'').trim(),boss=bosses.find(b=>b.species===species);if(!boss)return sendJson(res,400,{error:'Dieser Raidboss ist nicht freigegeben.'});const anchorName=String(input.anchorName||players[0].name).trim();if(!players.some(p=>p.name===anchorName))return sendJson(res,409,{error:'Der ausgewählte Spawn-Anker ist nicht mehr online.'});const n=players.length,baseLevel=Math.trunc(clamp(input.baseLevel??defs.baseLevel??35,1,100)),perPlayer=Math.trunc(clamp(input.levelPerPlayer??defs.levelPerPlayer??5,0,20)),maxLevel=Math.trunc(clamp(input.maxLevel??defs.maxLevel??65,1,100)),basePower=Math.trunc(clamp(input.basePower??defs.basePower??55,0,100)),powerPer=Math.trunc(clamp(input.powerPerPlayer??defs.powerPerPlayer??8,0,30)),baseScale=clamp(input.baseScale??defs.baseScale??2.8,1,5),scalePer=clamp(defs.scalePerPlayer??.12,0,.5),maxScale=clamp(defs.maxScale??4,1,5),distance=clamp(input.spawnDistance??defs.spawnDistance??1800,600,5000);const level=Math.min(maxLevel,baseLevel+Math.max(0,n-1)*perPlayer),power=Math.min(100,basePower+Math.max(0,n-1)*powerPer),scale=Math.min(maxScale,baseScale+Math.max(0,n-1)*scalePer),id=raidKey(),marker=guidParts(),angle=Math.random()*Math.PI*2,rewards=Array.isArray(rc.rewards)?rc.rewards.slice(0,8):[];const params={raid_id:id,species,level,power,scale,online_players:n,anchor_name:anchorName,distance,angle,marker_a:marker.a,marker_b:marker.b,marker_c:marker.c,marker_d:marker.d};rewards.forEach((r,i)=>{params[`reward_${i+1}_item`]=r.item;params[`reward_${i+1}_count`]=Math.trunc(Number(r.count)||0);});const result=await sendCommand('start_raid',params,18000);if(!result.ok)return sendJson(res,502,{error:result.message||'Raidboss konnte nicht erzeugt werden.',result});const current=raidFromRaw();upsertRaidStatus(current);const name=boss.name||displayName(species);const markerText=Number(result.marker_count||0)>0?'Die Position wurde auf der Karte markiert.':'Kartenmarker konnte nicht bestätigt werden – achtet auf die Servermeldung.';await announce(`RAID! ${name} Lv.${level} ist erschienen. ${markerText}`);return sendJson(res,201,{ok:true,raid:{...current,displayName:name},calculated:{onlinePlayers:n,level,power,scale},rewards,result});
  }
  if(req.method==='POST'&&url.pathname==='/api/admin/raids/cancel'){
    const current=raidFromRaw();if(!activeRaid(current))return sendJson(res,409,{error:'Es läuft aktuell kein Raid.'});const result=await sendCommand('cancel_raid',{},10000);if(!result.ok)return sendJson(res,502,{error:result.message||'Raid konnte nicht abgebrochen werden.'});transitionSeen.add(`${current.raidId}:CANCELLED`);await announce(`Raid ${current.displayName||current.species} wurde vom Serverteam beendet.`);await new Promise(r=>setTimeout(r,250));const next=raidFromRaw();upsertRaidStatus(next);return sendJson(res,200,{ok:true,current:next,result});
  }
  return sendJson(res,404,{error:'Raid route not found'});
}catch(err){console.error('[Raids]',err);if(!res.headersSent)return sendJson(res,500,{error:err.message||'Raid-System Fehler'});try{res.end();}catch{}}};return hasOptions?previousCreateServer(options,wrapped):previousCreateServer(wrapped);};

setTimeout(syncRaid,2500).unref?.();
const raidSyncTimer=setInterval(syncRaid,2000);raidSyncTimer.unref?.();
console.log('PalPanel v0.9.14 Raid-System geladen.');
console.log(`Raid IPC: ${RAID_STATUS_FILE}`);
require('./server-v0913.js');
