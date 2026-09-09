(() => {
  const resolver=window.PalNames;
  if(!resolver?.replaceInText)return;

  const skip=new Set(['SCRIPT','STYLE','NOSCRIPT','TEXTAREA','INPUT','SELECT']);
  function fixText(node){
    if(!node?.nodeValue)return;
    const parent=node.parentElement;
    if(parent&&skip.has(parent.tagName))return;
    const next=resolver.replaceInText(node.nodeValue);
    if(next!==node.nodeValue)node.nodeValue=next;
  }
  function fixTree(root){
    if(!root)return;
    if(root.nodeType===Node.TEXT_NODE)return fixText(root);
    if(root.nodeType!==Node.ELEMENT_NODE&&root.nodeType!==Node.DOCUMENT_FRAGMENT_NODE)return;
    if(root.nodeType===Node.ELEMENT_NODE&&skip.has(root.tagName))return;
    const walker=document.createTreeWalker(root,NodeFilter.SHOW_TEXT);
    let node;
    while((node=walker.nextNode()))fixText(node);
  }
  function fixAttributes(root){
    if(root?.nodeType!==Node.ELEMENT_NODE)return;
    for(const attr of ['title','aria-label']){
      if(!root.hasAttribute(attr))continue;
      const old=root.getAttribute(attr)||'';
      const next=resolver.replaceInText(old);
      if(next!==old)root.setAttribute(attr,next);
    }
  }

  function start(){
    fixTree(document.body);
    document.querySelectorAll('[title],[aria-label]').forEach(fixAttributes);
    const observer=new MutationObserver(records=>{
      for(const record of records){
        if(record.type==='characterData')fixText(record.target);
        for(const node of record.addedNodes||[]){
          fixTree(node);
          if(node.nodeType===Node.ELEMENT_NODE){
            fixAttributes(node);
            node.querySelectorAll?.('[title],[aria-label]').forEach(fixAttributes);
          }
        }
      }
    });
    observer.observe(document.body,{subtree:true,childList:true,characterData:true});
  }

  if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',start,{once:true});
  else start();
})();
