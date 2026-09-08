const fs = require('fs');
const path = require('path');
const http = require('http');
const crypto = require('crypto');
const { DatabaseSync } = require('node:sqlite');

const APP_DIR = path.resolve(__dirname, '..');
const defaults = JSON.parse(fs.readFileSync(path.join(APP_DIR, 'config', 'default.json'), 'utf8'));
const DATA_DIR = defaults.paths.data;
const DB_FILE = path.join(DATA_DIR, 'palpanel.db');
const USER_CONFIG = path.join(DATA_DIR, 'config.json');
const REST_FILE = path.join(DATA_DIR, 'palworld-rest.json');
const CATALOG_FILE = path.join(APP_DIR, 'config', 'shop-catalog.json');
const SESSION_COOKIE = 'palpanel_user';

fs.mkdirSync(DATA_DIR, { recursive: true });
const db = new DatabaseSync(DB_FILE, { timeout: 5000 });
db.exec(`
  PRAGMA journal_mode = WAL;
  PRAGMA foreign_keys = ON;
  CREATE TABLE IF NOT EXISTS users (
    id INTEGER PRIMARY KEY,
    steam_id TEXT NOT NULL UNIQUE,
    role TEXT NOT NULL DEFAULT 'player',
    created_at TEXT NOT NULL,
    last_login_at TEXT NOT NULL
  ) STRICT;
  CREATE TABLE IF NOT EXISTS user_sessions (
    id INTEGER PRIMARY KEY,
    user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    token_hash TEXT NOT NULL UNIQUE,
    created_at TEXT NOT NULL,
    expires_at TEXT NOT NULL
  ) STRICT;
  CREATE TABLE IF NOT EXISTS player_links (
    user_id INTEGER PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
    palworld_user_id TEXT,
    player_uid TEXT,
    palworld_name TEXT,
    account_name TEXT,
    level INTEGER,
    linked_at TEXT NOT NULL,
    last_seen_at TEXT NOT NULL
  ) STRICT;
  CREATE TABLE IF NOT EXISTS points_ledger (
    id INTEGER PRIMARY KEY,
    user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    amount INTEGER NOT NULL,
    reason TEXT NOT NULL,
    ref_type TEXT,
    ref_id TEXT,
    created_at TEXT NOT NULL
  ) STRICT;
  CREATE TABLE IF NOT EXISTS shop_items (
    id INTEGER PRIMARY KEY,
    slug TEXT NOT NULL UNIQUE,
    name TEXT NOT NULL,
    description TEXT NOT NULL DEFAULT '',
    price INTEGER NOT NULL DEFAULT 0,
    active INTEGER NOT NULL DEFAULT 1,
    payload_json TEXT NOT NULL DEFAULT '{}',
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
  ) STRICT;
  CREATE TABLE IF NOT EXISTS shop_orders (
    id INTEGER PRIMARY KEY,
    user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    item_id INTEGER REFERENCES shop_items(id),
    price INTEGER NOT NULL,
    status TEXT NOT NULL DEFAULT 'pending',
    created_at TEXT NOT NULL,
    fulfilled_at TEXT
  ) STRICT;
  CREATE UNIQUE INDEX IF NOT EXISTS ux_points_ref ON points_ledger(user_id,ref_type,ref_id) WHERE ref_id IS NOT NULL;
`);

function ensureColumn(table, name, ddl) {
  const cols = db.prepare(`PRAGMA table_info(${table})`).all();
  if (!cols.some(col => col.name === name)) db.exec(`ALTER TABLE ${table} ADD COLUMN ${ddl}`);
}
ensureColumn('shop_orders', 'order_key', 'order_key TEXT');
ensureColumn('shop_orders', 'sku', 'sku TEXT');
ensureColumn('shop_orders', 'item_name', 'item_name TEXT');
ensureColumn('shop_orders', 'item_asset', 'item_asset TEXT');
ensureColumn('shop_orders', 'item_count', 'item_count INTEGER NOT NULL DEFAULT 1');
ensureColumn('shop_orders', 'updated_at', 'updated_at TEXT');
ensureColumn('shop_orders', 'reserved_at', 'reserved_at TEXT');
ensureColumn('shop_orders', 'last_attempt_at', 'last_attempt_at TEXT');
ensureColumn('shop_orders', 'last_error', 'last_error TEXT');
ensureColumn('shop_orders', 'attempts', 'attempts INTEGER NOT NULL DEFAULT 0');
ensureColumn('shop_orders', 'refunded_at', 'refunded_at TEXT');
db.exec(`
  CREATE UNIQUE INDEX IF NOT EXISTS ux_shop_order_key ON shop_orders(order_key) WHERE order_key IS NOT NULL;
  CREATE INDEX IF NOT EXISTS ix_shop_orders_queue ON shop_orders(status, id);
`);

