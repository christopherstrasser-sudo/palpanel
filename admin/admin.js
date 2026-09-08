const $ = s => document.querySelector(s);
const page = document.body.dataset.page || 'dashboard';
let current = null;
let currentJobKey = '';
let settingsModel = null;

async function req(url, options = {}) {
  const res = await fetch(url, {
    headers: { 'Content-Type': 'application/json', ...(options.headers || {}) },
    credentials: 'same-origin',
    ...options
  });
  const data = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(data.error || `HTTP ${res.status}`);
  return data;
}

function el(id) { return document.getElementById(id); }
function setText(id, value) { const node = el(id); if (node) node.textContent = value; }
function esc(v) { return String(v ?? '').replace(/[&<>'"]/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;',"'":'&#39;','"':'&quot;'}[c])); }
function toast(message, error = false) {
  const node = el('toast');
  if (!node) return;
  node.textContent = message;
  node.className = `toast show${error ? ' error' : ''}`;
  clearTimeout(toast.t);
  toast.t = setTimeout(() => node.className = 'toast', 3200);
}

function showLogin() {
  el('loginView')?.classList.remove('hidden');
  el('adminView')?.classList.add('hidden');
  el('logoutBtn')?.classList.add('hidden');
}
function showAdmin() {
  el('loginView')?.classList.add('hidden');
  el('adminView')?.classList.remove('hidden');
  el('logoutBtn')?.classList.remove('hidden');
  refreshPage();
}

async function checkSession() {
  try {
    const session = await req('/api/admin/session');
    session.authenticated ? showAdmin() : showLogin();
  } catch { showLogin(); }
}

if (el('loginForm')) {
  el('loginForm').addEventListener('submit', async event => {
    event.preventDefault();
    setText('loginError', '');
    try {
      await req('/api/admin/login', {
        method: 'POST',
        body: JSON.stringify({ username: el('username').value, password: el('password').value })
      });
      el('password').value = '';
      showAdmin();
    } catch (err) { setText('loginError', err.message); }
  });
}

el('logoutBtn')?.addEventListener('click', async () => {
  try { await req('/api/admin/logout', { method: 'POST', body: '{}' }); } catch {}
  showLogin();
});

function uptime(seconds) {
  if (!Number.isFinite(Number(seconds))) return '—';
  const s = Number(seconds), d = Math.floor(s / 86400), h = Math.floor(s / 3600) % 24, m = Math.floor(s / 60) % 60;
  return d ? `${d}T ${h}Std. ${m}Min.` : `${h}Std. ${m}Min.`;
}

function renderStatus(data) {
  current = data;
  const s = data.server || {}, live = data.live || {}, info = live.info || {}, metrics = live.metrics || {};
  setText('serverState', s.running ? 'ONLINE' : 'OFFLINE');
  setText('serverName', info.servername || s.serverPath || '—');
  setText('steamState', s.steamcmdInstalled ? 'INSTALLIERT' : 'FEHLT');
  setText('pidState', s.pid || '—');
  setText('playerCount', metrics.currentplayernum ?? live.players?.length ?? '—');
  setText('playerSlots', `von ${metrics.maxplayernum ?? data.palworld?.maxPlayers ?? 32} Plätzen`);
  setText('serverFps', metrics.serverfps == null ? '—' : Math.round(metrics.serverfps));
  setText('frameTime', metrics.serverframetime == null ? '—' : `${Number(metrics.serverframetime).toFixed(1)} ms Bildzeit`);
  setText('gameVersion', info.version || '—');
  setText('gameUptime', uptime(metrics.uptime));
  setText('restState', data.rest?.connected ? 'AKTIV' : data.rest?.configured ? 'OFFLINE' : 'NICHT EINGERICHTET');
  setText('restHint', data.rest?.error || `Port ${data.palworld?.rest?.port || 8212}`);
  setText('playersUpdated', live.updatedAt ? new Date(live.updatedAt).toLocaleTimeString('de-DE') : '—');

  const pill = el('serverPill');
  if (pill) pill.className = `pill ${s.running ? 'online' : 'offline'}`;
  setText('serverPillText', s.running ? 'Server online' : 'Server offline');

  el('installBox')?.classList.toggle('hidden', !!s.installed);
  el('restBox')?.classList.toggle('hidden', !!(data.rest?.configured && data.rest?.connected));
  document.querySelectorAll('[data-action="start"]').forEach(b => b.disabled = !s.installed || s.running || data.job?.running);
  document.querySelectorAll('[data-action="stop"]').forEach(b => b.disabled = !s.running || data.job?.running);
  document.querySelectorAll('[data-action="restart"]').forEach(b => b.disabled = !s.running || data.job?.running);
  document.querySelectorAll('[data-action="update"]').forEach(b => b.disabled = !s.installed || s.running || data.job?.running);

  if (el('playersTable')) renderPlayers(live.players || []);
}

