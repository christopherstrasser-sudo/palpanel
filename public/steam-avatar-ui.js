(() => {
  const $ = id => document.getElementById(id);

  function renderAvatar(user = {}) {
    const frame = $('profileAvatarFrame');
    const image = $('profileSteamAvatar');
    const fallback = $('profileAvatarFallback');
    const name = $('profileSteamName');
    if (!frame || !image || !fallback || !name) return;

    const displayName = String(user.displayName || user.character?.name || 'Spieler');
    fallback.textContent = displayName.charAt(0).toUpperCase() || '?';
    name.textContent = displayName;
    image.alt = `Steam-Profilbild von ${displayName}`;

    frame.classList.remove('loaded');
    image.onload = () => frame.classList.add('loaded');
    image.onerror = () => {
      frame.classList.remove('loaded');
      image.removeAttribute('src');
    };

    const steamId = String(user.steamId || '');
    if (/^\d{17}$/.test(steamId)) image.src = `/api/steam/avatar/${encodeURIComponent(steamId)}`;
    else image.removeAttribute('src');
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
