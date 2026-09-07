const http = require('http');
const fs = require('fs');
const path = require('path');
const { spawn, execFileSync } = require('child_process');

const APP_DIR = path.resolve(__dirname, '..');
const DEFAULT_CONFIG = path.join(APP_DIR, 'config', 'default.json');
const PUBLIC_DIR = path.join(APP_DIR, 'public');

function loadJson(file) {
  return JSON.parse(fs.readFileSync(file, 'utf8'));
}

const defaults = loadJson(DEFAULT_CONFIG);
const root = defaults.paths.root;
for (const dir of Object.values(defaults.paths)) {
  fs.mkdirSync(dir, { recursive: true });
}

const USER_CONFIG = path.join(defaults.paths.data, 'config.json');
if (!fs.existsSync(USER_CONFIG)) {
  fs.writeFileSync(USER_CONFIG, JSON.stringify(defaults, null, 2), 'utf8');
}

function config() {
  try {
    const current = loadJson(USER_CONFIG);
    return {
      ...defaults,
      ...current,
      panel: { ...defaults.panel, ...(current.panel || {}) },
      paths: { ...defaults.paths, ...(current.paths || {}) },
      palworld: { ...defaults.palworld, ...(current.palworld || {}) },
      event: { ...defaults.event, ...(current.event || {}) }
    };
  } catch {
    return defaults;
  }
}

const state = {
  startedAt: Date.now(),
  job: null
};

function json(res, status, body) {
  const data = Buffer.from(JSON.stringify(body));
  res.writeHead(status, {
    'Content-Type': 'application/json; charset=utf-8',
    'Content-Length': data.length,
    'Cache-Control': 'no-store'
  });
  res.end(data);
}

function body(req) {
  return new Promise((resolve, reject) => {
    let raw = '';
    req.on('data', chunk => {
      raw += chunk;
      if (raw.length > 1024 * 1024) reject(new Error('Request too large'));
    });
    req.on('end', () => {
      if (!raw) return resolve({});
      try { resolve(JSON.parse(raw)); } catch { reject(new Error('Invalid JSON')); }
    });
    req.on('error', reject);
  });
}

function psEscape(value) {
  return String(value).replace(/'/g, "''");
}

function getServerProcesses() {
  const cfg = config();
  const serverDir = psEscape(path.resolve(cfg.paths.server));
  const command = `$root='${serverDir}'; @(Get-CimInstance Win32_Process | Where-Object { $_.ExecutablePath -and $_.ExecutablePath.StartsWith($root,[System.StringComparison]::OrdinalIgnoreCase) -and $_.Name -like 'PalServer*' } | Select-Object ProcessId,Name,CreationDate,ExecutablePath) | ConvertTo-Json -Compress`;
  try {
    const out = execFileSync('powershell.exe', ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', command], {
      encoding: 'utf8',
      windowsHide: true,
      timeout: 5000
    }).trim();
    if (!out) return [];
    const parsed = JSON.parse(out);
    return Array.isArray(parsed) ? parsed : [parsed];
  } catch {
    return [];
  }
}

function serverInstalled() {
  return fs.existsSync(path.join(config().paths.server, 'PalServer.exe'));
}

function steamCmdInstalled() {
  return fs.existsSync(path.join(config().paths.steamcmd, 'steamcmd.exe'));
}

function serverStatus() {
  const processes = getServerProcesses();
  const primary = processes[0] || null;
  return {
    installed: serverInstalled(),
    steamcmdInstalled: steamCmdInstalled(),
    running: processes.length > 0,
    processCount: processes.length,
    pid: primary ? Number(primary.ProcessId) : null,
    processName: primary ? primary.Name : null,
    serverPath: config().paths.server,
    executable: path.join(config().paths.server, 'PalServer.exe')
  };
}

function appendJob(line) {
  if (!state.job) return;
  const clean = String(line).replace(/\r/g, '').trimEnd();
  if (!clean) return;
  const pieces = clean.split('\n');
  for (const piece of pieces) {
    state.job.log.push(piece);
  }
  if (state.job.log.length > 500) state.job.log.splice(0, state.job.log.length - 500);
}

