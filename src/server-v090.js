const http = require('http');

function escapeHtml(value) {
  return String(value ?? '').replace(/[&<>"']/g, char => ({
    '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;'
  })[char]);
}

function sendHtml(res, html) {
  const body = Buffer.from(html);
  res.writeHead(200, {
    'Content-Type': 'text/html; charset=utf-8',
    'Content-Length': body.length,
    'Cache-Control': 'no-cache'
  });
  res.end(body);
}

function redirect(res, location) {
  res.writeHead(302, { Location: location, 'Cache-Control': 'no-store' });
  res.end();
}

function sharedDrawer() {
  return `
  <div id="accountShade" class="account-shade"></div>
  <aside id="accountDrawer" class="account-drawer" aria-hidden="true">
    <div class="drawer-head"><div><small>PALPANEL-IDENTITÄT</small><strong>Dein Abenteuer</strong></div><button id="accountClose">×</button></div>
    <div class="identity-mark"><i id="accountInitial">?</i><div><small>VERBUNDENER SPIELER</small><h2 id="accountName">—</h2><code id="accountSteamId">—</code></div></div>
    <div class="identity-status"><div><small>CHARAKTER</small><strong id="accountLinkState">PRÜFE</strong></div><div><small>PUNKTE</small><strong id="drawerPoints">0</strong></div><div><small>STUFE</small><strong id="accountLevel">—</strong></div></div>
    <div id="accountLinkNotice" class="link-notice"><b>Charakter noch nicht gefunden</b><p>Betritt den Palworld-Server mit diesem Steam-Konto und prüfe danach erneut.</p><button id="relinkBtn">Erneut suchen</button></div>
    <nav class="identity-nav"><a href="/profile">Mein Profil <b>→</b></a><a href="/shop">Punkteshop <b>→</b></a><a id="steamProfileLink" target="_blank" rel="noopener">Steam-Profil <b>↗</b></a></nav>
    <button id="userLogout" class="drawer-logout">Steam-Sitzung trennen</button>
  </aside>`;
}

function navFor(route) {
  const active = key => route === key ? ' class="active"' : '';
  return `<nav class="mainnav">
    <a${active('home')} href="/">Start</a>
    <a href="/#world">Welt</a>
    <a href="/#ranking">Rangliste</a>
    <a${active('profile')} href="/profile">Profil</a>
    <a${active('shop')} href="/shop">Punkteshop</a>
  </nav>`;
}

function shell({ title, subtitle, route, styles = [], main, footerText, scripts = [], extraBody = '' }) {
  const css = [
    '/styles.css',
    '/progression.css',
    '/palworld-theme.css',
    ...styles
  ].map(href => `<link rel="stylesheet" href="${href}">`).join('\n  ');
  const js = ['/account.js?v=0900', ...scripts].map(src => `<script src="${src}"></script>`).join('\n  ');
  return `<!doctype html>
<html lang="de">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <title>${escapeHtml(title)}</title>
  ${css}
</head>
<body>
  <div class="ambient ambient-a"></div><div class="ambient ambient-b"></div>
  <header class="topnav">
    <a class="brand" href="/"><span class="brand-orb">P</span><div><strong>PalPanel</strong><small>${escapeHtml(subtitle)}</small></div></a>
    ${navFor(route)}
    <div class="nav-actions"><button id="accountTrigger" class="account-trigger"><i></i><span><small>SPIELERKONTO</small><b id="accountTriggerText">Mit Steam anmelden</b></span><em id="accountPoints"></em></button></div>
  </header>
  ${sharedDrawer()}
  ${main}
  <footer><div class="brand footer-brand"><span class="brand-orb">P</span><div><strong>PalPanel</strong><small>${escapeHtml(subtitle)}</small></div></div><span>${escapeHtml(footerText)}</span><i>© 2026</i></footer>
  ${extraBody}
  ${js}
</body>
</html>`;
}