function nowIso() { return new Date().toISOString(); }
function loadJson(file, fallback = {}) { try { return JSON.parse(fs.readFileSync(file, 'utf8')); } catch { return fallback; } }
function config() {
  const current = loadJson(USER_CONFIG, defaults);
  const palworld = current.palworld || {};
  return {
    ...defaults,
    ...current,
    paths: { ...defaults.paths, ...(current.paths || {}) },
    palworld: { ...defaults.palworld, ...palworld, rest: { ...defaults.palworld.rest, ...(palworld.rest || {}) } }
  };
}
function parseCookies(req) {
  const out = {};
  String(req.headers.cookie || '').split(';').forEach(part => {
    const i = part.indexOf('=');
    if (i > 0) out[part.slice(0, i).trim()] = decodeURIComponent(part.slice(i + 1).trim());
  });
  return out;
}
function hashToken(token) { return crypto.createHash('sha256').update(token).digest('hex'); }
function sessionFor(req) {
  const token = parseCookies(req)[SESSION_COOKIE];
  if (!token) return null;
  const row = db.prepare(`SELECT s.user_id,s.expires_at,u.steam_id,u.role FROM user_sessions s JOIN users u ON u.id=s.user_id WHERE s.token_hash=?`).get(hashToken(token));
  if (!row || Date.parse(row.expires_at) <= Date.now()) return null;
  return row;
}
function sendJson(res, status, body) {
  const data = Buffer.from(JSON.stringify(body));
  res.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8', 'Content-Length': data.length, 'Cache-Control': 'no-store' });
  res.end(data);
}
function readBody(req) {
  return new Promise((resolve, reject) => {
    let raw = '';
    req.on('data', chunk => {
      raw += chunk;
      if (raw.length > 128 * 1024) reject(new Error('Request too large'));
    });
    req.on('end', () => {
      try { resolve(raw ? JSON.parse(raw) : {}); } catch (err) { reject(err); }
    });
    req.on('error', reject);
  });
}
function pointsBalance(userId) {
  return Number(db.prepare('SELECT COALESCE(SUM(amount),0) AS n FROM points_ledger WHERE user_id=?').get(userId)?.n || 0);
}
function linkFor(userId) {
  return db.prepare('SELECT * FROM player_links WHERE user_id=?').get(userId) || null;
}

function syncCatalog() {
  const catalog = loadJson(CATALOG_FILE, { items: [] });
  const items = Array.isArray(catalog.items) ? catalog.items : [];
  const seen = new Set();
  const stamp = nowIso();
  db.exec('BEGIN IMMEDIATE');
  try {
    for (const raw of items) {
      const sku = String(raw.sku || '').trim();
      const name = String(raw.name || '').trim();
      const description = String(raw.description || '').trim();
      const price = Math.trunc(Number(raw.price));
      const delivery = raw.delivery || {};
      const itemId = String(delivery.itemId || '').trim();
      const count = Math.trunc(Number(delivery.count));
      if (!/^[a-z0-9][a-z0-9-]{1,63}$/.test(sku) || !name || !Number.isInteger(price) || price < 0) continue;
      if (delivery.type !== 'give_item' || !/^[A-Za-z0-9_]+$/.test(itemId) || !Number.isInteger(count) || count < 1 || count > 9999) continue;
      seen.add(sku);
      db.prepare(`INSERT INTO shop_items(slug,name,description,price,active,payload_json,created_at,updated_at)
        VALUES(?,?,?,?,?,?,?,?)
        ON CONFLICT(slug) DO UPDATE SET name=excluded.name,description=excluded.description,price=excluded.price,active=excluded.active,payload_json=excluded.payload_json,updated_at=excluded.updated_at`)
        .run(sku, name, description, price, raw.active === false ? 0 : 1, JSON.stringify({ type: 'give_item', itemId, count }), stamp, stamp);
    }
    if (seen.size) {
      const placeholders = [...seen].map(() => '?').join(',');
      db.prepare(`UPDATE shop_items SET active=0,updated_at=? WHERE slug NOT IN (${placeholders})`).run(stamp, ...seen);
    }
    db.exec('COMMIT');
  } catch (err) {
    try { db.exec('ROLLBACK'); } catch {}
    throw err;
  }
}
syncCatalog();

