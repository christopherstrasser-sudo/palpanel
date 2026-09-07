const $ = (s) => document.querySelector(s);
let currentStatus = null;
let currentJobKey = '';

function toast(message, error = false) {
  const el = $('#toast');
  el.textContent = message;
  el.className = `toast show${error ? ' error' : ''}`;
  clearTimeout(toast.timer);
  toast.timer = setTimeout(() => el.className = 'toast', 3500);
}

async function request(url, options = {}) {
  const res = await fetch(url, {
    headers: { 'Content-Type': 'application/json', ...(options.headers || {}) },
    ...options
  });
  const data = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(data.error || `HTTP ${res.status}`);
  return data;
}

function setText(id, value) {
  const el = document.getElementById(id);
  if (el) el.textContent = value;
}

function countdown(event) {
  const now = Date.now();
  const start = event.startAt ? new Date(event.startAt).getTime() : null;
  const end = event.endAt ? new Date(event.endAt).getTime() : null;
  let target = null;
  let label = 'EVENTZEIT NOCH NICHT GESETZT';

  if (start && now < start) {
    target = start;
    label = 'START IN';
  } else if (end && now < end) {
    target = end;
    label = 'EVENT ENDET IN';
  } else if (end && now >= end) {
    label = 'EVENT BEENDET';
  } else if (start && now >= start) {
    label = 'EVENT LÄUFT';
  }

  setText('countdownLabel', label);
  if (!target) return setText('countdown', '-- : -- : -- : --');
  const delta = Math.max(0, target - now);
  const days = Math.floor(delta / 86400000);
  const hours = Math.floor(delta / 3600000) % 24;
  const minutes = Math.floor(delta / 60000) % 60;
  const seconds = Math.floor(delta / 1000) % 60;
  setText('countdown', [days, hours, minutes, seconds].map(v => String(v).padStart(2, '0')).join(' : '));
}

function renderStatus(data) {
  currentStatus = data;
  const s = data.server;
  setText('eventTitle', data.event.title || 'Palworld Community Event');
  setText('serverState', s.running ? 'ONLINE' : 'OFFLINE');
  setText('installState', s.installed ? 'INSTALLIERT' : 'NICHT INSTALLIERT');
  setText('serverPort', data.palworld.port);
  setText('maxPlayers', data.palworld.maxPlayers);
  setText('serverPath', s.serverPath);
  setText('steamState', s.steamcmdInstalled ? 'Installiert' : 'Fehlt');
  setText('processState', s.running ? (s.processName || 'Läuft') : 'Gestoppt');
  setText('pidState', s.pid || '—');

  const pill = $('#serverPill');
  pill.className = `status-pill ${s.running ? 'online' : 'offline'}`;
  setText('serverPillText', s.running ? 'Server online' : (s.installed ? 'Server offline' : 'Nicht installiert'));
  $('#installBox').classList.toggle('hidden', s.installed);

  document.querySelectorAll('[data-action="start"]').forEach(b => b.disabled = !s.installed || s.running || data.job?.running);
  document.querySelectorAll('[data-action="stop"]').forEach(b => b.disabled = !s.running || data.job?.running);
  document.querySelectorAll('[data-action="restart"]').forEach(b => b.disabled = !s.running || data.job?.running);
  document.querySelectorAll('[data-action="update"]').forEach(b => b.disabled = !s.installed || s.running || data.job?.running);
  $('#installBtn').disabled = !!data.job?.running;
  countdown(data.event);
}

async function refreshStatus() {
  try {
    renderStatus(await request('/api/status'));
  } catch (err) {
    setText('serverPillText', 'Backend nicht erreichbar');
    $('#serverPill').className = 'status-pill offline';
  }
}

async function refreshJob() {
  try {
    const { job } = await request('/api/job');
    const badge = $('#jobBadge');
    if (!job) {
      badge.textContent = 'IDLE';
      badge.className = 'job-badge';
      return;
    }
    const key = `${job.type}:${job.running}:${job.finishedAt || ''}:${job.log?.length || 0}`;
    if (key !== currentJobKey) {
      currentJobKey = key;
      $('#jobLog').textContent = (job.log || []).join('\n') || `${job.type} läuft…`;
      $('#jobLog').scrollTop = $('#jobLog').scrollHeight;
    }
    badge.textContent = job.running ? 'LÄUFT' : (job.success ? 'ERFOLGREICH' : 'FEHLER');
    badge.className = `job-badge ${job.running ? 'running' : (job.success ? 'ok' : 'fail')}`;
  } catch {}
}

async function action(name) {
  const labels = { start: 'Server wird gestartet…', stop: 'Server wird gestoppt…', restart: 'Server wird neu gestartet…', update: 'Update wurde gestartet.' };
  try {
    await request(`/api/server/${name}`, { method: 'POST', body: '{}' });
    toast(labels[name] || 'Aktion ausgeführt.');
    await refreshStatus();
    await refreshJob();
  } catch (err) {
    toast(err.message, true);
  }
}

$('#installBtn').addEventListener('click', async () => {
  if (!confirm('SteamCMD und Palworld Dedicated Server jetzt automatisch nach C:\\PalPanel installieren?')) return;
  try {
    await request('/api/server/install', { method: 'POST', body: '{}' });
    toast('Installation gestartet. Fortschritt rechts im Log.');
    await refreshStatus();
    await refreshJob();
  } catch (err) {
    toast(err.message, true);
  }
});

document.querySelectorAll('[data-action]').forEach(btn => btn.addEventListener('click', () => action(btn.dataset.action)));

setInterval(() => currentStatus && countdown(currentStatus.event), 1000);
setInterval(refreshStatus, 4000);
setInterval(refreshJob, 1500);
refreshStatus();
refreshJob();
