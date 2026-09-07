const fs=require('fs');const path=require('path');const {spawn}=require('child_process');
module.exports=function(ctx){
 const {config,serverStatus,stopPalworld,startPalworld,restRequest,runPowerShellJob,state}=ctx;
 function backups(){const dir=config().paths.backups;fs.mkdirSync(dir,{recursive:true});return fs.readdirSync(dir).filter(x=>/^palworld_.*\.zip$/i.test(x)).map(name=>{const s=fs.statSync(path.join(dir,name));return{name,size:s.size,createdAt:s.mtime.toISOString()}}).sort((a,b)=>b.createdAt.localeCompare(a.createdAt));}
 function backup(reason='manual'){const c=config();return runPowerShellJob('backup','backup-palworld.ps1',['-ServerDir',c.paths.server,'-BackupDir',c.paths.backups,'-Reason',reason,'-Retention',String(c.maintenance?.backupRetention||20)]);}
 function restore(name){const c=config();if(serverStatus().running)throw new Error('Server vor Restore stoppen.');if(!/^palworld_[\w.-]+\.zip$/i.test(name))throw new Error('Ungültiger Backupname.');const file=path.join(c.paths.backups,name);if(!fs.existsSync(file))throw new Error('Backup nicht gefunden.');return runPowerShellJob('restore','restore-palworld.ps1',['-ServerDir',c.paths.server,'-BackupFile',file,'-BackupDir',c.paths.backups]);}
 async function announce(message){return restRequest('/announce',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({message})});}
 async function kick(userid,message='Du wurdest vom Server getrennt.'){return restRequest('/kick',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({userid,message})});}
 async function ban(userid,message='Du wurdest vom Server gebannt.'){return restRequest('/ban',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({userid,message})});}
 async function unban(userid){return restRequest('/unban',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({userid})});}
 function maintenance(){const c=config();return c.maintenance||{};}
 function schedulerTick(){const c=config(),m=c.maintenance||{};if(!serverStatus().running)return;const now=new Date();const date=now.toISOString().slice(0,10);if(m.restartEnabled&&/^\d\d:\d\d$/.test(m.restartTime||'')){const local=`${String(now.getHours()).padStart(2,'0')}:${String(now.getMinutes()).padStart(2,'0')}`;const key=`restart:${date}:${local}`;if(local===m.restartTime&&state.v03Last!==key){state.v03Last=key;try{backup('scheduled-restart');}catch{}setTimeout(()=>{try{stopPalworld();setTimeout(()=>startPalworld(),2500)}catch{}},5000);}}
 if(m.backupEnabled&&Number(m.backupIntervalHours)>0){const list=backups();const last=list[0]?new Date(list[0].createdAt).getTime():0;if(Date.now()-last>=Number(m.backupIntervalHours)*3600000&&!(state.job&&state.job.running)){try{backup('automatic')}catch{}}}}
 setInterval(schedulerTick,60000);
 return{backups,backup,restore,announce,kick,ban,unban,maintenance};
};
