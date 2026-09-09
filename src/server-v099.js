const http = require('http');

const ASSET_VERSION = '0990';

function routeClass(pathname) {
  if (pathname === '/' || pathname === '') return 'route-home';
  if (pathname === '/profile' || pathname === '/profile/') return 'route-profile';
  if (pathname === '/shop' || pathname === '/shop/') return 'route-shop';
  if (pathname === '/event') return 'route-event';
  if (pathname === '/missions') return 'route-missions';
  if (pathname === '/hall-of-fame') return 'route-hall';
  if (/^\/player\/\d+\/?$/.test(pathname)) return 'route-player';
  return 'route-public';
}

function enhancePublicHtml(html, pathname) {
  let out = String(html || '');
  if (!out.includes(`/v099.css?v=${ASSET_VERSION}`) && out.includes('</head>')) {
    out = out.replace('</head>', `<link rel="stylesheet" href="/v099.css?v=${ASSET_VERSION}"></head>`);
  }
  const cls = `frontend-v099 ${routeClass(pathname)}`;
  out = out.replace(/<body([^>]*)>/i, (match, attrs) => {
    const classMatch = attrs.match(/\sclass=(['"])(.*?)\1/i);
    if (classMatch) {
      const merged = `${classMatch[2]} ${cls}`.trim();
      return `<body${attrs.replace(classMatch[0], ` class=${classMatch[1]}${merged}${classMatch[1]}`)}>`;
    }
    return `<body${attrs} class="${cls}">`;
  });
  return out;
}

function capturePublicHtml(req, res, listener, pathname) {
  const originalWriteHead = res.writeHead.bind(res);
  const originalEnd = res.end.bind(res);
  let status = null;
  let statusMessage = null;
  let headers = null;

  res.writeHead = function patchedWriteHead(code, message, suppliedHeaders) {
    status = code;
    if (typeof message === 'string') {
      statusMessage = message;
      headers = { ...(suppliedHeaders || {}) };
    } else {
      headers = { ...(message || {}) };
    }
    return res;
  };

  res.end = function patchedEnd(chunk, encoding, callback) {
    if (status != null) {
      const nextHeaders = { ...(headers || {}) };
      const contentType = String(nextHeaders['Content-Type'] || nextHeaders['content-type'] || '');
      if (status === 200 && contentType.toLowerCase().includes('text/html') && chunk != null) {
        const html = enhancePublicHtml(Buffer.isBuffer(chunk) ? chunk.toString('utf8') : String(chunk), pathname);
        const data = Buffer.from(html);
        delete nextHeaders['content-length'];
        nextHeaders['Content-Length'] = data.length;
        if (statusMessage) originalWriteHead(status, statusMessage, nextHeaders);
        else originalWriteHead(status, nextHeaders);
        return originalEnd(data, undefined, callback);
      }
      if (statusMessage) originalWriteHead(status, statusMessage, nextHeaders);
      else originalWriteHead(status, nextHeaders);
    }
    return originalEnd(chunk, encoding, callback);
  };

  return listener(req, res);
}

const previousCreateServer = http.createServer.bind(http);
http.createServer = function publicV099CreateServer(options, requestListener) {
  const hasOptions = typeof options !== 'function';
  const listener = hasOptions ? requestListener : options;
  const wrapped = (req, res) => {
    let url;
    try { url = new URL(req.url, 'http://localhost'); } catch { return listener(req, res); }

    const publicDocument = (url.pathname === '/' || url.pathname === '' ||
      url.pathname === '/profile' || url.pathname === '/profile/' ||
      url.pathname === '/shop' || url.pathname === '/shop/' ||
      url.pathname === '/event' || url.pathname === '/missions' ||
      url.pathname === '/hall-of-fame' || /^\/player\/\d+\/?$/.test(url.pathname));

    if ((req.method === 'GET' || req.method === 'HEAD') && publicDocument) {
      return capturePublicHtml(req, res, listener, url.pathname);
    }
    return listener(req, res);
  };
  return hasOptions ? previousCreateServer(options, wrapped) : previousCreateServer(wrapped);
};

console.log('PalPanel v0.9.9 Public Frontend Redesign geladen.');
require('./server-v098.js');
