const http=require('http');

const ASSET_VERSION='0910';
const PUBLIC_ROUTES=new Set(['','/','/profile','/profile/','/shop','/shop/','/event','/missions','/hall-of-fame']);
function isPublicDocument(pathname){return PUBLIC_ROUTES.has(pathname)||/^\/player\/\d+\/?$/.test(pathname);}

function enhanceHtml(html){
  let out=String(html||'');
  if(out.includes('/pal-names.js?v=0910'))return out;
  const assets=`<script src="/pal-names.js?v=${ASSET_VERSION}"></script><script defer src="/pal-name-dom.js?v=${ASSET_VERSION}"></script>`;
  return out.includes('</head>')?out.replace('</head>',`${assets}</head>`):out;
}

function captureHtml(req,res,listener){
  const originalWriteHead=res.writeHead.bind(res);
  const originalEnd=res.end.bind(res);
  let status=null,statusMessage=null,headers=null;

  res.writeHead=function patchedWriteHead(code,message,suppliedHeaders){
    status=code;
    if(typeof message==='string'){
      statusMessage=message;
      headers={...(suppliedHeaders||{})};
    }else headers={...(message||{})};
    return res;
  };

  res.end=function patchedEnd(chunk,encoding,callback){
    if(status!=null){
      const nextHeaders={...(headers||{})};
      const contentType=String(nextHeaders['Content-Type']||nextHeaders['content-type']||'');
      if(status===200&&contentType.toLowerCase().includes('text/html')&&chunk!=null){
        const html=enhanceHtml(Buffer.isBuffer(chunk)?chunk.toString('utf8'):String(chunk));
        const data=Buffer.from(html);
        delete nextHeaders['content-length'];
        nextHeaders['Content-Length']=data.length;
        if(statusMessage)originalWriteHead(status,statusMessage,nextHeaders);
        else originalWriteHead(status,nextHeaders);
        return originalEnd(data,undefined,callback);
      }
      if(statusMessage)originalWriteHead(status,statusMessage,nextHeaders);
      else originalWriteHead(status,nextHeaders);
    }
    return originalEnd(chunk,encoding,callback);
  };

  return listener(req,res);
}

const previousCreateServer=http.createServer.bind(http);
http.createServer=function palNamesCreateServer(options,requestListener){
  const hasOptions=typeof options!=='function';
  const listener=hasOptions?requestListener:options;
  const wrapped=(req,res)=>{
    let url;
    try{url=new URL(req.url,'http://localhost');}catch{return listener(req,res);}
    if((req.method==='GET'||req.method==='HEAD')&&isPublicDocument(url.pathname))return captureHtml(req,res,listener);
    return listener(req,res);
  };
  return hasOptions?previousCreateServer(options,wrapped):previousCreateServer(wrapped);
};

console.log('PalPanel v0.9.10 offizielle Pal-Anzeigenamen geladen.');
require('./server-v099.js');
