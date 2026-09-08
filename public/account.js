(() => {
  const $ = id => document.getElementById(id);
  let account = null;

  async function api(url, options = {}) {
    const res = await fetch(url, { credentials: 'same-origin', headers: { 'Accept': 'application/json', 'Content-Type': 'application/json' }, ...options });
    const data = await res.json().catch(() => ({}));
    if (!res.ok) throw new Error(data.error || `HTTP ${res.status}`);
    return data;
  }

  function openDrawer() {
    if (!account?.authenticated) return location.assign('/auth/steam');
    $('accountDrawer')?.classList.add('open');
    $('accountShade')?.classList.add('open');
    $('accountDrawer')?.setAttribute('aria-hidden', 'false');
    document.body.classList.add('drawer-open');
  }
  function closeDrawer() {
    $('accountDrawer')?.classList.remove('open');
    $('accountShade')?.classList.remove('open');
    $('accountDrawer')?.setAttribute('aria-hidden', 'true');
    document.body.classList.remove('drawer-open');
  }
  function setText(id, value) { const el = $(id); if (el) el.textContent = value; }

  function render(data) {
    account = data;
    const trigger = $('accountTrigger');
    if (!trigger) return;
    if (!data.authenticated) {
      trigger.classList.remove('authenticated');
      setText('accountTriggerText', 'MIT STEAM ANMELDEN ↗');
      setText('accountPoints', '');
      return;
    }
    const u = data.user;
    trigger.classList.add('authenticated');
    setText('accountTriggerText', u.displayName || 'STEAM-SPIELER');
    setText('accountPoints', `${Number(u.points || 0).toLocaleString('de-DE')} PUNKTE`);
    setText('accountName', u.displayName || 'Steam-Spieler');
    setText('accountSteamId', u.steamId);
    setText('drawerPoints', Number(u.points || 0).toLocaleString('de-DE'));
    setText('accountInitial', String(u.displayName || '?').charAt(0).toUpperCase());
    setText('accountLinkState', u.linked ? 'VERBUNDEN' : 'NICHT VERBUNDEN');
    setText('accountLevel', u.character?.level ?? '—');
    $('accountLinkState')?.classList.toggle('linked', !!u.linked);
    $('accountLinkNotice')?.classList.toggle('hidden', !!u.linked);
    const steam = $('steamProfileLink');
    if (steam) steam.href = `https://steamcommunity.com/profiles/${encodeURIComponent(u.steamId)}`;

    document.querySelectorAll('[data-account-name]').forEach(el => el.textContent = u.displayName || 'Steam-Spieler');
    document.querySelectorAll('[data-account-steam]').forEach(el => el.textContent = u.steamId);
    document.querySelectorAll('[data-account-points]').forEach(el => el.textContent = Number(u.points || 0).toLocaleString('de-DE'));
    document.querySelectorAll('[data-account-link]').forEach(el => el.textContent = u.linked ? 'VERBUNDEN' : 'NICHT VERBUNDEN');
    document.querySelectorAll('[data-account-character]').forEach(el => el.textContent = u.character?.name || 'Nicht verbunden');
    document.querySelectorAll('[data-account-level]').forEach(el => el.textContent = u.character?.level ?? '—');
  }

  async function refresh() {
    try { render(await api('/api/user/me')); }
    catch { render({ authenticated: false }); }
    return account;
  }

  $('accountTrigger')?.addEventListener('click', openDrawer);
  $('accountClose')?.addEventListener('click', closeDrawer);
  $('accountShade')?.addEventListener('click', closeDrawer);
  document.addEventListener('keydown', e => { if (e.key === 'Escape') closeDrawer(); });
  $('relinkBtn')?.addEventListener('click', async () => {
    const btn = $('relinkBtn');
    btn.disabled = true;
    btn.textContent = 'CHARAKTER WIRD GESUCHT…';
    try {
      const result = await api('/api/user/relink', { method: 'POST', body: '{}' });
      render(result);
      btn.textContent = result.linked ? 'CHARAKTER VERBUNDEN ✓' : 'NICHT GEFUNDEN — SERVER BETRETEN';
    } catch (e) {
      btn.textContent = 'VERKNÜPFUNG FEHLGESCHLAGEN';
    }
    setTimeout(() => {
      btn.disabled = false;
      btn.textContent = 'ERNEUT SUCHEN ↻';
    }, 2200);
  });
  $('userLogout')?.addEventListener('click', async () => {
    try { await api('/api/user/logout', { method: 'POST', body: '{}' }); } catch {}
    location.assign('/');
  });

  const params = new URLSearchParams(location.search);
  if (params.has('login')) history.replaceState({}, '', location.pathname + location.hash);

  window.PalAccount = { refresh, get: () => account, open: openDrawer };
  refresh();
  setInterval(() => document.visibilityState === 'visible' && refresh(), 30000);
})();