async function refreshStatus() {
  try { renderStatus(await req('/api/admin/status')); }
  catch (err) { if (/angemeldet/i.test(err.message)) showLogin(); }
}

function renderPlayers(players = []) {
  const body = el('playersTable');
  if (!body) return;
  if (!players.length) {
    body.innerHTML = '<tr><td colspan="7" class="empty">Keine Spieler online.</td></tr>';
    return;
  }
  body.innerHTML = players.map(p => `<tr><td><strong>${esc(p.name || 'Unbekannt')}</strong></td><td>${esc(p.accountName || '—')}</td><td><code>${esc(p.userId || '—')}</code></td><td>${p.level ?? '—'}</td><td>${p.ping == null ? '—' : `${Math.round(p.ping)} ms`}</td><td>${Math.round(p.location_x || 0)}, ${Math.round(p.location_y || 0)}</td><td><button class="btn mini" onclick="playerAction('kick','${esc(p.userId)}')">Entfernen</button> <button class="btn mini danger" onclick="playerAction('ban','${esc(p.userId)}')">Sperren</button></td></tr>`).join('');
}

async function refreshBackups() {
  if (!el('backupTable')) return;
  try {
    const data = await req('/api/admin/backups');
    el('backupTable').innerHTML = data.backups.length ? data.backups.map(x => `<tr><td><code>${esc(x.name)}</code></td><td>${new Date(x.createdAt).toLocaleString('de-DE')}</td><td>${(x.size / 1048576).toFixed(1)} MB</td><td><button class="btn mini danger" onclick="restoreBackup('${esc(x.name)}')">Wiederherstellen</button></td></tr>`).join('') : '<tr><td colspan="4" class="empty">Noch keine Sicherungen.</td></tr>';
  } catch (err) { toast(err.message, true); }
}

async function refreshJob() {
  if (!el('jobLog')) return;
  try {
    const { job } = await req('/api/admin/job');
    const badge = el('jobBadge');
    if (!job) {
      if (badge) { badge.textContent = 'BEREIT'; badge.className = 'job-badge'; }
      el('jobLog').textContent = 'Noch keine Aufgabe gestartet.';
      return;
    }
    const key = `${job.type}:${job.running}:${job.finishedAt}:${job.log?.length}`;
    if (key !== currentJobKey) {
      currentJobKey = key;
      el('jobLog').textContent = (job.log || []).join('\n') || job.type;
      el('jobLog').scrollTop = el('jobLog').scrollHeight;
    }
    if (badge) {
      badge.textContent = job.running ? 'LÄUFT' : job.success ? 'ERFOLGREICH' : 'FEHLER';
      badge.className = `job-badge ${job.running ? 'running' : job.success ? 'ok' : 'fail'}`;
    }
  } catch {}
}

function settingInput(key, spec, value) {
  if (spec.type === 'boolean') return `<label class="setting-item"><span>${esc(spec.label)}</span><select data-setting="${esc(key)}"><option value="true" ${value === true ? 'selected' : ''}>Aktiviert</option><option value="false" ${value === false ? 'selected' : ''}>Deaktiviert</option></select></label>`;
  const type = spec.type === 'number' ? 'number' : 'text';
  const step = spec.type === 'number' ? ' step="0.1"' : '';
  return `<label class="setting-item"><span>${esc(spec.label)}</span><input data-setting="${esc(key)}" type="${type}"${step} value="${esc(value ?? '')}"></label>`;
}

async function refreshSettings() {
  if (!el('settingsGrid')) return;
  try {
    settingsModel = await req('/api/admin/server-settings');
    el('settingsGrid').innerHTML = Object.entries(settingsModel.schema).map(([k, s]) => settingInput(k, s, settingsModel.values[k])).join('');
    setText('settingsState', 'Bereit');
  } catch (err) {
    setText('settingsState', 'Fehler');
    el('settingsGrid').innerHTML = `<div class="empty">${esc(err.message)}</div>`;
  }
}

