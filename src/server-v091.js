const http = require('http');
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

const APP_DIR = path.resolve(__dirname, '..');
const PUBLIC_DIR = path.join(APP_DIR, 'public');
const ASSET_VERSION = '0910';
const BANNER_PATH = '/palpanel-banner.png';
const BANNER_URL = `${BANNER_PATH}?v=${ASSET_VERSION}`;

function requestUrl(req) {
  try { return new URL(req.url, 'http://localhost'); }
  catch { return null; }
}

function isPublicDocument(pathname) {
  return pathname === '/' || pathname === '/profile' || pathname === '/profile/' || pathname === '/shop' || pathname === '/shop/' || /^\/player\/\d+\/?$/.test(pathname);
}

function etagFor(stat) {
  return `"${stat.size.toString(16)}-${Math.floor(stat.mtimeMs).toString(16)}"`;
}

function safePublicFile(pathname) {
  const relative = pathname.replace(/^\/+/, '');
  const file = path.resolve(PUBLIC_DIR, relative);
  return file.startsWith(`${PUBLIC_DIR}${path.sep}`) ? file : null;
}

function cacheHeader(url, longLived = false) {
  if (longLived || url.searchParams.get('v')) return 'public, max-age=31536000, immutable';
  return 'public, max-age=60, must-revalidate, stale-while-revalidate=300';
}

function serveFile(req, res, url, file, contentType, transform = null, longLived = false) {
  let stat;
  try { stat = fs.statSync(file); }
  catch { return false; }
  if (!stat.isFile()) return false;

  const etag = etagFor(stat);
  const headers = {
    'Content-Type': contentType,
    'Cache-Control': cacheHeader(url, longLived),
    'ETag': etag,
    'X-Content-Type-Options': 'nosniff'
  };

  if (String(req.headers['if-none-match'] || '') === etag) {
    res.writeHead(304, headers);
    res.end();
    return true;
  }

  if (transform) {
    let body = fs.readFileSync(file, 'utf8');
    body = transform(body);
    const data = Buffer.from(body);
    headers['Content-Length'] = data.length;
    res.writeHead(200, headers);
    if (req.method === 'HEAD') return res.end();
    res.end(data);
    return true;
  }

  headers['Content-Length'] = stat.size;
  res.writeHead(200, headers);
  if (req.method === 'HEAD') return res.end();
  fs.createReadStream(file).pipe(res);
  return true;
}

function serveOptimizedAsset(req, res, url) {
  if (!['GET', 'HEAD'].includes(req.method || 'GET')) return false;
  if (url.pathname.startsWith('/api/') || url.pathname.startsWith('/admin/')) return false;

  if (url.pathname === BANNER_PATH) {
    return serveFile(req, res, url, path.join(PUBLIC_DIR, 'palpanel-banner.png'), 'image/png', null, url.searchParams.get('v') === ASSET_VERSION);
  }

  const ext = path.extname(url.pathname).toLowerCase();
  const file = safePublicFile(url.pathname);
  if (!file) return false;

  if (ext === '.css') {
    return serveFile(req, res, url, file, 'text/css; charset=utf-8', css =>
      css.replaceAll("url('/palpanel-banner.png')", `url('${BANNER_URL}')`)
         .replaceAll('url("/palpanel-banner.png")', `url("${BANNER_URL}")`), false);
  }
  if (ext === '.js') {
    return serveFile(req, res, url, file, 'application/javascript; charset=utf-8', body => body, false);
  }
  if (ext === '.svg') return serveFile(req, res, url, file, 'image/svg+xml', null, !!url.searchParams.get('v'));
  if (ext === '.webp') return serveFile(req, res, url, file, 'image/webp', null, !!url.searchParams.get('v'));
  if (ext === '.png') return serveFile(req, res, url, file, 'image/png', null, !!url.searchParams.get('v'));
  return false;
}

function enhanceHtml(html) {
  let out = String(html || '').replaceAll('/palpanel-banner.png', BANNER_URL);
  out = out.replace('<img class="hero-banner"', '<img class="hero-banner" fetchpriority="high" decoding="async"');
  const enhancements = [
    `<meta name="theme-color" content="#061724">`,
    `<link rel="preload" as="image" href="${BANNER_URL}" fetchpriority="high">`,
    `<link rel="stylesheet" href="/wow.css?v=${ASSET_VERSION}">`
  ].join('');
  return out.includes('</head>') ? out.replace('</head>', `${enhancements}</head>`) : out;
}

function capturePublicHtml(req, res, listener) {
  const originalWriteHead = res.writeHead.bind(res);
  const originalEnd = res.end.bind(res);
  let pendingStatus = null;
  let pendingStatusMessage = null;
  let pendingHeaders = null;

  res.writeHead = function patchedWriteHead(statusCode, statusMessage, headers) {
    pendingStatus = statusCode;
    if (typeof statusMessage === 'string') {
      pendingStatusMessage = statusMessage;
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
        const html = enhanceHtml(Buffer.isBuffer(chunk) ? chunk.toString('utf8') : String(chunk));
        const data = Buffer.from(html);
        delete headers['content-length'];
        headers['Content-Length'] = data.length;
        headers['Cache-Control'] = 'no-cache';
        headers['Link'] = `<${BANNER_URL}>; rel=preload; as=image`;
        if (pendingStatusMessage) originalWriteHead(pendingStatus, pendingStatusMessage, headers);
        else originalWriteHead(pendingStatus, headers);
        return originalEnd(data, undefined, callback);
      }
      if (pendingStatusMessage) originalWriteHead(pendingStatus, pendingStatusMessage, headers);
      else originalWriteHead(pendingStatus, headers);
    }
    return originalEnd(chunk, encoding, callback);
  };

  return listener(req, res);
}

const previousCreateServer = http.createServer.bind(http);
http.createServer = function optimizedFrontendCreateServer(options, requestListener) {
  const hasOptions = typeof options !== 'function';
  const listener = hasOptions ? requestListener : options;

  const wrapped = (req, res) => {
    const url = requestUrl(req);
    if (url) {
      try {
        if (serveOptimizedAsset(req, res, url)) return;
        if (isPublicDocument(url.pathname) && (req.method === 'GET' || req.method === 'HEAD')) {
          return capturePublicHtml(req, res, listener);
        }
      } catch (err) {
        console.warn('[FrontendOptimizer]', err.message);
      }
    }
    return listener(req, res);
  };

  return hasOptions ? previousCreateServer(options, wrapped) : previousCreateServer(wrapped);
};

console.log(`PalPanel v0.9.1 Frontend Optimizer geladen. Asset-Version: ${ASSET_VERSION}`);
console.log(`Banner: Preload + ETag + versionierter Langzeitcache aktiv (${BANNER_URL})`);
require('./server-v090.js');
