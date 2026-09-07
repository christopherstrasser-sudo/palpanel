const http = require('http');
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const { spawn, execFileSync } = require('child_process');

const APP_DIR = path.resolve(__dirname, '..');
const DEFAULT_CONFIG = path.join(APP_DIR, 'config', 'default.json');
const PUBLIC_DIR = path.join(APP_DIR, 'public');
const ADMIN_DIR = path.join(APP_DIR, 'admin');

function loadJson(file) { return JSON.parse(fs.readFileSync(file, 'utf8')); }
const defaults = loadJson(DEFAULT_CONFIG);
for (const dir of Object.values(defaults.paths)) fs.mkdirSync(dir, { recursive: true });

const USER_CONFIG = path.join(defaults.paths.data, 'config.json');
if (!fs.existsSync(USER_CONFIG)) fs.writeFileSync(USER_CONFIG, JSON.stringify(defaults, null, 2), 'utf8');

function config() {
  try {
    const current = loadJson(USER_CONFIG);
    return {
      ...defaults, ...current,
      panel: { ...defaults.panel, ...(current.panel || {}) },
      paths: { ...defaults.paths, ...(current.paths || {}) },
      palworld: { ...defaults.palworld, ...(current.palworld || {}) },
      event: { ...defaults.event, ...(current.event || {}) }
    };
  } catch { return defaults; }
}

const ADMIN_FILE = path.join(defaults.paths.data, 'admin.json');
const sessions = new Map();

function hashPassword(password, salt) {
  return crypto.scryptSync(password, salt, 64).toString('hex');
}
function ensureAdmin() {
  if (fs.existsSync(ADMIN_FILE)) return;
  const password = crypto.randomBytes(9).toString('base64url');
  const salt = crypto.randomBytes(16).toString('hex');
  fs.writeFileSync(ADMIN_FILE, JSON.stringify({ username: 'admin', salt, hash: hashPassword(password, salt) }, null, 2));
  console.log('');
  console.log('============================================================');
  console.log(' PALPANEL ADMIN-ZUGANG ERSTELLT');
  console.log(' Benutzer: admin');
  console.log(` Passwort: ${password}`);
  console.log(' Bitte Zugangsdaten sicher notieren.');
  console.log('============================================================');
  console.log('');
}
ensureAdmin();

function parseCookies(req) {
  const out = {};
  for (const part of String(req.headers.cookie || '').split(';')) {
    const idx = part.indexOf('=');
    if (idx > 0) out[part.slice(0, idx).trim()] = decodeURIComponent(part.slice(idx + 1).trim());
  }
  return out;
}
function session(req) {
  const token = parseCookies(req).palpanel_admin;
  if (!token) return null;
  const item = sessions.get(token);
  if (!item || item.expires < Date.now()) { if (token) sessions.delete(token); return null; }
  item.expires = Date.now() + 12 * 60 * 60 * 1000;
  return item;
}
function requireAdmin(req, res) {
  if (!session(req)) { json(res, 401, { error: 'Nicht angemeldet.' }); return false; }
  return true;
}

