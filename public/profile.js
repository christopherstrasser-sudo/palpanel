(() => {
  const $ = id => document.getElementById(id);
  async function api(url, options = {}) {
    const res = await fetch(url, { credentials: 'same-origin', headers: { 'Accept': 'application/json', 'Content-Type': 'application/json' }, ...options });
    const data = await res.json().catch(() => ({}));
    if (!res.ok) throw new Error(data.error || `HTTP ${res.status}`);
    return data;
  }
  function esc(v){return String(v??'').replace(/[&<>'"]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;',"'":'&#39;','"':'&quot;'}[c]));}
  function fmtDate(v){try{return new Date(v).toLocaleString('de-DE')}catch{return '—'}}

  async function renderProfile() {
    const me = await window.PalAccount.refresh();
    const auth = !!me?.authenticated;
    $('profileGate')?.classList.toggle('hidden', auth);
    $('profileData')?.classList.toggle('hidden', !auth);
    if (!auth) return;
    const user = me.user;
    const badge = $('profileLinkBadge');
    if (badge) { badge.textContent = user.linked ? 'LINKED' : 'UNLINKED'; badge.className = user.linked ? 'linked' : ''; }
    $('profileLinkHelp').textContent = user.linked
      ? `Linked to ${user.character?.name || 'your character'}. Last seen ${user.character?.lastSeenAt ? fmtDate(user.character.lastSeenAt) : 'now'}.`
      : 'Join the Palworld server with this Steam account, then run a live scan.';
    try {
      const points = await api('/api/user/points');
      $('ledgerBalance').textContent = `${Number(points.balance || 0).toLocaleString('de-DE')} PTS`;
      const ledger = $('pointsLedger');
      ledger.innerHTML = points.ledger?.length ? points.ledger.map(row => `<div class="ledger-row"><span>${row.amount > 0 ? '+' : ''}${Number(row.amount).toLocaleString('de-DE')}</span><strong>${esc(row.reason)}</strong><em>${fmtDate(row.createdAt)}</em></div>`).join('') : '<div class="ledger-empty">NO POINT MOVEMENTS YET</div>';
    } catch {}
  }

  $('profileRelink')?.addEventListener('click', async () => {
    const btn = $('profileRelink'); btn.disabled = true; btn.textContent = 'SCANNING…';
    try { await api('/api/user/relink', { method:'POST', body:'{}' }); await renderProfile(); btn.textContent = 'SCAN COMPLETE ✓'; }
    catch { btn.textContent = 'SCAN FAILED'; }
    setTimeout(() => { btn.disabled = false; btn.textContent = 'SCAN LIVE SERVER ↻'; }, 1800);
  });

  setTimeout(renderProfile, 0);
})();