async function saveSettings() {
  try {
    const values = {};
    document.querySelectorAll('[data-setting]').forEach(node => {
      const key = node.dataset.setting, spec = settingsModel?.schema?.[key];
      values[key] = spec?.type === 'boolean' ? node.value === 'true' : spec?.type === 'number' ? Number(node.value) : node.value;
    });
    const result = await req('/api/admin/server-settings', { method: 'PUT', body: JSON.stringify({ values }) });
    toast(result.changed.length ? `${result.changed.length} Einstellung(en) gespeichert.${result.restartRequired ? ' Neustart erforderlich.' : ''}` : 'Keine Änderungen.');
    setText('settingsState', result.restartRequired ? 'NEUSTART NÖTIG' : 'Gespeichert');
    await refreshSettings();
  } catch (err) { toast(err.message, true); }
}

async function refreshLogs() {
  if (!el('liveLog')) return;
  try {
    const data = await req('/api/admin/server-logs');
    setText('logFile', data.available ? `${data.file} · ${new Date(data.updatedAt).toLocaleTimeString('de-DE')}` : 'Kein Protokoll gefunden');
    el('liveLog').textContent = data.available ? (data.content || 'Protokolldatei ist leer.') : 'Noch keine Palworld-Protokolldatei gefunden.';
    el('liveLog').scrollTop = el('liveLog').scrollHeight;
  } catch (err) { el('liveLog').textContent = err.message; }
}

async function serverAction(name) {
  try {
    await req(`/api/admin/server/${name}`, { method: 'POST', body: '{}' });
    toast('Aktion gestartet.');
    setTimeout(refreshStatus, 1000);
  } catch (err) { toast(err.message, true); }
}

document.querySelectorAll('[data-action]').forEach(button => button.addEventListener('click', () => serverAction(button.dataset.action)));
el('installBtn')?.addEventListener('click', async () => { if (!confirm('Server installieren?')) return; try { await req('/api/admin/server/install', { method: 'POST', body: '{}' }); toast('Installation gestartet.'); } catch (err) { toast(err.message, true); } });
el('restSetupBtn')?.addEventListener('click', async () => { if (!confirm('REST-Schnittstelle einrichten?')) return; try { await req('/api/admin/rest/setup', { method: 'POST', body: '{}' }); toast('REST-Schnittstelle eingerichtet.'); setTimeout(refreshStatus, 2500); } catch (err) { toast(err.message, true); } });
el('backupBtn')?.addEventListener('click', async () => { try { await req('/api/admin/backups', { method: 'POST', body: '{}' }); toast('Sicherung gestartet.'); setTimeout(refreshBackups, 2000); } catch (err) { toast(err.message, true); } });
el('announceBtn')?.addEventListener('click', async () => { const message = prompt('Nachricht an alle Spieler:'); if (!message) return; try { await req('/api/admin/players/announce', { method: 'POST', body: JSON.stringify({ message }) }); toast('Nachricht gesendet.'); } catch (err) { toast(err.message, true); } });
el('saveSettingsBtn')?.addEventListener('click', saveSettings);
el('refreshLogsBtn')?.addEventListener('click', refreshLogs);

window.playerAction = async (action, userId) => {
  const labels = { kick: 'Entfernen', ban: 'Sperren' };
  const label = labels[action] || action;
  if (!userId || !confirm(`${label} für ${userId} ausführen?`)) return;
  try {
    await req(`/api/admin/players/${action}`, { method: 'POST', body: JSON.stringify({ userid: userId }) });
    toast(`${label} ausgeführt.`);
    setTimeout(refreshStatus, 1000);
  } catch (err) { toast(err.message, true); }
};

window.restoreBackup = async name => {
  if (current?.server?.running) return toast('Server vor der Wiederherstellung stoppen.', true);
  if (!confirm(`Sicherung ${name} wirklich wiederherstellen? Vorher wird automatisch eine zusätzliche Sicherheitskopie erstellt.`)) return;
  try { await req('/api/admin/backups/restore', { method: 'POST', body: JSON.stringify({ name }) }); toast('Wiederherstellung gestartet.'); }
  catch (err) { toast(err.message, true); }
};

async function refreshPage() {
  if (['dashboard','server','players','backups'].includes(page)) await refreshStatus();
  if (page === 'backups') await refreshBackups();
  if (page === 'settings') await refreshSettings();
  if (page === 'logs') await refreshLogs();
  if (page === 'jobs') await refreshJob();
}

setInterval(() => !el('adminView')?.classList.contains('hidden') && ['dashboard','server','players','backups'].includes(page) && refreshStatus(), 4000);
setInterval(() => !el('adminView')?.classList.contains('hidden') && page === 'backups' && refreshBackups(), 10000);
setInterval(() => !el('adminView')?.classList.contains('hidden') && page === 'logs' && refreshLogs(), 3000);
setInterval(() => !el('adminView')?.classList.contains('hidden') && page === 'jobs' && refreshJob(), 1500);

checkSession();
