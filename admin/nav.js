(() => {
  if (!document.querySelector('link[href*="/admin/wow.css"]')) {
    const wow = document.createElement('link');
    wow.rel = 'stylesheet';
    wow.href = '/admin/wow.css?v=0980';
    document.head.appendChild(wow);
  }
  if (!document.querySelector('link[href*="/admin/v098.css"]')) {
    const polish = document.createElement('link');
    polish.rel = 'stylesheet';
    polish.href = '/admin/v098.css?v=0980';
    document.head.appendChild(polish);
  }
  document.body.classList.add('palpanel-admin-wow');

  const page = document.body.dataset.page || 'dashboard';
  const groups = [
    ['Community', [
      ['dashboard', '/admin/', 'Übersicht', '◈'],
      ['insights', '/admin/insights', 'Community Insights', '⌁'],
      ['season', '/admin/season', 'Community-Event', '✦'],
      ['missions', '/admin/missions', 'Wochenmissionen', '☷']
    ]],
    ['Server', [
      ['server', '/admin/server', 'Server', '◉'],
      ['players', '/admin/players', 'Spieler', '◎'],
      ['bridge', '/admin/bridge', 'Mod-Brücke', '⌁']
    ]],
    ['System', [
      ['backups', '/admin/backups', 'Sicherungen', '▣'],
      ['automation', '/admin/automation', 'Automatisierungen', '↻'],
      ['settings', '/admin/settings', 'Einstellungen', '◇'],
      ['logs', '/admin/logs', 'Live-Protokolle', '≡'],
      ['jobs', '/admin/jobs', 'Aufgaben', '✓']
    ]]
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
    nav.innerHTML = groups.map(([label, items]) => `
      <section class="nav-section">
        <div class="nav-section-label">${label}</div>
        ${items.map(([key, href, text, icon]) =>
          `<a${key === page ? ' class="active"' : ''} href="${href}"><span class="nav-icon" aria-hidden="true">${icon}</span><span class="nav-label">${text}</span></a>`
        ).join('')}
      </section>`).join('');
  }

  const logout = document.getElementById('logoutBtn');
  if (logout && !document.querySelector('.admin-side-meta')) {
    const meta = document.createElement('div');
    meta.className = 'admin-side-meta';
    meta.innerHTML = '<span>PALPANEL</span><b>v0.9.11</b>';
    logout.insertAdjacentElement('beforebegin', meta);
  }

  const clean = {
    '/admin/index.html': '/admin/',
    '/admin/insights.html': '/admin/insights',
    '/admin/season.html': '/admin/season',
    '/admin/missions.html': '/admin/missions',
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