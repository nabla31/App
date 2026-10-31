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
const https = require('https'), http = require('http'), fs = require('fs'), path = require('path'), os = require('os');
const { spawn, spawnSync } = require('child_process');
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
const portUp = url => new Promise(r => {
  const q = http.get(url, { timeout: 1500 }, s => { s.resume(); r(true); });
  q.on('error', () => r(false));
  q.on('timeout', () => { q.destroy(); r(false); });
});
const omniUp = () => portUp(OMNI);

process.on('uncaughtException', e => console.error('uncaught', e));
const HIST = path.join(DIR, 'history'); fs.mkdirSync(HIST, { recursive: true });
const CFG = path.join(DIR, 'config.json');
const SK = path.join(os.homedir(), '.claude', 'skills'), SKOFF = path.join(os.homedir(), '.claude', 'skills-off');
const slug = n => String(n || '').toLowerCase().trim().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '').slice(0, 40);
function readSkill(dir, n) {
  try {
    const t = fs.readFileSync(path.join(dir, n, 'SKILL.md'), 'utf8'), m = t.match(/^---\n([\s\S]*?)\n---\n?([\s\S]*)$/);
    return { name: n, description: ((m ? m[1] : '').match(/^description:\s*(.*)$/m) || [])[1] || '', body: (m ? m[2] : t).trim() };
  } catch { return null; }
}
function fetchText(url, n = 3) {
  return new Promise((ok, ko) => {
    https.get(url, { timeout: 10000, headers: { 'User-Agent': 'claude-ui' } }, r => {
      if (r.statusCode >= 300 && r.statusCode < 400 && r.headers.location && n > 0) { r.resume(); return ok(fetchText(new URL(r.headers.location, url).href, n - 1)); }
      if (r.statusCode !== 200) { r.resume(); return ko(new Error('HTTP ' + r.statusCode)); }
      let d = ''; r.on('data', x => { d += x; if (d.length > 200000) r.destroy(); }); r.on('end', () => ok(d));
    }).on('error', ko);
  });
}
let proc = null, run = null;
const busy = () => !!(run && !run.done);
let omniInstalling = false;
const omniInstalled = () => spawnSync('sh', ['-c', 'command -v omniroute']).status === 0;
function startOmni() {
  try {
    const out = fs.openSync(path.join(DIR, 'omniroute.log'), 'a');
    const p = spawn('omniroute', [], { detached: true, stdio: ['ignore', out, out] });
    p.on('error', () => {}); p.unref();
  } catch {}
}
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
  if (!/^(localhost|127\.0\.0\.1):8787$/.test(req.headers.host || '') || (req.method !== 'GET' && req.headers['x-cui'] !== '1')) {
    res.writeHead(403); return res.end('forbidden');
  }

  if (req.method === 'GET' && (u === '/' || u === '/index.html')) {
    res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
    return res.end(fs.readFileSync(path.join(DIR, 'public', 'index.html')));
  }
  if (req.method === 'GET' && u === '/manifest.json') {
    return json(res, 200, { name: 'Claude Code', short_name: 'Claude', start_url: '/', display: 'standalone', background_color: '#0f0f12', theme_color: '#0f0f12' });
  }
  if (u === '/api/status') {
    return json(res, 200, { omniroute: await omniUp(), busy: busy(), runId: run ? run.id : '', prompt: busy() ? run.prompt : '', home: os.homedir(), hasKey: !!readEnv().OMNIROUTE_KEY, omniInstalled: omniInstalled(), omniInstalling });
  }
  if (req.method === 'POST' && u === '/api/setup') {
    const b = await readBody(req);
    const f = path.join(DIR, '.env');
    let lines = [];
    try { lines = fs.readFileSync(f, 'utf8').split('\n'); } catch {}
    const kv = 'OMNIROUTE_KEY';
    lines = lines.filter(l => l.trim() && !new RegExp('^\\s*' + kv + '\\s*=').test(l));
    if (typeof b.key === 'string' && b.key.trim()) lines.push(kv + '=' + b.key.trim().replace(/[\r\n]/g, ''));
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
    else if (busy()) { run.done = true; run.events.push({ type: 'done', code: -2 }); run.subs.forEach(f => f()); }
    return json(res, 200, { ok: true });
  }
  if (u === '/api/config') {
    if (req.method === 'POST') {
      const b = await readBody(req); let c = {};
      try { c = JSON.parse(fs.readFileSync(CFG, 'utf8')); } catch {}
      fs.writeFileSync(CFG, JSON.stringify({ ...c, ...b })); return json(res, 200, { ok: true });
    }
    try { return json(res, 200, JSON.parse(fs.readFileSync(CFG, 'utf8'))); } catch { return json(res, 200, {}); }
  }
  if (u === '/api/conv' && req.method === 'GET') {
    const list = fs.readdirSync(HIST).filter(f => f.endsWith('.json')).map(f => {
      try { const c = JSON.parse(fs.readFileSync(path.join(HIST, f), 'utf8')); return { id: c.id, title: c.title, ts: c.ts }; } catch { return null; }
    }).filter(Boolean).sort((a, b) => b.ts - a.ts);
    return json(res, 200, { list });
  }
  if (u === '/api/conv' && req.method === 'POST') {
    const b = await readBody(req);
    if (!/^[a-z0-9]{3,20}$/.test(b.id || '')) return json(res, 400, { error: 'id' });
    fs.writeFileSync(path.join(HIST, b.id + '.json'), JSON.stringify({ id: b.id, title: b.title, ts: Date.now(), session: b.session, html: b.html }));
    return json(res, 200, { ok: true });
  }
  const cm = u.match(/^\/api\/conv\/([a-z0-9]{3,20})$/);
  if (cm) {
    const f = path.join(HIST, cm[1] + '.json');
    if (req.method === 'DELETE') { try { fs.unlinkSync(f); } catch {} return json(res, 200, { ok: true }); }
    try { return json(res, 200, JSON.parse(fs.readFileSync(f, 'utf8'))); } catch { return json(res, 404, {}); }
  }
  if (u.startsWith('/api/skills')) {
    const wr = (n, d, b, on) => {
      const dir = path.join(on === false ? SKOFF : SK, n);
      fs.mkdirSync(dir, { recursive: true });
      fs.writeFileSync(path.join(dir, 'SKILL.md'), '---\nname: ' + n + '\ndescription: ' + String(d || '').replace(/\n/g, ' ').trim() + '\n---\n' + String(b || '').trim() + '\n');
    };
    const rm = n => [SK, SKOFF].forEach(d => { try { fs.rmSync(path.join(d, n), { recursive: true, force: true }); } catch {} });
    if (u === '/api/skills' && req.method === 'GET') {
      const list = [];
      [SK, SKOFF].forEach(d => { try { fs.readdirSync(d).forEach(n => { const k = readSkill(d, n); if (k) list.push({ name: n, description: k.description, enabled: d === SK }); }); } catch {} });
      return json(res, 200, { list: list.sort((a, b) => a.name.localeCompare(b.name)) });
    }
    if (u === '/api/skills' && req.method === 'POST') {
      const b = await readBody(req), n = slug(b.name), old = slug(b.old);
      if (!n) return json(res, 200, { error: 'Donne un nom au skill.' });
      if (!String(b.body || '').trim()) return json(res, 200, { error: 'Écris les instructions.' });
      const off = old && fs.existsSync(path.join(SKOFF, old));
      if (old && old !== n) rm(old);
      wr(n, b.description, b.body, off ? false : true);
      return json(res, 200, { ok: true, name: n });
    }
    if (u === '/api/skills/toggle' && req.method === 'POST') {
      const b = await readBody(req), n = slug(b.name), from = path.join(b.on ? SKOFF : SK, n), to = path.join(b.on ? SK : SKOFF, n);
      try { fs.mkdirSync(path.dirname(to), { recursive: true }); fs.rmSync(to, { recursive: true, force: true }); fs.renameSync(from, to); } catch {}
      return json(res, 200, { ok: true });
    }
    if (u === '/api/skills/import' && req.method === 'POST') {
      const b = await readBody(req);
      try {
        let url = String(b.url || '').trim();
        if (!/^https:\/\//.test(url)) throw new Error('URL https requise');
        url = url.replace(/^https:\/\/github\.com\/([^/]+)\/([^/]+)\/blob\//, 'https://raw.githubusercontent.com/$1/$2/');
        const t = await fetchText(url), m = t.match(/^---\n([\s\S]*?)\n---\n?([\s\S]*)$/);
        const fm = m ? m[1] : '', body = (m ? m[2] : t).trim();
        const n = slug((fm.match(/^name:\s*(.*)$/m) || [])[1] || url.split('/').slice(-2, -1)[0] || 'skill-importe');
        if (!n || !body) throw new Error('fichier SKILL.md invalide');
        wr(n, (fm.match(/^description:\s*(.*)$/m) || [])[1] || '', body, true);
        return json(res, 200, { ok: true, name: n });
      } catch (e) { return json(res, 200, { error: e.message }); }
    }
    const sm = u.match(/^\/api\/skills\/([^/]+)$/);
    if (sm) {
      const n = slug(decodeURIComponent(sm[1]));
      if (req.method === 'DELETE') { rm(n); return json(res, 200, { ok: true }); }
      const k = readSkill(SK, n) || readSkill(SKOFF, n);
      return k ? json(res, 200, k) : json(res, 404, {});
    }
  }
  if (req.method === 'POST' && u === '/api/omni/install') {
    if (!omniInstalling && !omniInstalled()) {
      omniInstalling = true;
      const out = fs.openSync(path.join(DIR, 'omniroute-install.log'), 'a');
      const p = spawn('sh', ['-c', 'npm install -g omniroute'], { stdio: ['ignore', out, out] });
      p.on('close', () => { omniInstalling = false; }); p.on('error', () => { omniInstalling = false; });
    }
    return json(res, 200, { ok: true });
  }
  if (req.method === 'POST' && u === '/api/omni/test') {
    const b = await readBody(req), k = readEnv().OMNIROUTE_KEY, t0 = Date.now();
    const body = JSON.stringify({ model: b.model, max_tokens: 24, messages: [{ role: 'user', content: 'Réponds juste : ok' }] });
    const q = http.request(OMNI + '/v1/messages', { method: 'POST', timeout: 60000, headers: { 'Content-Type': 'application/json', 'anthropic-version': '2023-06-01', 'x-api-key': k || '', Authorization: 'Bearer ' + (k || ''), 'Content-Length': Buffer.byteLength(body) } }, r => {
      let d = ''; r.on('data', x => d += x);
      r.on('end', () => json(res, 200, { ok: r.statusCode < 300, status: r.statusCode, ms: Date.now() - t0, error: r.statusCode < 300 ? '' : d.slice(0, 300) }));
    });
    q.on('error', e => json(res, 200, { ok: false, status: 0, ms: 0, error: String(e.message) }));
    q.on('timeout', () => q.destroy());
    q.end(body); return;
  }
  if (req.method === 'GET' && (u === '/api/omni/models' || u === '/api/models')) {
    const k = readEnv().OMNIROUTE_KEY;
    const q = http.get(OMNI + '/v1/models', { headers: k ? { Authorization: 'Bearer ' + k } : {}, timeout: 4000 }, r => {
      let d = ''; r.on('data', x => d += x);
      r.on('end', () => { try { json(res, 200, { status: r.statusCode, models: (JSON.parse(d).data || []).map(m => m.id).sort() }); } catch { json(res, 200, { status: r.statusCode, models: [] }); } });
    });
    q.on('error', () => json(res, 200, { status: 0, models: [] }));
    q.on('timeout', () => q.destroy());
    return;
  }
  if (req.method === 'GET' && u === '/api/attach') {
    if (!run) { res.writeHead(204); return res.end(); }
    return attach(res, parseInt(new URL(req.url, 'http://x').searchParams.get('from') || '0', 10));
  }
  if (req.method === 'POST' && u === '/api/chat') {
    const b = await readBody(req);
    if (busy()) return json(res, 409, { error: 'Une réponse est déjà en cours.' });
    run = { id: Date.now().toString(36), events: [], done: false, subs: new Set(), prompt: b.prompt || '' };
    const emit = o => { run.events.push(o); run.subs.forEach(f => f()); };
    const finish = code => { if (run.done) return; run.done = true; proc = null; emit({ type: 'done', code }); };
    emit({ type: 'run', id: run.id });
    attach(res, 0);
    (async () => {
      const bk = b.backend === 'omni' ? 'omni' : '';
      const BU = OMNI, KV = 'OMNIROUTE_KEY';
      if (bk && !(await portUp(BU))) {
        if ((b.opts || {}).autoStart === false) { emit({ type: 'error', text: 'OmniRoute est arrêté (démarrage automatique désactivé dans les réglages).' }); return finish(-1); }
        if (!omniInstalled()) { emit({ type: 'error', text: 'OmniRoute n’est pas installé (Réglages → assistant OmniRoute).' }); return finish(-1); }
        emit({ type: 'note', text: 'Démarrage d’OmniRoute… (patiente, ça peut prendre 30 s)' });
        startOmni();
        for (let i = 0; i < 40 && !(await portUp(BU)); i++) await new Promise(r => setTimeout(r, 2000));
        if (!(await portUp(BU))) { emit({ type: 'error', text: 'OmniRoute ne démarre pas (voir ~/claude-ui/omniroute.log).' }); return finish(-1); }
      }
      if (run.done) return;
      const e = readEnv(), env = { ...process.env };
      Object.keys(e).forEach(k => { if (k !== 'OMNIROUTE_KEY') env[k] = e[k]; });
      const m = b.model || '';
      if (bk) {
        Object.assign(env, { ANTHROPIC_BASE_URL: BU, ANTHROPIC_API_KEY: '', CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC: '1' });
        if (e[KV]) env.ANTHROPIC_AUTH_TOKEN = e[KV];
        if (m) ['ANTHROPIC_MODEL', 'ANTHROPIC_SMALL_FAST_MODEL', 'ANTHROPIC_DEFAULT_OPUS_MODEL', 'ANTHROPIC_DEFAULT_SONNET_MODEL', 'ANTHROPIC_DEFAULT_HAIKU_MODEL'].forEach(k => env[k] = m);
      }
      let cwd = (b.cwd || '~').replace(/^~/, os.homedir());
      if (!fs.existsSync(cwd)) cwd = os.homedir();
      const args = ['-p', '--output-format', 'stream-json', '--verbose', '--include-partial-messages', '--permission-mode', b.mode || 'acceptEdits'];
      const o = b.opts || {};
      const tl = Array.isArray(o.tools) ? o.tools.filter(t => /^[A-Za-z]+$/.test(t)) : ['Bash', 'Read', 'Edit', 'Write', 'Glob', 'Grep', 'WebFetch', 'WebSearch', 'TodoWrite', 'Skill'];
      if (tl.includes('Edit')) tl.push('MultiEdit');
      if (tl.includes('Read')) tl.push('LS');
      if (b.mode !== 'plan' && tl.length) args.push('--allowedTools', tl.join(','));
      const mt = parseInt(o.maxTurns, 10); if (mt > 0) args.push('--max-turns', String(mt));
      if (o.append) args.push('--append-system-prompt', String(o.append).slice(0, 4000));
      String(o.addDirs || '').split(/[\n,]/).map(x => x.trim()).filter(Boolean).slice(0, 8).forEach(d => args.push('--add-dir', d.replace(/^~/, os.homedir())));
      if (o.fallback) args.push('--fallback-model', String(o.fallback));
      const th = parseInt(o.thinking, 10); if (th > 0) env.MAX_THINKING_TOKENS = String(th);
      if (bk && o.fast) ['ANTHROPIC_SMALL_FAST_MODEL', 'ANTHROPIC_DEFAULT_HAIKU_MODEL'].forEach(k => env[k] = String(o.fast));
      String(o.env || '').split('\n').forEach(l => { const m2 = l.match(/^\s*([A-Z_][A-Z0-9_]*)\s*=\s*(.*?)\s*$/); if (m2) env[m2[1]] = m2[2]; });
      if (!bk && m) args.push('--model', m);
      if (b.session) args.push('--resume', b.session);
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
    })();
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
<meta name="theme-color" content="#1b1a19">
<link rel="manifest" href="/manifest.json">
<title>Claude Code</title>
<style>
:root{--sp:cubic-bezier(.34,1.56,.64,1);--ac:#d97757;--onac:#fff;--ok:#5fb36b;--bad:#e5645a}
:root[data-t=dark]{--bg:#1b1a19;--s1:#232220;--s2:#2b2a28;--s3:#363432;--tx:#f0ede8;--dm:#b3ada5;--ln:#4a4743}
:root[data-t=light]{--bg:#fbf8f3;--s1:#f3efe8;--s2:#ebe5dc;--s3:#e0d9cd;--tx:#1e1b17;--dm:#5f584f;--ln:#cfc7bb}
:root{--acc:color-mix(in srgb,var(--ac) 24%,var(--s2))}
*{box-sizing:border-box;-webkit-tap-highlight-color:transparent}
html,body{height:100%;margin:0;background:var(--bg);color:var(--tx);font:16px/1.55 'Google Sans Flex','Roboto Flex',system-ui,Roboto,sans-serif}
button{font:600 14px/1.1 inherit;color:var(--tx);background:var(--s3);border:0;border-radius:999px;padding:11px 18px;transition:border-radius .3s var(--sp),transform .25s var(--sp),background .2s}
button:active{border-radius:12px;transform:scale(.95)}
.pri{background:var(--ac);color:var(--onac)}.tn{background:var(--acc)}.ib{width:44px;height:44px;padding:0;font-size:18px}
#chatView{display:flex;flex-direction:column;height:100%}
header{display:flex;align-items:center;gap:8px;padding:10px 12px}
header h1{flex:1;margin:0;font:700 21px 'Google Sans Flex',Georgia,serif;letter-spacing:-.3px;white-space:nowrap;overflow:hidden}header h1 b{color:var(--ac);margin-right:6px}
.pl{padding:8px 12px;font-size:13px}.pl i{display:inline-block;width:8px;height:8px;border-radius:50%;background:var(--bad);margin-right:6px}.pl.on i{background:var(--ok)}
#wrap{flex:1;position:relative;min-height:0;display:flex;flex-direction:column}
#chat{flex:1;overflow-y:auto;padding:6px 16px 18px;display:flex;flex-direction:column;gap:14px}
#welcome{position:absolute;inset:0;display:flex;flex-direction:column;align-items:center;justify-content:center;gap:10px;pointer-events:none;text-align:center;padding:20px}
#welcome h2{font:700 28px 'Google Sans Flex',Georgia,serif;margin:0 0 8px}#welcome button{pointer-events:auto;width:100%;max-width:340px;background:var(--s2)}
.user{align-self:flex-end;max-width:90%;background:var(--acc);border-radius:26px 26px 8px 26px;padding:11px 17px;white-space:pre-wrap;overflow-wrap:anywhere}
.bot{overflow-wrap:anywhere}.note{font-size:12.5px;color:var(--dm)}.note.err{color:var(--bad)}
code{background:var(--s3);padding:1px 6px;border-radius:7px;font:13.5px ui-monospace,monospace}
pre{background:var(--s1);border-radius:20px;padding:12px 14px;overflow-x:auto;margin:8px 0;font:12.5px/1.5 ui-monospace,monospace}pre code{background:none;padding:0}
details.tool,details.tk{font-size:14px;background:var(--s1);border-radius:20px;padding:9px 14px}
details summary{color:var(--dm);cursor:pointer;list-style:none;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}details summary::-webkit-details-marker{display:none}
details.tool summary i{display:inline-block;width:9px;height:9px;border-radius:3px;background:var(--ac);margin-right:9px;transition:border-radius .3s var(--sp)}
details.tool.done summary i{background:var(--ok);border-radius:50%}details.tool.fail summary i{background:var(--bad)}
details.tool summary b{color:var(--tx);margin-right:6px}details.tool pre{max-height:240px;margin:8px 0 2px}
details.tk summary{color:var(--ac);font-weight:600}details.tk div{color:var(--dm);font-style:italic;white-space:pre-wrap;max-height:200px;overflow:auto;font-size:13.5px;margin-top:6px}
.add{color:var(--ok)}.del{color:var(--bad)}.todo{font-size:14px;line-height:1.7;background:var(--s1);border-radius:20px;padding:10px 14px}
#think{color:var(--ac);font-size:14px;font-weight:600;display:flex;align-items:center;gap:10px}
.ld{width:20px;height:20px;background:var(--ac);animation:mo 1.8s var(--sp) infinite}
@keyframes mo{0%{border-radius:50%;transform:rotate(0)}33%{border-radius:32% 68% 68% 32%/32% 32% 68% 68%;transform:rotate(120deg)}66%{border-radius:22%;transform:rotate(240deg)}100%{border-radius:50%;transform:rotate(360deg)}}
#comp{margin:0 12px calc(10px + env(safe-area-inset-bottom));background:var(--s2);border-radius:32px;padding:12px 14px 10px}
textarea{width:100%;resize:none;max-height:150px;background:none;color:var(--tx);border:0;outline:0;font:inherit;padding:2px 4px}
#bar{display:flex;gap:10px;align-items:center;margin-top:6px}
.grp{display:flex;gap:2px;min-width:0}.grp button{background:var(--s3);font-size:12.5px;padding:9px 13px;border-radius:6px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;max-width:46vw}
.grp button:first-child{border-radius:999px 6px 6px 999px}.grp button:last-child{border-radius:6px 999px 999px 6px}
#go{margin-left:auto;background:var(--ac);color:var(--onac);width:54px;height:54px;border-radius:19px;padding:0;font-size:22px;flex:none}#go.stop{background:var(--bad);border-radius:50%}
.sheet{position:fixed;inset:0;background:#0009;display:none;align-items:flex-end;z-index:8}.sheet.show{display:flex}
.sheet .in{background:var(--bg);width:100%;max-height:88%;overflow:auto;border-radius:32px 32px 0 0;padding:22px 18px calc(18px + env(safe-area-inset-bottom));animation:up .45s var(--sp)}
@keyframes up{from{transform:translateY(60px);opacity:0}}
.sheet .in::before{content:'';display:block;width:34px;height:4px;border-radius:9px;background:var(--ln);margin:-12px auto 14px}.sheet h3{margin:0 0 10px;font-size:20px}
.row{display:flex;align-items:center;gap:10px;margin-top:14px}.row button{flex:1}
.it{display:flex;width:100%;justify-content:space-between;align-items:center;text-align:left;margin-top:8px;background:var(--s1);border-radius:20px;padding:14px 18px;gap:8px;font-weight:500}
.it .ctr{display:flex;gap:8px;align-items:center}.it small{color:var(--dm)}.it .x{color:var(--bad);padding:0 6px}
input.f,textarea.f,#psearch{width:100%;background:var(--s2);color:var(--tx);border:0;border-bottom:2px solid var(--ln);border-radius:18px 18px 6px 6px;padding:13px 15px;font:inherit;outline:0}
input.f:focus,textarea.f:focus{border-bottom-color:var(--ac)}
#setView{position:fixed;inset:0;background:var(--bg);overflow:auto;transform:translateX(100%);visibility:hidden;transition:transform .5s var(--sp),visibility 0s .5s;z-index:6;padding-bottom:40px}
#setView.open{transform:none;visibility:visible;transition:transform .5s var(--sp)}
.bar2{position:sticky;top:0;background:var(--bg);display:flex;align-items:center;gap:10px;padding:12px;z-index:2}.bar2 h1{margin:0;font:700 26px 'Google Sans Flex',Georgia,serif}
.sec{margin:22px 22px 8px;font:700 12px/1 inherit;color:var(--ac);letter-spacing:.09em;text-transform:uppercase}
.card{background:var(--s1);border-radius:30px;margin:0 12px 6px;padding:6px 0;overflow:hidden}
.it2{padding:14px 20px}.it2+.it2{border-top:1px solid var(--s2)}.it2 .t{font-weight:600}.s{font-size:13px;color:var(--dm)}.it2 .ctl{margin-top:10px}
.it2.inl{display:flex;align-items:center;justify-content:space-between;gap:12px}.it2.inl .ctl{margin:0}
.seg{display:flex;gap:2px}.seg button{flex:1;border-radius:8px;font-size:13px;padding:11px 4px}.seg button:first-child{border-radius:999px 8px 8px 999px}.seg button:last-child{border-radius:8px 999px 999px 8px}
.seg button.on{background:var(--ac);color:var(--onac);border-radius:999px}
.chs{display:flex;flex-wrap:wrap;gap:8px}.chs button{background:var(--s2);padding:9px 14px;font-size:13px}.chs button.on{background:var(--acc);box-shadow:inset 0 0 0 2px var(--ac)}
.dot{width:38px;height:38px;padding:0;border-radius:50%!important}.dot.on{box-shadow:0 0 0 3px var(--bg),0 0 0 6px var(--tx)}
input.sw{appearance:none;width:54px;height:32px;border-radius:999px;background:var(--s3);position:relative;transition:background .25s;flex:none}
input.sw::after{content:'';position:absolute;left:6px;top:6px;width:20px;height:20px;border-radius:50%;background:var(--dm);transition:all .3s var(--sp)}
input.sw:checked{background:var(--ac)}input.sw:checked::after{left:26px;top:4px;width:24px;height:24px;background:#fff}
.st{font-size:12px;padding:4px 11px;border-radius:999px;background:var(--s3);color:var(--dm);font-weight:600}.st.ok{background:color-mix(in srgb,var(--ok) 26%,var(--s2));color:var(--ok)}
.ph{display:flex;justify-content:space-between;align-items:center;padding:16px 20px 4px;font:700 18px inherit}
.stp{display:flex;gap:14px;padding:12px 20px}.stp>b{width:28px;height:28px;flex:none;border-radius:10px;background:var(--s3);display:grid;place-items:center;font-size:13px}
.stp.ok>b{background:var(--ok);color:#fff;border-radius:50%}.stp .t{font-weight:600}.stp button{margin:8px 8px 0 0}.stp input{margin-top:8px}
.wc{background:var(--acc);border-radius:30px;margin:6px 12px;padding:18px 22px}.wc b{font-size:18px}
#toast{position:fixed;left:50%;bottom:90px;transform:translate(-50%,30px);background:var(--tx);color:var(--bg);padding:12px 20px;border-radius:999px;opacity:0;pointer-events:none;transition:all .4s var(--sp);z-index:9;font-size:14px;max-width:88%}
#toast.show{opacity:1;transform:translate(-50%,0)}
</style></head><body>
<div id="chatView">
<header><button class="ib" id="bHist">☰</button><h1><b>✻</b>Claude Code</h1><button id="pill" class="pl"><i></i>Omni</button><button class="ib" id="new">＋</button><button class="ib" id="cog">⚙︎</button></header>
<div id="wrap"><div id="chat"></div>
<div id="welcome"><h2>Que veux-tu faire ?</h2>
<button id="setupBtn" class="pri">Configurer OmniRoute (3 min)</button>
<button data-q="Explique-moi ce projet : structure, rôle de chaque fichier.">Expliquer ce projet</button>
<button data-q="Cherche les bugs dans ce dossier et propose des corrections.">Chercher les bugs</button>
<button data-q="Liste les fichiers du dossier et dis-moi ce que tu peux faire pour m’aider.">Que peux-tu faire ici ?</button></div></div>
<div id="comp"><textarea id="in" rows="1" placeholder="Demande quelque chose à Claude…"></textarea>
<div id="bar"><div class="grp"><button id="modeBtn"></button><button id="skBtn">✦</button><button id="modelBtn"></button></div><button id="go">↑</button></div></div>
</div>
<div id="setView"><div class="bar2"><button class="ib" id="back">←</button><h1>Réglages</h1></div><div id="setBody"></div></div>
<div class="sheet" id="sh-hist"><div class="in"><h3>Conversations</h3><button class="pri" id="newc" style="width:100%">＋ Nouvelle conversation</button><div id="hlist"></div></div></div>
<div class="sheet" id="sh-pick"><div class="in"><h3>Choisir le modèle</h3>
<p class="s" id="bkInfo"></p><div class="row" style="margin-top:6px"><button id="bkAct" class="pri" style="display:none">Ouvrir les réglages</button></div>
<input type="text" id="psearch" placeholder="Rechercher…" autocapitalize="off" style="margin-top:10px"><div id="plist"></div>
<div class="row"><button id="pdash">Ouvrir le dashboard</button><button id="poff">Sans backend</button></div></div></div>
<div class="sheet" id="sh-sk"><div class="in"><h3>Skills</h3><p class="s">Un skill est une compétence que Claude peut utiliser. Touche-en un pour l’insérer dans ton message.</p><div id="sklist"></div><button class="pri" id="skNew" style="width:100%;margin-top:14px">＋ Nouveau skill</button></div></div>
<div class="sheet" id="sh-ske"><div class="in"><h3 id="skTitle">Nouveau skill</h3><div class="chs" id="skTpl"></div>
<p class="s" style="margin:12px 0 4px">Nom</p><input class="f" id="skName" autocapitalize="off" placeholder="ex : relecteur-de-code">
<p class="s" style="margin:12px 0 4px">Description (quand l’utiliser)</p><input class="f" id="skDesc">
<p class="s" style="margin:12px 0 4px">Instructions</p><textarea class="f" id="skBody" rows="7"></textarea>
<div class="row"><button id="skDel" style="display:none">Supprimer</button><button class="pri" id="skSave">Enregistrer</button></div>
<p class="s" style="margin:18px 0 4px">Importer depuis une URL (fichier SKILL.md)</p><input class="f" id="skUrl" placeholder="https://github.com/…/SKILL.md">
<div class="row"><button id="skImp">Importer</button></div><p class="s">N’importe que des skills de sources de confiance : Claude suit leurs instructions.</p></div></div>
<div id="toast"></div>
<script>
const $=s=>document.querySelector(s);
const $$=(t,c,h)=>{const e=document.createElement(t);if(c)e.className=c;if(h!=null)e.innerHTML=h;return e};
const api=(u,o={})=>fetch(u,{...o,headers:{'Content-Type':'application/json','X-CUI':'1'}});
const post=(u,b)=>api(u,{method:'POST',body:JSON.stringify(b||{})});
const ALL=['Bash','Read','Edit','Write','Glob','Grep','WebFetch','WebSearch','TodoWrite','Skill'];
const ACC=['#d97757','#7c6cf0','#2f9e8f','#3b82f6','#d6477a','#6f9b2f'];
const DEF={cwd:'~',model:'',mode:'acceptEdits',backend:'',tools:ALL,maxTurns:0,append:'',lang:'',addDirs:'',fast:'',fallback:'',thinking:'',theme:'auto',accent:'dyn',fontSize:16,showThink:'open',toolsOpen:false,env:'',autoStart:true};
const MODES={acceptEdits:'» Modifs auto',plan:'≡ Plan',bypassPermissions:'! Tout autoriser'};
const cfg=Object.assign({},DEF,JSON.parse(localStorage.getItem('cfg')||'{}'));
if(cfg.omni&&!cfg.backend)cfg.backend='omni';delete cfg.omni;if(cfg.backend==='free')cfg.backend='';
let session=localStorage.getItem('sid')||'',convId=localStorage.getItem('conv')||'',curRun='',busy=false,cur=null,gotDelta=false,gotThink=false,thinkCard=null,tools={},seen=0,finished=false,st={omni:{}},pickB='omni',models=[],t0=0,label='Réflexion',stick=true,kv={O:'',F:''},welcome=false;
const chat=$('#chat'),inp=$('#in'),go=$('#go');
let sv=null;const save=()=>{localStorage.setItem('cfg',JSON.stringify(cfg));clearTimeout(sv);sv=setTimeout(()=>post('/api/config',{cfg}).catch(()=>{}),400)};
const esc=s=>String(s).replace(/[&<>]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;'}[c]));
const open=id=>$('#sh-'+id).classList.add('show'),close=id=>$('#sh-'+id).classList.remove('show');
document.querySelectorAll('.sheet').forEach(e=>e.onclick=ev=>{if(ev.target===e)e.classList.remove('show')});
function hintFor(s,e){e=String(e||'');
  if(s===401||/unauthor|invalid.*(key|token)|401/i.test(e))return 'Clé refusée : recolle-la dans Réglages → étape 4.';
  if(s===404||/not found|unknown model|no such model|404/i.test(e))return 'Ce combo ou modèle n’existe pas : choisis-en un dans la liste (étape 5).';
  if(s===429||/rate.?limit|quota|429/i.test(e))return 'Quota atteint : ajoute un fournisseur au combo dans le dashboard OmniRoute.';
  if(s===0||/ECONNREFUSED|socket hang up/i.test(e))return 'OmniRoute ne répond pas : relance-le (étape 2).';
  if(/no (available )?(provider|account|credential|connection)|not connected/i.test(e))return 'Aucun fournisseur connecté : voir étape 3 (dashboard → Providers).';
  return ''}
const hintOf=(s,e)=>hintFor(s,e)||String(e||'').slice(0,160)||'Erreur inconnue.';
const wait=ms=>new Promise(r=>setTimeout(r,ms));
let tt=null;function toast(t){const e=$('#toast');e.textContent=t;e.classList.add('show');clearTimeout(tt);tt=setTimeout(()=>e.classList.remove('show'),2800)}
function apply(){const dark=matchMedia('(prefers-color-scheme:dark)').matches;
  document.documentElement.dataset.t=cfg.theme==='auto'?(dark?'dark':'light'):cfg.theme;
  const ac=cfg.accent==='dyn'?((window.Android&&Android.dynamicColor&&Android.dynamicColor())||ACC[0]):cfg.accent;
  document.documentElement.style.setProperty('--ac',ac);document.body.style.fontSize=cfg.fontSize+'px';
  if(window.Android&&Android.setStyle)Android.setStyle(ac,document.documentElement.dataset.t==='dark')}
matchMedia('(prefers-color-scheme:dark)').addEventListener('change',apply);
function md(t){return t.split('```').map((p,i)=>{
  if(i%2){const n=p.indexOf('\n');return '<pre><code>'+esc(p.slice(n+1).replace(/\n$/,''))+'</code></pre>'}
  return esc(p).replace(/`([^`\n]+)`/g,'<code>$1</code>').replace(/\*\*([^*\n]+)\*\*/g,'<b>$1</b>').replace(/^#{1,3} (.+)$/gm,'<b>$1</b>').replace(/\n/g,'<br>')}).join('')}
chat.addEventListener('scroll',()=>{stick=chat.scrollHeight-chat.scrollTop-chat.clientHeight<80});
const scroll=()=>{if(stick)chat.scrollTop=chat.scrollHeight};
const empty=()=>{$('#welcome').style.display=chat.childElementCount?'none':'flex'};
function add(kind,text){const d=document.createElement('div');d.className=kind;d.raw=text||'';
  if(kind==='user')d.textContent=text;else d.innerHTML=md(d.raw);
  d.append=t=>{d.raw+=t;d.innerHTML=md(d.raw);scroll()};chat.appendChild(d);empty();scroll();return d}
function note(t,err){const d=document.createElement('div');d.className='note'+(err?' err':'');d.textContent=t;chat.appendChild(d);empty();scroll()}
function spin(on){let t=$('#think');
  if(on){if(!t){t=document.createElement('div');t.id='think'}t.innerHTML='<span class="ld"></span>'+label+'… '+Math.round((Date.now()-t0)/1000)+'s';chat.appendChild(t);scroll()}
  else if(t)t.remove()}
setInterval(()=>{if(busy&&$('#think'))spin(true)},1000);
function thinkText(t){if(cfg.showThink==='hide')return;
  if(!thinkCard){thinkCard=document.createElement('details');thinkCard.className='tk';thinkCard.open=cfg.showThink==='open';
    thinkCard.innerHTML='<summary>✻ Réflexion</summary><div></div>';chat.appendChild(thinkCard)}
  thinkCard.querySelector('div').textContent+=t;scroll()}
const endThink=()=>{if(thinkCard){thinkCard.open=false;thinkCard=null}};
function diff(o,n){return(o?o.split('\n').map(l=>'<span class="del">- '+esc(l)+'</span>').join('\n')+'\n':'')+n.split('\n').map(l=>'<span class="add">+ '+esc(l)+'</span>').join('\n')}
function toolCard(b){
  const i=b.input||{},brief=i.command||i.file_path||i.pattern||i.path||i.url||i.description||'';
  if(b.name==='TodoWrite'&&Array.isArray(i.todos)){const d=document.createElement('div');d.className='todo';
    d.innerHTML=i.todos.map(t=>(t.status==='completed'?'☑ ':t.status==='in_progress'?'◐ ':'☐ ')+esc(t.content)).join('<br>');chat.appendChild(d);scroll();return}
  const d=document.createElement('details');d.className='tool';d.open=!!cfg.toolsOpen;
  d.innerHTML='<summary><i></i><b>'+esc(b.name)+'</b>'+esc(String(brief).slice(0,100))+'</summary><pre></pre>';
  const p=d.querySelector('pre');
  if(b.name==='Edit'&&i.new_string!=null)p.innerHTML=diff(i.old_string||'',i.new_string);
  else if(b.name==='Write'&&i.content!=null)p.innerHTML=diff('',i.content.slice(0,3000));
  else p.textContent=i.command?'$ '+i.command:JSON.stringify(i,null,2);
  chat.appendChild(d);tools[b.id]=d;scroll()}
function setBusy(b){busy=b;go.textContent=b?'■':'↑';go.classList.toggle('stop',b);if(!b)spin(false)}
function handle(ev){
  if(ev.type==='run')curRun=ev.id;
  else if(ev.type==='system'&&ev.session_id){session=ev.session_id;localStorage.setItem('sid',session)}
  else if(ev.type==='stream_event'){const e=ev.event||{},d=e.delta||{};
    if(e.type==='message_start'){cur=null;gotDelta=false;gotThink=false;thinkCard=null}
    else if(e.type==='content_block_delta'&&d.type==='thinking_delta'){spin(false);gotThink=true;thinkText(d.thinking||'')}
    else if(e.type==='content_block_delta'&&d.type==='text_delta'){spin(false);endThink();if(!cur)cur=add('bot','');cur.append(d.text);gotDelta=true}}
  else if(ev.type==='assistant'){spin(false);
    for(const b of(ev.message&&ev.message.content)||[]){
      if(b.type==='thinking'&&!gotThink&&b.thinking)thinkText(b.thinking);
      if(b.type==='text'&&!gotDelta&&b.text.trim()){endThink();add('bot',b.text)}
      if(b.type==='tool_use'){endThink();label='Outil '+b.name;toolCard(b)}}
    endThink();cur=null;gotDelta=false;if(busy)spin(true)}
  else if(ev.type==='user'){label='Réflexion';
    for(const b of(ev.message&&ev.message.content)||[]){
      if(b.type==='tool_result'&&tools[b.tool_use_id]){
        let c=b.content;if(Array.isArray(c))c=c.map(x=>x.text||'').join('\n');
        const d=tools[b.tool_use_id];d.classList.add(b.is_error?'fail':'done');
        const p=d.querySelector('pre');if(!/<span/.test(p.innerHTML))p.textContent+='\n\n'+String(c||'').slice(0,4000)}}
    if(busy)spin(true)}
  else if(ev.type==='result'){
    if(ev.session_id){session=ev.session_id;localStorage.setItem('sid',session)}
    if(ev.is_error){note('Erreur : '+(ev.result||'inconnue'),true);{const t=cfg.backend==='omni'?hintFor(null,ev.result):'';if(t)note('→ '+t)}if(/session|conversation/i.test(ev.result||'')){session='';localStorage.removeItem('sid')}}
    const s=[];if(ev.duration_ms)s.push((ev.duration_ms/1000).toFixed(1)+'s');
    if(ev.total_cost_usd&&!cfg.backend)s.push('$'+ev.total_cost_usd.toFixed(4));if(s.length)note(s.join(' · '))}
  else if(ev.type==='stderr'&&ev.text.trim()&&!/unrecognized_model/.test(ev.text))note(ev.text.trim().slice(0,300),true);
  else if(ev.type==='error'){note(ev.text,true);const t=cfg.backend==='omni'?hintFor(null,ev.text):'';if(t)note('→ '+t)}
  else if(ev.type==='note')note(ev.text);
  else if(ev.type==='done')finished=true}
async function consume(r){const rd=r.body.getReader(),dec=new TextDecoder();let buf='';
  for(;;){const{done,value}=await rd.read();if(done)return;buf+=dec.decode(value,{stream:true});let i;
    while((i=buf.indexOf('\n\n'))>=0){const c=buf.slice(0,i);buf=buf.slice(i+2);
      if(c.startsWith('data: ')){seen++;try{handle(JSON.parse(c.slice(6)))}catch(e){}}}}}
async function follow(r){
  setBusy(true);label='Réflexion';spin(true);seen=0;finished=false;
  while(!finished){
    try{if(!r){r=await api('/api/attach?from='+seen);if(r.status===204)break}await consume(r)}catch(e){}
    r=null;if(!finished)await wait(1000)}
  setBusy(false);if(curRun)localStorage.setItem('runSaved',curRun);persist()}
let pt=null;
function persist(){clearTimeout(pt);pt=setTimeout(()=>{
  if(!convId||!chat.childElementCount)return;
  const u=chat.querySelector('.user'),h=chat.innerHTML.replace(/<div id="think"[^>]*>.*?<\/div>/,'');
  post('/api/conv',{id:convId,title:(u?u.textContent:'Conversation').slice(0,48),session,html:h}).catch(()=>{})},300)}
const genId=()=>Date.now().toString(36)+Math.random().toString(36).slice(2,5);
function newConv(){if(busy)return toast('Attends la fin de la réponse (ou ■).');
  persist();convId=genId();localStorage.setItem('conv',convId);session='';localStorage.removeItem('sid');chat.innerHTML='';tools={};empty();close('hist')}
async function loadConv(id){if(busy)return;
  const c=await(await api('/api/conv/'+id)).json();if(!c.id)return;
  convId=c.id;session=c.session||'';localStorage.setItem('conv',convId);
  if(session)localStorage.setItem('sid',session);else localStorage.removeItem('sid');
  chat.innerHTML=c.html||'';tools={};empty();stick=true;scroll();close('hist')}
async function openHist(){open('hist');const l=(await(await api('/api/conv')).json()).list||[];
  $('#hlist').innerHTML=l.length?l.map(c=>'<button class="it" data-id="'+c.id+'"><span>'+esc(c.title||'Conversation')+'<br><small>'+new Date(c.ts).toLocaleString('fr-FR',{day:'2-digit',month:'2-digit',hour:'2-digit',minute:'2-digit'})+'</small></span><span class="x" data-del="'+c.id+'">✕</span></button>').join(''):'<p class="s">Aucune conversation enregistrée.</p>'}
$('#hlist').onclick=async e=>{const d=e.target.dataset.del;
  if(d){e.stopPropagation();await api('/api/conv/'+d,{method:'DELETE'});if(d===convId)newConv();return openHist()}
  const b=e.target.closest('.it');if(b)loadConv(b.dataset.id)};
const appendP=()=>[cfg.lang==='fr'?'Réponds toujours en français.':cfg.lang==='en'?'Always answer in English.':'',cfg.append].filter(Boolean).join('\n');
async function sendMsg(){
  if(busy){api('/api/stop',{method:'POST'});return}
  const prompt=inp.value.trim();if(!prompt)return;
  if(!convId){convId=genId();localStorage.setItem('conv',convId)}
  inp.value='';fit();stick=true;add('user',prompt);cur=null;gotDelta=false;t0=Date.now();persist();
  try{const r=await post('/api/chat',{prompt,session,cwd:cfg.cwd,model:cfg.model,mode:cfg.mode,backend:cfg.backend,
    opts:{tools:cfg.tools,maxTurns:cfg.maxTurns,append:appendP(),addDirs:cfg.addDirs,fast:cfg.fast,fallback:cfg.fallback,thinking:cfg.thinking,env:cfg.env,autoStart:cfg.autoStart}});
    if(!r.ok){const j=await r.json().catch(()=>({}));throw new Error(j.error||r.status)}
    await follow(r)}catch(e){note('Erreur : '+e.message,true);setBusy(false)}}
function fit(){inp.style.height='auto';inp.style.height=Math.min(inp.scrollHeight,150)+'px'}
function chips(){$('#modeBtn').textContent=MODES[cfg.mode]||cfg.mode;
  $('#setupBtn').style.display=cfg.backend&&cfg.model?'none':'';
  $('#modelBtn').textContent=cfg.backend?'⇄ '+(cfg.model||'choisir')+' · Omni':'Choisir un modèle'}
inp.addEventListener('input',fit);go.onclick=sendMsg;
document.querySelectorAll('#welcome button[data-q]').forEach(b=>b.onclick=()=>{inp.value=b.dataset.q;fit();inp.focus()});
$('#modeBtn').onclick=()=>{const k=Object.keys(MODES);cfg.mode=k[(k.indexOf(cfg.mode)+1)%k.length];save();chips()};
$('#setupBtn').onclick=()=>{location.hash='settings'};$('#bHist').onclick=openHist;$('#new').onclick=newConv;$('#newc').onclick=newConv;
/* ---------- sélecteur de modèle ---------- */
const info=t=>{$('#bkInfo').textContent=t};
async function poll(){try{const s=await(await api('/api/status')).json();
  st.omni={up:s.omniroute,hasKey:s.hasKey,installed:s.omniInstalled,installing:s.omniInstalling};
  $('#pill').classList.toggle('on',!!st.omni.up);refreshProv();return s}catch{}}
async function openPick(){open('pick');loadPick()}
async function loadPick(){
  const act=$('#bkAct');act.style.display='none';models=[];$('#plist').innerHTML='';$('#psearch').value='';
  await poll();const s=st.omni;
  if(!s.up||!s.hasKey){info(!s.up?'OmniRoute est arrêté.':'Il manque la clé OmniRoute.');act.style.display='';return}
  info('Chargement…');const r=await(await api('/api/models')).json();
  models=(r.models||[]).sort((a,b)=>/claudeui/i.test(b)-/claudeui/i.test(a));
  info(r.status===401?'Clé refusée : vérifie-la dans les réglages.':models.length?models.length+' modèles / combos : touche pour choisir':'Aucun modèle : connecte un fournisseur dans le dashboard.');renderPick()}
function renderPick(){const q=$('#psearch').value.toLowerCase();
  $('#plist').innerHTML=models.filter(m=>m.toLowerCase().includes(q)).slice(0,80).map(m=>'<button class="it" data-m="'+esc(m)+'">'+esc(m)+'<span>'+(m===cfg.model&&cfg.backend==='omni'?'✓':'')+'</span></button>').join('')}
$('#modelBtn').onclick=()=>openPick();$('#psearch').oninput=renderPick;
$('#plist').onclick=e=>{const b=e.target.closest('[data-m]');if(!b)return;cfg.backend='omni';cfg.model=b.dataset.m;save();chips();close('pick');refreshProv()};
$('#poff').onclick=()=>{cfg.backend='';save();chips();close('pick')};
$('#pdash').onclick=()=>openDash();
$('#bkAct').onclick=()=>{close('pick');location.hash='settings'};
async function openDash(){close('pick');
  if(!st.omni.installed)return toast('Installe d’abord OmniRoute (Réglages).');
  if(!st.omni.up){toast('Démarrage d’OmniRoute…');await post('/api/omniroute/start');for(let i=0;i<40&&!st.omni.up;i++){await wait(2000);await poll()}}
  if(!st.omni.up)return toast('OmniRoute ne répond pas (voir ~/claude-ui/omniroute.log).');
  const url='http://localhost:20128';
  if(window.Android&&Android.showUrl)Android.showUrl(url);else if(window.Android&&Android.showDashboard)Android.showDashboard();else location.href=url}
$('#pill').onclick=()=>openDash();
/* ---------- skills ---------- */
const SKTPL=[['relecteur-de-code','Relit du code : bugs, failles, améliorations','Quand on te demande de relire du code :\n1. Lis les fichiers concernés.\n2. Liste les bugs probables, les failles et les cas limites.\n3. Propose des corrections précises, du plus important au moins important.\n4. Reste concis.'],['messages-de-commit','Rédige un message de commit clair','Quand on te demande un message de commit :\n1. Regarde les changements (git diff).\n2. Écris un titre de 50 caractères maximum, à l’impératif.\n3. Ajoute 2 ou 3 lignes qui expliquent le pourquoi.'],['expliquer-simplement','Explique du code ou un concept pas à pas','Explique comme à un débutant : une idée par étape, un exemple concret, aucun jargon sans définition.']];
let skEdit='';
async function loadSk(){const l=(await(await api('/api/skills')).json()).list||[];
  $('#sklist').innerHTML=l.length?l.map(k=>'<div class="it" data-n="'+esc(k.name)+'"><span style="flex:1;min-width:0">'+esc(k.name)+'<br><small>'+esc(k.description||'')+'</small></span><span class="ctr"><input type="checkbox" class="sw" data-t="'+esc(k.name)+'"'+(k.enabled?' checked':'')+'><button class="ib tn" data-e="'+esc(k.name)+'">✎</button></span></div>').join(''):'<p class="s">Aucun skill pour l’instant : crée-en un avec le bouton ci-dessous (des modèles sont proposés).</p>'}
async function openSkills(){open('sk');loadSk()}
function openSkEd(k){skEdit=k?k.name:'';$('#skTitle').textContent=k?'Modifier le skill':'Nouveau skill';
  $('#skName').value=k?k.name:'';$('#skDesc').value=k?k.description:'';$('#skBody').value=k?k.body:'';
  $('#skDel').style.display=k?'':'none';$('#skUrl').value='';$('#skTpl').style.display=k?'none':'';close('sk');open('ske')}
$('#skTpl').innerHTML=SKTPL.map((t,i)=>'<button data-i="'+i+'">'+t[0]+'</button>').join('');
$('#skTpl').onclick=e=>{const b=e.target.closest('[data-i]');if(!b)return;const t=SKTPL[b.dataset.i];$('#skName').value=t[0];$('#skDesc').value=t[1];$('#skBody').value=t[2]};
$('#sklist').onclick=async e=>{if(e.target.dataset.t)return;
  const ed=e.target.closest('[data-e]');if(ed)return openSkEd(await(await api('/api/skills/'+encodeURIComponent(ed.dataset.e))).json());
  const row=e.target.closest('[data-n]');if(row){inp.value='Utilise le skill « '+row.dataset.n+' » : ';fit();close('sk');inp.focus()}};
$('#sklist').onchange=async e=>{const t=e.target.dataset.t;if(t){await post('/api/skills/toggle',{name:t,on:e.target.checked});toast(e.target.checked?'Skill activé':'Skill désactivé')}};
$('#skNew').onclick=()=>openSkEd(null);$('#skBtn').onclick=openSkills;
$('#skSave').onclick=async()=>{const r=await(await post('/api/skills',{old:skEdit,name:$('#skName').value,description:$('#skDesc').value,body:$('#skBody').value})).json();
  if(r.error)return toast(r.error);close('ske');toast('Skill enregistré ✓');openSkills()};
$('#skDel').onclick=async()=>{if(!confirm('Supprimer ce skill ?'))return;await api('/api/skills/'+encodeURIComponent(skEdit),{method:'DELETE'});close('ske');openSkills()};
$('#skImp').onclick=async()=>{const u=$('#skUrl').value.trim();if(!u)return toast('Colle une URL');
  const r=await(await post('/api/skills/import',{url:u})).json();if(r.error)return toast('Échec : '+r.error);close('ske');toast('Skill importé : '+r.name);openSkills()};
/* ---------- page Réglages ---------- */
const SCHEMA=[
 {h:'Modèle',items:[
  {k:'backend',t:'seg',l:'Backend',o:[['','Aucun'],['omni','OmniRoute']]},
  {t:'btn',l:'Ouvrir le dashboard OmniRoute',c:()=>openDash()},
  {k:'autoStart',t:'sw',l:'Démarrer OmniRoute automatiquement'},
  {k:'model',t:'text',l:'Modèle / combo',s:'Ex : Claudeui, auto',pick:1},
  {k:'fast',t:'text',l:'Modèle rapide',s:'Tâches de fond. Vide = même modèle'},
  {k:'fallback',t:'text',l:'Modèle de secours',s:'Utilisé si le principal est saturé'},
  {k:'thinking',t:'seg',l:'Budget de réflexion',o:[['','Auto'],['4000','Court'],['16000','Moyen'],['32000','Long']]}]},
 {h:'Comportement',items:[
  {k:'mode',t:'seg',l:'Permissions',o:[['acceptEdits','Modifs auto'],['plan','Plan'],['bypassPermissions','Tout']]},
  {k:'tools',t:'chips',l:'Outils autorisés',o:ALL},
  {t:'btn',l:'Gérer mes skills',c:()=>openSkills()},
  {k:'maxTurns',t:'num',l:'Étapes maximum',s:'0 = illimité'},
  {k:'lang',t:'seg',l:'Langue des réponses',o:[['','Auto'],['fr','Français'],['en','English']]},
  {k:'append',t:'area',l:'Consignes supplémentaires',s:'Ajoutées au prompt système'}]},
 {h:'Projet',items:[
  {k:'cwd',t:'text',l:'Dossier de travail',s:'Ex : ~/claude-ui'},
  {k:'addDirs',t:'area',l:'Dossiers supplémentaires',s:'Un par ligne'}]},
 {h:'Apparence',items:[
  {k:'theme',t:'seg',l:'Thème',o:[['auto','Auto'],['dark','Sombre'],['light','Clair']]},
  {k:'accent',t:'color',l:'Couleur (✦ = couleurs de ton Pixel)'},
  {k:'fontSize',t:'range',l:'Taille du texte',min:14,max:20},
  {k:'showThink',t:'seg',l:'Réflexion du modèle',o:[['open','Ouverte'],['closed','Repliée'],['hide','Masquée']]},
  {k:'toolsOpen',t:'sw',l:'Détails des outils dépliés'}]},
 {h:'Avancé',items:[
  {k:'env',t:'area',l:'Variables d’environnement',s:'CLE=valeur, une par ligne'},
  {t:'btn',l:'Effacer tout l’historique',c:async()=>{if(!confirm('Effacer toutes les conversations ?'))return;const l=(await(await api('/api/conv')).json()).list||[];for(const c of l)await api('/api/conv/'+c.id,{method:'DELETE'});newConv();toast('Historique effacé')}},
  {t:'btn',l:'Réinitialiser les réglages',c:()=>{if(!confirm('Revenir aux réglages par défaut ?'))return;Object.assign(cfg,DEF,{tools:ALL.slice()});save();apply();chips();renderSettings();toast('Réglages réinitialisés')}}]}];
function ctl(it){const v=cfg[it.k];let w;
  const set=x=>{cfg[it.k]=x;save();apply();chips()};
  if(it.t==='seg'){w=$$('div','seg');it.o.forEach(([val,lab])=>{const b=$$('button',String(v)===String(val)?'on':'',lab);b.onclick=()=>{set(val);[...w.children].forEach(c=>c.classList.remove('on'));b.classList.add('on')};w.append(b)})}
  else if(it.t==='chips'){w=$$('div','chs');it.o.forEach(n=>{const b=$$('button',v.includes(n)?'on':'',n);b.onclick=()=>{const a=new Set(cfg[it.k]);a.has(n)?a.delete(n):a.add(n);set([...a]);b.classList.toggle('on')};w.append(b)})}
  else if(it.t==='sw'){w=$$('input','sw');w.type='checkbox';w.checked=!!v;w.onchange=()=>set(w.checked)}
  else if(it.t==='range'){w=$$('input');w.type='range';w.min=it.min;w.max=it.max;w.value=v;w.style.cssText='width:100%;accent-color:var(--ac)';w.oninput=()=>set(+w.value)}
  else if(it.t==='color'){w=$$('div','chs');[...(window.Android&&Android.dynamicColor&&Android.dynamicColor()?['dyn']:[]),...ACC].forEach(c=>{const b=$$('button','dot'+(v===c?' on':''));b.style.background=c==='dyn'?'conic-gradient(#7c6cf0,#2f9e8f,#3b82f6,#d6477a,#7c6cf0)':c;b.onclick=()=>{set(c);[...w.children].forEach(x=>x.classList.remove('on'));b.classList.add('on')};w.append(b)})}
  else if(it.t==='btn'){w=$$('button','tn',it.l);w.style.width='100%';w.onclick=it.c}
  else if(it.t==='area'){w=$$('textarea','f');w.rows=3;w.value=v||'';w.oninput=()=>set(w.value)}
  else{w=$$('input','f');w.type=it.t==='num'?'number':'text';w.value=v||'';w.autocapitalize='off';w.oninput=()=>set(it.t==='num'?(+w.value||0):w.value.trim())}
  return w}
function row(it){const inl=it.t==='sw',r=$$('div','it2'+(inl?' inl':''));
  if(it.t!=='btn'){r.append($$('div','','<div class="t">'+it.l+'</div>'+(it.s?'<div class="s">'+it.s+'</div>':'')))}
  const w=ctl(it);w.classList.add('ctl');r.append(w);
  if(it.pick){const b=$$('button','tn','Choisir dans la liste');b.style.marginTop='8px';b.onclick=()=>openPick();r.append(b)}
  return r}
const btn=(l,a,c)=>'<button class="'+(c||'tn')+'" onclick="provAct(\''+a+'\')">'+l+'</button>';
const step=(n,ok,t,s,a)=>'<div class="stp'+(ok?' ok':'')+'"><b>'+(ok?'✓':n)+'</b><div><div class="t">'+t+'</div><div class="s">'+s+'</div>'+(a||'')+'</div></div>';
const kin=(id,ph)=>'<input class="f" type="password" placeholder="'+ph+'" value="'+esc(kv[id])+'" oninput="kv.'+id+'=this.value" autocomplete="off">';
let diag='';
function provHTML(){const o=st.omni;
  return '<div class="sec">OmniRoute</div><div class="card"><div class="ph">Assistant de démarrage <span class="st'+(o.up?' ok':'')+'">'+(o.up?'en marche':'arrêté')+'</span></div>'+
  '<div class="s" style="padding:0 20px 6px">OmniRoute relie Claude Code à des modèles gratuits. Chaque étape se coche toute seule.</div>'+
  step(1,o.installed,'Installer OmniRoute',o.installing?'Installation en cours (quelques minutes)…':'Une seule fois.',o.installed||o.installing?'':btn('Installer','installO','pri'))+
  step(2,o.up,'Démarrer','Lance OmniRoute sur ton téléphone.',o.installed&&!o.up?btn('Démarrer','startO','pri'):'')+
  step(3,false,'Connecter un fournisseur','Dashboard → Providers : connecte au moins un fournisseur (beaucoup offrent un accès gratuit). Puis crée un combo dans Combos.',o.up?btn('Ouvrir le dashboard','dashO'):'')+
  step(4,o.hasKey,'Créer et coller la clé API','Dashboard → API Keys : crée une clé, copie-la, colle-la ici.',kin('O','Clé OmniRoute')+btn('Enregistrer','keyO'))+
  step(5,cfg.backend==='omni'&&!!cfg.model,'Choisir ton combo','<b>'+(cfg.model?esc(cfg.model):'Aucun')+'</b>',btn('Choisir dans la liste','pickO','pri'))+
  step(6,diag.startsWith('✓'),'Tester un envoi','<span>'+esc(diag||'Envoie un vrai message de test.')+'</span>',btn('Tester','testO','pri'))+'</div>'}
function refreshProv(){const b=$('#prov');if(!b||!$('#setView').classList.contains('open'))return;
  const a=document.activeElement;if(a&&a.tagName==='INPUT'&&b.contains(a))return;b.innerHTML=provHTML()}
async function provAct(a){
  if(a==='installO'){await post('/api/omni/install');toast('Installation lancée : garde l’app ouverte')}
  else if(a==='startO'){await post('/api/omniroute/start');toast('Démarrage…')}
  else if(a==='dashO')return openDash();
  else if(a==='pickO')return openPick();
  else if(a==='keyO'){const v=kv.O.trim();if(!v)return toast('Colle d’abord la clé');await post('/api/setup',{key:v,backend:'omni'});kv.O='';toast('Clé enregistrée ✓')}
  else if(a==='testO'){diag='Test en cours…';refreshProv();await poll();
    if(!st.omni.up)diag='✗ OmniRoute est arrêté (étape 2).';
    else if(!st.omni.hasKey)diag='✗ Clé manquante (étape 4).';
    else if(!cfg.model)diag='✗ Choisis d’abord un combo (étape 5).';
    else{const r=await(await post('/api/omni/test',{model:cfg.model})).json();
      diag=r.ok?'✓ Ça marche ! Réponse en '+(r.ms/1000).toFixed(1)+' s':'✗ '+hintOf(r.status,r.error)}}
  await poll();refreshProv()}
function renderSettings(){const b=$('#setBody');b.innerHTML='';
  if(welcome)b.append($$('div','wc','<b>Bienvenue 👋</b><div class="s" style="margin-top:6px">Suis l’assistant OmniRoute ci-dessous (6 étapes, 3 minutes), ou reviens au chat avec ← pour passer.</div>'));
  const pv=$$('div');pv.id='prov';pv.innerHTML=provHTML();b.append(pv);
  SCHEMA.forEach(sec=>{b.append($$('div','sec',sec.h));const c=$$('div','card');sec.items.forEach(it=>c.append(row(it)));b.append(c)});
  poll()}
function route(){const on=location.hash==='#settings';if(window.Android&&Android.onRoute)Android.onRoute(on);$('#setView').classList.toggle('open',on);
  if(on)renderSettings();else if(welcome){welcome=false;localStorage.setItem('setupDone','1')}}
addEventListener('hashchange',route);
$('#cog').onclick=()=>{location.hash='settings'};$('#back').onclick=()=>history.back();
(async()=>{
  apply();history.replaceState(null,'',location.pathname);
  let first=false;
  try{const sc=await(await api('/api/config')).json();if(sc.cfg)Object.assign(cfg,sc.cfg);
    if(cfg.omni&&!cfg.backend)cfg.backend='omni';delete cfg.omni;if(cfg.backend==='free')cfg.backend='';if(!Array.isArray(cfg.tools))cfg.tools=ALL.slice();
    if(!cfg.skMig){cfg.tools=[...new Set([...cfg.tools,'Skill'])];cfg.skMig=1;save()}
    apply();
    if(!sc.setupDone&&!localStorage.getItem('setupDone')){post('/api/config',{setupDone:true});first=true}}catch{}
  chips();const s=await poll();
  if(convId)await loadConv(convId);else empty();
  if(s&&s.runId&&s.runId!==localStorage.getItem('runSaved'))follow(null);
  if(first){welcome=true;location.hash='settings'}
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
