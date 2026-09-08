const http = require('http');

const originalCreateServer = http.createServer.bind(http);

const CLEAN_ADMIN_ROUTES = new Map([
  ['/admin/server', '/admin/server.html'],
  ['/admin/players', '/admin/players.html'],
  ['/admin/backups', '/admin/backups.html'],
  ['/admin/automation', '/admin/automation.html'],
  ['/admin/settings', '/admin/settings.html'],
  ['/admin/logs', '/admin/logs.html'],
  ['/admin/jobs', '/admin/jobs.html']
]);

const LEGACY_ADMIN_ROUTES = new Map(
  [...CLEAN_ADMIN_ROUTES.entries()].map(([clean, file]) => [file, clean])
);

http.createServer = function cleanAdminCreateServer(options, requestListener) {
  const hasOptions = typeof options !== 'function';
  const listener = hasOptions ? requestListener : options;

  const wrappedListener = (req, res) => {
    try {
      const url = new URL(req.url, 'http://localhost');

      if ((req.method === 'GET' || req.method === 'HEAD') && LEGACY_ADMIN_ROUTES.has(url.pathname)) {
        const location = `${LEGACY_ADMIN_ROUTES.get(url.pathname)}${url.search}`;
        res.writeHead(308, { Location: location, 'Cache-Control': 'no-store' });
        return res.end();
      }

      const fileRoute = CLEAN_ADMIN_ROUTES.get(url.pathname);
      if (fileRoute) req.url = `${fileRoute}${url.search}`;
    } catch {}

    return listener(req, res);
  };

  return hasOptions
    ? originalCreateServer(options, wrappedListener)
    : originalCreateServer(wrappedListener);
};

console.log('PalPanel v0.6.1 Clean Admin URLs geladen.');
require('./server-v06.js');
