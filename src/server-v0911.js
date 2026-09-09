const fs=require('fs');
const path=require('path');
const http=require('http');
const {DatabaseSync}=require('node:sqlite');

const APP_DIR=path.resolve(__dirname,'..');
const defaults=JSON.parse(fs.readFileSync(path.join(APP_DIR,'config','default.json'),'utf8'));
const DATA_DIR=defaults.paths.data;
const DB_FILE=path.join(DATA_DIR,'palpanel.db');
const MISSION_FILE=path.join(DATA_DIR,'missions.json');
const SEASON_FILE=path.join(DATA_DIR,'season.json');
let database=null;

function db(){if(!database){database=new DatabaseSync(DB_FILE,{timeout:5000});try{database.exec('PRAGMA journal_mode = WAL;');}catch{}}return database;}
const num=v=>Number(v||0);
const clamp=(v,min,max)=>Math.max(min,Math.min(max,Number(v)||0));
function safeGet(sql,...p){try{return db().prepare(sql).get(...p)||null;}catch{return null;}}
function safeAll(sql,...p){try{return db().prepare(sql).all(...p);}catch{return [];}}
function sendJson(res,status,body){const data=Buffer.from(JSON.stringify(body));res.writeHead(status,{'Content-Type':'application/json; charset=utf-8','Content-Length':data.length,'Cache-Control':'no-store'});res.end(data);}
function sendHtml(res,html){const data=Buffer.from(html);res.writeHead(200,{'Content-Type':'text/html; charset=utf-8','Content-Length':data.length,'Cache-Control':'no-cache'});res.end(data);}
function loadJson(file,fallback={}){try{return JSON.parse(fs.readFileSync(file,'utf8'));}catch{return fallback;}}
function validDate(v){const n=Date.parse(v||'');return Number.isFinite(n)?n:null;}
function pctChange(current,previous){current=num(current);previous=num(previous);if(previous===0)return current===0?0:null;return (current-previous)/previous*100;}
function daysBetween(a,b){return Math.max(0,(Number(b)-Number(a))/86400000);}
function displayName(userId){const r=safeGet(`SELECT COALESCE(NULLIF(l.palworld_name,''),'Entdecker #'||u.id) AS name,l.level AS level,l.last_seen_at AS lastSeen FROM users u LEFT JOIN player_links l ON l.user_id=u.id WHERE u.id=?`,Number(userId));return r||{name:`Entdecker #${userId}`,level:null,lastSeen:null};}

async function requireAdmin(req,res){
  try{
    const local=loadJson(path.join(DATA_DIR,'config.json'),{});
    const port=local.panel?.port||defaults.panel?.port||8787;
    const response=await fetch(`http://127.0.0.1:${port}/api/admin/session`,{headers:{Cookie:String(req.headers.cookie||''),Accept:'application/json'},signal:AbortSignal.timeout(4000)});
    const body=await response.json().catch(()=>({}));
    if(!response.ok||!body.authenticated){sendJson(res,401,{error:'Nicht angemeldet.'});return false;}
    return true;
  }catch{sendJson(res,401,{error:'Admin-Sitzung konnte nicht geprüft werden.'});return false;}
}

function eventMetrics(start,end){
  const cap=safeGet(`SELECT COUNT(*) AS captures,COUNT(DISTINCT species_key) AS uniqueSpecies,COALESCE(SUM(CASE WHEN is_alpha=1 THEN 1 ELSE 0 END),0) AS alphas FROM pal_captures WHERE captured_at>=? AND captured_at<?`,start,end)||{};
  const boss=safeGet('SELECT COUNT(*) AS bosses FROM boss_completions WHERE completed_at>=? AND completed_at<?',start,end)||{};
  const ids=new Set();
  safeAll('SELECT DISTINCT user_id AS id FROM pal_captures WHERE captured_at>=? AND captured_at<?',start,end).forEach(r=>ids.add(num(r.id)));
  safeAll('SELECT DISTINCT user_id AS id FROM boss_completions WHERE completed_at>=? AND completed_at<?',start,end).forEach(r=>ids.add(num(r.id)));
  return{captures:num(cap.captures),uniqueSpecies:num(cap.uniqueSpecies),alphas:num(cap.alphas),bosses:num(boss.bosses),activePlayers:[...ids].filter(Boolean).length,participantIds:[...ids].filter(Boolean),events:num(cap.captures)+num(boss.bosses)};
}