function shopItemBySku(sku) {
  return db.prepare('SELECT * FROM shop_items WHERE slug=? AND active=1').get(sku) || null;
}
function publicCatalog() {
  return db.prepare('SELECT id,slug AS sku,name,description,price,payload_json AS payloadJson FROM shop_items WHERE active=1 ORDER BY price ASC,id ASC').all().map(row => {
    let delivery = {};
    try { delivery = JSON.parse(row.payloadJson || '{}'); } catch {}
    return { sku: row.sku, name: row.name, description: row.description, price: Number(row.price), quantity: Number(delivery.count || 1) };
  });
}
function orderPayload(row) {
  if (!row) return null;
  return {
    orderKey: row.order_key,
    sku: row.sku,
    name: row.item_name,
    quantity: Number(row.item_count || 1),
    price: Number(row.price || 0),
    status: row.status,
    attempts: Number(row.attempts || 0),
    createdAt: row.created_at,
    updatedAt: row.updated_at,
    fulfilledAt: row.fulfilled_at,
    lastError: row.last_error || null,
    refundedAt: row.refunded_at || null
  };
}
function ordersForUser(userId) {
  return db.prepare('SELECT * FROM shop_orders WHERE user_id=? AND order_key IS NOT NULL ORDER BY id DESC LIMIT 30').all(userId).map(orderPayload);
}

function reserveOrder(userId, item) {
  const payload = JSON.parse(item.payload_json || '{}');
  if (payload.type !== 'give_item' || !/^[A-Za-z0-9_]+$/.test(String(payload.itemId || ''))) throw new Error('Shop-Artikel hat keine gültige Zustellung.');
  const qty = Math.trunc(Number(payload.count));
  if (!Number.isInteger(qty) || qty < 1 || qty > 9999) throw new Error('Shop-Artikel hat eine ungültige Menge.');
  const price = Math.max(0, Math.trunc(Number(item.price) || 0));
  const orderKey = crypto.randomUUID();
  const stamp = nowIso();

  db.exec('BEGIN IMMEDIATE');
  try {
    const balance = pointsBalance(userId);
    if (balance < price) {
      const err = new Error(`Nicht genug Punkte. Benötigt: ${price} PTS, verfügbar: ${balance} PTS.`);
      err.code = 'INSUFFICIENT_POINTS';
      throw err;
    }
    const result = db.prepare(`INSERT INTO shop_orders(user_id,item_id,price,status,created_at,order_key,sku,item_name,item_asset,item_count,updated_at,attempts)
      VALUES(?,?,?,'CREATED',?,?,?,?,?,?,?,0)`)
      .run(userId, item.id, price, stamp, orderKey, item.slug, item.name, String(payload.itemId), qty, stamp);
    if (price > 0) {
      db.prepare(`INSERT INTO points_ledger(user_id,amount,reason,ref_type,ref_id,created_at)
        VALUES(?,?,?,?,?,?)`).run(userId, -price, `Shop: ${item.name}`, 'shop-reserve', orderKey, stamp);
    }
    db.prepare(`UPDATE shop_orders SET status='PAYMENT_RESERVED',reserved_at=?,updated_at=? WHERE id=?`).run(stamp, stamp, result.lastInsertRowid);
    db.exec('COMMIT');
  } catch (err) {
    try { db.exec('ROLLBACK'); } catch {}
    throw err;
  }
  return db.prepare('SELECT * FROM shop_orders WHERE order_key=?').get(orderKey);
}

