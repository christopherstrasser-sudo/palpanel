(() => {
  const $ = id => document.getElementById(id);

  function esc(value) {
    return String(value ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  }
  function prettyName(value) {
    let text = String(value || '').trim();
    text = text.replace(/^TowerType:/i, 'Turm ').replace(/^Tower:/i, '');
    text = text.replace(/^BOSS_/i, '').replace(/^Boss_/i, '');
    text = text.replace(/_/g, ' ');
    text = text.replace(/([a-zäöüß])([A-ZÄÖÜ])/g, '$1 $2');
    return text.replace(/\s+/g, ' ').trim() || 'Unbekannt';
  }
  function fmtPlaytime(seconds) {
    const s = Math.max(0, Number(seconds) || 0);
    const h = Math.floor(s / 3600);
    const m = Math.floor(s / 60) % 60;
    return `${h} Std. ${String(m).padStart(2, '0')} Min.`;
  }
  async function api(url) {
    const res = await fetch(url, { headers: { Accept: 'application/json' } });
    const data = await res.json().catch(() => ({}));
    if (!res.ok) throw new Error(data.error || `HTTP ${res.status}`);
    return data;
  }
  function setText(id, value) {
    const el = $(id);
    if (el) el.textContent = value;
  }
  function renderList(id, rows, emptyText, key) {
    const root = $(id);
    if (!root) return;
    if (!rows?.length) {
      root.innerHTML = `<div class="public-profile-empty">${esc(emptyText)}</div>`;
      return;
    }
    root.innerHTML = rows.map((row, i) => `<article class="public-profile-list-row">
      <b>${String(i + 1).padStart(2, '0')}</b>
      <strong>${esc(prettyName(row[key]))}</strong>
      <span>${row.alphaSeen ? 'ALPHA ERFASST' : ''}${row.captures > 1 ? `${row.alphaSeen ? ' · ' : ''}×${Number(row.captures)}` : ''}</span>
    </article>`).join('');
  }
  function render(profile) {
    document.title = `PalPanel // ${profile.name}`;
    setText('publicPlayerName', profile.name);
    setText('publicPlayerInitial', String(profile.name || '?').trim().charAt(0).toUpperCase() || '?');
    setText('publicPlayerLevel', profile.level ?? '—');
    setText('publicPlayerRank', `#${Number(profile.rank || 1).toLocaleString('de-DE')}`);
    setText('publicPlayerScore', Number(profile.eventScore || 0).toLocaleString('de-DE'));
    setText('publicPlayerPlaytime', fmtPlaytime(profile.playtimeSeconds));
    setText('publicUniquePals', Number(profile.uniquePals || 0).toLocaleString('de-DE'));
    setText('publicCaptures', Number(profile.totalCaptures || 0).toLocaleString('de-DE'));
    setText('publicAlphaCaptures', Number(profile.alphaCaptures || 0).toLocaleString('de-DE'));
    setText('publicBossKills', Number(profile.bossKills || 0).toLocaleString('de-DE'));
    setText('publicLevelUps', Number(profile.levelUps || 0).toLocaleString('de-DE'));
    setText('publicDeaths', Number(profile.deaths || 0).toLocaleString('de-DE'));

    const avatar = $('publicPlayerAvatar');
    const frame = $('publicPlayerAvatarFrame');
    if (avatar && frame && /^\/api\/steam\/avatar\/user\/\d+$/.test(String(profile.avatarUrl || ''))) {
      avatar.onload = () => frame.classList.add('loaded');
      avatar.onerror = () => avatar.remove();
      avatar.src = profile.avatarUrl;
    }

    renderList('publicDiscoveries', profile.discoveries, 'Noch keine Pal-Entdeckungen erfasst.', 'speciesKey');
    renderList('publicAlphas', profile.recentAlphas, 'Noch keine Alpha-Fänge erfasst.', 'speciesKey');
    renderList('publicBosses', profile.recentBosses, 'Noch keine Boss-Abschlüsse erfasst.', 'bossKey');
    $('publicProfile')?.classList.remove('hidden');
  }
  function showError(message) {
    $('publicProfileLoading')?.classList.add('hidden');
    const error = $('publicProfileError');
    if (error) {
      error.classList.remove('hidden');
      error.querySelector('p').textContent = message;
    }
  }

  const pathMatch = location.pathname.match(/^\/player\/(\d+)\/?$/);
  const queryId = new URLSearchParams(location.search).get('id');
  const id = pathMatch?.[1] || queryId;
  if (!/^\d+$/.test(String(id || ''))) {
    showError('Dieses Spielerprofil ist ungültig.');
    return;
  }
  api(`/api/public/player/${id}`)
    .then(data => {
      $('publicProfileLoading')?.classList.add('hidden');
      render(data.profile || {});
    })
    .catch(err => showError(err.message || 'Spielerprofil konnte nicht geladen werden.'));
})();
