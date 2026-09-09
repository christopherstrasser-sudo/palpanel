const http = require('http');

// Runs before PalPanel's historical createServer wrappers. Some older modules
// translate clean frontend paths (for example /shop) to legacy *.html files.
// Normalize only the incoming public view routes internally so the v0.9.0
// renderer receives them first, without changing the browser-visible URL.
const originalEmit = http.Server.prototype.emit;

http.Server.prototype.emit = function palPanelFrontendRouteGuard(event, ...args) {
  if (event === 'request') {
    const req = args[0];
    try {
      const url = new URL(req.url, 'http://localhost');
      let nextPath = null;
      if (url.pathname === '/profile') nextPath = '/profile/';
      else if (url.pathname === '/shop') nextPath = '/shop/';
      else if (/^\/player\/\d+$/.test(url.pathname)) nextPath = `${url.pathname}/`;
      if (nextPath) req.url = `${nextPath}${url.search}`;
    } catch {}
  }
  return originalEmit.call(this, event, ...args);
};