function homeView() {
  return shell({
    title: 'PalPanel // Gemeinschaftswelt',
    subtitle: 'GEMEINSAME WELT',
    route: 'home',
    styles: ['/banner-fix.css', '/ui-polish.css?v=0900', '/v088-final.css?v=0900', '/public-player.css?v=0900'],
    footerText: 'Ein Server. Eine Welt. Eure Geschichte.',
    scripts: ['/app.js?v=0900'],
    main: `<main>
    <section class="hero">
      <div class="hero-image"><img class="hero-banner" src="/palpanel-banner.png" alt="Palworld-Gemeinschaft"><div class="hero-image-overlay"></div><div class="hero-badge"><span>PALPAGOS-GEMEINSCHAFT</span><b>AKTIV</b></div></div>
      <div class="hero-panel"><div class="hero-copy"><span class="eyebrow">DEIN GEMEINSCHAFTSSERVER</span><h1 id="eventTitle">Palworld-Gemeinschaftsevent</h1><p id="serverDescription">Eine gemeinsame Welt, aktuelle Spielerdaten, Ranglisten und dein persönlicher Fortschritt an einem Ort.</p></div><div class="hero-countdown"><small id="countdownLabel">EVENTZEIT</small><strong id="countdown">-- : -- : -- : --</strong><div class="countdown-legend"><span>Tage</span><span>Std.</span><span>Min.</span><span>Sek.</span></div></div></div>
    </section>
    <section class="status-strip">
      <article><span>SERVER</span><strong id="serverState">PRÜFE…</strong><small id="serverName">Palworld-Server</small></article>
      <article><span>SPIELER</span><strong id="playerCount">—</strong><small id="maxPlayers">von 32 Plätzen</small></article>
      <article><span>LEISTUNG</span><strong id="serverFps">—</strong><small id="frameTime">Bilder/s</small></article>
      <article><span>LAUFZEIT</span><strong id="serverUptime">—</strong><small id="gameVersion">Palworld</small></article>
    </section>
    <section class="content-section" id="world">
      <div class="section-heading"><div><span>AKTUELLE WELT</span><h2>Was gerade auf dem Server passiert.</h2><p>Aktive Spieler und ihre aktuelle Position direkt aus dem Gameserver.</p></div><b id="apiChip" class="api-chip">AKTUELLE DATEN —</b></div>
      <div class="world-grid"><div class="map-card"><div class="map-toolbar"><span>PALPAGOS-WELTKARTE</span><small>AKTUELLE POSITIONEN</small></div><div id="liveMap" class="live-map"><div class="map-cross x"></div><div class="map-cross y"></div><span id="mapEmpty" class="map-empty">Noch keine Positionsdaten</span><div class="map-glow"></div></div></div><aside class="players-card"><div class="players-head"><div><span>AKTIV</span><h3>Spieler in der Welt</h3></div><b id="playersHint">Synchronisiere…</b></div><div id="onlinePlayers" class="online-list"><div class="ranking-row"><span>—</span><strong>Noch keine Daten</strong><em>—</em></div></div></aside></div>
    </section>
    <section class="content-section" id="ranking">
      <div class="section-heading"><div><span>GEMEINSCHAFT</span><h2>Wer hinterlässt die größte Spur?</h2><p>Die Event-Punkte bleiben dauerhaft bestehen. Käufe im Punkteshop verändern deine Ranglistenposition nicht. Klicke auf einen Spieler, um sein öffentliches Abenteuerprofil zu öffnen.</p></div></div>
      <div class="ranking-layout"><section class="leaderboard-card"><div class="card-title"><span>EVENT-PUNKTE</span><h3>Rangliste</h3></div><div id="publicLeaderboard" class="public-leaderboard"><div class="public-rank empty"><b>—</b><strong>Noch keine Ranglistendaten</strong><i>0</i></div></div></section><section class="profile-teaser"><div><span>DEINE EXPEDITION</span><h3>Alles, was du auf dem Server erreichst.</h3><p>Steam-Anmeldung, Charakter-Verknüpfung, Spielzeit, Paldex-Fortschritt, Punkte und Event-Punkte.</p></div><a href="/profile">Mein Profil öffnen <b>→</b></a></section></div>
    </section>
  </main>`
  });
}

