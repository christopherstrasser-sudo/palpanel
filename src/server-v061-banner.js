const fs = require('fs');
const path = require('path');
const http = require('http');
const crypto = require('crypto');

const APP_DIR = path.resolve(__dirname, '..');
const LEGACY = path.join(APP_DIR, 'public', 'assets', 'banner');
const FIXED = path.join(APP_DIR, 'public', 'assets', 'banner-fixed');
const EXPECTED_SIZE = 116108;
const EXPECTED_SHA256 = '372f32a78176a20d17bde62b3e483e6080df73c1b24c45b96a15a20a3f9b3277';
let bannerBuffer = null;

function readText(file) {
  return fs.readFileSync(file, 'utf8').trim();
}

function getBannerBuffer() {
  if (bannerBuffer) return bannerBuffer;
  const pieces = [
    readText(path.join(LEGACY, 'part-00.b64')),
    readText(path.join(LEGACY, 'part-01.b64')),
    readText(path.join(LEGACY, 'part-02.b64')),
    readText(path.join(LEGACY, 'part-03.b64')),
    readText(path.join(LEGACY, 'part-04.b64')),
    readText(path.join(LEGACY, 'part-05.b64')),
    readText(path.join(FIXED, 'fix-05-tail.b64')),
    readText(path.join(FIXED, 'fix-06-a.b64')),
    readText(path.join(FIXED, 'fix-06-b.b64')),
    readText(path.join(FIXED, 'fix-07-a.b64')),
    readText(path.join(FIXED, 'fix-07-b.b64')),
    readText(path.join(FIXED, 'fix-08-a.b64')),
    readText(path.join(FIXED, 'fix-08-b.b64')),
    readText(path.join(LEGACY, 'part-09.b64')),
    readText(path.join(LEGACY, 'part-10.b64')),
    readText(path.join(LEGACY, 'part-11.b64')),
    readText(path.join(FIXED, 'fix-12-a.b64')),
    readText(path.join(FIXED, 'fix-12-b.b64'))
  ];
  const data = Buffer.from(pieces.join(''), 'base64');
  const sha256 = crypto.createHash('sha256').update(data).digest('hex');
  const riff = data.subarray(0, 4).toString('ascii');
  const webp = data.subarray(8, 12).toString('ascii');
  if (data.length !== EXPECTED_SIZE || riff !== 'RIFF' || webp !== 'WEBP' || sha256 !== EXPECTED_SHA256) {
    throw new Error(`Banner validation failed: ${data.length} bytes, ${riff}/${webp}, sha256=${sha256}`);
  }
  bannerBuffer = data;
  return bannerBuffer;
}

try {
  const data = getBannerBuffer();
  console.log(`PalPanel Banner OK: ${data.length} Bytes, SHA256 ${EXPECTED_SHA256.slice(0, 12)}...`);
} catch (err) {
  console.error('[Banner] VALIDIERUNG FEHLGESCHLAGEN:', err.message);
}

const previousCreateServer = http.createServer.bind(http);
http.createServer = function bannerCreateServer(handler) {
  return previousCreateServer((req, res) => {
    try {
      const url = new URL(req.url, 'http://localhost');
      if ((req.method === 'GET' || req.method === 'HEAD') && url.pathname === '/palpanel-banner.webp') {
        const data = getBannerBuffer();
        res.writeHead(200, {
          'Content-Type': 'image/webp',
          'Content-Length': data.length,
          'Cache-Control': 'no-cache, no-store, must-revalidate',
          'X-PalPanel-Banner': 'verified-q78'
        });
        return req.method === 'HEAD' ? res.end() : res.end(data);
      }
      return handler(req, res);
    } catch (err) {
      console.error('[Banner]', err.message);
      if (!res.headersSent) {
        res.writeHead(500, { 'Content-Type': 'text/plain; charset=utf-8', 'Cache-Control': 'no-store' });
        return res.end('PalPanel banner unavailable');
      }
      try { res.end(); } catch {}
    }
  });
};

console.log('PalPanel v0.6.1 Banner-Asset geladen.');
require('./server-v06.js');
