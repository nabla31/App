#!/data/data/com.termux/files/usr/bin/bash
# Installe "Claude UI" + OmniRoute dans Termux
set -e
export DEBIAN_FRONTEND=noninteractive
echo "→ Paquets…"
pkg update -y
pkg install -y nodejs-lts python build-essential git procps termux-tools util-linux
command -v omniroute >/dev/null || npm install -g omniroute
command -v claude >/dev/null || npm install -g @anthropic-ai/claude-code || echo "⚠ Installation de claude échouée : installe Claude Code à la main."

APP="$HOME/claude-ui"
mkdir -p "$APP/public" "$HOME/.shortcuts"

cat > "$APP/server.js" <<'JS_EOF'
const http = require('http'), fs = require('fs'), path = require('path'), os = require('os');
const { spawn } = require('child_process');
const PORT = 8787, OMNI = 'http://localhost:20128', DIR = __dirname;

function readEnv() {
  const e = {};
  try {
    fs.readFileSync(path.join(DIR, '.env'), 'utf8').split('\n').forEach(l => {
      const m = l.match(/^\s*([A-Za-z0-9_]+)\s*=\s*(.*?)\s*$/);
      if (m && !l.trim().startsWith('#')) e[m[1]] = m[2].replace(/^["']|["']$/g, '');
    });
  } catch {}
  return e;
}
const json = (res, c, o) => { res.writeHead(c, { 'Content-Type': 'application/json' }); res.end(JSON.stringify(o)); };
const readBody = req => new Promise(r => {
  let b = ''; req.on('data', d => b += d);
  req.on('end', () => { try { r(JSON.parse(b || '{}')); } catch { r({}); } });
});
const omniUp = () => new Promise(r => {
  const q = http.get(OMNI, { timeout: 1500 }, s => { s.resume(); r(true); });
  q.on('error', () => r(false));
  q.on('timeout', () => { q.destroy(); r(false); });
});

let proc = null, run = null;
function attach(res, from) {
  res.writeHead(200, { 'Content-Type': 'text/event-stream', 'Cache-Control': 'no-cache', 'X-Accel-Buffering': 'no' });
  let i = from;
  const flush = () => {
    while (i < run.events.length) res.write('data: ' + JSON.stringify(run.events[i++]) + '\n\n');
    if (run.done) { run.subs.delete(flush); res.end(); }
  };
  run.subs.add(flush);
  res.on('close', () => run.subs.delete(flush));
  flush();
}

http.createServer(async (req, res) => {
  const u = req.url.split('?')[0];

  if (req.method === 'GET' && (u === '/' || u === '/index.html')) {
    res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
    return res.end(fs.readFileSync(path.join(DIR, 'public', 'index.html')));
  }
  if (req.method === 'GET' && u === '/manifest.json') {
    return json(res, 200, { name: 'Claude Code', short_name: 'Claude', start_url: '/', display: 'standalone', background_color: '#0f0f12', theme_color: '#0f0f12' });
  }
  if (u === '/api/status') {
    return json(res, 200, { omniroute: await omniUp(), busy: !!proc, prompt: proc && run ? run.prompt : '', home: os.homedir(), hasKey: !!readEnv().OMNIROUTE_KEY });
  }
  if (req.method === 'POST' && u === '/api/setup') {
    const b = await readBody(req);
    const f = path.join(DIR, '.env');
    let lines = [];
    try { lines = fs.readFileSync(f, 'utf8').split('\n'); } catch {}
    lines = lines.filter(l => l.trim() && !/^\s*OMNIROUTE_KEY\s*=/.test(l));
    if (typeof b.key === 'string' && b.key.trim()) lines.push('OMNIROUTE_KEY=' + b.key.trim().replace(/[\r\n]/g, ''));
    fs.writeFileSync(f, lines.join('\n') + '\n', { mode: 0o600 });
    return json(res, 200, { ok: true });
  }
  if (req.method === 'POST' && u === '/api/omniroute/start') {
    if (await omniUp()) return json(res, 200, { ok: true });
    try {
      const out = fs.openSync(path.join(DIR, 'omniroute.log'), 'a');
      const p = spawn('omniroute', [], { detached: true, stdio: ['ignore', out, out] });
      p.on('error', () => {});
      p.unref();
    } catch (e) { return json(res, 500, { error: e.message }); }
    return json(res, 200, { ok: true });
  }
  if (req.method === 'POST' && u === '/api/omniroute/stop') {
    spawn('pkill', ['-f', 'omniroute'], { stdio: 'ignore' }).on('error', () => {});
    return json(res, 200, { ok: true });
  }
  if (req.method === 'POST' && u === '/api/stop') {
    if (proc) proc.kill('SIGTERM');
    return json(res, 200, { ok: true });
  }
  if (req.method === 'GET' && u === '/api/omni/models') {
    const k = readEnv().OMNIROUTE_KEY;
    const q = http.get(OMNI + '/v1/models', { headers: k ? { Authorization: 'Bearer ' + k } : {}, timeout: 4000 }, r => {
      let d = ''; r.on('data', x => d += x);
      r.on('end', () => { try { json(res, 200, { models: (JSON.parse(d).data || []).map(m => m.id).sort() }); } catch { json(res, 200, { models: [] }); } });
    });
    q.on('error', () => json(res, 200, { models: [] }));
    q.on('timeout', () => { q.destroy(); });
    return;
  }
  if (req.method === 'GET' && u === '/api/attach') {
    if (!run) { res.writeHead(204); return res.end(); }
    return attach(res, parseInt(new URL(req.url, 'http://x').searchParams.get('from') || '0', 10));
  }
  if (req.method === 'POST' && u === '/api/chat') {
    const b = await readBody(req);
    if (proc) return json(res, 409, { error: 'Une réponse est déjà en cours.' });
    const e = readEnv(), env = { ...process.env };
    Object.keys(e).forEach(k => { if (k !== 'OMNIROUTE_KEY') env[k] = e[k]; });
    const m = b.model || '';
    if (b.useOmni) {
      Object.assign(env, { ANTHROPIC_BASE_URL: OMNI, ANTHROPIC_API_KEY: '', CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC: '1' });
      if (e.OMNIROUTE_KEY) env.ANTHROPIC_AUTH_TOKEN = e.OMNIROUTE_KEY;
      if (m) ['ANTHROPIC_MODEL', 'ANTHROPIC_SMALL_FAST_MODEL', 'ANTHROPIC_DEFAULT_OPUS_MODEL', 'ANTHROPIC_DEFAULT_SONNET_MODEL', 'ANTHROPIC_DEFAULT_HAIKU_MODEL'].forEach(k => env[k] = m);
    }
    let cwd = (b.cwd || '~').replace(/^~/, os.homedir());
    if (!fs.existsSync(cwd)) cwd = os.homedir();
    const args = ['-p', '--output-format', 'stream-json', '--verbose', '--include-partial-messages', '--permission-mode', b.mode || 'acceptEdits'];
    if (b.mode !== 'plan') args.push('--allowedTools', 'Bash,Read,Edit,MultiEdit,Write,Glob,Grep,LS,TodoWrite,WebFetch,WebSearch,NotebookEdit');
    if (!b.useOmni && m) args.push('--model', m);
    if (b.session) args.push('--resume', b.session);
    run = { events: [], done: false, subs: new Set(), prompt: b.prompt || '' };
    const emit = o => { run.events.push(o); run.subs.forEach(f => f()); };
    const finish = code => { if (run.done) return; run.done = true; proc = null; emit({ type: 'done', code }); };
    proc = spawn('claude', args, { cwd, env });
    proc.on('error', err => { emit({ type: 'error', text: err.code === 'ENOENT' ? 'Commande "claude" introuvable dans Termux.' : err.message }); finish(-1); });
    proc.stdin.on('error', () => {});
    proc.stdin.end(b.prompt || '');
    let buf = '';
    proc.stdout.on('data', d => {
      buf += d.toString(); let i;
      while ((i = buf.indexOf('\n')) >= 0) {
        const line = buf.slice(0, i).trim(); buf = buf.slice(i + 1);
        if (line) { try { emit(JSON.parse(line)); } catch {} }
      }
    });
    proc.stderr.on('data', d => emit({ type: 'stderr', text: d.toString() }));
    proc.on('close', finish);
    return attach(res, 0);
  }
  res.writeHead(404); res.end('404');
}).listen(PORT, '127.0.0.1', () => console.log('Claude UI sur http://localhost:' + PORT));
JS_EOF

cat > "$APP/public/index.html" <<'HTML_EOF'
<!doctype html>
<html lang="fr"><head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<meta name="theme-color" content="#262624">
<link rel="manifest" href="/manifest.json">
<title>Claude Code</title>
<style>
:root{--bg:#262624;--pn:#30302e;--ln:#3f3e3b;--tx:#faf9f5;--dm:#a09f98;--ac:#d97757;--ok:#7fc77f;--bad:#e5766c}
*{box-sizing:border-box;-webkit-tap-highlight-color:transparent}
html,body{height:100%;margin:0;background:var(--bg);color:var(--tx);font:16px/1.6 system-ui,Roboto,sans-serif}
body{display:flex;flex-direction:column}
header{display:flex;align-items:center;gap:6px;padding:10px 14px}
header h1{flex:1;margin:0;font:600 17px Georgia,serif}header h1 b{color:var(--ac);font-weight:400;margin-right:6px}
button{font:inherit;color:var(--tx);background:none;border:1px solid var(--ln);border-radius:10px;padding:6px 10px}
button:active{opacity:.6}
#pill i{display:inline-block;width:8px;height:8px;border-radius:50%;background:var(--bad);margin-right:6px}
#pill.on i{background:var(--ok)}
#chat{flex:1;overflow-y:auto;padding:6px 16px 18px;display:flex;flex-direction:column;gap:14px}
.user{align-self:stretch;background:var(--pn);border:1px solid var(--ln);border-radius:14px;padding:10px 14px;white-space:pre-wrap;overflow-wrap:anywhere}
.bot{overflow-wrap:anywhere}
.note{font-size:12.5px;color:var(--dm)}.note.err{color:var(--bad)}
code{background:#0004;padding:1px 5px;border-radius:5px;font:13.5px ui-monospace,monospace}
pre{background:#1d1d1b;border:1px solid var(--ln);border-radius:10px;padding:10px;overflow-x:auto;margin:8px 0;font:12.5px/1.5 ui-monospace,monospace}
pre code{background:none;padding:0}
details.tool{font-size:14px;border-left:2px solid var(--ln);padding-left:10px}
details.tool summary{color:var(--dm);cursor:pointer;list-style:none;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
details.tool summary::-webkit-details-marker{display:none}
details.tool summary i{display:inline-block;width:8px;height:8px;border-radius:50%;background:var(--ac);margin-right:8px}
details.tool.done summary i{background:var(--ok)}details.tool.fail summary i{background:var(--bad)}
details.tool summary b{color:var(--tx);margin-right:6px}
details.tool pre{max-height:240px;margin:6px 0}
.add{color:var(--ok)}.del{color:var(--bad)}
.todo{font-size:14px;line-height:1.7}
#think{color:var(--ac);font-size:14px}#think i{display:inline-block;animation:sp 2s linear infinite;font-style:normal}
@keyframes sp{to{transform:rotate(360deg)}}
#comp{margin:0 12px calc(10px + env(safe-area-inset-bottom));background:var(--pn);border:1px solid var(--ln);border-radius:20px;padding:10px 12px 8px}
textarea{width:100%;resize:none;max-height:150px;background:none;color:var(--tx);border:0;outline:0;font:inherit;padding:2px}
#bar{display:flex;gap:8px;align-items:center;margin-top:4px}
.chip{font-size:12.5px;color:var(--dm);padding:4px 9px;border-radius:999px;max-width:48%;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
#go{margin-left:auto;background:var(--ac);border:0;border-radius:50%;width:38px;height:38px;padding:0;color:#fff;font-size:18px}
#go.stop{background:var(--bad)}
#sheet{position:fixed;inset:0;background:#000a;display:none;align-items:flex-end;z-index:5}
#sheet.show{display:flex}
#sheet .in{background:var(--bg);width:100%;max-height:92%;overflow:auto;border-radius:18px 18px 0 0;padding:16px 16px calc(16px + env(safe-area-inset-bottom));border-top:1px solid var(--ln)}
label{display:block;font-size:13px;color:var(--dm);margin:12px 0 4px}
input[type=text],input[type=password]{width:100%;background:var(--pn);color:var(--tx);border:1px solid var(--ln);border-radius:10px;padding:10px;font:inherit}
.row{display:flex;align-items:center;gap:10px;margin-top:14px}
</style></head><body>
<header><h1><b>✻</b>Claude Code</h1><button id="pill"><i></i>OmniRoute</button><button id="new">＋</button><button id="cog">⚙︎</button></header>
<div id="chat"></div>
<div id="comp">
  <textarea id="in" rows="1" placeholder="Demande quelque chose à Claude…"></textarea>
  <div id="bar"><button class="chip" id="modeBtn"></button><button class="chip" id="modelBtn"></button><button id="go">↑</button></div>
</div>
<div id="sheet"><div class="in">
  <h3 id="sheetTitle" style="margin:0">Réglages</h3>
  <label>Dossier de travail</label><input type="text" id="cwd" placeholder="~/mon-projet">
  <label>Clé API OmniRoute</label><input type="password" id="key" placeholder="Colle ta clé (vide = inchangée)" autocomplete="off">
  <div class="row"><button id="getkey" style="flex:1">Ouvrir le dashboard OmniRoute</button></div>
  <label>Combo / modèle OmniRoute</label><input type="text" id="model" list="models" placeholder="ex : Claudeui" autocapitalize="off">
  <datalist id="models"></datalist>
  <div class="row"><button id="refresh" style="flex:1">Charger mes combos</button></div>
  <div class="row"><input type="checkbox" id="omni"><span>Passer par OmniRoute (modèles gratuits)</span></div>
  <div class="row"><button id="save" style="flex:1;background:var(--ac);border:0">Enregistrer</button></div>
</div></div>
<script>
const $=s=>document.querySelector(s);
const MODES={acceptEdits:'⏵⏵ Accepter les modifs',plan:'◫ Mode plan',bypassPermissions:'⚠ Tout autoriser'};
const cfg=Object.assign({cwd:'~',model:'',mode:'acceptEdits',omni:false},JSON.parse(localStorage.getItem('cfg')||'{}'));
let session=localStorage.getItem('sid')||'',busy=false,cur=null,gotDelta=false,tools={},seen=0,finished=false,omniOn=false,hasKey=false,firstRun=false;
const chat=$('#chat'),inp=$('#in'),go=$('#go');
const save=()=>localStorage.setItem('cfg',JSON.stringify(cfg));
const esc=s=>String(s).replace(/[&<>]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;'}[c]));
function md(t){return t.split('```').map((p,i)=>{
  if(i%2){const n=p.indexOf('\n');return '<pre><code>'+esc(p.slice(n+1).replace(/\n$/,''))+'</code></pre>'}
  return esc(p).replace(/`([^`\n]+)`/g,'<code>$1</code>').replace(/\*\*([^*\n]+)\*\*/g,'<b>$1</b>').replace(/^#{1,3} (.+)$/gm,'<b>$1</b>').replace(/\n/g,'<br>')}).join('')}
const scroll=()=>{chat.scrollTop=chat.scrollHeight};
function add(kind,text){const d=document.createElement('div');d.className=kind;d.raw=text||'';
  if(kind==='user')d.textContent=text;else d.innerHTML=md(d.raw);
  d.append=t=>{d.raw+=t;d.innerHTML=md(d.raw);scroll()};chat.appendChild(d);scroll();return d}
function note(t,err){const d=document.createElement('div');d.className='note'+(err?' err':'');d.textContent=t;chat.appendChild(d);scroll()}
function think(on){let t=$('#think');if(on&&!t){t=document.createElement('div');t.id='think';t.innerHTML='<i>✻</i> Réflexion…';chat.appendChild(t);scroll()}if(!on&&t)t.remove()}
function diff(o,n){return (o?o.split('\n').map(l=>'<span class="del">- '+esc(l)+'</span>').join('\n')+'\n':'')+n.split('\n').map(l=>'<span class="add">+ '+esc(l)+'</span>').join('\n')}
function toolCard(b){
  const i=b.input||{},brief=i.command||i.file_path||i.pattern||i.path||i.url||i.description||'';
  if(b.name==='TodoWrite'&&Array.isArray(i.todos)){
    const d=document.createElement('div');d.className='todo';
    d.innerHTML=i.todos.map(t=>(t.status==='completed'?'☑ ':t.status==='in_progress'?'◐ ':'☐ ')+esc(t.content)).join('<br>');
    chat.appendChild(d);scroll();return}
  const d=document.createElement('details');d.className='tool';
  d.innerHTML='<summary><i></i><b>'+esc(b.name)+'</b>'+esc(String(brief).slice(0,100))+'</summary><pre></pre>';
  const p=d.querySelector('pre');
  if(b.name==='Edit'&&i.new_string!=null)p.innerHTML=diff(i.old_string||'',i.new_string);
  else if(b.name==='Write'&&i.content!=null)p.innerHTML=diff('',i.content.slice(0,3000));
  else p.textContent=i.command?'$ '+i.command:JSON.stringify(i,null,2);
  chat.appendChild(d);tools[b.id]=d;scroll()}
function setBusy(b){busy=b;go.textContent=b?'■':'↑';go.classList.toggle('stop',b);if(!b)think(false)}
function handle(ev){
  if(ev.type==='system'&&ev.session_id){session=ev.session_id;localStorage.setItem('sid',session)}
  else if(ev.type==='stream_event'){const e=ev.event||{};
    if(e.type==='message_start'){cur=null;gotDelta=false}
    else if(e.type==='content_block_delta'&&e.delta&&e.delta.type==='text_delta'){think(false);if(!cur)cur=add('bot','');cur.append(e.delta.text);gotDelta=true}}
  else if(ev.type==='assistant'){think(false);
    for(const b of(ev.message&&ev.message.content)||[]){
      if(b.type==='text'&&!gotDelta&&b.text.trim())add('bot',b.text);
      if(b.type==='tool_use')toolCard(b)}
    cur=null;gotDelta=false;if(busy)think(true)}
  else if(ev.type==='user'){
    for(const b of(ev.message&&ev.message.content)||[]){
      if(b.type==='tool_result'&&tools[b.tool_use_id]){
        let c=b.content;if(Array.isArray(c))c=c.map(x=>x.text||'').join('\n');
        const d=tools[b.tool_use_id];d.classList.add(b.is_error?'fail':'done');
        const p=d.querySelector('pre');if(!/<span/.test(p.innerHTML))p.textContent+='\n\n'+String(c||'').slice(0,4000)}}}
  else if(ev.type==='result'){
    if(ev.session_id){session=ev.session_id;localStorage.setItem('sid',session)}
    if(ev.is_error){note('Erreur : '+(ev.result||'inconnue'),true);if(/session|conversation/i.test(ev.result||'')){session='';localStorage.removeItem('sid')}}
    const s=[];if(ev.duration_ms)s.push((ev.duration_ms/1000).toFixed(1)+'s');
    if(ev.total_cost_usd&&!cfg.omni)s.push('$'+ev.total_cost_usd.toFixed(4));if(s.length)note(s.join(' · '))}
  else if(ev.type==='stderr'&&ev.text.trim())note(ev.text.trim().slice(0,300),true);
  else if(ev.type==='error')note(ev.text,true);
  else if(ev.type==='done')finished=true}
async function consume(r){const rd=r.body.getReader(),dec=new TextDecoder();let buf='';
  for(;;){const{done,value}=await rd.read();if(done)return;buf+=dec.decode(value,{stream:true});let i;
    while((i=buf.indexOf('\n\n'))>=0){const c=buf.slice(0,i);buf=buf.slice(i+2);
      if(c.startsWith('data: ')){seen++;try{handle(JSON.parse(c.slice(6)))}catch(e){}}}}}
async function follow(r){
  setBusy(true);think(true);seen=0;finished=false;
  while(!finished){
    try{if(!r){r=await fetch('/api/attach?from='+seen);if(r.status===204)break}await consume(r)}catch(e){}
    r=null;if(!finished)await new Promise(x=>setTimeout(x,1000))}
  setBusy(false)}
async function sendMsg(){
  if(busy){fetch('/api/stop',{method:'POST'});return}
  const prompt=inp.value.trim();if(!prompt)return;
  inp.value='';fit();add('user',prompt);cur=null;gotDelta=false;
  try{const r=await fetch('/api/chat',{method:'POST',headers:{'Content-Type':'application/json'},
    body:JSON.stringify({prompt,session,cwd:cfg.cwd,model:cfg.model,mode:cfg.mode,useOmni:cfg.omni})});
    if(!r.ok){const j=await r.json().catch(()=>({}));throw new Error(j.error||r.status)}
    await follow(r)}catch(e){note('Erreur : '+e.message,true);setBusy(false)}}
function fit(){inp.style.height='auto';inp.style.height=Math.min(inp.scrollHeight,150)+'px'}
function chips(){$('#modeBtn').textContent=MODES[cfg.mode];$('#modelBtn').textContent=(cfg.omni?'⇄ ':'')+(cfg.model||'modèle par défaut')}
inp.addEventListener('input',fit);go.onclick=sendMsg;
$('#modeBtn').onclick=()=>{const k=Object.keys(MODES);cfg.mode=k[(k.indexOf(cfg.mode)+1)%k.length];save();chips()};
$('#modelBtn').onclick=()=>openSheet(false);
$('#new').onclick=()=>{if(busy)return;session='';localStorage.removeItem('sid');chat.innerHTML='';tools={};note('Nouvelle conversation')};
function openSheet(first){firstRun=!!first;$('#sheetTitle').textContent=first?'Configuration initiale':'Réglages';
  $('#cwd').value=cfg.cwd;$('#model').value=cfg.model;$('#omni').checked=first?true:cfg.omni;$('#key').value='';$('#sheet').classList.add('show')}
$('#cog').onclick=()=>openSheet(false);
$('#sheet').onclick=e=>{if(e.target.id==='sheet'&&!firstRun)$('#sheet').classList.remove('show')};
$('#refresh').onclick=async()=>{
  const key=$('#key').value.trim();if(key)await fetch('/api/setup',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({key})});
  const m=(await(await fetch('/api/omni/models')).json()).models||[];
  $('#models').innerHTML=m.map(x=>'<option value="'+esc(x)+'">').join('');
  const g=m.find(x=>/claudeui/i.test(x));if(g&&!$('#model').value)$('#model').value=g;
  note(m.length?m.length+' modèles/combos chargés — tape dans le champ pour choisir':'Aucun modèle : vérifie la clé et qu’OmniRoute tourne',!m.length)};
$('#save').onclick=async()=>{const key=$('#key').value.trim();
  if(key)try{await fetch('/api/setup',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({key})});hasKey=true}catch{}
  Object.assign(cfg,{cwd:$('#cwd').value.trim()||'~',model:$('#model').value.trim(),omni:$('#omni').checked&&(hasKey||!firstRun)});
  save();localStorage.setItem('setupDone','1');firstRun=false;$('#sheet').classList.remove('show');chips()};
async function openDash(){
  $('#sheet').classList.remove('show');
  if(!omniOn){note('Démarrage d’OmniRoute…');await fetch('/api/omniroute/start',{method:'POST'});
    for(let i=0;i<30&&!omniOn;i++){await new Promise(r=>setTimeout(r,2000));await poll()}}
  if(!omniOn)return note('OmniRoute ne répond pas (voir ~/claude-ui/omniroute.log).',true);
  if(window.Android&&Android.showDashboard)Android.showDashboard();else location.href='http://localhost:20128'}
$('#getkey').onclick=openDash;$('#pill').onclick=openDash;
async function poll(){try{const s=await(await fetch('/api/status')).json();omniOn=s.omniroute;hasKey=s.hasKey;$('#pill').classList.toggle('on',omniOn)}catch{}}
(async()=>{await poll();
  if(!localStorage.getItem('setupDone'))openSheet(true);
  note('Dossier : '+cfg.cwd+(session?' · conversation reprise':''));chips();
  try{const s=await(await fetch('/api/status')).json();if(s.busy){add('user',s.prompt||'…');follow(null)}}catch{}
  setInterval(poll,5000)})();
</script></body></html>
HTML_EOF

[ -f "$APP/.env" ] || cat > "$APP/.env" <<'ENV_EOF'
# Clé API OmniRoute (dashboard OmniRoute > API Keys), utilisée si "Passer par OmniRoute" est coché
OMNIROUTE_KEY=
# Ou ta clé Anthropic directe, si tu n'utilises pas OmniRoute :
# ANTHROPIC_API_KEY=
ENV_EOF

cat > "$APP/start.sh" <<'START_EOF'
#!/data/data/com.termux/files/usr/bin/bash
termux-wake-lock 2>/dev/null
cd "$HOME/claude-ui"
pgrep -f "node server.js" >/dev/null || nohup node server.js > server.log 2>&1 &
sleep 1.5
termux-open-url http://localhost:8787
START_EOF

cat > "$HOME/.shortcuts/Claude UI" <<'W1_EOF'
#!/data/data/com.termux/files/usr/bin/bash
bash "$HOME/claude-ui/start.sh"
W1_EOF

cat > "$HOME/.shortcuts/OmniRoute" <<'W2_EOF'
#!/data/data/com.termux/files/usr/bin/bash
termux-wake-lock 2>/dev/null
pgrep -f omniroute >/dev/null || nohup omniroute > "$HOME/claude-ui/omniroute.log" 2>&1 &
sleep 2
termux-open-url http://localhost:20128
W2_EOF

chmod +x "$APP/start.sh" "$HOME/.shortcuts/"*
echo
echo "✅ Installé. Retourne dans l'app Claude UI."
sleep 4
echo "   Widgets Termux:Widget : \"Claude UI\" et \"OmniRoute\""
