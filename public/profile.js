(() => {
  const $ = id => document.getElementById(id);

  async function api(url, options = {}) {
    const res = await fetch(url, {
      credentials: 'same-origin',
      headers: { 'Accept': 'application/json', 'Content-Type': 'application/json' },
      ...options
    });
    const data = await res.json().catch(() => ({}));
    if (!res.ok) throw new Error(data.error || `HTTP ${res.status}`);
    return data;
  }

  function esc(value) {
    return String(value ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  }
  function fmtDate(value) {
    if (!value) return '—';
    const d = new Date(value);
    if (Number.isNaN(d.getTime())) return '—';
    return d.toLocaleString('de-DE', { day: '2-digit', month: '2-digit', year: '2-digit', hour: '2-digit', minute: '2-digit' });
  }
  function fmtPlaytime(seconds) {
    const s = Math.max(0, Number(seconds) || 0);
    const h = Math.floor(s / 3600);
    const m = Math.floor(s / 60) % 60;
    return `${h}h ${String(m).padStart(2, '0')}m`;
  }
  function prettyName(value) {
    let text = String(value || '').trim();
    text = text.replace(/^TowerType:/i, 'Turm ').replace(/^Tower:/i, '');
    text = text.replace(/^BOSS_/i, '').replace(/^Boss_/i, '');
    text = text.replace(/_/g, ' ');
    text = text.replace(/([a-zäöüß])([A-ZÄÖÜ])/g, '$1 $2');
    text = text.replace(/\s+/g, ' ').trim();
    return text || 'Unbekannt';
  }
  function prettyReason(reason) {
    const raw = String(reason || 'Fortschritt');
    const rules = [
      [/^Neue Pal-Art:\s*(.+)$/i, m => `Neue Pal-Art: ${prettyName(m[1])}`],
      [/^Pal gefangen:\s*(.+)$/i, m => `Pal gefangen: ${prettyName(m[1])}`],
      [/^Alpha-Pal gefangen:\s*(.+)$/i, m => `Alpha-Pal gefangen: ${prettyName(m[1])}`],
      [/^Boss besiegt:\s*(.+)$/i, m => `Boss besiegt: ${prettyName(m[1])}`],
      [/^Level\s+(\d+)\s+erreicht$/i, m => `Stufe ${m[1]} erreicht`]
    ];
    for (const [pattern, replace] of rules) {
      const match = raw.match(pattern);
      if (match) return replace(match);
    }
    return raw;
  }
  function kindLabel(kind) {
    return ({
      alpha: 'ALPHA',
      entdeckung: 'NEUE ART',
      fang: 'FANG',
      meilenstein: 'MEILENSTEIN',
      boss: 'BOSS',
      spielzeit: 'SPIELZEIT',
      stufe: 'STUFE',
      shop: 'PUNKTESHOP',
      tod: 'TOD',
      bonus: 'BONUS',
      fortschritt: 'FORTSCHRITT'
    })[kind] || 'FORTSCHRITT';
  }
  function progressPercent(current, target, complete = false) {
    if (complete) return 100;
    const t = Math.max(1, Number(target) || 1);
    return Math.max(0, Math.min(100, (Number(current) || 0) / t * 100));
  }

  function renderMilestones(rows = []) {
    const root = $('milestoneGrid');
    if (!root) return;
    if (!rows.length) {
      root.innerHTML = '<div class="adventure-empty">Noch keine Meilensteine verfügbar.</div>';
      return;
    }
    root.innerHTML = rows.map(row => {
      const pct = progressPercent(row.current, row.target, row.complete);
      let status = '';
      let detail = '';
      if (row.type === 'spielzeit') {
        const currentMin = Math.floor(Number(row.current || 0) / 60);
        const targetMin = Math.max(1, Math.round(Number(row.target || 0) / 60));
        const remaining = Math.max(0, targetMin - currentMin);
        status = `${currentMin} / ${targetMin} Min.`;
        detail = `Noch ${remaining} Min. bis +${Number(row.rewardPoints || 0)} Punkte und +${Number(row.rewardScore || 0)} Event-Punkte.`;
      } else if (row.type === 'paldex') {
        status = `${Number(row.current || 0)} / ${Number(row.target || 0)} Arten`;
        detail = row.complete
          ? 'Alle aktuell hinterlegten Paldex-Meilensteine erreicht.'
          : `Belohnung: +${Number(row.rewardPoints || 0)} Punkte und +${Number(row.rewardScore || 0)} Event-Punkte.`;
      } else {
        status = row.complete ? 'Rang 1' : `${Number(row.current || 0).toLocaleString('de-DE')} / ${Number(row.target || 0).toLocaleString('de-DE')} Event-Punkte`;
        detail = row.complete ? 'Du stehst aktuell an der Spitze.' : `Noch ${Number(row.pointsToNextRank || 0).toLocaleString('de-DE')} Event-Punkte bis zum nächsten Rangplatz.`;
      }
      return `<article class="milestone-card ${esc(row.type)}${row.complete ? ' complete' : ''}">
        <div class="milestone-top"><span>${esc(row.title)}</span><b>${Math.round(pct)}%</b></div>
        <strong>${esc(status)}</strong>
        <div class="milestone-track"><i style="width:${pct.toFixed(1)}%"></i></div>
        <small>${esc(detail)}</small>
      </article>`;
    }).join('');
  }

  function renderActivity(rows = []) {
    const root = $('activityFeed');
    if (!root) return;
    $('activityCount').textContent = rows.length ? `${rows.length} Einträge` : '0 Einträge';
    if (!rows.length) {
      root.innerHTML = '<div class="adventure-empty">Noch keine Aktivitäten vorhanden.</div>';
      return;
    }
    root.innerHTML = rows.map(row => {
      const amount = Number(row.amount || 0);
      const amountText = amount === 0 ? 'nur Statistik' : `${amount > 0 ? '+' : ''}${amount.toLocaleString('de-DE')} Punkte`;
      return `<article class="activity-row" data-kind="${esc(row.kind)}">
        <div class="activity-mark"><i></i></div>
        <div class="activity-copy"><span>${kindLabel(row.kind)}</span><strong>${esc(prettyReason(row.label))}</strong><small>${fmtDate(row.at)}</small></div>
        <b class="activity-amount${amount < 0 ? ' negative' : ''}${amount === 0 ? ' neutral' : ''}">${esc(amountText)}</b>
      </article>`;
    }).join('');
  }

  function renderDiscoveries(rows = []) {
    const root = $('recentDiscoveries');
    if (!root) return;
    $('discoveryCount').textContent = `${rows.length} ${rows.length === 1 ? 'Art' : 'Arten'}`;
    if (!rows.length) {
      root.innerHTML = '<div class="adventure-empty">Noch keine neuen Pal-Arten entdeckt.</div>';
      return;
    }
    root.innerHTML = rows.map((row, index) => `<article class="discovery-row">
      <b>${String(index + 1).padStart(2, '0')}</b>
      <div><strong>${esc(prettyName(row.speciesKey))}</strong><small>${fmtDate(row.discoveredAt)}${row.alphaSeen ? ' · Alpha erfasst' : ''}</small></div>
      <em>×${Number(row.captures || 1)}</em>
    </article>`).join('');
  }

  function renderMiniHistory(targetId, rows, type) {
    const root = $(targetId);
    if (!root) return;
    if (!rows?.length) {
      root.innerHTML = `<span>${type === 'alpha' ? 'Noch keine Alpha-Fänge.' : 'Noch keine Boss-Abschlüsse.'}</span>`;
      return;
    }
    root.innerHTML = rows.map(row => {
      const name = type === 'alpha' ? prettyName(row.speciesKey) : prettyName(row.bossKey);
      const at = type === 'alpha' ? row.capturedAt : row.completedAt;
      return `<div><strong>${esc(name)}</strong><small>${fmtDate(at)}</small></div>`;
    }).join('');
  }

  function renderSources(rows = [], balance = 0) {
    const root = $('pointSources');
    if (!root) return;
    $('sourceBalance').textContent = `${Number(balance || 0).toLocaleString('de-DE')} Punkte`;
    if (!rows.length) {
      root.innerHTML = '<div class="adventure-empty">Noch keine Punktebewegungen.</div>';
      return;
    }
    const max = Math.max(1, ...rows.map(row => Math.abs(Number(row.amount || 0))));
    root.innerHTML = rows.map(row => {
      const amount = Number(row.amount || 0);
      const width = Math.max(4, Math.abs(amount) / max * 100);
      return `<article class="source-row${amount < 0 ? ' negative' : ''}">
        <div><span>${esc(row.label)}</span><b>${amount > 0 ? '+' : ''}${amount.toLocaleString('de-DE')}</b></div>
        <div class="source-track"><i style="width:${width.toFixed(1)}%"></i></div>
      </article>`;
    }).join('');
  }

  function renderSummary(summary = {}) {
    $('heroLevel').textContent = summary.level ?? '—';
    $('heroPoints').textContent = Number(summary.points || 0).toLocaleString('de-DE');
    $('heroScore').textContent = Number(summary.eventScore || 0).toLocaleString('de-DE');
    $('heroRank').textContent = `#${Number(summary.rank || 1).toLocaleString('de-DE')}`;
    $('heroCharacter').textContent = summary.characterName ? `Charakter: ${summary.characterName}` : 'Charakter noch nicht verbunden';
    $('heroOnlineState').textContent = summary.characterName ? 'Charakter verbunden' : 'Verknüpfung ausstehend';
    $('profileUniquePals').textContent = Number(summary.uniquePals || 0).toLocaleString('de-DE');
    $('profileCaptures').textContent = Number(summary.totalCaptures || 0).toLocaleString('de-DE');
    $('profileAlphaCaptures').textContent = Number(summary.alphaCaptures || 0).toLocaleString('de-DE');
    $('profileBossKills').textContent = Number(summary.bossKills || 0).toLocaleString('de-DE');
    $('profileLevelUps').textContent = Number(summary.levelUps || 0).toLocaleString('de-DE');
    $('profileDeaths').textContent = Number(summary.deaths || 0).toLocaleString('de-DE');
    $('profilePlaytime').textContent = fmtPlaytime(summary.playtimeSeconds);
    $('profileLastSeen').textContent = fmtDate(summary.lastSeenAt);
  }

  async function renderProfile() {
    const me = await window.PalAccount.refresh();
    const authenticated = !!me?.authenticated;
    $('profileGate')?.classList.toggle('hidden', authenticated);
    $('profileData')?.classList.toggle('hidden', !authenticated);
    if (!authenticated) return;

    const user = me.user;
    const badge = $('profileLinkBadge');
    if (badge) {
      badge.textContent = user.linked ? 'VERBUNDEN' : 'NICHT VERBUNDEN';
      badge.className = user.linked ? 'linked' : '';
    }
    $('profileLinkHelp').textContent = user.linked
      ? `Verbunden mit ${user.character?.name || 'deinem Charakter'}. PalPanel hält deinen Fortschritt automatisch aktuell.`
      : 'Betritt den Palworld-Server mit diesem Steam-Konto und starte danach erneut die Suche.';

    try {
      const adventure = await api('/api/user/adventure');
      renderSummary(adventure.summary || {});
      renderMilestones(adventure.milestones || []);
      renderActivity(adventure.recentEvents || []);
      renderDiscoveries(adventure.discoveries || []);
      renderMiniHistory('recentAlphas', adventure.recentAlphas || [], 'alpha');
      renderMiniHistory('recentBosses', adventure.recentBosses || [], 'boss');
      renderSources(adventure.pointSources || [], adventure.summary?.points || 0);
    } catch (err) {
      console.warn('[Profil] Abenteuerdaten konnten nicht geladen werden:', err.message);
    }
  }

  $('profileRelink')?.addEventListener('click', async () => {
    const btn = $('profileRelink');
    btn.disabled = true;
    btn.textContent = 'SERVER WIRD GEPRÜFT…';
    try {
      await api('/api/user/relink', { method: 'POST', body: '{}' });
      await renderProfile();
      btn.textContent = 'PRÜFUNG ABGESCHLOSSEN ✓';
    } catch {
      btn.textContent = 'PRÜFUNG FEHLGESCHLAGEN';
    }
    setTimeout(() => {
      btn.disabled = false;
      btn.textContent = 'Server erneut prüfen ↻';
    }, 1800);
  });

  setTimeout(renderProfile, 0);
  setInterval(() => document.visibilityState === 'visible' && renderProfile(), 30000);
})();
