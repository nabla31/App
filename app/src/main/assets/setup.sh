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

let proc = null;

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
    return json(res, 200, { omniroute: await omniUp(), busy: !!proc, home: os.homedir(), hasKey: !!readEnv().OMNIROUTE_KEY });
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
  if (req.method === 'POST' && u === '/api/chat') {
    const b = await readBody(req);
    if (proc) return json(res, 409, { error: 'Une réponse est déjà en cours.' });
    res.writeHead(200, { 'Content-Type': 'text/event-stream', 'Cache-Control': 'no-cache', 'X-Accel-Buffering': 'no' });
    let open = true;
    res.on('close', () => { open = false; });
    const send = o => { if (open) res.write('data: ' + JSON.stringify(o) + '\n\n'); };

    const e = readEnv();
    const childEnv = { ...process.env };
    Object.keys(e).forEach(k => { if (k !== 'OMNIROUTE_KEY') childEnv[k] = e[k]; });
    if (b.useOmni) {
      childEnv.ANTHROPIC_BASE_URL = OMNI;
      if (e.OMNIROUTE_KEY) childEnv.ANTHROPIC_AUTH_TOKEN = e.OMNIROUTE_KEY;
    }
    let cwd = (b.cwd || '~').replace(/^~/, os.homedir());
    if (!fs.existsSync(cwd)) cwd = os.homedir();

    const args = ['-p', '--output-format', 'stream-json', '--verbose', '--include-partial-messages',
      '--permission-mode', b.mode || 'acceptEdits'];
    if (b.model) args.push('--model', b.model);
    if (b.session) args.push('--resume', b.session);

    proc = spawn('claude', args, { cwd, env: childEnv });
    proc.on('error', err => {
      send({ type: 'error', text: err.code === 'ENOENT' ? 'Commande "claude" introuvable dans Termux.' : err.message });
      proc = null; send({ type: 'done', code: -1 }); res.end();
    });
    proc.stdin.on('error', () => {});
    proc.stdin.end(b.prompt || '');

    let buf = '';
    proc.stdout.on('data', d => {
      buf += d.toString();
      let i;
      while ((i = buf.indexOf('\n')) >= 0) {
        const line = buf.slice(0, i).trim(); buf = buf.slice(i + 1);
        if (!line) continue;
        try { send(JSON.parse(line)); } catch {}
      }
    });
    proc.stderr.on('data', d => send({ type: 'stderr', text: d.toString() }));
    proc.on('close', code => { proc = null; send({ type: 'done', code }); res.end(); });
    return;
  }
  res.writeHead(404); res.end('404');
}).listen(PORT, '127.0.0.1', () => console.log('Claude UI sur http://localhost:' + PORT));
JS_EOF