function userMetrics(start,end){
  const map=new Map();
  const get=id=>{id=num(id);if(!map.has(id))map.set(id,{userId:id,captures:0,uniqueSpecies:0,alphas:0,bosses:0});return map.get(id);};
  for(const r of safeAll(`SELECT user_id AS userId,COUNT(*) AS captures,COUNT(DISTINCT species_key) AS uniqueSpecies,COALESCE(SUM(CASE WHEN is_alpha=1 THEN 1 ELSE 0 END),0) AS alphas FROM pal_captures WHERE captured_at>=? AND captured_at<? GROUP BY user_id`,start,end)){const x=get(r.userId);x.captures=num(r.captures);x.uniqueSpecies=num(r.uniqueSpecies);x.alphas=num(r.alphas);}
  for(const r of safeAll('SELECT user_id AS userId,COUNT(*) AS bosses FROM boss_completions WHERE completed_at>=? AND completed_at<? GROUP BY user_id',start,end)){get(r.userId).bosses=num(r.bosses);}
  for(const x of map.values())x.score=x.captures+x.uniqueSpecies*3+x.alphas*6+x.bosses*12;
  return map;
}

function previousActivity(userId,before){
  const a=safeGet('SELECT MAX(captured_at) AS at FROM pal_captures WHERE user_id=? AND captured_at<?',Number(userId),before)?.at;
  const b=safeGet('SELECT MAX(completed_at) AS at FROM boss_completions WHERE user_id=? AND completed_at<?',Number(userId),before)?.at;
  const ta=validDate(a)||0,tb=validDate(b)||0;return Math.max(ta,tb)||null;
}

function dailyTimeline(startMs,days=14){
  const end=new Date().toISOString(),start=new Date(startMs).toISOString();
  const buckets=new Map();
  for(let i=0;i<days;i++){const d=new Date(startMs+i*86400000).toISOString().slice(0,10);buckets.set(d,{date:d,captures:0,alphas:0,bosses:0});}
  for(const r of safeAll(`SELECT substr(captured_at,1,10) AS day,COUNT(*) AS captures,COALESCE(SUM(CASE WHEN is_alpha=1 THEN 1 ELSE 0 END),0) AS alphas FROM pal_captures WHERE captured_at>=? AND captured_at<? GROUP BY substr(captured_at,1,10)`,start,end)){if(buckets.has(r.day)){const x=buckets.get(r.day);x.captures=num(r.captures);x.alphas=num(r.alphas);}}
  for(const r of safeAll(`SELECT substr(completed_at,1,10) AS day,COUNT(*) AS bosses FROM boss_completions WHERE completed_at>=? AND completed_at<? GROUP BY substr(completed_at,1,10)`,start,end)){if(buckets.has(r.day))buckets.get(r.day).bosses=num(r.bosses);}
  return[...buckets.values()].map(x=>({...x,total:x.captures+x.bosses}));
}