function bridgePaths() {
  const cfg = config();
  const win64 = path.join(cfg.paths.server, 'Pal', 'Binaries', 'Win64');
  const nested = path.join(win64, 'ue4ss');
  const direct = win64;
  const root = fs.existsSync(path.join(nested, 'UE4SS.dll')) ? nested : direct;
  return {
    root,
    win64,
    memberLayout: path.join(root, 'MemberVariableLayout.ini'),
    ue4ssDll: path.join(root, 'UE4SS.dll'),
    proxyDll: path.join(win64, 'dwmapi.dll'),
    ipcDir: path.join(cfg.paths.data, 'bridge-ipc')
  };
}
function parseKv(raw) {
  const out = {};
  String(raw || '').split(/\r?\n/).forEach(line => {
    const i = line.indexOf('=');
    if (i < 1) return;
    const key = line.slice(0, i);
    const value = line.slice(i + 1);
    try { out[key] = decodeURIComponent(value.replace(/\+/g, '%20')); }
    catch { out[key] = value; }
  });
  return out;
}
function enc(value) { return encodeURIComponent(String(value ?? '')); }
function bridgeReady() {
  const p = bridgePaths();
  if (!fs.existsSync(p.ue4ssDll) || !fs.existsSync(p.proxyDll) || !fs.existsSync(p.memberLayout)) return false;
  const heartbeat = path.join(p.ipcDir, 'heartbeat.txt');
  try { return Date.now() - fs.statSync(heartbeat).mtimeMs < 7000; } catch { return false; }
}
async function sendBridgeCommand(commandId, type, params = {}, timeoutMs = 9000) {
  const p = bridgePaths();
  if (!bridgeReady()) throw new Error('PalPanelBridge ist aktuell nicht live.');
  fs.mkdirSync(p.ipcDir, { recursive: true });
  const commandPath = path.join(p.ipcDir, 'command.txt');
  const responsePath = path.join(p.ipcDir, 'response.txt');
  if (fs.existsSync(commandPath)) {
    const err = new Error('Bridge ist beschäftigt.');
    err.code = 'BRIDGE_BUSY';
    throw err;
  }
  try { fs.rmSync(responsePath, { force: true }); } catch {}
  const lines = [`id=${enc(commandId)}`, `type=${enc(type)}`];
  Object.entries(params).forEach(([key, value]) => lines.push(`${key}=${enc(value)}`));
  const tmp = `${commandPath}.tmp`;
  fs.writeFileSync(tmp, `${lines.join('\n')}\n`, 'utf8');
  fs.renameSync(tmp, commandPath);

  const started = Date.now();
  while (Date.now() - started < timeoutMs) {
    await new Promise(resolve => setTimeout(resolve, 100));
    if (!fs.existsSync(responsePath)) continue;
    let response;
    try { response = parseKv(fs.readFileSync(responsePath, 'utf8')); } catch { continue; }
    if (response.id !== commandId) continue;
    try { fs.rmSync(responsePath, { force: true }); } catch {}
    return { ok: response.ok === '1', message: response.message || '' };
  }
  const err = new Error('Bridge-Timeout: keine Antwort vom Gameserver.');
  err.code = 'BRIDGE_TIMEOUT';
  throw err;
}

function restCredentials() { return loadJson(REST_FILE, null); }
async function livePlayers() {
  const cfg = config();
  const creds = restCredentials();
  if (!creds?.password) return [];
  const auth = Buffer.from(`${creds.username || 'admin'}:${creds.password}`).toString('base64');
  const response = await fetch(`http://${cfg.palworld.rest.host || '127.0.0.1'}:${cfg.palworld.rest.port || 8212}/v1/api/players`, {
    headers: { Accept: 'application/json', Authorization: `Basic ${auth}` },
    signal: AbortSignal.timeout(3500)
  });
  if (!response.ok) return [];
  const body = await response.json().catch(() => ({}));
  return Array.isArray(body.players) ? body.players : [];
}
function sameIdentity(value, expected) {
  const a = String(value || '').trim();
  const b = String(expected || '').trim();
  if (!a || !b) return false;
  if (a === b) return true;
  const ad = a.replace(/\D/g, '');
  const bd = b.replace(/\D/g, '');
  return !!ad && ad === bd;
}
function findOnlinePlayer(players, steamId, link) {
  return players.find(player =>
    sameIdentity(player.userId, link.palworld_user_id) ||
    sameIdentity(player.userId, steamId) ||
    sameIdentity(player.playerId || player.playerUid, link.player_uid)
  ) || null;
}

