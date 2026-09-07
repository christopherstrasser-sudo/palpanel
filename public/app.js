const $ = (s) => document.querySelector(s);
let currentStatus = null;

async function request(url) {
  const res = await fetch(url, { headers: { 'Accept': 'application/json' } });
  const data = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(data.error || `HTTP ${res.status}`);
  return data;
}
function setText(id, value) { const el = document.getElementById(id); if (el) el.textContent = value; }
function eventState(event) {
  const now=Date.now(), start=event.startAt?new Date(event.startAt).getTime():null, end=event.endAt?new Date(event.endAt).getTime():null;
  if(start&&now<start)return 'GEPLANT'; if(end&&now<end)return 'LÄUFT'; if(end&&now>=end)return 'BEENDET'; if(start&&now>=start)return 'LÄUFT'; return 'OFFEN';
}
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
  return d>0 ? `${d}d ${h}h` : `${h}h ${m}m`;
}
function renderPlayers(players=[]) {
  const wrap=$('#onlinePlayers');
  if(!players.length){wrap.innerHTML='<div class="ranking-row"><span>—</span><strong>Niemand online</strong><em>0 Spieler</em></div>';return;}
  wrap.innerHTML=players.map((p,i)=>`<div class="ranking-row"><span>${String(i+1).padStart(2,'0')}</span><strong>${escapeHtml(p.name)} <small>Lv. ${p.level||'—'}</small></strong><em>${p.ping==null?'—':`${p.ping} ms`}</em></div>`).join('');
}
function escapeHtml(value){return String(value??'').replace(/[&<>'"]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;',"'":'&#39;','"':'&quot;'}[c]));}
function renderMap(players=[]) {
  const map=$('#liveMap');
  map.querySelectorAll('.player-dot').forEach(e=>e.remove());
  const empty=$('#mapEmpty');
  if(!players.length){empty.style.display='block';return;}
  empty.style.display='none';
  const xs=players.map(p=>Number(p.location_x)||0), ys=players.map(p=>Number(p.location_y)||0);
  const maxAbs=Math.max(1,...xs.map(Math.abs),...ys.map(Math.abs));
  for(const p of players){
    const x=50+(Number(p.location_x)||0)/maxAbs*42, y=50-(Number(p.location_y)||0)/maxAbs*42;
    const dot=document.createElement('div'); dot.className='player-dot'; dot.style.left=`${Math.max(4,Math.min(96,x))}%`; dot.style.top=`${Math.max(4,Math.min(96,y))}%`; dot.title=`${p.name} · Lv. ${p.level||'—'} · ${Math.round(Number(p.location_x)||0)}, ${Math.round(Number(p.location_y)||0)}`;
    dot.innerHTML=`<span></span><b>${escapeHtml(p.name)}</b>`; map.appendChild(dot);
  }
}
function render(data){
  currentStatus=data; const s=data.server, p=data.palworld||{};
  setText('eventTitle',data.event.title||'Palworld Community Event');
  setText('serverState',s.running?'ONLINE':'OFFLINE');
  setText('serverName',p.name||'Palworld Server');
  setText('serverDescription',p.description||'Live-Status, Event-Fortschritt, Ranglisten und Worldmap an einem Ort.');
  setText('playerCount',Number.isFinite(Number(p.currentPlayers))?p.currentPlayers:'—');
  setText('maxPlayers',`von ${p.maxPlayers||32} Slots`);
  setText('serverFps',p.fps==null?'—':Math.round(Number(p.fps)));
  setText('frameTime',p.frameTime==null?'Live Performance':`${Number(p.frameTime).toFixed(1)} ms Frametime`);
  setText('serverUptime',formatUptime(p.uptime));
  setText('gameVersion',p.version||'Palworld');
  setText('playersHint',data.live.connected?'Live aus dem Gameserver':'Live-API noch nicht verbunden');
  const chip=$('#apiChip'); chip.textContent=data.live.connected?'API LIVE':'API OFFLINE'; chip.className=`live-chip ${data.live.connected?'online':''}`;
  const pill=$('#serverPill'); pill.className=`status-pill ${s.running?'online':'offline'}`; setText('serverPillText',s.running?'Server online':'Server offline');
  renderPlayers(data.players||[]); renderMap(data.players||[]); countdown(data.event);
}
async function refresh(){try{render(await request('/api/public/status'));}catch{setText('serverPillText','Backend nicht erreichbar');$('#serverPill').className='status-pill offline';}}
setInterval(()=>currentStatus&&countdown(currentStatus.event),1000); setInterval(refresh,4000); refresh();