function isoWeek(date=new Date()){
  const local=new Date(date.getFullYear(),date.getMonth(),date.getDate());const day=(local.getDay()+6)%7;const monday=new Date(local);monday.setDate(local.getDate()-day);monday.setHours(0,0,0,0);const end=new Date(monday);end.setDate(monday.getDate()+7);const thursday=new Date(monday);thursday.setDate(monday.getDate()+3);const first=new Date(thursday.getFullYear(),0,4);const fd=(first.getDay()+6)%7;first.setDate(first.getDate()-fd+3);first.setHours(0,0,0,0);const week=1+Math.round((thursday-first)/604800000);return{year:thursday.getFullYear(),week,key:`${thursday.getFullYear()}-W${String(week).padStart(2,'0')}`,label:`KW ${String(week).padStart(2,'0')}`,start:monday.toISOString(),end:end.toISOString(),startMs:monday.getTime(),endMs:end.getTime()};
}
const VARIANTS={captures:[['Fangrunde',12],['Große Fangtour',20],['Fangmarathon',30]],uniqueSpecies:[['Paldex-Streifzug',6],['Artenforscher',10],['Paldex-Woche',15]],alphaCaptures:[['Alpha-Kontakt',1],['Alpha-Jagd',3],['Alpha-Elite',5]],bosses:[['Bossprobe',1],['Bossjäger',2],['Bossbrecher',3]],expeditionScore:[['Expeditionsdrang',45],['Große Expedition',80],['Palpagos-Intensiv',130]]};
function missionSet(week,cfg){return Object.keys(VARIANTS).map((metric,i)=>{const [title,base]=VARIANTS[metric][(week.week+i*2)%3];return{metric,title,target:Math.max(1,Math.round(base*(Number(cfg.targetMultiplier)||1)))};});}
function missionAnalysis(nowMs){
  const cfg={enabled:true,targetMultiplier:1,rewardMultiplier:1,completionBonus:250,...loadJson(MISSION_FILE,{})};
  const week=isoWeek(new Date(nowMs));const users=userMetrics(week.start,week.end);const missions=missionSet(week,cfg);let completed=0,progressSum=0;
  const rows=[];
  for(const x of users.values()){
    let userCompleted=0,userProgress=0;
    for(const m of missions){const value=m.metric==='captures'?x.captures:m.metric==='uniqueSpecies'?x.uniqueSpecies:m.metric==='alphaCaptures'?x.alphas:m.metric==='bosses'?x.bosses:x.score;const progress=clamp(value/m.target*100,0,100);progressSum+=progress;userProgress+=progress;if(value>=m.target){completed++;userCompleted++;}}
    const info=displayName(x.userId);rows.push({userId:x.userId,name:info.name,completed:userCompleted,progress:userProgress/missions.length,score:x.score});
  }
  rows.sort((a,b)=>b.completed-a.completed||b.progress-a.progress||b.score-a.score);
  const participants=users.size,totalSlots=participants*missions.length,avgProgress=totalSlots?progressSum/totalSlots:0,completionRate=totalSlots?completed/totalSlots*100:0;
  const claimed=num(safeGet('SELECT COUNT(*) AS n FROM weekly_mission_claims WHERE week_key=?',week.key)?.n),heroes=num(safeGet('SELECT COUNT(*) AS n FROM weekly_mission_titles WHERE week_key=?',week.key)?.n);
  const elapsed=clamp((nowMs-week.startMs)/(week.endMs-week.startMs)*100,0,100);
  let difficulty='balanced';
  if(participants>=2&&elapsed>30&&avgProgress<elapsed*.55)difficulty='hard';
  else if(participants>=2&&elapsed<78&&avgProgress>Math.min(92,elapsed*1.45+12))difficulty='easy';
  return{enabled:cfg.enabled!==false,week,participants,missions,averageProgress:avgProgress,completionRate,claimed,heroes,elapsed,difficulty,leaderboard:rows.slice(0,8)};
}

function seasonMetric(kind,s){
  const start=s.startAt&&validDate(s.startAt)?new Date(validDate(s.startAt)).toISOString():null;
  const end=s.endAt&&validDate(s.endAt)?new Date(validDate(s.endAt)).toISOString():null;
  if(kind==='bosses'){
    const parts=[],p=[];if(start){parts.push('completed_at>=?');p.push(start);}if(end){parts.push('completed_at<=?');p.push(end);}return num(safeGet(`SELECT COUNT(*) AS n FROM boss_completions${parts.length?' WHERE '+parts.join(' AND '):''}`,...p)?.n);
  }
  const parts=[],p=[];if(start){parts.push('captured_at>=?');p.push(start);}if(end){parts.push('captured_at<=?');p.push(end);}const expr=kind==='captures'?'COUNT(*)':kind==='alphas'?'COALESCE(SUM(CASE WHEN is_alpha=1 THEN 1 ELSE 0 END),0)':'COUNT(DISTINCT species_key)';return num(safeGet(`SELECT ${expr} AS n FROM pal_captures${parts.length?' WHERE '+parts.join(' AND '):''}`,...p)?.n);
}
function seasonAnalysis(nowMs){
  const s=loadJson(SEASON_FILE,null);if(!s)return{available:false};
  const goals=s.communityGoals||{};const defs=[['captures','Fänge','captures'],['uniqueSpecies','Pal-Arten','uniqueSpecies'],['alphaCaptures','Alpha-Fänge','alphas'],['bosses','Bosse','bosses']];
  const rows=defs.map(([key,label,metric])=>{const current=seasonMetric(metric,s),target=Math.max(1,num(goals[key]));return{key,label,current,target,progress:clamp(current/target*100,0,100)};});
  const progress=rows.length?Math.min(...rows.map(r=>r.progress)):0;const bottleneck=[...rows].sort((a,b)=>a.progress-b.progress)[0]||null;const start=validDate(s.startAt),end=validDate(s.endAt);let elapsed=null,daysRemaining=null,pace='unknown';
  if(start&&end&&end>start){elapsed=clamp((nowMs-start)/(end-start)*100,0,100);daysRemaining=Math.max(0,(end-nowMs)/86400000);if(progress+15<elapsed)pace='behind';else if(progress>elapsed+10)pace='ahead';else pace='on-track';}
  const state=s.active===false?'inactive':start&&nowMs<start?'upcoming':end&&nowMs>end?'ended':'active';
  return{available:true,id:s.id||'',title:s.title||'Community-Event',state,progress,elapsed,daysRemaining,pace,bottleneck,goals:rows};
}

