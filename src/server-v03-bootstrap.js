const fs = require('fs');
const path = require('path');
const vm = require('vm');

const target = path.join(__dirname, 'server-v03.js');
let code = fs.readFileSync(target, 'utf8');

const broken = ");let c=cfg();server.listen(c.panel.port,c.panel.host,()=>console.log(`PalPanel v${VERSION} | Frontend http://localhost:${c.panel.port} | Admin /admin`));";
const fixed = ");const listenCfg=cfg();server.listen(listenCfg.panel.port,listenCfg.panel.host,()=>console.log(`PalPanel v${VERSION} | Frontend http://localhost:${listenCfg.panel.port} | Admin /admin`));";

if (!code.includes(broken)) {
  console.error('[PalPanel] Erwartete v0.3-Startsequenz wurde nicht gefunden.');
  process.exit(1);
}

code = code.replace("const VERSION='0.3.0'", "const VERSION='0.3.1'");
code = code.replace(broken, fixed);
vm.runInThisContext(code, { filename: target });
