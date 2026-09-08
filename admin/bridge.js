const bridgeEl = id => document.getElementById(id);

async function bridgeReq(url, options = {}) {
  const res = await fetch(url, {
    credentials: 'same-origin',
    headers: { 'Content-Type': 'application/json', ...(options.headers || {}) },
    ...options
  });
  const data = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(data.error || `HTTP ${res.status}`);
  return data;
}

function bridgeToast(message, error = false) {
  const node = bridgeEl('toast');
  if (!node) return;
  node.textContent = message;
  node.className = `toast show${error ? ' error' : ''}`;
  clearTimeout(bridgeToast.t);
  bridgeToast.t = setTimeout(() => node.className = 'toast', 3400);
}

function ageLabel(ms) {
  if (ms == null) return 'Noch kein Lebenszeichen';
  if (ms < 1500) return 'gerade eben';
  if (ms < 60000) return `vor ${Math.max(1, Math.round(ms / 1000))} Sek.`;
  return `vor ${Math.round(ms / 60000)} Min.`;
}

function renderBridge(data) {
  bridgeEl('ue4ssState').textContent = data.ue4ss.installed ? 'BEREIT' : 'FEHLT';
  bridgeEl('ue4ssHint').textContent = data.ue4ss.installed ? 'Laufzeitumgebung gefunden' : 'Laufzeitumgebung nicht gefunden';
  bridgeEl('bridgeState').textContent = data.bridge.installed ? (data.bridge.updateAvailable ? 'AKTUALISIERUNG' : 'INSTALLIERT') : 'FEHLT';
  bridgeEl('bridgeVersion').textContent = data.bridge.installedVersion ? `Version ${data.bridge.installedVersion}` : 'Nicht installiert';
  bridgeEl('heartbeatState').textContent = data.heartbeat.live ? 'AKTIV' : data.bridge.installed ? 'OFFLINE' : '—';
  bridgeEl('heartbeatAge').textContent = ageLabel(data.heartbeat.ageMs);
  bridgeEl('bridgeCapabilities').textContent = (data.capabilities || []).length;
  bridgeEl('sourceVersion').textContent = `Quelle ${data.sourceVersion || '—'}`;
  bridgeEl('bridgeServerState').textContent = data.serverRunning ? 'ONLINE' : 'GESTOPPT';
  bridgeEl('bridgeDestination').textContent = data.bridge.destination || '—';
  bridgeEl('bridgeIpc').textContent = data.bridge.ipcDir || '—';
  bridgeEl('installedVersion').textContent = data.bridge.installedVersion || '—';
  bridgeEl('ue4ssWarning').classList.toggle('hidden', data.ue4ss.installed);

  const pill = bridgeEl('bridgePill');
  pill.className = `pill ${data.heartbeat.live ? 'online' : 'offline'}`;
  bridgeEl('bridgePillText').textContent = data.heartbeat.live ? 'Mod-Brücke aktiv' : data.bridge.installed ? 'Mod-Brücke offline' : 'Nicht installiert';

  bridgeEl('installBridgeBtn').disabled = data.serverRunning || !data.ue4ss.installed;
  bridgeEl('uninstallBridgeBtn').disabled = data.serverRunning || !data.bridge.installed;
  bridgeEl('pingBridgeBtn').disabled = !data.heartbeat.live;
  bridgeEl('giveItemBtn').disabled = !data.heartbeat.live || !data.players?.length;

  const select = bridgeEl('bridgePlayer');
  const previous = select.value;
  const players = data.players || [];
  select.innerHTML = players.length
    ? players.map(p => `<option value="${String(p.name).replace(/"/g, '&quot;')}">${p.name}${p.level != null ? ` · Stufe ${p.level}` : ''}</option>`).join('')
    : '<option value="">Keine aktiven Spieler</option>';
  if (players.some(p => p.name === previous)) select.value = previous;

  bridgeEl('bridgeRestartHint').textContent = data.bridge.installed && !data.heartbeat.live
    ? 'Die Dateien der Mod-Brücke sind installiert. Starte den Gameserver neu, damit UE4SS den Mod lädt.'
    : 'Installation und Aktualisierungen werden erst beim nächsten Gameserver-Start geladen.';
}

async function refreshBridge() {
  if (bridgeEl('adminView')?.classList.contains('hidden')) return;
  try {
    const data = await bridgeReq('/api/admin/bridge/status');
    renderBridge(data);
  } catch (err) {
    bridgeEl('bridgePillText').textContent = 'Statusfehler';
  }
}

bridgeEl('installBridgeBtn')?.addEventListener('click', async () => {
  if (!confirm('PalPanelBridge installieren oder aktualisieren? Der Gameserver muss gestoppt sein.')) return;
  try {
    const result = await bridgeReq('/api/admin/bridge/install', { method: 'POST', body: '{}' });
    bridgeToast(`Mod-Brücke ${result.version} installiert. Gameserver jetzt starten.`);
    await refreshBridge();
  } catch (err) { bridgeToast(err.message, true); }
});

bridgeEl('uninstallBridgeBtn')?.addEventListener('click', async () => {
  if (!confirm('PalPanelBridge wirklich aus dem Gameserver entfernen?')) return;
  try {
    await bridgeReq('/api/admin/bridge/uninstall', { method: 'POST', body: '{}' });
    bridgeToast('Mod-Brücke entfernt.');
    await refreshBridge();
  } catch (err) { bridgeToast(err.message, true); }
});

bridgeEl('pingBridgeBtn')?.addEventListener('click', async () => {
  try {
    const result = await bridgeReq('/api/admin/bridge/ping', { method: 'POST', body: '{}' });
    bridgeToast(`Mod-Brücke antwortet: ${result.message}`);
  } catch (err) { bridgeToast(err.message, true); }
});

bridgeEl('giveItemForm')?.addEventListener('submit', async event => {
  event.preventDefault();
  const playerName = bridgeEl('bridgePlayer').value;
  const itemId = bridgeEl('bridgeItemId').value.trim();
  const count = Number(bridgeEl('bridgeItemCount').value);
  const resultBox = bridgeEl('bridgeResult');
  if (!playerName) return bridgeToast('Kein aktiver Spieler ausgewählt.', true);
  if (!confirm(`${count} × ${itemId} direkt an ${playerName} geben?`)) return;
  resultBox.className = 'bridge-result';
  resultBox.textContent = 'Befehl wird an den laufenden PalServer gesendet…';
  bridgeEl('giveItemBtn').disabled = true;
  try {
    const result = await bridgeReq('/api/admin/bridge/give-item', {
      method: 'POST',
      body: JSON.stringify({ playerName, itemId, count })
    });
    resultBox.className = 'bridge-result ok';
    resultBox.textContent = `✓ ${result.message}`;
    bridgeToast('Gegenstand direkt zugestellt.');
  } catch (err) {
    resultBox.className = 'bridge-result fail';
    resultBox.textContent = `✕ ${err.message}`;
    bridgeToast(err.message, true);
  } finally {
    setTimeout(refreshBridge, 400);
  }
});

setTimeout(refreshBridge, 600);
setInterval(refreshBridge, 3000);