function setOrderWaiting(orderKey, reason) {
  db.prepare(`UPDATE shop_orders SET status='WAITING_FOR_PLAYER',last_error=?,updated_at=? WHERE order_key=? AND status!='DELIVERED'`)
    .run(String(reason || '').slice(0, 500), nowIso(), orderKey);
}
function refundOrder(orderKey, reason) {
  const stamp = nowIso();
  db.exec('BEGIN IMMEDIATE');
  try {
    const row = db.prepare('SELECT * FROM shop_orders WHERE order_key=?').get(orderKey);
    if (!row || row.status === 'DELIVERED' || row.status === 'FAILED_REFUNDED') {
      db.exec('COMMIT');
      return row;
    }
    if (Number(row.price) > 0) {
      db.prepare(`INSERT OR IGNORE INTO points_ledger(user_id,amount,reason,ref_type,ref_id,created_at)
        VALUES(?,?,?,?,?,?)`).run(row.user_id, Number(row.price), `Shop-Rückerstattung: ${row.item_name || row.sku}`, 'shop-refund', orderKey, stamp);
    }
    db.prepare(`UPDATE shop_orders SET status='FAILED_REFUNDED',refunded_at=?,last_error=?,updated_at=? WHERE order_key=?`)
      .run(stamp, String(reason || 'Zustellung fehlgeschlagen').slice(0, 500), stamp, orderKey);
    db.exec('COMMIT');
    return db.prepare('SELECT * FROM shop_orders WHERE order_key=?').get(orderKey);
  } catch (err) {
    try { db.exec('ROLLBACK'); } catch {}
    throw err;
  }
}

const processingOrders = new Set();
async function attemptDelivery(orderKey) {
  if (processingOrders.has(orderKey)) return db.prepare('SELECT * FROM shop_orders WHERE order_key=?').get(orderKey) || null;
  processingOrders.add(orderKey);
  try {
    let order = db.prepare(`SELECT o.*,u.steam_id FROM shop_orders o JOIN users u ON u.id=o.user_id WHERE o.order_key=?`).get(orderKey);
    if (!order || ['DELIVERED', 'FAILED_REFUNDED'].includes(order.status)) return order;
    const link = linkFor(order.user_id);
    if (!link) {
      setOrderWaiting(orderKey, 'Charakter nicht verknüpft.');
      return db.prepare('SELECT * FROM shop_orders WHERE order_key=?').get(orderKey);
    }
    if (!bridgeReady()) {
      setOrderWaiting(orderKey, 'Gameserver/Bridge aktuell nicht bereit.');
      return db.prepare('SELECT * FROM shop_orders WHERE order_key=?').get(orderKey);
    }

    let players = [];
    try { players = await livePlayers(); } catch {}
    const online = findOnlinePlayer(players, order.steam_id, link);
    if (!online) {
      setOrderWaiting(orderKey, 'Spieler aktuell nicht online.');
      return db.prepare('SELECT * FROM shop_orders WHERE order_key=?').get(orderKey);
    }

    const targetName = String(online.name || link.palworld_name || '').trim();
    if (!targetName) {
      setOrderWaiting(orderKey, 'Live-Spielername konnte nicht aufgelöst werden.');
      return db.prepare('SELECT * FROM shop_orders WHERE order_key=?').get(orderKey);
    }

    const stamp = nowIso();
    db.prepare(`UPDATE shop_orders SET status='DELIVERING',attempts=attempts+1,last_attempt_at=?,last_error=NULL,updated_at=? WHERE order_key=?`)
      .run(stamp, stamp, orderKey);

    try {
      const result = await sendBridgeCommand(orderKey, 'give_item', {
        target: targetName,
        item: order.item_asset,
        count: Number(order.item_count)
      });
      if (result.ok) {
        const done = nowIso();
        db.prepare(`UPDATE shop_orders SET status='DELIVERED',fulfilled_at=?,updated_at=?,last_error=NULL WHERE order_key=?`).run(done, done, orderKey);
      } else {
        const msg = String(result.message || 'Bridge hat die Zustellung abgelehnt.');
        const lower = msg.toLowerCase();
        if (lower.includes('player not found') || lower.includes('inventory unavailable')) setOrderWaiting(orderKey, msg);
        else if (lower.includes('unknown command') || lower.includes('item missing') || lower.includes('count out of range')) refundOrder(orderKey, msg);
        else setOrderWaiting(orderKey, msg);
      }
    } catch (err) {
      setOrderWaiting(orderKey, err.message || 'Zustellung wird erneut versucht.');
    }
    return db.prepare('SELECT * FROM shop_orders WHERE order_key=?').get(orderKey);
  } finally {
    processingOrders.delete(orderKey);
  }
}