function profileView() {
  return shell({
    title: 'PalPanel // Meine Expedition',
    subtitle: 'MEINE EXPEDITION',
    route: 'profile',
    styles: ['/ui-polish.css?v=0900', '/v088-final.css?v=0900'],
    footerText: 'Deine Geschichte auf diesem Server.',
    scripts: ['/profile.js?v=0900', '/steam-avatar-ui.js?v=0900'],
    main: `<main class="profile-shell adventure-profile">
    <section class="profile-banner adventure-hero">
      <div class="profile-banner-content">
        <div class="profile-steam-identity">
          <div id="profileAvatarFrame" class="profile-steam-avatar"><span id="profileAvatarFallback">?</span><img id="profileSteamAvatar" alt="Steam-Profilbild"><i></i></div>
          <div class="profile-steam-meta"><small>STEAM-PROFIL</small><strong id="profileSteamName">Spielerprofil</strong><span>Mit PalPanel verbunden</span></div>
        </div>
        <span class="profile-kicker">DEINE EXPEDITION</span>
        <h1 data-account-name>Unbekannter Spieler</h1>
        <p>Deine Fänge, Bosse, Spielzeit und Meilensteine – alles, was deine Geschichte auf diesem Server ausmacht.</p>
        <div class="adventure-identity-line"><span id="heroCharacter">Charakter wird geprüft…</span><span id="heroOnlineState">Status wird geprüft…</span></div>
        <div class="profile-code"><small>STEAM-ID</small><code data-account-steam>—</code></div>
      </div>
      <div class="adventure-hero-stats">
        <article><span>STUFE</span><strong id="heroLevel">—</strong><small>Charakterstufe</small></article>
        <article><span>PUNKTE</span><strong id="heroPoints">0</strong><small>Ausgebbares Guthaben</small></article>
        <article><span>EVENT-PUNKTE</span><strong id="heroScore">0</strong><small>Dauerhafter Rangwert</small></article>
        <article class="rank-card"><span>RANG</span><strong id="heroRank">#—</strong><small>In der Gemeinschaft</small></article>
      </div>
    </section>
    <section id="profileGate" class="profile-gate">
      <span>STEAM-ANMELDUNG ERFORDERLICH</span><h2>Verbinde dein Steam-Konto und öffne deine Expedition.</h2><a href="/auth/steam">Mit Steam anmelden →</a>
    </section>
    <section id="profileData" class="profile-data hidden">
      <div class="adventure-section-heading"><div><span>FORTSCHRITT</span><h2>Dein Abenteuer auf einen Blick.</h2></div><p>Alle Werte stammen direkt aus deinem laufenden Spiel und deiner PalPanel-Historie.</p></div>
      <div class="adventure-stat-grid">
        <article class="adventure-stat"><i>◇</i><span>PAL-ARTEN</span><strong id="profileUniquePals">0</strong><small>Einzigartige Arten entdeckt</small></article>
        <article class="adventure-stat"><i>◎</i><span>FÄNGE</span><strong id="profileCaptures">0</strong><small>Gesamtfänge</small></article>
        <article class="adventure-stat alpha"><i>✦</i><span>ALPHA-FÄNGE</span><strong id="profileAlphaCaptures">0</strong><small>Besondere Fänge</small></article>
        <article class="adventure-stat boss"><i>◆</i><span>BOSSE</span><strong id="profileBossKills">0</strong><small>Einmalige Abschlüsse</small></article>
        <article class="adventure-stat"><i>↟</i><span>STUFENAUFSTIEGE</span><strong id="profileLevelUps">0</strong><small>Seit dem Live-Tracking</small></article>
        <article class="adventure-stat"><i>⌁</i><span>SPIELZEIT</span><strong id="profilePlaytime">0h 00m</strong><small>Auf diesem Server</small></article>
        <article class="adventure-stat death"><i>×</i><span>TODE</span><strong id="profileDeaths">0</strong><small>Nur Statistik, keine Strafe</small></article>
      </div>
      <section class="adventure-milestones">
        <div class="adventure-section-heading compact"><div><span>NÄCHSTE ZIELE</span><h2>Was als Nächstes auf dich wartet.</h2></div><p>Fortschritt, Belohnung und Abstand zum nächsten Ziel.</p></div>
        <div id="milestoneGrid" class="milestone-grid"><div class="adventure-empty">Meilensteine werden geladen…</div></div>
      </section>
      <div class="adventure-main-grid">
        <section class="adventure-panel activity-panel"><div class="adventure-panel-head"><div><span>AKTIVITÄTEN</span><h3>Deine letzten Abenteuer-Momente</h3></div><b id="activityCount">—</b></div><div id="activityFeed" class="activity-feed"><div class="adventure-empty">Aktivitäten werden geladen…</div></div></section>
        <div class="adventure-side-stack">
          <section class="adventure-panel discoveries-panel"><div class="adventure-panel-head"><div><span>ENTDECKUNGEN</span><h3>Zuletzt neu entdeckt</h3></div><b id="discoveryCount">0 Arten</b></div><div id="recentDiscoveries" class="discovery-list"><div class="adventure-empty">Noch keine Entdeckungen.</div></div></section>
          <section class="adventure-panel trophies-panel"><div class="adventure-panel-head"><div><span>ERFOLGE</span><h3>Alpha & Bosse</h3></div></div><div class="trophy-columns"><div><small>LETZTE ALPHA-FÄNGE</small><div id="recentAlphas" class="mini-history"><span>Noch keine Alpha-Fänge.</span></div></div><div><small>LETZTE BOSSE</small><div id="recentBosses" class="mini-history"><span>Noch keine Boss-Abschlüsse.</span></div></div></div></section>
        </div>
      </div>
      <div class="adventure-lower-grid">
        <section class="adventure-panel sources-panel"><div class="adventure-panel-head"><div><span>PUNKTEBILANZ</span><h3>Woher deine Punkte kommen</h3></div><b id="sourceBalance">0 Punkte</b></div><div id="pointSources" class="point-sources"><div class="adventure-empty">Noch keine Punktebewegungen.</div></div></section>
        <section class="adventure-panel character-panel"><div class="adventure-panel-head"><div><span>CHARAKTER</span><h3>Deine Verknüpfung</h3></div><b id="profileLinkBadge">PRÜFE</b></div><div class="character-record adventure-character-record"><small>PALWORLD-NAME</small><strong data-account-character>—</strong><small>STUFE</small><strong data-account-level>—</strong><small>ZULETZT GESEHEN</small><strong id="profileLastSeen">—</strong><p id="profileLinkHelp">PalPanel verbindet deine Steam-Identität automatisch mit dem passenden Palworld-Spieler.</p><button id="profileRelink">Server erneut prüfen ↻</button></div></section>
      </div>
    </section>
  </main>`
  });
}

