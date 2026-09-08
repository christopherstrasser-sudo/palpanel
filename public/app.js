const $ = s => document.querySelector(s);
let currentStatus = null;

async function request(url) {
  const res = await fetch(url, { headers: { Accept: 'application/json' } });
  const data = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(data.error || `HTTP ${res.status}`);
  return data;
}
function setText(id, value) { const el = document.getElementById(id); if (el) el.textContent = value; }
function countdown(event) {
  const now=Date.now(), start=event.startAt?new Date(event.startAt).getTime():null, end=event.endAt?new Date(event.endAt).getTime():null;
  let target=null,label='EVENTZEIT NOCH NICHT GESETZT';
  if(start&&now<start){target=start;label='START IN';} else if(end&&now<end){target=end;label='EVENT ENDET IN';} else if(end&&now>=end){label='EVENT BEENDET';} else if(start&&now>=start){label='EVENT LÄUFT';}
  setText('countdownLabel',label); if(!target)return setText('countdown','-- : -- : -- : --');
  const delta=Math.max(0,target-now),days=Math.floor(delta/86400000),hours=Math.floor(delta/3600000)%24,minutes=Math.floor(delta/60000)%60,seconds=Math.floor(delta/1000)%60;
  setText('countdown',[days,hours,minutes,seconds].map(v=>String(v).padStart(2,'0')).join(' : '));
}
function formatUptime(seconds) {
  if (!Number.isFinite(Number(seconds))) return '—';
  const s=Number(seconds), d=Math.floor(s/86400), h=Math.floor(s/3600)%24, m=Math.floor(s/60)%60;
  return d>0 ? `${d}T ${h}Std.` : `${h}Std. ${m}Min.`;
}
function formatPlaytime(seconds){const s=Math.max(0,Number(seconds)||0),h=Math.floor(s/3600),m=Math.floor(s/60)%60;return `${h}Std. ${String(m).padStart(2,'0')}Min.`;}
function escapeHtml(value){return String(value??'').replace(/[&<>'"]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;',"'":'&#39;','"':'&quot;'}[c]));}
function renderPlayers(players=[]) {
  const wrap=$('#onlinePlayers'); if(!wrap)return;
  setText('playersHint', players.length ? `${players.length} AKTIV` : 'NIEMAND AKTIV');
  if(!players.length){wrap.innerHTML='<div class="ranking-row"><span>—</span><strong>Niemand aktiv</strong><em>0</em></div>';return;}
  wrap.innerHTML=players.map((p,i)=>`<div class="ranking-row"><span>${String(i+1).padStart(2,'0')}</span><strong>${escapeHtml(p.name)} <small>Stufe ${p.level||'—'}</small></strong><em>${p.ping==null?'—':`${Math.round(p.ping)} ms`}</em></div>`).join('');
}
function renderMap(players=[]) {
  const map=$('#liveMap'); if(!map)return;
  map.querySelectorAll('.player-dot').forEach(e=>e.remove());
  const empty=$('#mapEmpty');
  if(!players.length){if(empty)empty.style.display='block';return;}
  if(empty)empty.style.display='none';
  const xs=players.map(p=>Number(p.location_x)||0), ys=players.map(p=>Number(p.location_y)||0);
  const maxAbs=Math.max(1,...xs.map(Math.abs),...ys.map(Math.abs));
  for(const p of players){
    const x=50+(Number(p.location_x)||0)/maxAbs*42, y=50-(Number(p.location_y)||0)/maxAbs*42;
    const dot=document.createElement('div'); dot.className='player-dot'; dot.style.left=`${Math.max(4,Math.min(96,x))}%`; dot.style.top=`${Math.max(4,Math.min(96,y))}%`; dot.title=`${p.name} · Stufe ${p.level||'—'} · ${Math.round(Number(p.location_x)||0)}, ${Math.round(Number(p.location_y)||0)}`;
    dot.innerHTML=`<span></span><b>${escapeHtml(p.name)}</b>`; map.appendChild(dot);
  }
}
function render(data){
  currentStatus=data; const s=data.server, p=data.palworld||{};
  setText('eventTitle',data.event.title||'Palworld-Gemeinschaftsevent');
  setText('serverState',s.running?'ONLINE':'OFFLINE');
  setText('serverName',p.name||'Palworld-Server');
  setText('serverDescription',p.description||'Eine gemeinsame Welt, aktuelle Spielerdaten, Ranglisten und dein persönlicher Fortschritt an einem Ort.');
  setText('playerCount',Number.isFinite(Number(p.currentPlayers))?p.currentPlayers:'—');
  setText('maxPlayers',`von ${p.maxPlayers||32} Plätzen`);
  setText('serverFps',p.fps==null?'—':Math.round(Number(p.fps)));
  setText('frameTime',p.frameTime==null?'Server-FPS':`${Number(p.frameTime).toFixed(1)} ms Bildzeit`);
  setText('serverUptime',formatUptime(p.uptime));
  setText('gameVersion',p.version||'Palworld');
  const chip=$('#apiChip'); if(chip){chip.textContent=data.live.connected?'AKTUELLE DATEN AKTIV':'AKTUELLE DATEN NICHT VERFÜGBAR';chip.classList.toggle('online',!!data.live.connected)}
  const pill=$('#serverPill'); if(pill){pill.className=`server-chip ${s.running?'online':'offline'}`;setText('serverPillText',s.running?'Server online':'Server offline')}
  renderPlayers(data.players||[]); renderMap(data.players||[]); countdown(data.event);
}
function rankingAvatar(row={}){
  const initial=escapeHtml(String(row.name||'?').trim().charAt(0).toUpperCase()||'?');
  const avatarUrl=String(row.avatarUrl||'');
  const safeUrl=/^\/api\/steam\/avatar\/\d{17}$/.test(avatarUrl)?avatarUrl:'';
  return `<span class="rank-steam-avatar"><span>${initial}</span>${safeUrl?`<img src="${safeUrl}" alt="" loading="lazy" onload="this.parentElement.classList.add('loaded')" onerror="this.remove()">`:''}</span>`;
}
function renderLeaderboard(rows=[]){
  const wrap=$('#publicLeaderboard'); if(!wrap)return;
  if(!rows.length){wrap.innerHTML='<div class="public-rank empty"><b>—</b><strong>Noch keine Ranglistendaten</strong><i>0</i></div>';return;}
  wrap.innerHTML=rows.slice(0,6).map((row,i)=>`<div class="public-rank"><b>${String(i+1).padStart(2,'0')}</b>${rankingAvatar(row)}<strong>${escapeHtml(row.name)}<small>${Number(row.uniquePals||0)} Pal-Arten · ${formatPlaytime(row.playtimeSeconds)}</small></strong><i>${Number(row.eventScore||0).toLocaleString('de-DE')}</i></div>`).join('');
}
async function refresh(){try{render(await request('/api/public/status'))}catch{setText('serverPillText','PalPanel nicht erreichbar');const p=$('#serverPill');if(p)p.className='server-chip offline'}}
async function refreshLeaderboard(){try{const d=await request('/api/public/leaderboard');renderLeaderboard(d.leaderboard||[])}catch{renderLeaderboard([])}}
setInterval(()=>currentStatus&&countdown(currentStatus.event),1000);
setInterval(refresh,4000);
setInterval(refreshLeaderboard,10000);
refresh();refreshLeaderboard();
