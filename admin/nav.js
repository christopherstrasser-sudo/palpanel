(() => {
  const page = document.body.dataset.page || 'dashboard';
  const items = [
    ['dashboard', '/admin/', 'Übersicht'],
    ['server', '/admin/server', 'Server'],
    ['players', '/admin/players', 'Spieler'],
    ['bridge', '/admin/bridge', 'Mod-Brücke'],
    ['backups', '/admin/backups', 'Sicherungen'],
    ['automation', '/admin/automation', 'Automatisierungen'],
    ['settings', '/admin/settings', 'Einstellungen'],
    ['logs', '/admin/logs', 'Live-Protokolle'],
    ['jobs', '/admin/jobs', 'Aufgaben']
  ];

  const nav = document.querySelector('.sidebar nav');
  if (nav) {
    nav.innerHTML = items.map(([key, href, label]) =>
      `<a${key === page ? ' class="active"' : ''} href="${href}">${label}</a>`
    ).join('');
  }

  const clean = {
    '/admin/index.html': '/admin/',
    '/admin/server.html': '/admin/server',
    '/admin/players.html': '/admin/players',
    '/admin/bridge.html': '/admin/bridge',
    '/admin/backups.html': '/admin/backups',
    '/admin/automation.html': '/admin/automation',
    '/admin/settings.html': '/admin/settings',
    '/admin/logs.html': '/admin/logs',
    '/admin/jobs.html': '/admin/jobs'
  };

  document.querySelectorAll('a[href^="/admin/"]').forEach(link => {
    const url = new URL(link.href, location.origin);
    if (clean[url.pathname]) link.href = `${clean[url.pathname]}${url.search}${url.hash}`;
  });
})();
