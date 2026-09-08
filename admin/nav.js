(() => {
  const page = document.body.dataset.page || 'dashboard';
  const items = [
    ['dashboard', '/admin/', 'Dashboard'],
    ['server', '/admin/server', 'Server'],
    ['players', '/admin/players', 'Spieler'],
    ['backups', '/admin/backups', 'Backups'],
    ['automation', '/admin/automation', 'Automatisierungen'],
    ['settings', '/admin/settings', 'Einstellungen'],
    ['logs', '/admin/logs', 'Live-Logs'],
    ['jobs', '/admin/jobs', 'Jobs']
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
