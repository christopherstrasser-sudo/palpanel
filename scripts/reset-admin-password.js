const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

const APP_DIR = path.resolve(__dirname, '..');
const DEFAULT_CONFIG = path.join(APP_DIR, 'config', 'default.json');

function loadJson(file) {
  return JSON.parse(fs.readFileSync(file, 'utf8'));
}

function hashPassword(password, salt) {
  return crypto.scryptSync(password, salt, 64).toString('hex');
}

try {
  const defaults = loadJson(DEFAULT_CONFIG);
  const dataDir = defaults.paths.data;
  fs.mkdirSync(dataDir, { recursive: true });

  const adminFile = path.join(dataDir, 'admin.json');
  const username = 'admin';
  const password = crypto.randomBytes(12).toString('base64url');
  const salt = crypto.randomBytes(16).toString('hex');

  fs.writeFileSync(
    adminFile,
    JSON.stringify({ username, salt, hash: hashPassword(password, salt) }, null, 2),
    'utf8'
  );

  console.log('');
  console.log('============================================================');
  console.log(' PALPANEL ADMIN-PASSWORT ZURUECKGESETZT');
  console.log('============================================================');
  console.log(` Benutzer: ${username}`);
  console.log(` Passwort: ${password}`);
  console.log('');
  console.log(` Gespeichert in: ${adminFile}`);
  console.log('');
  console.log(' WICHTIG:');
  console.log(' Falls PalPanel gerade laeuft, bitte PalPanel danach einmal');
  console.log(' neu starten. Bestehende Sessions werden dadurch ebenfalls');
  console.log(' verworfen.');
  console.log('============================================================');
  console.log('');
} catch (err) {
  console.error('');
  console.error('[FEHLER] Admin-Passwort konnte nicht zurueckgesetzt werden:');
  console.error(err && err.stack ? err.stack : err);
  process.exitCode = 1;
}
