(() => {
  async function api(url) {
    const res = await fetch(url, { credentials: 'same-origin', headers: { Accept: 'application/json' } });
    if (res.status === 401) return null;
    const data = await res.json().catch(() => ({}));
    if (!res.ok) throw new Error(data.error || `HTTP ${res.status}`);
    return data;
  }

  async function refresh() {
    try {
      if (location.pathname === '/' || location.pathname === '') {
        const data = await api('/api/public/community/competition');
        if (data) window.PalAchievements?.renderCompetition(data);
        return;
      }
      if (location.pathname === '/profile' || location.pathname === '/profile/') {
        const data = await api('/api/user/achievements');
        if (data) window.PalAchievements?.renderProfile(data, { publicMode: false });
        return;
      }
      const match = location.pathname.match(/^\/player\/(\d+)\/?$/);
      if (match) {
        const data = await api(`/api/public/player/${match[1]}/achievements`);
        if (data) window.PalAchievements?.renderProfile(data, { publicMode: true });
      }
    } catch (err) {
      console.warn('[AchievementsUI]', err.message);
    }
  }

  const start = () => {
    setTimeout(refresh, 120);
    setInterval(() => {
      if (document.visibilityState === 'visible') refresh();
    }, location.pathname === '/' ? 15000 : 30000);
  };
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', start, { once: true });
  else start();
})();