const state = { startedAt: Date.now(), job: null };
function json(res, status, body, headers = {}) {
  const data = Buffer.from(JSON.stringify(body));
  res.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8', 'Content-Length': data.length, 'Cache-Control': 'no-store', ...headers });
  res.end(data);
}
function readBody(req) {
  return new Promise((resolve, reject) => {
    let raw = '';
    req.on('data', chunk => { raw += chunk; if (raw.length > 1024 * 1024) reject(new Error('Request too large')); });
    req.on('end', () => { if (!raw) return resolve({}); try { resolve(JSON.parse(raw)); } catch { reject(new Error('Invalid JSON')); } });
    req.on('error', reject);
  });
}
function psEscape(value) { return String(value).replace(/'/g, "''"); }
function getServerProcesses() {
  const cfg = config();
  const serverDir = psEscape(path.resolve(cfg.paths.server));
  const command = `$root='${serverDir}'; @(Get-CimInstance Win32_Process | Where-Object { $_.ExecutablePath -and $_.ExecutablePath.StartsWith($root,[System.StringComparison]::OrdinalIgnoreCase) -and $_.Name -like 'PalServer*' } | Select-Object ProcessId,Name,CreationDate,ExecutablePath) | ConvertTo-Json -Compress`;
  try {
    const out = execFileSync('powershell.exe', ['-NoProfile','-ExecutionPolicy','Bypass','-Command',command], { encoding:'utf8', windowsHide:true, timeout:5000 }).trim();
    if (!out) return [];
    const parsed = JSON.parse(out); return Array.isArray(parsed) ? parsed : [parsed];
  } catch { return []; }
}
function serverInstalled() { return fs.existsSync(path.join(config().paths.server, 'PalServer.exe')); }
function steamCmdInstalled() { return fs.existsSync(path.join(config().paths.steamcmd, 'steamcmd.exe')); }
function serverStatus() {
  const processes = getServerProcesses(); const primary = processes[0] || null;
  return { installed:serverInstalled(), steamcmdInstalled:steamCmdInstalled(), running:processes.length>0, processCount:processes.length, pid:primary?Number(primary.ProcessId):null, processName:primary?primary.Name:null, serverPath:config().paths.server, executable:path.join(config().paths.server,'PalServer.exe') };
}
function appendJob(line) {
  if (!state.job) return;
  const clean = String(line).replace(/\r/g,'').trimEnd(); if (!clean) return;
  for (const piece of clean.split('\n')) state.job.log.push(piece);
  if (state.job.log.length > 500) state.job.log.splice(0, state.job.log.length - 500);
}
function runPowerShellJob(type, scriptName, args=[]) {
  if (state.job && state.job.running) throw new Error(`Es läuft bereits ein Job: ${state.job.type}`);
  const script = path.join(APP_DIR,'scripts',scriptName);
  state.job = { type, running:true, success:null, startedAt:new Date().toISOString(), finishedAt:null, exitCode:null, log:[] };
  appendJob(`PalPanel: ${type} gestartet.`);
  const child = spawn('powershell.exe',['-NoProfile','-ExecutionPolicy','Bypass','-File',script,...args],{cwd:APP_DIR,windowsHide:true});
  child.stdout.on('data',d=>appendJob(d.toString('utf8'))); child.stderr.on('data',d=>appendJob(d.toString('utf8')));
  child.on('error',err=>{appendJob(`FEHLER: ${err.message}`);state.job.running=false;state.job.success=false;state.job.finishedAt=new Date().toISOString();});
  child.on('close',code=>{state.job.running=false;state.job.exitCode=code;state.job.success=code===0;state.job.finishedAt=new Date().toISOString();appendJob(code===0?'PalPanel: Job erfolgreich abgeschlossen.':`PalPanel: Job fehlgeschlagen (Exitcode ${code}).`);});
  return state.job;
}
function startPalworld() {
  const cfg=config(); if(!serverInstalled()) throw new Error('Palworld Dedicated Server ist noch nicht installiert.'); if(getServerProcesses().length) throw new Error('Palworld Server läuft bereits.');
  const exe=path.join(cfg.paths.server,'PalServer.exe');
  const args=[`-port=${Number(cfg.palworld.port)||8211}`,`-players=${Number(cfg.palworld.maxPlayers)||32}`,...(cfg.palworld.publicLobby?['-publiclobby']:[]),...((cfg.palworld.startupArgs||[]).map(String))];
  const child=spawn(exe,args,{cwd:cfg.paths.server,detached:true,stdio:'ignore',windowsHide:false}); child.unref(); return {pid:child.pid,args};
}
function stopPalworld() {
  const cfg=config(); const serverDir=psEscape(path.resolve(cfg.paths.server));
  const command=`$root='${serverDir}'; $p=@(Get-CimInstance Win32_Process | Where-Object { $_.ExecutablePath -and $_.ExecutablePath.StartsWith($root,[System.StringComparison]::OrdinalIgnoreCase) -and $_.Name -like 'PalServer*' }); $count=$p.Count; $p | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }; Write-Output $count`;
  try { const out=execFileSync('powershell.exe',['-NoProfile','-ExecutionPolicy','Bypass','-Command',command],{encoding:'utf8',windowsHide:true,timeout:10000}).trim(); return {stopped:Number(out)||0}; }
  catch(err){ throw new Error(`Server konnte nicht gestoppt werden: ${err.message}`); }
}
function contentType(file){const ext=path.extname(file).toLowerCase();return ({'.html':'text/html; charset=utf-8','.css':'text/css; charset=utf-8','.js':'application/javascript; charset=utf-8','.json':'application/json; charset=utf-8','.svg':'image/svg+xml','.png':'image/png','.ico':'image/x-icon'})[ext]||'application/octet-stream';}
function safeStatic(res, base, pathname, fallback='index.html') {
  const normalized = path.normalize(path.join(base, pathname));
  if (!normalized.startsWith(base)) return json(res,403,{error:'Forbidden'});
  fs.readFile(normalized,(err,data)=>{
    if(err){return fs.readFile(path.join(base,fallback),(e,d)=>{if(e)return json(res,404,{error:'Not found'});res.writeHead(200,{'Content-Type':'text/html; charset=utf-8'});res.end(d);});}
    res.writeHead(200,{'Content-Type':contentType(normalized),'Cache-Control':'no-cache'});res.end(data);
  });
}

async function api(req,res,url){
  const cfg=config();
  if(req.method==='POST'&&url.pathname==='/api/admin/login'){
    try{const input=await readBody(req);const admin=loadJson(ADMIN_FILE);const ok=input.username===admin.username&&crypto.timingSafeEqual(Buffer.from(hashPassword(String(input.password||''),admin.salt),'hex'),Buffer.from(admin.hash,'hex'));
      if(!ok)return json(res,401,{error:'Ungültige Zugangsdaten.'}); const token=crypto.randomBytes(32).toString('hex');sessions.set(token,{username:admin.username,expires:Date.now()+12*60*60*1000});return json(res,200,{ok:true},{'Set-Cookie':`palpanel_admin=${token}; HttpOnly; SameSite=Strict; Path=/; Max-Age=43200`});
    }catch(err){return json(res,400,{error:err.message});}
  }
  if(req.method==='POST'&&url.pathname==='/api/admin/logout'){const token=parseCookies(req).palpanel_admin;if(token)sessions.delete(token);return json(res,200,{ok:true},{'Set-Cookie':'palpanel_admin=; HttpOnly; SameSite=Strict; Path=/; Max-Age=0'});}
  if(req.method==='GET'&&url.pathname==='/api/admin/session') return json(res,200,{authenticated:!!session(req)});

  if(req.method==='GET'&&url.pathname==='/api/public/status'){
    const s=serverStatus(); return json(res,200,{version:'0.1.1',server:{running:s.running,installed:s.installed},event:cfg.event,palworld:{port:cfg.palworld.port,maxPlayers:cfg.palworld.maxPlayers}});
  }

  if(url.pathname.startsWith('/api/admin/')&&!requireAdmin(req,res)) return;
  if(req.method==='GET'&&url.pathname==='/api/admin/status') return json(res,200,{version:'0.1.1',panelUptimeSeconds:Math.floor((Date.now()-state.startedAt)/1000),server:serverStatus(),event:cfg.event,palworld:{port:cfg.palworld.port,maxPlayers:cfg.palworld.maxPlayers,publicLobby:cfg.palworld.publicLobby},paths:cfg.paths,job:state.job?{type:state.job.type,running:state.job.running,success:state.job.success}:null});
  if(req.method==='GET'&&url.pathname==='/api/admin/job') return json(res,200,{job:state.job});
  if(req.method==='GET'&&url.pathname==='/api/admin/config') return json(res,200,cfg);

  if(req.method==='POST'&&url.pathname==='/api/admin/server/install'){
    try{const job=runPowerShellJob('Palworld Installation','install-palworld.ps1',['-Root',cfg.paths.root,'-ServerDir',cfg.paths.server,'-SteamCmdDir',cfg.paths.steamcmd]);return json(res,202,{ok:true,job});}catch(err){return json(res,409,{ok:false,error:err.message});}
  }
  if(req.method==='POST'&&url.pathname==='/api/admin/server/update'){
    try{if(serverStatus().running)return json(res,409,{ok:false,error:'Server vor dem Update stoppen.'});const job=runPowerShellJob('Palworld Update','update-palworld.ps1',['-ServerDir',cfg.paths.server,'-SteamCmdDir',cfg.paths.steamcmd]);return json(res,202,{ok:true,job});}catch(err){return json(res,409,{ok:false,error:err.message});}
  }
  if(req.method==='POST'&&url.pathname==='/api/admin/server/start'){try{return json(res,200,{ok:true,result:startPalworld()});}catch(err){return json(res,409,{ok:false,error:err.message});}}
  if(req.method==='POST'&&url.pathname==='/api/admin/server/stop'){try{return json(res,200,{ok:true,result:stopPalworld()});}catch(err){return json(res,500,{ok:false,error:err.message});}}
  if(req.method==='POST'&&url.pathname==='/api/admin/server/restart'){try{stopPalworld();await new Promise(r=>setTimeout(r,1500));return json(res,200,{ok:true,result:startPalworld()});}catch(err){return json(res,500,{ok:false,error:err.message});}}
  if(req.method==='PUT'&&url.pathname==='/api/admin/config/event'){
    try{const input=await readBody(req);const current=config();current.event={...current.event,title:typeof input.title==='string'?input.title.slice(0,100):current.event.title,startAt:input.startAt||null,endAt:input.endAt||null};fs.writeFileSync(USER_CONFIG,JSON.stringify(current,null,2),'utf8');return json(res,200,{ok:true,event:current.event});}catch(err){return json(res,400,{ok:false,error:err.message});}
  }
  return json(res,404,{error:'API route not found'});
}

const server=http.createServer(async(req,res)=>{
  try{
    const url=new URL(req.url,'http://localhost');
    if(url.pathname.startsWith('/api/'))return await api(req,res,url);
    if(url.pathname==='/admin')return res.writeHead(302,{Location:'/admin/'}).end();
    if(url.pathname.startsWith('/admin/')){
      let p=decodeURIComponent(url.pathname.slice('/admin'.length));if(p==='/'||!p)p='/index.html';return safeStatic(res,ADMIN_DIR,p,'index.html');
    }
    let p=decodeURIComponent(url.pathname);if(p==='/')p='/index.html';return safeStatic(res,PUBLIC_DIR,p,'index.html');
  }catch(err){console.error(err);return json(res,500,{error:err.message||'Internal server error'});}
});
const cfg=config();
server.listen(cfg.panel.port,cfg.panel.host,()=>{
  console.log('');console.log('============================================================');console.log(' PalPanel v0.1.1');console.log('============================================================');console.log(` Frontend: http://localhost:${cfg.panel.port}`);console.log(` Admin:    http://localhost:${cfg.panel.port}/admin`);console.log(` Server:   ${cfg.paths.server}`);console.log('============================================================');console.log('');
});
