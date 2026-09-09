const http = require('http');

const ASSET_VERSION = '0970';

function enhanceHomeHtml(html) {
  let out = String(html || '');
  if (out.includes('/player-dashboard.js?v=0970')) return out;
  const assets = `<link rel="stylesheet" href="/player-dashboard.css?v=${ASSET_VERSION}"><script src="/player-dashboard.js?v=${ASSET_VERSION}"></script>`;
  return out.includes('</head>') ? out.replace('</head>', `${assets}</head>`) : out;
}

function captureHomeHtml(req, res, listener) {
  const originalWriteHead = res.writeHead.bind(res);
  const originalEnd = res.end.bind(res);
  let pendingStatus = null;
  let pendingMessage = null;
  let pendingHeaders = null;

  res.writeHead = function patchedWriteHead(statusCode, statusMessage, headers) {
    pendingStatus = statusCode;
    if (typeof statusMessage === 'string') {
      pendingMessage = statusMessage;
      pendingHeaders = { ...(headers || {}) };
    } else {
      pendingHeaders = { ...(statusMessage || {}) };
    }
    return res;
  };

  res.end = function patchedEnd(chunk, encoding, callback) {
    if (pendingStatus != null) {
      const headers = { ...(pendingHeaders || {}) };
      const contentType = String(headers['Content-Type'] || headers['content-type'] || '');
      if (pendingStatus === 200 && contentType.toLowerCase().includes('text/html') && chunk != null) {
        const html = enhanceHomeHtml(Buffer.isBuffer(chunk) ? chunk.toString('utf8') : String(chunk));
        const data = Buffer.from(html);
        delete headers['content-length'];
        headers['Content-Length'] = data.length;
        if (pendingMessage) originalWriteHead(pendingStatus, pendingMessage, headers);
        else originalWriteHead(pendingStatus, headers);
        return originalEnd(data, undefined, callback);
      }
      if (pendingMessage) originalWriteHead(pendingStatus, pendingMessage, headers);
      else originalWriteHead(pendingStatus, headers);
    }
    return originalEnd(chunk, encoding, callback);
  };

  return listener(req, res);
}

const previousCreateServer = http.createServer.bind(http);
http.createServer = function playerDashboardCreateServer(options, requestListener) {
  const hasOptions = typeof options !== 'function';
  const listener = hasOptions ? requestListener : options;
  const wrapped = (req, res) => {
    let url;
    try { url = new URL(req.url, 'http://localhost'); } catch { return listener(req, res); }
    if ((req.method === 'GET' || req.method === 'HEAD') && (url.pathname === '/' || url.pathname === '')) {
      return captureHomeHtml(req, res, listener);
    }
    return listener(req, res);
  };
  return hasOptions ? previousCreateServer(options, wrapped) : previousCreateServer(wrapped);
};

console.log('PalPanel v0.9.7 persönliches Player-Dashboard geladen.');
require('./server-v096.js');