function playerWatch(currentStart,currentEnd,currentUsers,previousUsers){
  const now=Date.parse(currentEnd);const linked=safeAll('SELECT user_id AS userId,palworld_name AS name,level,last_seen_at AS lastSeen FROM player_links WHERE last_seen_at IS NOT NULL');
  const inactive=linked.map(r=>({...r,userId:num(r.userId),name:r.name||`Entdecker #${r.userId}`,daysAway:daysBetween(validDate(r.lastSeen)||now,now)})).filter(r=>r.daysAway>=7).sort((a,b)=>b.daysAway-a.daysAway).slice(0,10);
  const inactive14=linked.filter(r=>daysBetween(validDate(r.lastSeen)||now,now)>=14).length;
  const returners=[],newPlayers=[];
  for(const x of currentUsers.values()){
    const prior=previousActivity(x.userId,currentStart);const info=displayName(x.userId);
    if(!prior)newPlayers.push({userId:x.userId,name:info.name,score:x.score});
    else{const gap=daysBetween(prior,Date.parse(currentStart));if(gap>=7)returners.push({userId:x.userId,name:info.name,gapDays:gap,score:x.score});}
  }
  const top=[];let totalScore=0;
  for(const x of currentUsers.values()){const prev=previousUsers.get(x.userId);const info=displayName(x.userId);totalScore+=x.score;top.push({userId:x.userId,name:info.name,score:x.score,previousScore:prev?.score||0,delta:x.score-(prev?.score||0),captures:x.captures,alphas:x.alphas,bosses:x.bosses});}
  top.sort((a,b)=>b.score-a.score||b.delta-a.delta);
  return{linkedPlayers:linked.length,inactiveCount:inactive.length,inactive14Count:inactive14,inactive,returners:returners.slice(0,8),newPlayers:newPlayers.slice(0,8),topPerformers:top.slice(0,8),topShare:totalScore>0&&top[0]?top[0].score/totalScore*100:0,totalScore};
}

