import Foundation

/// 离线日志文档；正文从结构化参数进入 DOM，浏览器负责连续文字选区与原生复制。
enum LogWebDocument {
    static let html = #"""
<!doctype html>
<html lang="zh-CN"><head><meta charset="utf-8">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src 'none'; img-src 'none'; frame-src 'none'; form-action 'none'; base-uri 'none'">
<style>
:root{color-scheme:light;--fg:#202127;--muted:#777a83;--line:#e2e3e8;--bg:#fafafa;--accent:#1676d2;font-size:12px}
:root.dark{color-scheme:dark;--fg:#dddde3;--muted:#93939f;--line:#36363d;--bg:#1d1d23;--accent:#56abff}
*{box-sizing:border-box}html,body{margin:0;min-height:100%;color:var(--fg);background:transparent;font-family:ui-monospace,Menlo,monospace}
body{padding:0 6px 12px}table{border-collapse:collapse;table-layout:fixed;width:100%}
thead{position:sticky;top:0;background:var(--bg);z-index:1;user-select:none;-webkit-user-select:none}
th{font:500 10px -apple-system,sans-serif;color:var(--muted);text-align:left;padding:9px 8px;border-bottom:1px solid var(--line);position:relative}
td{vertical-align:top;padding:7px 8px;white-space:pre-wrap;overflow-wrap:anywhere;line-height:1.45;user-select:text;-webkit-user-select:text}
td.meta{color:var(--muted);font-size:10px}td.level{font-size:9px}td.INFO{color:var(--accent)}td.WARNING{color:#cc8b26}td.ERROR,td.FAULT{color:#e65763}
tr.chosen{background:rgba(65,130,220,.10)}::selection{background:rgba(69,142,250,.38)}mark{background:rgba(232,190,40,.25);color:inherit}
.resize{position:absolute;right:0;top:0;width:6px;height:100%;cursor:col-resize}
</style></head><body><table aria-label="日志文字"><colgroup id="columns"></colgroup><thead><tr id="head"></tr></thead><tbody id="logs"></tbody></table>
<script>
'use strict';
(() => {
 const definitions=[['id','#',42],['clock','时间',104],['level','级别',58],['process','进程 / 分类',118],['message','消息',0]];
 let current=null,pending=null,down=false,lastTarget='',selectedIDs=new Set(),rowAnchor=null,requestedFollow=false;
 const widths={}, root=document.documentElement, logs=document.getElementById('logs');
 const send=(kind,extra={})=>window.webkit?.messageHandlers?.logs?.postMessage({kind,...extra});
 const selected=()=>{const s=getSelection();return s&&!s.isCollapsed&&s.toString().length>0;};
 const rowData=ids=>(current?.rows||[]).filter(r=>ids.has(r.id)).map(r=>({id:r.id,raw:r.raw}));
 function selectionRows(){
   const s=getSelection();if(!selected())return [];
   const range=s.getRangeAt(0), ids=new Set();
   for(const tr of logs.children)if(range.intersectsNode(tr))ids.add(tr.dataset.id);
   return rowData(ids);
 }
 function message(cell,text,search){
   if(!search){cell.textContent=text;return;}
   let start=0,index;const lower=text.toLowerCase(),term=search.toLowerCase();
   while((index=lower.indexOf(term,start))!==-1){
     cell.append(document.createTextNode(text.slice(start,index)));
     const mark=document.createElement('mark');mark.textContent=text.slice(index,index+search.length);cell.append(mark);start=index+search.length;
   }
   cell.append(document.createTextNode(text.slice(start)));
 }
 function paint(p){
   const contextChanged=current&&current.context!==p.context;
   const anchor=[...logs.children].find(r=>r.getBoundingClientRect().bottom>32);
   const anchorID=anchor?.dataset.id,offset=anchor?.getBoundingClientRect().top;
   const visible=definitions.filter(d=>!p.hidden.includes(d[0]));
   root.classList.toggle('dark',p.dark);root.style.fontSize=p.font+'px';
   const columns=document.getElementById('columns'),head=document.getElementById('head');
   columns.replaceChildren();head.replaceChildren();
   for(const [key,title,width] of visible){
     const col=document.createElement('col');if(widths[key]||width)col.style.width=(widths[key]||width)+'px';columns.append(col);
     const th=document.createElement('th');th.textContent=title;head.append(th);
     if(width){const handle=document.createElement('span');handle.className='resize';th.append(handle);
       handle.onpointerdown=e=>{e.preventDefault();down=true;const start=e.clientX,initial=th.getBoundingClientRect().width;
         handle.setPointerCapture(e.pointerId);handle.onpointermove=event=>{widths[key]=Math.max(36,initial+event.clientX-start);col.style.width=widths[key]+'px';};
         handle.onpointerup=()=>{handle.onpointermove=null;down=false;flush();};};}
   }
   const fragment=document.createDocumentFragment();
   for(const row of p.rows){
     const tr=document.createElement('tr');tr.dataset.id=row.id;
     if(selectedIDs.has(row.id)&&!contextChanged)tr.className='chosen';
     for(const [key] of visible){const td=document.createElement('td');td.className=key==='message'?'message':'meta '+key+(key==='level'?' '+row.level:'');
       if(key==='message')message(td,row[key],p.search);else td.textContent=row[key];tr.append(td);}
     fragment.append(tr);
   }
   logs.replaceChildren(fragment);current=p;
   if(contextChanged){selectedIDs.clear();rowAnchor=null;window.scrollTo(0,0);}
   if(p.follow)window.scrollTo(0,document.body.scrollHeight);
   else if(p.target&&p.target!==lastTarget){[...logs.children].find(r=>r.dataset.id===p.target)?.scrollIntoView({block:'center'});}
   else if(!contextChanged&&anchorID){const next=[...logs.children].find(r=>r.dataset.id===anchorID);if(next)window.scrollBy(0,next.getBoundingClientRect().top-offset);}
   lastTarget=p.target;
 }
 function flush(){if(pending&&!down&&!selected()){const p=pending;pending=null;paint(p);}}
 window.lumen={update(p){
   // 普通刷新只保留最新待显示快照，不能在拖选或非空选区中重建 DOM。
   const reset=current&&(current.context!==p.context||(p.follow&&!requestedFollow)||(p.target&&p.target!==lastTarget));
   requestedFollow=p.follow;
   if(reset){getSelection().removeAllRanges();down=false;pending=null;paint(p);return;}
   if(down||selected()){pending=p;return;}
   if(current&&JSON.stringify(current)===JSON.stringify(p))return;
   paint(p);
 }};
 document.addEventListener('pointerdown',e=>{if(e.button!==0||e.target.closest('thead'))return;down=true;requestedFollow=false;send('pause');});
 document.addEventListener('pointerup',()=>{down=false;setTimeout(flush,0);});
 window.addEventListener('blur',()=>{down=false;flush();});
 document.addEventListener('selectionchange',()=>{
   if(selected()){requestedFollow=false;send('pause');send('selection',{rows:selectionRows()});}else setTimeout(flush,0);
 });
 document.addEventListener('click',e=>{
   if(selected())return;
   const tr=e.target.closest('tbody tr');if(!tr)return;
   const id=tr.dataset.id;
   // 普通点击仅供详情定位，不画整行选中背景；修饰键显式选择完整记录。
   if(e.shiftKey&&rowAnchor){const ids=current.rows.map(r=>r.id),a=ids.indexOf(rowAnchor),b=ids.indexOf(id);selectedIDs=new Set(ids.slice(Math.min(a,b),Math.max(a,b)+1));}
   else if(e.metaKey){if(selectedIDs.has(id))selectedIDs.delete(id);else selectedIDs.add(id);rowAnchor=id;}
   else{selectedIDs.clear();rowAnchor=id;}
   for(const r of logs.children)r.classList.toggle('chosen',selectedIDs.has(r.dataset.id));
   send('selection',{rows:rowData(selectedIDs.size?selectedIDs:new Set([id]))});
 });
 document.addEventListener('keydown',e=>{
   if(e.key==='Escape'){getSelection().removeAllRanges();flush();}
   if(e.metaKey&&e.key.toLowerCase()==='c'&&!selected()&&selectedIDs.size){
     // 完整记录复制交给 macOS，普通字符复制完全使用 WebKit 的原生实现。
     e.preventDefault();send('copyRows');
   }
 });
 document.addEventListener('wheel',()=>{requestedFollow=false;send('pause');},{passive:true});
 document.addEventListener('dragover',e=>e.preventDefault());document.addEventListener('drop',e=>e.preventDefault());
})();
</script></body></html>
"""#
}
