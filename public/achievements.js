(() => {
  const esc = value => String(value ?? '').replace(/[&<>"']/g, c => ({ '&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;' }[c]));
  const prettyName = value => String(value || '').trim()
    .replace(/^TowerType:/i,'Turm ').replace(/^Tower:/i,'')
    .replace(/^BOSS_/i,'').replace(/^Boss_/i,'')
    .replace(/_/g,' ').replace(/([a-zäöüß])([A-ZÄÖÜ])/g,'$1 $2')
    .replace(/\s+/g,' ').trim() || 'Unbekannt';
  const fmtPlaytime = seconds => {
    const s = Math.max(0, Number(seconds) || 0), h = Math.floor(s / 3600), m = Math.floor(s / 60) % 60;
    return `${h}h ${String(m).padStart(2,'0')}m`;
  };
  const tierLabel = tier => ({ bronze:'BRONZE', silver:'SILBER', gold:'GOLD', legendary:'LEGENDÄR' })[tier] || String(tier || '').toUpperCase();

  function rarestCard(rare) {
    if (!rare) return `<article class="rarest-card"><span class="rarest-label">SELTENSTER FANG</span><h3>Noch offen</h3><p>Sobald der erste Pal erfasst wurde, beginnt PalPanel seine Community-Seltenheit zu berechnen.</p><span class="rarity-pill pioneer">NOCH KEINE DATEN</span></article>`;
    const holders = Number(rare.holders || 0), total = Number(rare.communityHunters || 0);
    return `<article class="rarest-card">
      <span class="rarest-label">SELTENSTER FANG</span>
      <h3>${esc(prettyName(rare.speciesKey))}</h3>
      <p>${rare.alphaSeen ? 'Alpha erfasst · ' : ''}${holders} von ${total || holders} ${total === 1 ? 'Entdecker' : 'Entdeckern'} haben diese Art bisher gefangen.</p>
      <span class="rarity-pill ${esc(rare.rarity?.key || 'common')}">${esc(rare.rarity?.label || 'SELTENHEIT')}</span>
      <div class="rarity-meta"><span>${Number(rare.sharePercent || 0).toLocaleString('de-DE')}% der Community</span><span>×${Number(rare.captures || 1)} eigener Fang</span></div>
    </article>`;
  }

  function badgeCard(item) {
    return `<article class="achievement-badge${item.unlocked ? ' unlocked' : ''}" data-tier="${esc(item.tier)}">
      <div class="badge-top"><i class="badge-icon">${esc(item.icon)}</i><span class="badge-tier">${esc(tierLabel(item.tier))}${item.unlocked ? ' · FREIGESCHALTET' : ''}</span></div>
      <strong>${esc(item.title)}</strong><small>${esc(item.description)}</small>
      <div class="achievement-progress"><i style="width:${Math.max(0,Math.min(100,Number(item.progress)||0)).toFixed(1)}%"></i></div>
    </article>`;
  }

  function renderProfile(data, options = {}) {
    const isPublic = !!options.publicMode;
    const anchor = document.querySelector(isPublic ? '.public-profile-stat-grid' : '.adventure-stat-grid');
    if (!anchor) return;
    let section = document.getElementById(isPublic ? 'publicAchievementSection' : 'achievementSection');
    if (!section) {
      section = document.createElement('section');
      section.id = isPublic ? 'publicAchievementSection' : 'achievementSection';
      section.className = 'achievement-section';
      anchor.insertAdjacentElement('afterend', section);
    }
    const all = Array.isArray(data?.achievements) ? data.achievements : [];
    const visible = isPublic ? all.filter(item => item.unlocked) : all;
    section.innerHTML = `<div class="achievement-head"><div><span>TROPHÄEN & SELTENHEIT</span><h2>${isPublic ? 'Spuren in der Gemeinschaft.' : 'Deine Trophäensammlung.'}</h2></div><div class="achievement-summary"><b>${Number(data?.unlockedCount || 0)} / ${Number(data?.totalCount || all.length)} ERFOLGE</b><b>${Number(data?.trophyValue || 0).toLocaleString('de-DE')} TROPHÄENWERT</b></div></div>
      <div class="achievement-showcase">${rarestCard(data?.rarestCapture)}<div class="achievement-grid">${visible.length ? visible.map(badgeCard).join('') : '<div class="public-profile-empty">Noch keine Erfolge freigeschaltet.</div>'}</div></div>`;
  }

  function metricValue(row, metric) {
    if (metric === 'uniquePals') return `${Number(row.uniquePals || 0)} Arten`;
    if (metric === 'alphaCaptures') return `${Number(row.alphaCaptures || 0)} Alpha`;
    if (metric === 'bossKills') return `${Number(row.bossKills || 0)} Bosse`;
    if (metric === 'playtimeSeconds') return fmtPlaytime(row.playtimeSeconds);
    if (metric === 'trophyValue') return `${Number(row.trophyValue || 0)} TP`;
    return String(row[metric] ?? '—');
  }
  function competitionCard(label, title, rows, metric) {
    const list = (rows || []).slice(0,5);
    return `<article class="competition-card"><span>${esc(label)}</span><h3>${esc(title)}</h3><div class="competition-list">${list.length ? list.map((row,i) => `<a class="competition-row" href="/player/${Number(row.userId)}"><b>${String(i+1).padStart(2,'0')}</b><strong>${esc(row.name)}</strong><em>${esc(metricValue(row,metric))}</em></a>`).join('') : '<div class="public-profile-empty">Noch keine Daten.</div>'}</div></article>`;
  }

  function renderCompetition(data) {
    const ranking = document.getElementById('ranking');
    if (!ranking) return;
    let section = document.getElementById('communityCompetition');
    if (!section) {
      section = document.createElement('section');
      section.id = 'communityCompetition';
      section.className = 'content-section community-competition';
      ranking.insertAdjacentElement('afterend', section);
    }
    const rare = Array.isArray(data?.rareSpecies) ? data.rareSpecies : [];
    section.innerHTML = `<div class="competition-head"><div><span>COMMUNITY-DUELLE</span><h2>Nicht nur Event-Punkte zählen.</h2></div><p>Wer sammelt am meisten, jagt die meisten Alphas, besiegt Bosse und baut die stärkste Trophäensammlung auf?</p></div>
      <div class="competition-grid">
        ${competitionCard('PALDEX','Die Sammler',data?.collectors,'uniquePals')}
        ${competitionCard('ALPHA','Die Jäger',data?.alphaHunters,'alphaCaptures')}
        ${competitionCard('BOSSE','Die Bezwinger',data?.bossHunters,'bossKills')}
        ${competitionCard('SPIELZEIT','Die Veteranen',data?.veterans,'playtimeSeconds')}
        ${competitionCard('TROPHÄEN','Die Legenden',data?.trophyLeaders,'trophyValue')}
      </div>
      ${rare.length ? `<div class="rare-species-strip">${rare.map(row => `<span class="rare-species-chip"><b>${esc(row.rarity?.label || 'SELTEN')}</b>${esc(prettyName(row.speciesKey))} · ${Number(row.holders || 0)} Besitzer</span>`).join('')}</div>` : ''}`;
  }

  window.PalAchievements = { renderProfile, renderCompetition, prettyName };
})();