let workerBusy = false;
async function processQueue() {
  if (workerBusy) return;
  workerBusy = true;
  try {
    const queued = db.prepare(`SELECT order_key FROM shop_orders
      WHERE order_key IS NOT NULL AND status IN ('PAYMENT_RESERVED','WAITING_FOR_PLAYER','DELIVERING')
      ORDER BY id ASC LIMIT 5`).all();
    for (const row of queued) await attemptDelivery(row.order_key);
  } catch (err) {
    console.error('[PointShop] Queue:', err.message);
  } finally {
    workerBusy = false;
  }
}

function shopMe(session) {
  const link = linkFor(session.user_id);
  return {
    authenticated: true,
    points: pointsBalance(session.user_id),
    linked: !!link,
    character: link ? { name: link.palworld_name, level: link.level } : null,
    catalog: publicCatalog(),
    orders: ordersForUser(session.user_id)
  };
}

const previousCreateServer = http.createServer.bind(http);
http.createServer = function pointShopCreateServer(options, requestListener) {
  const hasOptions = typeof options !== 'function';
  const listener = hasOptions ? requestListener : options;
  const wrapped = async (req, res) => {
    let url;
    try { url = new URL(req.url, 'http://localhost'); }
    catch { return listener(req, res); }

    try {
      if ((req.method === 'GET' || req.method === 'HEAD') && url.pathname === '/shop') {
        req.url = `/shop.html${url.search}`;
        return listener(req, res);
      }
      if (req.method === 'GET' && url.pathname === '/api/shop/catalog') {
        return sendJson(res, 200, { catalog: publicCatalog() });
      }
      if (req.method === 'GET' && url.pathname === '/api/shop/me') {
        const session = sessionFor(req);
        if (!session) return sendJson(res, 401, { error: 'Nicht angemeldet.' });
        return sendJson(res, 200, shopMe(session));
      }
      if (req.method === 'POST' && url.pathname === '/api/shop/orders') {
        const session = sessionFor(req);
        if (!session) return sendJson(res, 401, { error: 'Nicht angemeldet.' });
        if (!linkFor(session.user_id)) return sendJson(res, 409, { error: 'Verbinde zuerst deinen Palworld-Charakter mit PalPanel.' });
        const input = await readBody(req);
        const sku = String(input.sku || '').trim();
        if (!/^[a-z0-9][a-z0-9-]{1,63}$/.test(sku)) return sendJson(res, 400, { error: 'Ungültige SKU.' });
        const item = shopItemBySku(sku);
        if (!item) return sendJson(res, 404, { error: 'Shop-Artikel nicht gefunden oder nicht aktiv.' });
        let order = reserveOrder(session.user_id, item);
        order = await attemptDelivery(order.order_key) || order;
        return sendJson(res, 201, { ok: true, points: pointsBalance(session.user_id), order: orderPayload(order) });
      }
      return listener(req, res);
    } catch (err) {
      console.error('[PointShop]', err);
      const status = err.code === 'INSUFFICIENT_POINTS' ? 409 : 500;
      if (!res.headersSent) return sendJson(res, status, { error: err.message || 'Point-Shop Fehler' });
      try { res.end(); } catch {}
    }
  };
  return hasOptions ? previousCreateServer(options, wrapped) : previousCreateServer(wrapped);
};

setTimeout(processQueue, 6000).unref();
setInterval(processQueue, 10000).unref();
console.log(`PalPanel v0.8 Point-Shop geladen. Catalog: ${CATALOG_FILE}`);
console.log('Shop-Queue: idempotente Zustellung über Order-Key, Retry alle 10 Sekunden.');
require('./server-v073.js');
