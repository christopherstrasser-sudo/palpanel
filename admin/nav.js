(() => {
  if (!document.querySelector('link[href*="/admin/wow.css"]')) {
    const wow = document.createElement('link');
    wow.rel = 'stylesheet';
    wow.href = '/admin/wow.css?v=0910';
    document.head.appendChild(wow);
  }
  document.body.classList.add('palpanel-admin-wow');

  const page = document.body.dataset.page || 'dashboard';
  const items = [
    ['dashboard', '/admin/', 'Übersicht', '◈'],
    ['season', '/admin/season', 'Community-Event', '✦'],
    ['server', '/admin/server', 'Server', '◉'],
    ['players', '/admin/players', 'Spieler', '◎'],
    ['bridge', '/admin/bridge', 'Mod-Brücke', '⌁'],
    ['backups', '/admin/backups', 'Sicherungen', '▣'],
    ['automation', '/admin/automation', 'Automatisierungen', '↻'],
    ['settings', '/admin/settings', 'Einstellungen', '◇'],
    ['logs', '/admin/logs', 'Live-Protokolle', '≡'],
    ['jobs', '/admin/jobs', 'Aufgaben', '✓']
  ];

  const brand = document.querySelector('.sidebar .brand');
  if (brand && !document.querySelector('.admin-environment')) {
    const env = document.createElement('div');
    env.className = 'admin-environment';
    env.innerHTML = '<i></i><span>LOCAL CONTROL CENTER</span>';
    brand.insertAdjacentElement('afterend', env);
  }

  const nav = document.querySelector('.sidebar nav');
  if (nav) {
    nav.innerHTML = items.map(([key, href, label, icon]) =>
      `<a${key === page ? ' class="active"' : ''} href="${href}"><span class="nav-icon" aria-hidden="true">${icon}</span><span class="nav-label">${label}</span></a>`
    ).join('');
  }

  const logout = document.getElementById('logoutBtn');
  if (logout && !document.querySelector('.admin-side-meta')) {
    const meta = document.createElement('div');
    meta.className = 'admin-side-meta';
    meta.innerHTML = '<span>PALPANEL</span><b>v0.9.3</b>';
    logout.insertAdjacentElement('beforebegin', meta);
  }

  const clean = {
    '/admin/index.html': '/admin/',
    '/admin/season.html': '/admin/season',
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