function runPowerShellJob(type, scriptName, args = []) {
  if (state.job && state.job.running) {
    throw new Error(`Es läuft bereits ein Job: ${state.job.type}`);
  }

  const script = path.join(APP_DIR, 'scripts', scriptName);
  state.job = {
    type,
    running: true,
    success: null,
    startedAt: new Date().toISOString(),
    finishedAt: null,
    exitCode: null,
    log: []
  };

  appendJob(`PalPanel: ${type} gestartet.`);
  const child = spawn('powershell.exe', ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', script, ...args], {
    cwd: APP_DIR,
    windowsHide: true
  });

  child.stdout.on('data', data => appendJob(data.toString('utf8')));
  child.stderr.on('data', data => appendJob(data.toString('utf8')));
  child.on('error', err => {
    appendJob(`FEHLER: ${err.message}`);
    state.job.running = false;
    state.job.success = false;
    state.job.finishedAt = new Date().toISOString();
  });
  child.on('close', code => {
    state.job.running = false;
    state.job.exitCode = code;
    state.job.success = code === 0;
    state.job.finishedAt = new Date().toISOString();
    appendJob(code === 0 ? 'PalPanel: Job erfolgreich abgeschlossen.' : `PalPanel: Job fehlgeschlagen (Exitcode ${code}).`);
  });

  return state.job;
}

function startPalworld() {
  const cfg = config();
  if (!serverInstalled()) throw new Error('Palworld Dedicated Server ist noch nicht installiert.');
  if (getServerProcesses().length) throw new Error('Palworld Server läuft bereits.');

  const exe = path.join(cfg.paths.server, 'PalServer.exe');
  const args = [
    `-port=${Number(cfg.palworld.port) || 8211}`,
    `-players=${Number(cfg.palworld.maxPlayers) || 32}`,
    ...(cfg.palworld.publicLobby ? ['-publiclobby'] : []),
    ...((cfg.palworld.startupArgs || []).map(String))
  ];

  const child = spawn(exe, args, {
    cwd: cfg.paths.server,
    detached: true,
    stdio: 'ignore',
    windowsHide: false
  });
  child.unref();
  return { pid: child.pid, args };
}

function stopPalworld() {
  const cfg = config();
  const serverDir = psEscape(path.resolve(cfg.paths.server));
  const command = `$root='${serverDir}'; $p=@(Get-CimInstance Win32_Process | Where-Object { $_.ExecutablePath -and $_.ExecutablePath.StartsWith($root,[System.StringComparison]::OrdinalIgnoreCase) -and $_.Name -like 'PalServer*' }); $count=$p.Count; $p | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }; Write-Output $count`;
  try {
    const out = execFileSync('powershell.exe', ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', command], {
      encoding: 'utf8', windowsHide: true, timeout: 10000
    }).trim();
    return { stopped: Number(out) || 0 };
  } catch (err) {
    throw new Error(`Server konnte nicht gestoppt werden: ${err.message}`);
  }
}

function contentType(file) {
  const ext = path.extname(file).toLowerCase();
  return ({
    '.html': 'text/html; charset=utf-8',
    '.css': 'text/css; charset=utf-8',
    '.js': 'application/javascript; charset=utf-8',
    '.json': 'application/json; charset=utf-8',
    '.svg': 'image/svg+xml',
    '.png': 'image/png',
    '.ico': 'image/x-icon'
  })[ext] || 'application/octet-stream';
}

function serveStatic(req, res) {
  let pathname = decodeURIComponent(new URL(req.url, 'http://localhost').pathname);
  if (pathname === '/') pathname = '/index.html';
  const target = path.normalize(path.join(PUBLIC_DIR, pathname));
  if (!target.startsWith(PUBLIC_DIR)) return json(res, 403, { error: 'Forbidden' });
  fs.readFile(target, (err, data) => {
    if (err) {
      if (pathname !== '/index.html') {
        return fs.readFile(path.join(PUBLIC_DIR, 'index.html'), (fallbackErr, fallback) => {
          if (fallbackErr) return json(res, 404, { error: 'Not found' });
          res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
          res.end(fallback);
        });
      }
      return json(res, 404, { error: 'Not found' });
    }
    res.writeHead(200, { 'Content-Type': contentType(target), 'Cache-Control': 'no-cache' });
    res.end(data);
  });
}