function shopView() {
  return shell({
    title: 'PalPanel // Punkteshop',
    subtitle: 'PUNKTESHOP',
    route: 'shop',
    styles: ['/shop.css?v=0900'],
    footerText: 'Käufe im Punkteshop verändern deine Event-Punkte nicht.',
    scripts: ['/shop.js?v=0900'],
    extraBody: '<div id="shopToast" class="shop-toast"></div>',
    main: `<main class="shop-shell">
    <section class="shop-hero"><div><span class="shop-kicker">DEINE PUNKTE. DEINE AUSRÜSTUNG.</span><h1>Punkteshop</h1><p>Verdiente Punkte gegen Gegenstände tauschen. Bist du auf dem Server, landet dein Kauf direkt im Inventar. Bist du nicht verbunden, wartet PalPanel automatisch auf dich.</p></div><div class="shop-wallet"><span>VERFÜGBAR</span><strong id="shopPoints">—</strong><small>PUNKTE</small></div></section>
    <section id="shopGate" class="shop-gate"><span>STEAM-ANMELDUNG ERFORDERLICH</span><h2>Melde dich an, um Punkte auszugeben.</h2><a href="/auth/steam">Mit Steam anmelden →</a></section>
    <section id="shopData" class="hidden">
      <div id="shopLinkWarning" class="shop-warning hidden"><div><span>CHARAKTER FEHLT</span><strong>Verbinde zuerst deinen Palworld-Charakter.</strong><p>Betritt den Server mit deinem Steam-Konto und nutze danach „Erneut suchen“ im Spielerkonto.</p></div><button id="shopRelink">Server prüfen ↻</button></div>
      <div class="shop-heading"><div><span>ANGEBOT</span><h2>Direkt in dein Inventar.</h2></div><p>Der Browser übermittelt nur die Artikelkennung. Preis, Gegenstands-ID und Menge werden ausschließlich von PalPanel bestimmt.</p></div>
      <div id="shopCatalog" class="shop-grid"><div class="shop-loading">Punkteshop wird geladen…</div></div>
      <section class="orders-panel"><div class="orders-head"><div><span>BESTELLUNGEN</span><h2>Deine letzten Käufe</h2></div><b id="queueBadge">0 OFFEN</b></div><div id="shopOrders" class="orders-list"><div class="order-empty">Noch keine Bestellungen.</div></div></section>
    </section>
  </main>`
  });
}

