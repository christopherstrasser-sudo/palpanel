(() => {
  const frame = document.getElementById('profileAvatarFrame');
  const image = document.getElementById('profileSteamAvatar');
  const fallback = document.getElementById('profileAvatarFallback');
  const name = document.getElementById('profileSteamName');
  if (!frame || !image || !fallback) return;

  let renderedUserId = null;

  function apply(user) {
    if (!user) return;
    const displayName = user.character?.accountName || user.displayName || user.character?.name || 'Steam-Konto';
    const initial = String(displayName).trim().charAt(0).toUpperCase() || '?';
    fallback.textContent = initial;
    if (name) name.textContent = displayName;

    const steamId = String(user.steamId || '');
    if (!/^\d{17}$/.test(steamId)) {
      frame.classList.remove('loaded');
      image.removeAttribute('src');
      return;
    }

    if (renderedUserId === steamId && image.getAttribute('src')) return;
    renderedUserId = steamId;
    frame.classList.remove('loaded');
    image.onload = () => frame.classList.add('loaded');
    image.onerror = () => {
      frame.classList.remove('loaded');
      image.removeAttribute('src');
    };
    image.src = `/api/steam/avatar/${steamId}`;
  }

  async function refresh() {
    try {
      const result = await window.PalAccount?.refresh?.();
      if (result?.authenticated) apply(result.user);
    } catch {}
  }

  window.addEventListener('DOMContentLoaded', refresh, { once: true });
  setTimeout(refresh, 250);
  setInterval(() => document.visibilityState === 'visible' && refresh(), 30000);
})();