cat > "$APP/public/index.html" <<'HTML_EOF'
<!doctype html>
<html lang="fr"><head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<meta name="theme-color" content="#0f0f12">
<link rel="manifest" href="/manifest.json">
<title>Claude Code</title>
<style>
:root{--bg:#0f0f12;--card:#1a1a20;--line:#2a2a33;--txt:#ececf1;--dim:#8b8b99;--acc:#d97757;--ok:#4ade80;--bad:#f87171}
*{box-sizing:border-box;-webkit-tap-highlight-color:transparent}
html,body{height:100%;margin:0;background:var(--bg);color:var(--txt);font:16px/1.5 system-ui,-apple-system,Roboto,sans-serif}
body{display:flex;flex-direction:column;padding-top:env(safe-area-inset-top)}
header{display:flex;align-items:center;gap:8px;padding:10px 12px;border-bottom:1px solid var(--line)}
header h1{font-size:17px;margin:0;flex:1;font-weight:600}
header h1 span{color:var(--acc)}
button{font:inherit;color:var(--txt);background:var(--card);border:1px solid var(--line);border-radius:10px;padding:7px 11px}
button:active{opacity:.7}
#pill{font-size:13px;display:flex;gap:6px;align-items:center}
#pill i{width:9px;height:9px;border-radius:50%;background:var(--bad);display:inline-block}
#pill.on i{background:var(--ok)}
#chat{flex:1;overflow-y:auto;padding:14px 12px;display:flex;flex-direction:column;gap:12px}
.msg{max-width:92%;padding:10px 13px;border-radius:16px;word-wrap:break-word;overflow-wrap:anywhere}
.user{align-self:flex-end;background:var(--acc);color:#fff;border-bottom-right-radius:4px;white-space:pre-wrap}
.bot{align-self:flex-start;background:var(--card);border:1px solid var(--line);border-bottom-left-radius:4px}
.note{align-self:center;font-size:12.5px;color:var(--dim);text-align:center}
.note.err{color:var(--bad)}
code{background:#0006;padding:1px 5px;border-radius:5px;font:13.5px ui-monospace,monospace}
pre{background:#08080b;border:1px solid var(--line);border-radius:10px;padding:10px;overflow-x:auto;margin:8px 0;font:12.5px/1.45 ui-monospace,monospace}
pre code{background:none;padding:0}
details.tool{align-self:stretch;background:var(--card);border:1px solid var(--line);border-radius:12px;font-size:13.5px}
details.tool summary{padding:8px 12px;color:var(--dim);cursor:pointer;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
details.tool pre{margin:0 8px 8px;max-height:220px}
.dots span{display:inline-block;width:6px;height:6px;margin:0 2px;background:var(--dim);border-radius:50%;animation:b 1s infinite}
.dots span:nth-child(2){animation-delay:.15s}.dots span:nth-child(3){animation-delay:.3s}
@keyframes b{0%,60%,100%{opacity:.3}30%{opacity:1}}
footer{padding:8px 10px calc(8px + env(safe-area-inset-bottom));border-top:1px solid var(--line);display:flex;gap:8px;align-items:flex-end}
textarea{flex:1;resize:none;max-height:140px;background:var(--card);color:var(--txt);border:1px solid var(--line);border-radius:14px;padding:10px 13px;font:inherit;outline:none}
#go{background:var(--acc);border:0;border-radius:50%;width:44px;height:44px;font-size:20px;padding:0;color:#fff}
#go.stop{background:var(--bad)}
#sheet{position:fixed;inset:0;background:#000a;display:none;align-items:flex-end;z-index:5}
#sheet.show{display:flex}
#sheet div.in{background:var(--bg);width:100%;border-radius:18px 18px 0 0;padding:16px 16px calc(16px + env(safe-area-inset-bottom));border-top:1px solid var(--line)}
label{display:block;font-size:13px;color:var(--dim);margin:12px 0 4px}
input[type=text],select{width:100%;background:var(--card);color:var(--txt);border:1px solid var(--line);border-radius:10px;padding:10px;font:inherit}
.row{display:flex;align-items:center;gap:10px;margin-top:14px}
</style></head><body>
<header>
  <h1><span>●</span> Claude Code</h1>
  <button id="pill" title="Démarrer / arrêter OmniRoute"><i></i><span>OmniRoute</span></button>
  <button id="new" title="Nouvelle conversation">＋</button>
  <button id="cog" title="Réglages">⚙︎</button>
</header>
<div id="chat"></div>
<footer>
  <textarea id="in" rows="1" placeholder="Demande quelque chose à Claude…"></textarea>
  <button id="go">➤</button>
</footer>
<div id="sheet"><div class="in">
  <h3 id="sheetTitle" style="margin:0">Réglages</h3>
  <label>Dossier de travail</label><input type="text" id="cwd" placeholder="~/mon-projet">
  <label>Modèle</label>
  <select id="model"><option value="">Par défaut</option><option value="sonnet">Sonnet</option><option value="opus">Opus</option><option value="haiku">Haiku</option></select>
  <label>Permissions</label>
  <select id="mode">
    <option value="acceptEdits">Éditer sans demander</option>
    <option value="plan">Plan (lecture seule)</option>
    <option value="bypassPermissions">Tout autoriser (attention)</option>
  </select>
  <label>Clé API OmniRoute</label><input type="text" id="key" placeholder="Colle ta clé (vide = inchangée)" autocomplete="off" autocapitalize="off">
  <div class="row"><button id="getkey" style="flex:1">Ouvrir OmniRoute pour créer une clé</button></div>
  <div class="row"><input type="checkbox" id="omni"><span>Passer par OmniRoute</span></div>
  <div class="row"><button id="save" style="flex:1;background:var(--acc);border:0;color:#fff">Enregistrer</button></div>
</div></div>
<script>
const $=s=>document.querySelector(s);
const cfg=Object.assign({cwd:'~',model:'',mode:'acceptEdits',omni:false},JSON.parse(localStorage.getItem('cfg')||'{}'));
let session=localStorage.getItem('sid')||'',busy=false,cur=null,gotDelta=false,tools={};
const chat=$('#chat'),inp=$('#in'),go=$('#go');
const esc=s=>s.replace(/[&<>]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;'}[c]));
function md(t){return t.split('```').map((p,i)=>{
  if(i%2){const n=p.indexOf('\n');return '<pre><code>'+esc(p.slice(n+1).replace(/\n$/,''))+'</code></pre>'}
  return esc(p).replace(/`([^`\n]+)`/g,'<code>$1</code>').replace(/\*\*([^*\n]+)\*\*/g,'<b>$1</b>').replace(/^#{1,3} (.+)$/gm,'<b>$1</b>').replace(/\n/g,'<br>')
}).join('')}
const scroll=()=>{chat.scrollTop=chat.scrollHeight};
function add(kind,text){
  const d=document.createElement('div');d.className='msg '+kind;d.raw=text||'';
  if(kind==='user')d.textContent=text;else d.innerHTML=md(d.raw);
  d.append=t=>{d.raw+=t;d.innerHTML=md(d.raw);scroll()};
  chat.appendChild(d);scroll();return d;
}
function note(t,err){const d=document.createElement('div');d.className='note'+(err?' err':'');d.textContent=t;chat.appendChild(d);scroll()}
function toolCard(b){
  const i=b.input||{};const brief=i.command||i.file_path||i.pattern||i.path||i.url||i.description||JSON.stringify(i);
  const d=document.createElement('details');d.className='tool';
  d.innerHTML='<summary>🔧 '+esc(b.name)+' · '+esc(String(brief).slice(0,120))+'</summary><pre></pre>';
  d.querySelector('pre').textContent=typeof i.command==='string'?i.command:JSON.stringify(i,null,2);
  chat.appendChild(d);tools[b.id]=d;scroll();
}
function typing(on){
  let t=$('#typing');
  if(on&&!t){t=document.createElement('div');t.id='typing';t.className='msg bot dots';t.innerHTML='<span></span><span></span><span></span>';chat.appendChild(t);scroll()}
  if(!on&&t)t.remove();
}
function setBusy(b){busy=b;go.textContent=b?'■':'➤';go.classList.toggle('stop',b);if(!b)typing(false)}
function handle(ev){
  if(ev.type==='system'&&ev.session_id){session=ev.session_id;localStorage.setItem('sid',session)}
  else if(ev.type==='stream_event'){
    const e=ev.event||{};
    if(e.type==='message_start'){cur=null;gotDelta=false}
    else if(e.type==='content_block_delta'&&e.delta&&e.delta.type==='text_delta'){
      typing(false);if(!cur)cur=add('bot','');cur.append(e.delta.text);gotDelta=true}
  }
  else if(ev.type==='assistant'){
    typing(false);
    for(const b of (ev.message&&ev.message.content)||[]){
      if(b.type==='text'&&!gotDelta&&b.text.trim())add('bot',b.text);
      if(b.type==='tool_use')toolCard(b);
    }
    cur=null;gotDelta=false;
  }
  else if(ev.type==='user'){
    for(const b of (ev.message&&ev.message.content)||[]){
      if(b.type==='tool_result'&&tools[b.tool_use_id]){
        let c=b.content;if(Array.isArray(c))c=c.map(x=>x.text||'').join('\n');
        const p=tools[b.tool_use_id].querySelector('pre');
        p.textContent+='\n\n→ '+String(c||'').slice(0,4000);
      }
    }
  }
  else if(ev.type==='result'){
    if(ev.session_id){session=ev.session_id;localStorage.setItem('sid',session)}
    if(ev.is_error)note('Erreur : '+(ev.result||'inconnue'),true);
    const s=[];if(ev.duration_ms)s.push((ev.duration_ms/1000).toFixed(1)+'s');
    if(ev.total_cost_usd)s.push('$'+ev.total_cost_usd.toFixed(4));
    if(s.length)note(s.join(' · '));
  }
  else if(ev.type==='stderr'&&ev.text.trim())note(ev.text.trim().slice(0,300),true);
  else if(ev.type==='error')note(ev.text,true);
}
async function sendMsg(){
  if(busy){fetch('/api/stop',{method:'POST'});return}
  const prompt=inp.value.trim();if(!prompt)return;
  inp.value='';fit();add('user',prompt);setBusy(true);typing(true);cur=null;gotDelta=false;
  try{
    const r=await fetch('/api/chat',{method:'POST',headers:{'Content-Type':'application/json'},
      body:JSON.stringify({prompt,session,cwd:cfg.cwd,model:cfg.model,mode:cfg.mode,useOmni:cfg.omni})});
    if(!r.ok){const j=await r.json().catch(()=>({}));throw new Error(j.error||r.status)}
    const rd=r.body.getReader(),dec=new TextDecoder();let buf='';
    for(;;){
      const {done,value}=await rd.read();if(done)break;
      buf+=dec.decode(value,{stream:true});let i;
      while((i=buf.indexOf('\n\n'))>=0){
        const c=buf.slice(0,i);buf=buf.slice(i+2);
        if(c.startsWith('data: ')){try{handle(JSON.parse(c.slice(6)))}catch(e){}}
      }
    }
  }catch(e){note('Connexion perdue : '+e.message,true)}
  setBusy(false);
}
function fit(){inp.style.height='auto';inp.style.height=Math.min(inp.scrollHeight,140)+'px'}
inp.addEventListener('input',fit);
inp.addEventListener('keydown',e=>{if(e.key==='Enter'&&(e.ctrlKey||e.metaKey)){e.preventDefault();sendMsg()}});
go.onclick=sendMsg;
$('#new').onclick=()=>{if(busy)return;session='';localStorage.removeItem('sid');chat.innerHTML='';tools={};note('Nouvelle conversation')};
let firstRun=false;
function openSheet(first){
  firstRun=!!first;$('#sheetTitle').textContent=first?'Configuration initiale':'Réglages';
  $('#cwd').value=cfg.cwd;$('#model').value=cfg.model;$('#mode').value=cfg.mode;$('#omni').checked=first?true:cfg.omni;$('#key').value='';
  $('#sheet').classList.add('show');
}
$('#cog').onclick=()=>openSheet(false);
$('#sheet').onclick=e=>{if(e.target.id==='sheet'&&!firstRun)$('#sheet').classList.remove('show')};
$('#save').onclick=async()=>{
  const key=$('#key').value.trim();
  if(key){try{await fetch('/api/setup',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({key})})}catch{}}
  Object.assign(cfg,{cwd:$('#cwd').value.trim()||'~',model:$('#model').value,mode:$('#mode').value,omni:$('#omni').checked&&(!!key||!firstRun||hasKey)});
  localStorage.setItem('cfg',JSON.stringify(cfg));localStorage.setItem('setupDone','1');
  firstRun=false;$('#sheet').classList.remove('show');
};
$('#getkey').onclick=async()=>{
  note('Démarrage d’OmniRoute… patiente quelques secondes');$('#sheet').classList.remove('show');
  await fetch('/api/omniroute/start',{method:'POST'});
  for(let i=0;i<30;i++){await poll();if(omniOn)break;await new Promise(r=>setTimeout(r,2000))}
  if(omniOn)location.href='http://localhost:20128';else note('OmniRoute ne répond pas (voir omniroute.log).',true);
};
let omniOn=false,hasKey=false;
async function poll(){
  try{const s=await (await fetch('/api/status')).json();omniOn=s.omniroute;hasKey=s.hasKey;$('#pill').classList.toggle('on',omniOn)}catch{}
}
$('#pill').onclick=async()=>{
  note(omniOn?'Arrêt d’OmniRoute…':'Démarrage d’OmniRoute… (patiente quelques secondes)');
  await fetch('/api/omniroute/'+(omniOn?'stop':'start'),{method:'POST'});
  for(let i=0;i<12;i++){await new Promise(r=>setTimeout(r,2000));await poll()}
};
poll();setInterval(poll,5000);
if(!localStorage.getItem('setupDone'))openSheet(true);
note('Prêt. Dossier : '+cfg.cwd+(session?' · conversation reprise':''));
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
