(() => {
  if (location.pathname !== '/' && location.pathname !== '') return;

  const esc = value => String(value ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
  const num = value => Number(value || 0);
  const fmt = value => num(value).toLocaleString('de-DE');
  const prettyName = value => String(value || '').trim()
    .replace(/^TowerType:/i,'Turm ').replace(/^Tower:/i,'')
    .replace(/^BOSS_/i,'').replace(/^Boss_/i,'')
    .replace(/_/g,' ').replace(/([a-zäöüß])([A-ZÄÖÜ])/g,'$1 $2')
    .replace(/\s+/g,' ').trim() || 'Unbekannt';

  async function api(url) {
    const res = await fetch(url, { credentials:'same-origin', headers:{ Accept:'application/json' } });
    if (res.status === 401) return null;
    const data = await res.json().catch(() => ({}));
    if (!res.ok) throw new Error(data.error || `HTTP ${res.status}`);
    return data;
  }

  function ensureSection() {
    let section = document.getElementById('playerDashboard');
    if (section) return section;
    const anchor = document.querySelector('.status-strip') || document.querySelector('.hero');
    if (!anchor) return null;
    section = document.createElement('section');
    section.id = 'playerDashboard';
    section.className = 'player-dashboard hidden';
    anchor.insertAdjacentElement('afterend', section);
    return section;
  }

  function missionRow(row) {
    const pct = Math.max(0, Math.min(100, num(row.progress)));
    const state = row.claimed ? 'ABGEHOLT' : row.claimable ? 'ABHOLBEREIT' : row.complete ? 'ERLEDIGT' : `${Math.round(pct)}%`;
    return `<a class="dashboard-mission${row.claimable ? ' claimable' : ''}${row.complete ? ' complete' : ''}" href="/missions">
      <i>${esc(row.icon || '☷')}</i>
      <div><span>${esc(row.title || 'Wochenmission')}</span><small>${fmt(row.current)} / ${fmt(row.target)}</small><em><b style="width:${pct.toFixed(1)}%"></b></em></div>
      <strong>${esc(state)}</strong>
    </a>`;
  }

  function noticeRow(row) {
    return `<a class="dashboard-notice" href="${esc(row.href || '/profile')}">
      <i>${esc(row.icon || '✦')}</i><div><strong>${esc(row.title)}</strong><small>${esc(row.message)}</small></div><b>→</b>
    </a>`;
  }

  function render(data) {
    const root = ensureSection();
    if (!root) return;
    const { me, adventure, achievements, missions, season, notifications } = data;
    if (!me?.authenticated) {
      root.classList.add('hidden');
      root.innerHTML = '';
      return;
    }

    const user = me.user || {};
    const summary = adventure?.summary || {};
    const achievementRows = Array.isArray(achievements?.achievements) ? achievements.achievements : [];
    const unlocked = achievementRows.filter(x => x.unlocked);
    const missionRows = Array.isArray(missions?.missions) ? missions.missions : [];
    const missionSummary = missions?.summary || {};
    const seasonPersonal = season?.personal || null;
    const seasonCommunity = season?.community || null;
    const notices = Array.isArray(notifications?.notifications) ? notifications.notifications : [];
    const unread = num(notifications?.unread);
    const unreadRows = notices.filter(x => !x.read).slice(0,3);
    const recentAchievements = notices.filter(x => x.type === 'achievement').slice(0,2);
    const rare = achievements?.rarestCapture || null;
    const claimableMissions = missionRows.filter(x => x.claimable).length;
    const claimableSeason = Array.isArray(season?.rewards) ? season.rewards.filter(x => x.claimable).length : 0;

    const priorityMissions = missionRows
      .slice()
      .sort((a,b) => Number(b.claimable)-Number(a.claimable) || Number(a.claimed)-Number(b.claimed) || num(b.progress)-num(a.progress))
      .slice(0,3);

    const personalPct = Math.round(num(seasonPersonal?.progress));
    const communityPct = Math.round(num(seasonCommunity?.progress));
    const displayName = user.displayName || summary.characterName || 'Entdecker';
    const rank = num(summary.rank || 1);
    const points = num(summary.points ?? user.points);
    const eventScore = num(summary.eventScore);
    const trophyValue = num(achievements?.trophyValue);

    const actionBits = [];
    if (claimableMissions) actionBits.push(`${claimableMissions} Missionsbelohnung${claimableMissions === 1 ? '' : 'en'} bereit`);
    if (claimableSeason) actionBits.push(`${claimableSeason} Saisonbelohnung${claimableSeason === 1 ? '' : 'en'} bereit`);
    if (unread) actionBits.push(`${unread} ${unread === 1 ? 'ungelesener Hinweis' : 'ungelesene Hinweise'}`);

    root.innerHTML = `<div class="dashboard-head">
      <div><span>DEIN PALPANEL</span><h2>Willkommen zurück, ${esc(displayName)}.</h2><p>${actionBits.length ? esc(actionBits.join(' · ')) : 'Alles im Blick. Dein nächster Fortschritt wartet schon.'}</p></div>
      <a href="/profile">Vollständiges Profil <b>→</b></a>
    </div>
    <div class="dashboard-stat-grid">
      <a href="/#ranking"><span>RANG</span><strong>#${fmt(rank)}</strong><small>${fmt(eventScore)} Event-Punkte</small></a>
      <a href="/shop"><span>GUTHABEN</span><strong>${fmt(points)}</strong><small>Shop-Punkte</small></a>
      <a href="/profile"><span>TROPHÄEN</span><strong>${fmt(trophyValue)}</strong><small>${fmt(achievements?.unlockedCount || unlocked.length)} Erfolge</small></a>
      <button id="dashboardInboxOpen" type="button"><span>INBOX</span><strong>${fmt(unread)}</strong><small>${unread ? 'ungelesene Hinweise' : 'alles gelesen'}</small></button>
    </div>
    <div class="dashboard-main-grid">
      <article class="dashboard-panel dashboard-weekly">
        <div class="dashboard-panel-head"><div><span>DIESE WOCHE</span><h3>Wochenmissionen</h3></div><b>${fmt(missionSummary.completed)} / ${fmt(missionSummary.total || missionRows.length)}</b></div>
        <div class="dashboard-mission-list">${priorityMissions.length ? priorityMissions.map(missionRow).join('') : '<div class="dashboard-empty">Noch keine Wochenmissionen verfügbar.</div>'}</div>
        <a class="dashboard-panel-link" href="/missions">Alle Missionen öffnen <b>→</b></a>
      </article>
      <article class="dashboard-panel dashboard-season">
        <div class="dashboard-panel-head"><div><span>SAISON</span><h3>${esc(season?.season?.title || 'Community-Event')}</h3></div><b>${personalPct}%</b></div>
        <div class="dashboard-season-meter"><div style="--dashboard-season:${personalPct}"><strong>${personalPct}%</strong><span>DEIN FORTSCHRITT</span></div></div>
        <div class="dashboard-season-bars">
          <div><span>Persönlich <b>${personalPct}%</b></span><em><i style="width:${Math.max(0,Math.min(100,personalPct))}%"></i></em></div>
          <div><span>Community <b>${communityPct}%</b></span><em><i style="width:${Math.max(0,Math.min(100,communityPct))}%"></i></em></div>
        </div>
        <a class="dashboard-panel-link" href="/event">Zum Saison-Event <b>→</b></a>
      </article>
      <article class="dashboard-panel dashboard-highlight">
        <div class="dashboard-panel-head"><div><span>DEIN HIGHLIGHT</span><h3>${rare ? 'Seltenster Fang' : 'Deine Expedition'}</h3></div><b>${rare ? esc(rare.rarity?.label || 'SELTEN') : '✦'}</b></div>
        ${rare ? `<div class="dashboard-rare"><i>◆</i><strong>${esc(prettyName(rare.speciesKey))}</strong><p>${rare.alphaSeen ? 'Alpha · ' : ''}${fmt(rare.holders)} von ${fmt(rare.communityHunters || rare.holders)} Community-Jägern besitzen diese Art.</p><span>${num(rare.sharePercent).toLocaleString('de-DE')}% der Community</span></div>` : '<div class="dashboard-empty">Sobald PalPanel Fänge erfasst, erscheint hier dein seltenstes Community-Fundstück.</div>'}
        <div class="dashboard-recent-achievements">${recentAchievements.length ? recentAchievements.map(x => `<span><i>${esc(x.icon || '✦')}</i><b>${esc(x.title)}</b></span>`).join('') : `<span><i>✦</i><b>${fmt(achievements?.unlockedCount || unlocked.length)} Erfolge freigeschaltet</b></span>`}</div>
        <a class="dashboard-panel-link" href="/profile">Trophäen ansehen <b>→</b></a>
      </article>
    </div>
    ${unreadRows.length ? `<div class="dashboard-alert-strip"><div><span>NEU FÜR DICH</span><strong>${unreadRows.length === 1 ? 'Ein Hinweis braucht deine Aufmerksamkeit.' : 'Das ist seit deinem letzten Blick passiert.'}</strong></div><div class="dashboard-alert-list">${unreadRows.map(noticeRow).join('')}</div></div>` : ''}`;

    root.classList.remove('hidden');
    document.getElementById('dashboardInboxOpen')?.addEventListener('click', () => document.getElementById('notificationTrigger')?.click());
  }

  async function refresh() {
    try {
      const me = await api('/api/user/me');
      if (!me?.authenticated) return render({ me });
      const [adventure, achievements, missions, season, notifications] = await Promise.all([
        api('/api/user/adventure'),
        api('/api/user/achievements'),
        api('/api/user/missions'),
        api('/api/user/season'),
        api('/api/user/notifications')
      ]);
      render({ me, adventure, achievements, missions, season, notifications });
    } catch (err) {
      console.warn('[PlayerDashboard]', err.message);
    }
  }

  const start = () => {
    ensureSection();
    setTimeout(refresh, 180);
    setInterval(() => document.visibilityState === 'visible' && refresh(), 30000);
  };
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', start, { once:true });
  else start();
})();