async function api(req, res, url) {
  const cfg = config();

  if (req.method === 'GET' && url.pathname === '/api/status') {
    return json(res, 200, {
      version: '0.1.0',
      panelUptimeSeconds: Math.floor((Date.now() - state.startedAt) / 1000),
      server: serverStatus(),
      event: cfg.event,
      palworld: {
        port: cfg.palworld.port,
        maxPlayers: cfg.palworld.maxPlayers,
        publicLobby: cfg.palworld.publicLobby
      },
      paths: cfg.paths,
      job: state.job ? { type: state.job.type, running: state.job.running, success: state.job.success } : null
    });
  }

  if (req.method === 'GET' && url.pathname === '/api/job') {
    return json(res, 200, { job: state.job });
  }

  if (req.method === 'POST' && url.pathname === '/api/server/install') {
    try {
      const job = runPowerShellJob('Palworld Installation', 'install-palworld.ps1', [
        '-Root', cfg.paths.root,
        '-ServerDir', cfg.paths.server,
        '-SteamCmdDir', cfg.paths.steamcmd
      ]);
      return json(res, 202, { ok: true, job });
    } catch (err) { return json(res, 409, { ok: false, error: err.message }); }
  }

  if (req.method === 'POST' && url.pathname === '/api/server/update') {
    try {
      if (serverStatus().running) return json(res, 409, { ok: false, error: 'Server vor dem Update stoppen.' });
      const job = runPowerShellJob('Palworld Update', 'update-palworld.ps1', [
        '-ServerDir', cfg.paths.server,
        '-SteamCmdDir', cfg.paths.steamcmd
      ]);
      return json(res, 202, { ok: true, job });
    } catch (err) { return json(res, 409, { ok: false, error: err.message }); }
  }

  if (req.method === 'POST' && url.pathname === '/api/server/start') {
    try { return json(res, 200, { ok: true, result: startPalworld() }); }
    catch (err) { return json(res, 409, { ok: false, error: err.message }); }
  }

  if (req.method === 'POST' && url.pathname === '/api/server/stop') {
    try { return json(res, 200, { ok: true, result: stopPalworld() }); }
    catch (err) { return json(res, 500, { ok: false, error: err.message }); }
  }

  if (req.method === 'POST' && url.pathname === '/api/server/restart') {
    try {
      stopPalworld();
      await new Promise(resolve => setTimeout(resolve, 1500));
      return json(res, 200, { ok: true, result: startPalworld() });
    } catch (err) { return json(res, 500, { ok: false, error: err.message }); }
  }

  if (req.method === 'GET' && url.pathname === '/api/config') {
    return json(res, 200, cfg);
  }

  if (req.method === 'PUT' && url.pathname === '/api/config/event') {
    try {
      const input = await body(req);
      const current = config();
      current.event = {
        ...current.event,
        title: typeof input.title === 'string' ? input.title.slice(0, 100) : current.event.title,
        startAt: input.startAt || null,
        endAt: input.endAt || null
      };
      fs.writeFileSync(USER_CONFIG, JSON.stringify(current, null, 2), 'utf8');
      return json(res, 200, { ok: true, event: current.event });
    } catch (err) { return json(res, 400, { ok: false, error: err.message }); }
  }

  return json(res, 404, { error: 'API route not found' });
}

const server = http.createServer(async (req, res) => {
  try {
    const url = new URL(req.url, 'http://localhost');
    if (url.pathname.startsWith('/api/')) return await api(req, res, url);
    return serveStatic(req, res);
  } catch (err) {
    console.error(err);
    return json(res, 500, { error: err.message || 'Internal server error' });
  }
});

const cfg = config();
server.listen(cfg.panel.port, cfg.panel.host, () => {
  console.log('');
  console.log('============================================================');
  console.log(` PalPanel v0.1.0`);
  console.log('============================================================');
  console.log(` Dashboard: http://localhost:${cfg.panel.port}`);
  console.log(` Server:    ${cfg.paths.server}`);
  console.log(` SteamCMD:  ${cfg.paths.steamcmd}`);
  console.log('============================================================');
  console.log('');
});
