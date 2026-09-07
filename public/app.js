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
  const now=Date.now(); const start=event.startAt?new Date(event.startAt).getTime():null; const end=event.endAt?new Date(event.endAt).getTime():null;
  if(start&&now<start)return 'GEPLANT'; if(end&&now<end)return 'LÄUFT'; if(end&&now>=end)return 'BEENDET'; if(start&&now>=start)return 'LÄUFT'; return 'OFFEN';
}
function countdown(event) {
  const now=Date.now(); const start=event.startAt?new Date(event.startAt).getTime():null; const end=event.endAt?new Date(event.endAt).getTime():null;
  let target=null,label='EVENTZEIT NOCH NICHT GESETZT';
  if(start&&now<start){target=start;label='START IN';} else if(end&&now<end){target=end;label='EVENT ENDET IN';} else if(end&&now>=end){label='EVENT BEENDET';} else if(start&&now>=start){label='EVENT LÄUFT';}
  setText('countdownLabel',label); if(!target)return setText('countdown','-- : -- : -- : --');
  const delta=Math.max(0,target-now),days=Math.floor(delta/86400000),hours=Math.floor(delta/3600000)%24,minutes=Math.floor(delta/60000)%60,seconds=Math.floor(delta/1000)%60;
  setText('countdown',[days,hours,minutes,seconds].map(v=>String(v).padStart(2,'0')).join(' : '));
}
function render(data){
  currentStatus=data; const s=data.server;
  setText('eventTitle',data.event.title||'Palworld Community Event'); setText('serverState',s.running?'ONLINE':'OFFLINE'); setText('serverPort',data.palworld.port); setText('maxPlayers',`von ${data.palworld.maxPlayers} Slots`); setText('playerCount','—'); setText('eventState',eventState(data.event));
  const pill=$('#serverPill'); pill.className=`status-pill ${s.running?'online':'offline'}`; setText('serverPillText',s.running?'Server online':'Server offline'); countdown(data.event);
}
async function refresh(){try{render(await request('/api/public/status'));}catch{setText('serverPillText','Backend nicht erreichbar');$('#serverPill').className='status-pill offline';}}
setInterval(()=>currentStatus&&countdown(currentStatus.event),1000); setInterval(refresh,4000); refresh();