function insightPayload(){
  const nowMs=Date.now(),nowIso=new Date(nowMs).toISOString();const currentStart=new Date(nowMs-7*86400000).toISOString(),previousStart=new Date(nowMs-14*86400000).toISOString();
  const current=eventMetrics(currentStart,nowIso),previous=eventMetrics(previousStart,currentStart);const currentUsers=userMetrics(currentStart,nowIso),previousUsers=userMetrics(previousStart,currentStart);const missions=missionAnalysis(nowMs),season=seasonAnalysis(nowMs),watch=playerWatch(currentStart,nowIso,currentUsers,previousUsers);const timeline=dailyTimeline(nowMs-13*86400000,14);
  const trends={activePlayers:pctChange(current.activePlayers,previous.activePlayers),captures:pctChange(current.captures,previous.captures),alphas:pctChange(current.alphas,previous.alphas),bosses:pctChange(current.bosses,previous.bosses),events:pctChange(current.events,previous.events)};
  const insights=[];const add=(level,category,title,message,action,metric)=>insights.push({level,category,title,message,action,metric});

  if(previous.activePlayers>=3&&current.activePlayers<=previous.activePlayers*.5)add('critical','Aktivität','Aktive Community deutlich eingebrochen',`Nur ${current.activePlayers} Spieler erzeugten in den letzten sieben Tagen Aktivität; zuvor waren es ${previous.activePlayers}.`,'Plane kurzfristig ein gemeinsames Event oder sprich zuletzt aktive Spieler gezielt an.',`${Math.round(trends.activePlayers||0)} %`);
  else if(previous.activePlayers>=3&&current.activePlayers<previous.activePlayers*.7)add('warning','Aktivität','Aktivität geht zurück',`${current.activePlayers} aktive Spieler gegenüber ${previous.activePlayers} im Vergleichszeitraum.`,'Ein kleiner Community-Anreiz oder ein angekündigter Abend kann den Rückgang früh abfangen.',`${Math.round(trends.activePlayers||0)} %`);
  else if(current.activePlayers>=3&&trends.activePlayers!=null&&trends.activePlayers>=30)add('positive','Aktivität','Mehr Spieler sind aktiv',`Die Zahl aktiver Spieler ist von ${previous.activePlayers} auf ${current.activePlayers} gestiegen.`,'Nutze den Aufschwung für ein gemeinsames Ziel oder eine neue Challenge.',`+${Math.round(trends.activePlayers)} %`);

  if(previous.captures>=10&&current.captures<previous.captures*.6)add('warning','Gameplay','Fangaktivität sinkt',`In sieben Tagen wurden ${current.captures} Pals gefangen; zuvor waren es ${previous.captures}.`,'Eine Sammel-Challenge oder ein Paldex-Ziel würde genau diesen Bereich wieder anstoßen.',`${Math.round(trends.captures||0)} %`);
  if(previous.alphas>=3&&current.alphas<previous.alphas*.5)add('warning','Gameplay','Alpha-Jagd verliert Tempo',`${current.alphas} Alpha-Fänge gegenüber ${previous.alphas} im vorherigen Zeitraum.`,'Starte eine Alpha-Jagd oder erhöhe temporär den Alpha-Anreiz bei den Wochenmissionen.',`${Math.round(trends.alphas||0)} %`);
  if(previous.bosses>=3&&current.bosses<previous.bosses*.5)add('warning','Gameplay','Boss-Aktivität ist eingebrochen',`${current.bosses} Boss-Abschlüsse gegenüber ${previous.bosses} in den sieben Tagen davor.`,'Ein gemeinsamer Bossabend oder eine Boss-Wochenmission wäre aktuell sinnvoll.',`${Math.round(trends.bosses||0)} %`);

  if(missions.participants>=2&&missions.difficulty==='hard')add('warning','Missionen','Wochenmissionen wirken zu schwer',`Die Woche ist zu ${Math.round(missions.elapsed)} % vorbei, der mittlere Missionsfortschritt liegt aber erst bei ${Math.round(missions.averageProgress)} %.`,'Senke den Ziel-Multiplikator leicht oder belasse die Werte und beobachte noch einen Tag.',`${Math.round(missions.averageProgress)} % Fortschritt`);
  else if(missions.participants>=2&&missions.difficulty==='easy')add('info','Missionen','Wochenmissionen werden sehr schnell erledigt',`Bei ${Math.round(missions.elapsed)} % vergangener Woche liegt der mittlere Fortschritt bereits bei ${Math.round(missions.averageProgress)} %.`,'Wenn du längere Motivation willst, erhöhe den Ziel-Multiplikator für die nächste Woche leicht.',`${Math.round(missions.completionRate)} % abgeschlossen`);
  else if(missions.participants>=2)add('positive','Missionen','Wochenmissionen liegen im gesunden Bereich',`${missions.participants} Teilnehmer kommen im Mittel auf ${Math.round(missions.averageProgress)} % Fortschritt.`,'Keine Anpassung nötig; die aktuelle Schwierigkeit wirkt passend.',`${Math.round(missions.averageProgress)} %`);

  if(season.available&&season.state==='active'&&season.pace==='behind')add('warning','Saison','Community-Saison liegt hinter dem Zeitplan',`Der schwächste Zielbereich steht bei ${Math.round(season.progress)} %, während bereits ${Math.round(season.elapsed)} % der Saisonzeit vergangen sind. Engpass: ${season.bottleneck?.label||'—'}.`,'Plane ein Event gezielt für den Engpass oder passe das betroffene Community-Ziel an.',`${Math.round(season.progress)} %`);
  else if(season.available&&season.state==='active'&&season.pace==='ahead')add('positive','Saison','Saison liegt vor dem Zeitplan',`Community-Fortschritt ${Math.round(season.progress)} % bei ${Math.round(season.elapsed)} % vergangener Zeit.`,'Du kannst die aktuelle Pace beibehalten oder für den Endspurt ein Bonusziel vorbereiten.',`${Math.round(season.progress)} %`);

  if(watch.linkedPlayers>=4&&watch.inactive14Count/watch.linkedPlayers>=.3)add('warning','Bindung','Viele verknüpfte Spieler sind länger inaktiv',`${watch.inactive14Count} von ${watch.linkedPlayers} verbundenen Spielern wurden seit mindestens 14 Tagen nicht gesehen.`,'Ein Rückkehrer-Event oder eine kurze Community-Ankündigung könnte verlorene Spieler reaktivieren.',`${Math.round(watch.inactive14Count/watch.linkedPlayers*100)} %`);
  if(watch.returners.length)add('positive','Bindung','Rückkehrer sind wieder aktiv',`${watch.returners.length} Spieler haben nach mindestens einer Woche Aktivitätspause wieder Gameplay erzeugt.`,'Nutze den Moment: Rückkehrer reagieren oft gut auf klare aktuelle Ziele und Gruppenaktivitäten.',`${watch.returners.length} Rückkehrer`);
  if(watch.newPlayers.length)add('info','Community','Neue Spieleraktivität erkannt',`${watch.newPlayers.length} Spieler tauchen erstmals in den erfassten Gameplay-Ereignissen auf.`,'Prüfe, ob Einstieg, Regeln und aktuelle Ziele für Neulinge gut sichtbar sind.',`${watch.newPlayers.length} neu`);
  if(watch.topPerformers.length>=4&&watch.topShare>=45)add('info','Wettbewerb','Aktivität konzentriert sich stark auf einen Spieler',`${watch.topPerformers[0].name} erzeugt rund ${Math.round(watch.topShare)} % des gewichteten 7-Tage-Aktivitätsscores.`,'Neben Ranglisten auch kooperative Ziele betonen, damit die Motivation breiter verteilt bleibt.',`${Math.round(watch.topShare)} % Anteil`);
  if(current.events<8)add('info','Datenbasis','Noch wenig Daten für starke Trend-Aussagen',`In den letzten sieben Tagen liegen nur ${current.events} relevante Fang-/Boss-Ereignisse vor.`,'Trends als Hinweis lesen und nach mehr Spielaktivität erneut prüfen.',`${current.events} Ereignisse`);

  const priority={critical:0,warning:1,info:2,positive:3};insights.sort((a,b)=>priority[a.level]-priority[b.level]);
  let score=100;for(const i of insights){if(i.level==='critical')score-=24;else if(i.level==='warning')score-=11;}score=clamp(score,0,100);const attentionCount=insights.filter(i=>i.level==='critical'||i.level==='warning').length;const status=score>=85?'STABIL':score>=65?'BEOBACHTEN':'HANDLUNGSBEDARF';
  return{updatedAt:nowIso,window:{currentStart,currentEnd:nowIso,previousStart,previousEnd:currentStart},health:{score,status,attentionCount},current,previous,trends,timeline,missions,season,watch,insights};
}