function playerView() {
  return shell({
    title: 'PalPanel // Spielerprofil',
    subtitle: 'SPIELERPROFIL',
    route: 'player',
    styles: ['/ui-polish.css?v=0900', '/v088-final.css?v=0900', '/public-player.css?v=0900'],
    footerText: 'Ein Server. Eine Welt. Eure Geschichte.',
    scripts: ['/player.js?v=0900'],
    main: `<main class="public-profile-shell">
    <section id="publicProfileLoading" class="public-profile-loading"><div><span>ÖFFENTLICHES PROFIL</span><h1>Expedition wird geladen…</h1><p>PalPanel sammelt die öffentlichen Fortschrittsdaten.</p></div></section>
    <section id="publicProfileError" class="public-profile-error hidden"><div><span>PROFIL NICHT VERFÜGBAR</span><h1>Nichts gefunden.</h1><p>Dieses Spielerprofil konnte nicht geladen werden.</p><a href="/#ranking">Zur Rangliste →</a></div></section>
    <div id="publicProfile" class="hidden">
      <section class="public-profile-hero">
        <div class="public-profile-identity"><div id="publicPlayerAvatarFrame" class="public-profile-avatar"><span id="publicPlayerInitial">?</span><img id="publicPlayerAvatar" alt="Spielerprofilbild"></div><span class="public-profile-kicker">ÖFFENTLICHES ABENTEUERPROFIL</span><h1 id="publicPlayerName">Unbekannter Spieler</h1><p>Ein Blick auf die Spuren, die dieser Entdecker in unserer gemeinsamen Palpagos-Welt hinterlassen hat.</p><div class="public-profile-privacy">Öffentlich sichtbar sind nur Spiel- und Eventfortschritt. Steam-ID, Punktestand und Kontodaten bleiben privat.</div></div>
        <div class="public-profile-scorecard"><article><span>STUFE</span><strong id="publicPlayerLevel">—</strong><small>Charakterstufe</small></article><article><span>RANG</span><strong id="publicPlayerRank">#—</strong><small>In der Gemeinschaft</small></article><article><span>EVENT-PUNKTE</span><strong id="publicPlayerScore">0</strong><small>Dauerhafter Rangwert</small></article><article><span>SPIELZEIT</span><strong id="publicPlayerPlaytime">0 Std.</strong><small>Auf diesem Server</small></article></div>
      </section>
      <section class="public-profile-section"><div class="public-profile-heading"><div><span>FORTSCHRITT</span><h2>Die Expedition in Zahlen.</h2></div><p>Aggregierte Werte aus PalPanel – ohne private Konto- oder Steam-Daten.</p></div><div class="public-profile-stat-grid"><article class="public-profile-stat"><i>◇</i><span>PAL-ARTEN</span><strong id="publicUniquePals">0</strong><small>Einzigartige Arten</small></article><article class="public-profile-stat"><i>◎</i><span>FÄNGE</span><strong id="publicCaptures">0</strong><small>Gesamtfänge</small></article><article class="public-profile-stat"><i>✦</i><span>ALPHA-FÄNGE</span><strong id="publicAlphaCaptures">0</strong><small>Besondere Fänge</small></article><article class="public-profile-stat"><i>◆</i><span>BOSSE</span><strong id="publicBossKills">0</strong><small>Abschlüsse</small></article><article class="public-profile-stat"><i>↟</i><span>STUFENAUFSTIEGE</span><strong id="publicLevelUps">0</strong><small>Live erfasst</small></article><article class="public-profile-stat"><i>×</i><span>TODE</span><strong id="publicDeaths">0</strong><small>Nur Statistik</small></article></div></section>
      <section class="public-profile-grid"><section class="public-profile-panel"><div class="public-profile-panel-head"><div><span>ENTDECKUNGEN</span><h3>Zuletzt entdeckte Pal-Arten</h3></div><b>LETZTE 8</b></div><div id="publicDiscoveries" class="public-profile-list"><div class="public-profile-empty">Wird geladen…</div></div></section><div class="public-profile-side"><section class="public-profile-panel"><div class="public-profile-panel-head"><div><span>ALPHA</span><h3>Letzte Alpha-Fänge</h3></div></div><div id="publicAlphas" class="public-profile-list"><div class="public-profile-empty">Wird geladen…</div></div></section><section class="public-profile-panel"><div class="public-profile-panel-head"><div><span>BOSSE</span><h3>Letzte Abschlüsse</h3></div></div><div id="publicBosses" class="public-profile-list"><div class="public-profile-empty">Wird geladen…</div></div></section></div></section>
    </div>
  </main>`
  });
}

