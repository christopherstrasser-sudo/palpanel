const fs = require('fs');
const path = require('path');
const { DatabaseSync } = require('node:sqlite');

const APP_DIR = path.resolve(__dirname, '..');
const defaults = JSON.parse(fs.readFileSync(path.join(APP_DIR, 'config', 'default.json'), 'utf8'));
const DATA_DIR = defaults.paths.data;
const USER_CONFIG = path.join(DATA_DIR, 'config.json');
const PROGRESSION_FILE = path.join(DATA_DIR, 'progression.json');
const DB_FILE = path.join(DATA_DIR, 'palpanel.db');
const EVENTS_DIR = path.join(DATA_DIR, 'bridge-ipc', 'events');
const FAILED_DIR = path.join(DATA_DIR, 'bridge-ipc', 'events-failed');

fs.mkdirSync(EVENTS_DIR, { recursive: true });
fs.mkdirSync(FAILED_DIR, { recursive: true });

function loadJson(file, fallback = null) {
  try { return JSON.parse(fs.readFileSync(file, 'utf8')); } catch { return fallback; }
}

function panelPort() {
  const current = loadJson(USER_CONFIG, {}) || {};
  return Number(current.panel?.port || defaults.panel.port || 8787);
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

function readEvent(file) {
  const full = path.join(EVENTS_DIR, file);
  const event = parseKv(fs.readFileSync(full, 'utf8'));
  if (event.type !== 'capture') throw new Error(`unsupported event type: ${event.type || 'missing'}`);
  if (!event.event_id) throw new Error('event_id missing');
  if (!event.player_uid) throw new Error('player_uid missing');
  if (!event.species) throw new Error('species missing');
  return { full, event };
}

function moveFailed(file, reason) {
  const from = path.join(EVENTS_DIR, file);
  const stamp = new Date().toISOString().replace(/[:.]/g, '-');
  const to = path.join(FAILED_DIR, `${stamp}_${file}`);
  try { fs.renameSync(from, to); }
  catch {
    try { fs.copyFileSync(from, to); fs.rmSync(from, { force: true }); } catch {}
  }
  try { fs.writeFileSync(`${to}.error.txt`, String(reason || 'unknown error'), 'utf8'); } catch {}
}

let linkDb = null;
function db() {
  if (!linkDb) linkDb = new DatabaseSync(DB_FILE, { timeout: 2000 });
  return linkDb;
}
function canonicalIdentity(value) {
  return String(value || '').trim().replace(/[^0-9a-z]/gi, '').toUpperCase();
}
function linkedUserId(playerUid) {
  const wanted = canonicalIdentity(playerUid);
  if (!wanted) return null;
  try {
    const rows = db().prepare('SELECT user_id,palworld_user_id,player_uid FROM player_links').all();
    const row = rows.find(link =>
      canonicalIdentity(link.player_uid) === wanted ||
      canonicalIdentity(link.palworld_user_id) === wanted
    );
    return row ? Number(row.user_id) : null;
  } catch {
    return null;
  }
}

const processing = new Set();
const lastAttempt = new Map();
const lastLoggedError = new Map();

function shouldRetry(file) {
  return Date.now() - Number(lastAttempt.get(file) || 0) >= 3000;
}

function logErrorOnce(file, message) {
  const previous = lastLoggedError.get(file);
  if (previous === message) return;
  lastLoggedError.set(file, message);
  console.warn(`[CaptureEvents] ${file}: ${message}`);
}

async function dispatchEvent(file) {
  if (processing.has(file) || !shouldRetry(file)) return;
  processing.add(file);
  lastAttempt.set(file, Date.now());

  try {
    let parsed;
    try {
      parsed = readEvent(file);
    } catch (err) {
      moveFailed(file, err.message);
      console.warn(`[CaptureEvents] Ungültiges Event verschoben: ${file} (${err.message})`);
      return;
    }

    const progression = loadJson(PROGRESSION_FILE, null);
    const bridgeKey = progression?.bridgeKey;
    if (!bridgeKey) {
      logErrorOnce(file, 'Progression Bridge-Key noch nicht verfügbar; Event bleibt in der Queue.');
      return;
    }

    const e = parsed.event;
    const userId = linkedUserId(e.player_uid);
    const payload = {
      source: 'PalPanelBridge',
      eventId: e.event_id,
      type: 'capture',
      ...(userId ? { userId } : {}),
      playerUid: e.player_uid,
      palworldUserId: e.player_uid,
      speciesKey: e.species,
      alpha: e.alpha === '1' || String(e.alpha).toLowerCase() === 'true',
      rare: e.rare === '1' || String(e.rare).toLowerCase() === 'true',
      captureCount: Number(e.capture_count) || null,
      level: Number(e.level) || null,
      uniqueNpcId: e.unique_npc || null,
      palId: e.pal_id || null,
      rawSpecies: e.raw_species || e.species,
      bridgeSource: e.source || null,
      capturedAt: e.time ? Number(e.time) : null
    };

    let response;
    let body = {};
    try {
      response = await fetch(`http://127.0.0.1:${panelPort()}/api/internal/progression/event`, {
        method: 'POST',
        headers: {
          'Accept': 'application/json',
          'Content-Type': 'application/json',
          'X-PalPanel-Bridge-Key': bridgeKey
        },
        body: JSON.stringify(payload),
        signal: AbortSignal.timeout(4000)
      });
      body = await response.json().catch(() => ({}));
    } catch (err) {
      logErrorOnce(file, `PalPanel noch nicht erreichbar: ${err.message}`);
      return;
    }

    if (!response.ok) {
      const message = String(body.error || `HTTP ${response.status}`);
      const lower = message.toLowerCase();
      if (response.status === 400 && (
        lower.includes('specieskey fehlt') ||
        lower.includes('unbekannter event-typ') ||
        lower.includes('eventid fehlt')
      )) {
        moveFailed(file, message);
        console.warn(`[CaptureEvents] Permanenter Fehler, Event verschoben: ${file} (${message})`);
        return;
      }
      logErrorOnce(file, `${message} — wird erneut versucht.`);
      return;
    }

    fs.rmSync(parsed.full, { force: true });
    lastAttempt.delete(file);
    lastLoggedError.delete(file);

    const tag = payload.alpha ? ' ALPHA' : payload.rare ? ' LUCKY' : '';
    if (body.duplicate) {
      console.log(`[CaptureEvents] Duplicate ignoriert: ${payload.speciesKey} (${payload.eventId})`);
    } else {
      console.log(`[CaptureEvents] ${payload.speciesKey}${tag} -> +${Number(body.pointsAwarded || 0)} PTS / +${Number(body.scoreAwarded || 0)} Score | Unique: ${Number(body.uniquePals || 0)}`);
    }
  } finally {
    processing.delete(file);
  }
}

let scanBusy = false;
async function scanEvents() {
  if (scanBusy) return;
  scanBusy = true;
  try {
    const files = fs.readdirSync(EVENTS_DIR)
      .filter(name => name.toLowerCase().endsWith('.evt'))
      .sort()
      .slice(0, 25);
    for (const file of files) await dispatchEvent(file);
  } catch (err) {
    console.error('[CaptureEvents] Queue scan:', err.message);
  } finally {
    scanBusy = false;
  }
}

require('./server-v081.js');

setTimeout(scanEvents, 2500).unref();
setInterval(scanEvents, 1000).unref();
console.log(`PalPanel v0.8.2 Live-Capture-Worker geladen. Events: ${EVENTS_DIR}`);
