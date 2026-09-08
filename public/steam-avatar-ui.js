(() => {
  const $ = id => document.getElementById(id);
  let renderedSteamId = '';

  function renderAvatar(user = {}) {
    const frame = $('profileAvatarFrame');
    const image = $('profileSteamAvatar');
    const fallback = $('profileAvatarFallback');
    const name = $('profileSteamName');
    if (!frame || !image || !fallback || !name) return;

    const displayName = String(user.character?.accountName || user.displayName || user.character?.name || 'Steam-Konto').trim();
    fallback.textContent = displayName.charAt(0).toUpperCase() || '?';
    name.textContent = displayName;
    image.alt = `Steam-Profilbild von ${displayName}`;

    const steamId = String(user.steamId || '');
    if (!/^\d{17}$/.test(steamId)) {
      renderedSteamId = '';
      frame.classList.remove('loaded');
      image.removeAttribute('src');
      return;
    }
    if (renderedSteamId === steamId && image.getAttribute('src')) return;
    renderedSteamId = steamId;

    frame.classList.remove('loaded');
    image.onload = () => frame.classList.add('loaded');
    image.onerror = () => {
      frame.classList.remove('loaded');
      renderedSteamId = '';
      image.removeAttribute('src');
    };
    image.src = `/api/steam/avatar/${steamId}`;
  }

  async function refresh() {
    try {
      const account = await window.PalAccount?.refresh?.();
      if (account?.authenticated) renderAvatar(account.user || {});
    } catch {}
  }

  setTimeout(refresh, 80);
  setInterval(() => document.visibilityState === 'visible' && refresh(), 30000);
})();
