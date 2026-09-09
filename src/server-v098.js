const http = require('http');

const ASSET_VERSION = '0980';

function enhanceAdminHtml(html) {
  let out = String(html || '');
  out = out.replace(/\/admin\/wow\.css\?v=\d+/g, `/admin/wow.css?v=${ASSET_VERSION}`);

  const additions = [];
  if (!out.includes('/admin/wow.css?v=0980')) additions.push(`<link rel="stylesheet" href="/admin/wow.css?v=${ASSET_VERSION}">`);
  if (!out.includes('/admin/v098.css?v=0980')) additions.push(`<link rel="stylesheet" href="/admin/v098.css?v=${ASSET_VERSION}">`);
  if (!out.includes('/admin/v098-state.js?v=0980')) additions.push(`<script defer src="/admin/v098-state.js?v=${ASSET_VERSION}"></script>`);

  if (additions.length && out.includes('</head>')) out = out.replace('</head>', `${additions.join('')}</head>`);
  return out;
}

function captureAdminHtml(req, res, listener) {
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
        const html = enhanceAdminHtml(Buffer.isBuffer(chunk) ? chunk.toString('utf8') : String(chunk));
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
http.createServer = function adminV098CreateServer(options, requestListener) {
  const hasOptions = typeof options !== 'function';
  const listener = hasOptions ? requestListener : options;
  const wrapped = (req, res) => {
    let url;
    try { url = new URL(req.url, 'http://localhost'); } catch { return listener(req, res); }
    if ((req.method === 'GET' || req.method === 'HEAD') && (url.pathname === '/admin' || url.pathname.startsWith('/admin/'))) {
      return captureAdminHtml(req, res, listener);
    }
    return listener(req, res);
  };
  return hasOptions ? previousCreateServer(options, wrapped) : previousCreateServer(wrapped);
};

console.log('PalPanel v0.9.8 Admin Auth-Gate + Control-Center-Refinement geladen.');
require('./server-v097.js');