function insightsPage(){
  return `<!doctype html><html lang="de"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>PalPanel Admin · Community Insights</title><link rel="stylesheet" href="/admin/admin.css"><link rel="stylesheet" href="/admin/wow.css?v=0980"><link rel="stylesheet" href="/admin/v098.css?v=0980"><link rel="stylesheet" href="/admin/insights.css?v=0911"><script defer src="/admin/v098-state.js?v=0980"></script></head><body data-page="insights"><div class="shell"><aside class="sidebar"><div class="brand"><span class="brand-mark">P</span><div><strong>PalPanel</strong><small>ADMIN-BEREICH</small></div></div><nav></nav><button id="logoutBtn" class="ghost hidden">Abmelden</button></aside><main class="content"><section id="loginView" class="login-card"><span class="eyebrow">ADMIN-ANMELDUNG</span><h1>PalPanel-Verwaltung</h1><p>Melde dich an, um die Community-Auswertung zu öffnen.</p><form id="loginForm"><label>Benutzer<input id="username" value="admin" autocomplete="username"></label><label>Passwort<input id="password" type="password" autocomplete="current-password"></label><button class="btn primary">Anmelden</button></form><div id="loginError" class="error"></div></section><section id="adminView" class="hidden"><div class="page-head insights-head"><div><span class="eyebrow">COMMUNITY INTELLIGENCE</span><h1>Was braucht deine Community?</h1><p>Automatische 7-Tage-Auswertung aus echter PalPanel-Telemetrie – mit Trends und konkreten Handlungsvorschlägen.</p></div><div class="actions"><span id="insightsUpdated" class="version">Lade…</span><button id="refreshInsights" class="btn">Neu auswerten</button></div></div><section class="stats insights-stats"><article class="card health-card"><span>COMMUNITY HEALTH</span><strong id="healthScore">—</strong><small id="healthStatus">—</small></article><article class="card"><span>AKTIVE SPIELER · 7 TAGE</span><strong id="activePlayers">—</strong><small id="activeTrend">—</small></article><article class="card"><span>AKTIVITÄTEN</span><strong id="activityEvents">—</strong><small id="activityTrend">Fänge + Bosse</small></article><article class="card"><span>AUFMERKSAMKEIT</span><strong id="attentionCount">—</strong><small>Hinweise mit Handlungsbedarf</small></article></section><section class="insight-layout"><div class="insight-main"><section class="card insight-card"><div class="section-head"><div><span class="eyebrow">PALPANEL-AUSWERTUNG</span><h2>Erkenntnisse & Empfehlungen</h2></div><span id="insightCount" class="version">—</span></div><div id="insightList" class="insight-list"></div></section><section class="card trend-card"><div class="section-head"><div><span class="eyebrow">14-TAGE-VERLAUF</span><h2>Community-Aktivität</h2></div></div><div id="timelineChart" class="timeline-chart"></div><div class="trend-legend"><span><i class="capture"></i>Fänge</span><span><i class="boss"></i>Bosse</span></div></section></div><div class="insight-side"><section class="card"><div class="section-head"><div><span class="eyebrow">7 TAGE VS. DAVOR</span><h2>Gameplay-Trends</h2></div></div><div id="trendGrid" class="insight-trend-grid"></div></section><section class="card"><div class="section-head"><div><span class="eyebrow">WOCHENMISSIONEN</span><h2>Schwierigkeit</h2></div></div><div id="missionInsight" class="meter-block"></div></section><section class="card"><div class="section-head"><div><span class="eyebrow">COMMUNITY-EVENT</span><h2>Saison-Pace</h2></div></div><div id="seasonInsight" class="meter-block"></div></section></div></section><section class="watch-grid"><article class="card"><div class="section-head"><div><span class="eyebrow">TOP-PERFORMER</span><h2>Wer gerade Tempo macht</h2></div></div><div id="topPerformers" class="watch-list"></div></article><article class="card"><div class="section-head"><div><span class="eyebrow">RÜCKKEHRER & NEUE</span><h2>Frische Aktivität</h2></div></div><div id="returners" class="watch-list"></div></article><article class="card"><div class="section-head"><div><span class="eyebrow">INAKTIVITÄT</span><h2>Spieler im Blick behalten</h2></div></div><div id="inactivePlayers" class="watch-list"></div></article></section></section></main></div><div id="toast" class="toast"></div><script src="/admin/nav.js"></script><script src="/admin/admin.js"></script><script src="/admin/insights.js?v=0911"></script></body></html>`;
}

const previousCreateServer=http.createServer.bind(http);
http.createServer=function insightsCreateServer(options,requestListener){
  const hasOptions=typeof options!=='function',listener=hasOptions?requestListener:options;
  const wrapped=async(req,res)=>{let url;try{url=new URL(req.url,'http://localhost');}catch{return listener(req,res);}try{
    if((req.method==='GET'||req.method==='HEAD')&&(url.pathname==='/admin/insights'||url.pathname==='/admin/insights.html'))return sendHtml(res,insightsPage());
    if(req.method==='GET'&&url.pathname==='/api/admin/insights'){if(!await requireAdmin(req,res))return;return sendJson(res,200,insightPayload());}
  }catch(err){console.warn('[Insights]',err.message);if(!res.headersSent)return sendJson(res,500,{error:`Insights konnten nicht berechnet werden: ${err.message}`});}
  return listener(req,res);};
  return hasOptions?previousCreateServer(options,wrapped):previousCreateServer(wrapped);
};

console.log('PalPanel v0.9.11 Admin Community Insights geladen.');
require('./server-v0910.js');