const previousCreateServer = http.createServer.bind(http);
http.createServer = function frontendRendererCreateServer(handler) {
  return previousCreateServer(async (req, res) => {
    try {
      const url = new URL(req.url, 'http://localhost');
      if (req.method === 'GET') {
        if (url.pathname === '/index.html') return redirect(res, '/');
        if (url.pathname === '/profile.html') return redirect(res, '/profile');
        if (url.pathname === '/shop.html') return redirect(res, '/shop');
        if (url.pathname === '/player.html') {
          const id = url.searchParams.get('id');
          return redirect(res, /^\d+$/.test(String(id || '')) ? `/player/${id}` : '/#ranking');
        }
        if (url.pathname === '/world') return redirect(res, '/#world');
        if (url.pathname === '/ranking') return redirect(res, '/#ranking');
        if (url.pathname === '/') return sendHtml(res, homeView());
        if (url.pathname === '/profile' || url.pathname === '/profile/') return sendHtml(res, profileView());
        if (url.pathname === '/shop' || url.pathname === '/shop/') return sendHtml(res, shopView());
        if (/^\/player\/\d+\/?$/.test(url.pathname)) return sendHtml(res, playerView());
      }
    } catch (err) {
      console.warn('[FrontendRenderer]', err.message);
    }
    return handler(req, res);
  });
};

console.log('PalPanel v0.9.0 dynamisches Frontend-Routing geladen. Keine statischen Public-HTML-Seiten erforderlich.');
require('./server-v089.js');
