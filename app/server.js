#!/usr/bin/env node
'use strict';

// ═══════════════════════════════════════════════════════════
// Bot Manager — Node.js Backend v3.0
// Express + JWT + SSE logs + child_process
// ═══════════════════════════════════════════════════════════

const http   = require('http');
const https  = require('https');
const fs     = require('fs');
const path   = require('path');
const crypto = require('crypto');
const {spawn, execSync, spawnSync} = require('child_process');
const {EventEmitter} = require('events');
const os     = require('os');
const url    = require('url');

const PORT   = parseInt(process.env.PORT || '5000');
const PD     = process.env.PANEL_DIR   || '/opt/botpanel';
const BD     = process.env.BOTS_DIR    || '/opt/botpanel/bots';
const SVC    = '/etc/systemd/system/botpanel.service';
const VER    = '3.0.0';
const DRAM   = 256;

let HASH   = process.env.BOTPANEL_HASH   || '';
let TOKEN  = process.env.BOTPANEL_TOKEN  || '';
let SECRET = process.env.BOTPANEL_SECRET || crypto.randomBytes(32).toString('hex');

// ── Helpers ───────────────────────────────────────────────
const b64u = s => Buffer.from(s).toString('base64url');
const je   = o => JSON.stringify(o);

function signJwt(payload) {
  const h = b64u(je({alg:'HS256',typ:'JWT'}));
  const b = b64u(je(payload));
  const s = crypto.createHmac('sha256',SECRET).update(`${h}.${b}`).digest('base64url');
  return `${h}.${b}.${s}`;
}
function verifyJwt(tok) {
  try {
    const [h,b,s] = tok.split('.');
    const exp = crypto.createHmac('sha256',SECRET).update(`${h}.${b}`).digest('base64url');
    if (!crypto.timingSafeEqual(Buffer.from(s,'base64url'),Buffer.from(exp,'base64url'))) return null;
    const p = JSON.parse(Buffer.from(b,'base64url').toString());
    if (p.exp && p.exp < Date.now()/1000) return null;
    return p;
  } catch { return null; }
}

function checkBcrypt(pw, hash) {
  const r = spawnSync('python3',['-c',
    `import bcrypt,sys;sys.exit(0 if bcrypt.checkpw(sys.argv[1].encode(),sys.argv[2].encode()) else 1)`,
    pw, hash], {timeout:8000});
  return r.status === 0;
}
function hashBcrypt(pw) {
  const r = spawnSync('python3',['-c',
    `import bcrypt,sys;print(bcrypt.hashpw(sys.argv[1].encode(),bcrypt.gensalt()).decode())`,
    pw], {timeout:10000, encoding:'utf8'});
  if (r.status !== 0) throw new Error('bcrypt failed');
  return r.stdout.trim();
}

function safeExec(cmd, opts={}) {
  try { return {ok:true, out:execSync(cmd,{stdio:'pipe',timeout:5000,...opts}).toString().trim()}; }
  catch(e) { return {ok:false, out:e.stderr?.toString()||e.message}; }
}

function validPid(p) { return typeof p==='string' && /^[a-z0-9_]{1,64}$/.test(p); }
function botDir(pid) { return path.join(BD, pid); }
function metaFile(pid) { return path.join(BD, pid, '.bm.json'); }
function safeJoin(base, rel) {
  const r = path.resolve(base, rel);
  if (!r.startsWith(path.resolve(base)+path.sep) && r!==path.resolve(base)) throw new Error('Traversal');
  return r;
}
function readMeta(pid) {
  try { return JSON.parse(fs.readFileSync(metaFile(pid),'utf8')); } catch { return {}; }
}
function writeMeta(pid, m) { fs.writeFileSync(metaFile(pid), je(m,null,2)); }

function updateSvc(key, val) {
  if (!fs.existsSync(SVC)) return;
  let c = fs.readFileSync(SVC,'utf8');
  const re = new RegExp(`(Environment="${key.replace(/[.*+?^${}()|[\]\\]/g,'\\$&')}=)[^"]*(")`, 'g');
  if (re.test(c)) c = c.replace(re, `$1${val}$2`);
  else c = c.replace('[Service]\n', `[Service]\nEnvironment="${key}=${val}"\n`);
  fs.writeFileSync(SVC, c);
  safeExec('systemctl daemon-reload');
}

// ── State ─────────────────────────────────────────────────
const procs  = {};
const tstart = {};
const logBus = new EventEmitter();
const logBuf = {}; // pid -> string[]
logBus.setMaxListeners(500);

function logPush(pid, line) {
  if (!logBuf[pid]) logBuf[pid] = [];
  logBuf[pid].push(line);
  if (logBuf[pid].length > 3000) logBuf[pid].shift();
  logBus.emit(pid, line);
}

// ── Activity log ──────────────────────────────────────────
const activityLog = []; // global activity feed
function activity(type, pid, msg) {
  activityLog.unshift({type, pid, msg, ts: new Date().toISOString()});
  if (activityLog.length > 200) activityLog.pop();
}

// ── HTTP router ───────────────────────────────────────────
const routes = [];
function route(method, pattern, ...handlers) {
  const keys = [];
  const rx = new RegExp('^' + pattern.replace(/:([^/]+)/g, (_,k) => { keys.push(k); return '([^/]+)'; })
    .replace(/\*/g,'(.*)') + '(?:\\?.*)?$');
  routes.push({method, rx, keys, handlers});
}

function auth(req) {
  const h = req.headers['authorization'] || '';
  const t = h.startsWith('Bearer ') ? h.slice(7) : (new URLSearchParams(req._qs||'').get('token')||'');
  if (!t) return false;
  if (TOKEN && t.length===TOKEN.length && crypto.timingSafeEqual(Buffer.from(t),Buffer.from(TOKEN))) return true;
  return !!verifyJwt(t);
}
function needAuth(req, res, next) {
  if (!auth(req)) return send(res, 401, {error:'Unauthorized'});
  next();
}

function send(res, status, data, ct='application/json') {
  const body = typeof data === 'string' ? data : je(data);
  res.writeHead(status, {'Content-Type':ct,'Access-Control-Allow-Origin':'*'});
  res.end(body);
}
function sendFile(res, fp, ct='application/octet-stream') {
  res.writeHead(200,{'Content-Type':ct,'Access-Control-Allow-Origin':'*'});
  fs.createReadStream(fp).pipe(res);
}

// Parse multipart/form-data without deps
function parseMultipart(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    req.on('data', c => chunks.push(c));
    req.on('end', () => {
      const buf = Buffer.concat(chunks);
      const ct  = req.headers['content-type'] || '';
      const m   = ct.match(/boundary=([^\s;]+)/);
      if (!m) return resolve({fields:{}, files:{}});
      const boundary = '--' + m[1];
      const parts = [];
      let pos = 0;
      const bBuf = Buffer.from(boundary);
      while (pos < buf.length) {
        const idx = buf.indexOf(bBuf, pos);
        if (idx === -1) break;
        const end = buf.indexOf(bBuf, idx + bBuf.length);
        const part = buf.slice(idx + bBuf.length + 2, end === -1 ? buf.length : end - 2);
        const hdEnd = part.indexOf('\r\n\r\n');
        if (hdEnd === -1) { pos = idx + 1; continue; }
        const hd = part.slice(0, hdEnd).toString();
        const body = part.slice(hdEnd + 4);
        const nameMx = hd.match(/name="([^"]+)"/);
        const fileMx = hd.match(/filename="([^"]+)"/);
        if (nameMx) parts.push({name:nameMx[1], filename:fileMx?.[1], body});
        pos = idx + 1;
      }
      const fields = {}, files = {};
      for (const p of parts) {
        if (p.filename) files[p.name] = {filename:p.filename, buffer:p.body};
        else fields[p.name] = p.body.toString().replace(/\r\n$/,'');
      }
      resolve({fields, files});
    });
    req.on('error', reject);
  });
}

// Parse JSON body
function parseBody(req) {
  return new Promise((resolve, reject) => {
    let raw = '';
    req.on('data', c => raw += c);
    req.on('end', () => {
      try { resolve(raw ? JSON.parse(raw) : {}); }
      catch { resolve({}); }
    });
    req.on('error', reject);
  });
}

// ── Rate limiting ─────────────────────────────────────────
const rl = {}; // key -> [{ts}]
function rateLimit(key, n, windowMs) {
  const now = Date.now();
  if (!rl[key]) rl[key] = [];
  rl[key] = rl[key].filter(t => now - t < windowMs);
  if (rl[key].length >= n) return false;
  rl[key].push(now);
  return true;
}

// ── Request handler ───────────────────────────────────────
const server = http.createServer(async (req, res) => {
  const parsed = url.parse(req.url, true);
  req._path = parsed.pathname;
  req._qs   = parsed.search ? parsed.search.slice(1) : '';
  req._query= parsed.query;

  // CORS preflight
  res.setHeader('Access-Control-Allow-Origin','*');
  res.setHeader('Access-Control-Allow-Headers','Content-Type,Authorization');
  res.setHeader('Access-Control-Allow-Methods','GET,POST,PUT,DELETE,OPTIONS');
  if (req.method === 'OPTIONS') { res.writeHead(200); res.end(); return; }

  // Static files
  const staticDir = path.join(PD, 'static');
  if (req.method==='GET' && !req._path.startsWith('/api') && !req._path.startsWith('/webhook')) {
    const fp = req._path === '/' ? path.join(staticDir,'index.html') : path.join(staticDir, req._path.slice(1));
    const safe = path.resolve(fp);
    if (safe.startsWith(staticDir) && fs.existsSync(safe) && fs.statSync(safe).isFile()) {
      const ext = path.extname(safe);
      const ct  = {'.html':'text/html','.js':'text/javascript','.css':'text/css','.png':'image/png','.svg':'image/svg+xml'}[ext]||'application/octet-stream';
      if (ext==='.html') {
        res.writeHead(200,{'Content-Type':'text/html','Cache-Control':'no-store,no-cache,must-revalidate,max-age=0','Pragma':'no-cache'});
      } else {
        res.writeHead(200,{'Content-Type':ct});
      }
      fs.createReadStream(safe).pipe(res);
      return;
    }
    // SPA fallback
    const idx = path.join(staticDir,'index.html');
    if (fs.existsSync(idx)) {
      res.writeHead(200,{'Content-Type':'text/html','Cache-Control':'no-store,no-cache,must-revalidate'});
      fs.createReadStream(idx).pipe(res);
    } else { send(res,404,'Not found','text/plain'); }
    return;
  }

  // Match route
  for (const {method, rx, keys, handlers} of routes) {
    if (method !== req.method && method !== '*') continue;
    const m = req._path.match(rx);
    if (!m) continue;
    req.params = {};
    keys.forEach((k,i) => req.params[k] = decodeURIComponent(m[i+1]||''));
    req.query  = req._query;

    // Parse body for non-GET/SSE
    if (!['GET','DELETE'].includes(req.method) && req.headers['content-type']?.includes('application/json')) {
      req.body = await parseBody(req);
    } else { req.body = {}; }

    let i = 0;
    const next = () => { if (i < handlers.length) handlers[i++](req, res, next); };
    next();
    return;
  }

  send(res, 404, {error:'Not found'});
});

// ═══════════════════════════════════════════════════════════
// API ROUTES
// ═══════════════════════════════════════════════════════════

// ── Auth ──────────────────────────────────────────────────
const loginLock = {};

route('POST','/api/login', async (req,res) => {
  const ip = req.socket.remoteAddress;
  const now = Date.now();
  const lk = loginLock[ip]||{n:0,until:0};
  if (lk.until > now) return send(res,429,{error:`Locked ${Math.ceil((lk.until-now)/1000)}s`});
  if (!rateLimit('login'+ip, 10, 60000)) return send(res,429,{error:'Rate limit'});

  const {password=''} = req.body;
  if (!password || !HASH) return send(res,401,{error:'Invalid'});
  const ok = checkBcrypt(password, HASH);
  if (!ok) {
    lk.n++; if (lk.n>=5){lk.until=now+900000;lk.n=0;} loginLock[ip]=lk;
    return send(res,401,{error:'Invalid password'});
  }
  loginLock[ip]={n:0,until:0};
  const token = signJwt({sub:'admin', exp:Math.floor(now/1000)+86400});
  send(res,200,{token, expires_in:86400});
});

route('GET','/api/ping', needAuth, (req,res) => {
  send(res,200,{ok:true, version:VER, ts:Math.floor(Date.now()/1000)});
});

// ── Panel settings ────────────────────────────────────────
route('POST','/api/panel/password', needAuth, async (req,res) => {
  const {password=''} = req.body;
  if (password.length < 4) return send(res,400,{error:'Too short'});
  try {
    const h = hashBcrypt(password);
    updateSvc('BOTPANEL_HASH', h); HASH = h;
    send(res,200,{ok:true});
  } catch(e) { send(res,500,{error:e.message}); }
});

route('GET','/api/panel/token', needAuth, (req,res) => send(res,200,{token:TOKEN}));

route('POST','/api/panel/token', needAuth, (req,res) => {
  try {
    const t = crypto.randomBytes(32).toString('base64url');
    updateSvc('BOTPANEL_TOKEN', t); TOKEN = t;
    send(res,200,{ok:true, token:t});
  } catch(e) { send(res,500,{error:e.message}); }
});

// ── Projects ──────────────────────────────────────────────
route('GET','/api/projects', needAuth, (req,res) => {
  if (!fs.existsSync(BD)) return send(res,200,[]);
  const out = [];
  for (const pid of fs.readdirSync(BD).sort()) {
    try {
      const d = path.join(BD,pid);
      if (!fs.statSync(d).isDirectory()) continue;
      const m = readMeta(pid);
      const proc = procs[pid];
      const running = !!proc && proc.exitCode===null;
      const up = running && tstart[pid] ? Math.floor((Date.now()-tstart[pid])/1000) : 0;
      out.push({id:pid, name:m.name||pid, token:m.token||'', created:m.created||'',
        running, main:m.main||'bot.py', autostart:!!m.autostart, uptime:up,
        ram_limit:m.ram_limit||DRAM, cpu_limit:m.cpu_limit||80,
        platform:m.platform||'telegram', lang:m.lang||'python'});
    } catch {}
  }
  send(res,200,out);
});

route('POST','/api/projects', needAuth, async (req,res) => {
  const {name='', token='', template='basic', lang='python', platform='telegram', restore_only=false} = req.body;
  if (!name.trim()) return send(res,400,{error:'Name required'});
  const pid = name.trim().toLowerCase().replace(/\s+/g,'_').replace(/[^a-z0-9_]/g,'').replace(/_+/g,'_').slice(0,64);
  if (!validPid(pid)) return send(res,400,{error:'Invalid name'});
  const bd = botDir(pid);
  if (fs.existsSync(bd)) return send(res,409,{error:'Already exists'});
  fs.mkdirSync(bd,{recursive:true});

  const mf = {python:'bot.py',php:'bot.php',ruby:'bot.rb',node:'bot.js'}[lang]||'bot.py';
  const rf = {python:'requirements.txt',php:'composer.json',ruby:'Gemfile',node:'package.json'}[lang];

  if (!restore_only) {
    fs.writeFileSync(path.join(bd,mf), makeBotTemplate(template,token,lang,platform));
    if (rf) fs.writeFileSync(path.join(bd,rf), makeDepsFile(lang,platform));
  }
  writeMeta(pid,{name:name.trim(), token, created:new Date().toISOString(), main:mf,
    autostart:false, template, platform, lang, ram_limit:DRAM, cpu_limit:80});
  logBuf[pid] = [];
  activity('create',pid,`Project "${name}" created`);
  setTimeout(()=>installDeps(pid).catch(()=>{}), 200);
  send(res,201,{id:pid, name:name.trim()});
});

route('DELETE','/api/projects/:pid', needAuth, (req,res) => {
  const {pid} = req.params;
  if (!validPid(pid)) return send(res,400,{error:'Invalid'});
  const bd = botDir(pid);
  if (!fs.existsSync(bd)) return send(res,404,{error:'Not found'});
  botStop(pid);
  delete logBuf[pid];
  fs.rmSync(bd,{recursive:true,force:true});
  const vd = path.join(PD,'bots_venv',pid);
  if (fs.existsSync(vd)) fs.rmSync(vd,{recursive:true,force:true});
  activity('delete',pid,`Project "${pid}" deleted`);
  send(res,200,{ok:true});
});

route('POST','/api/projects/:pid/rename', needAuth, async (req,res) => {
  const {pid} = req.params;
  const {name=''} = req.body;
  if (!name.trim()) return send(res,400,{error:'Name required'});
  if (!validPid(pid)||!fs.existsSync(botDir(pid))) return send(res,404,{error:'Not found'});
  const m = readMeta(pid); m.name = name.trim(); writeMeta(pid,m);
  activity('rename',pid,`Renamed to "${name}"`);
  send(res,200,{ok:true, name:name.trim()});
});

route('POST','/api/projects/:pid/autostart', needAuth, async (req,res) => {
  const {pid} = req.params;
  const {enabled=false} = req.body;
  if (!validPid(pid)) return send(res,400,{error:'Invalid'});
  const m = readMeta(pid); m.autostart = !!enabled; writeMeta(pid,m);
  send(res,200,{ok:true, autostart:!!enabled});
});

route('POST','/api/projects/:pid/limits', needAuth, async (req,res) => {
  const {pid} = req.params;
  const m = readMeta(pid);
  if (req.body.ram_limit!==undefined) m.ram_limit = parseInt(req.body.ram_limit)||DRAM;
  if (req.body.cpu_limit!==undefined) m.cpu_limit = parseInt(req.body.cpu_limit)||80;
  writeMeta(pid,m); send(res,200,{ok:true});
});

route('PUT','/api/projects/:pid/token', needAuth, async (req,res) => {
  const {pid} = req.params;
  const m = readMeta(pid); m.token = req.body.token||''; writeMeta(pid,m);
  send(res,200,{ok:true});
});

// ── ENV ───────────────────────────────────────────────────
route('GET','/api/projects/:pid/env', needAuth, (req,res) => {
  const {pid} = req.params;
  if (!validPid(pid)) return send(res,400,{error:'Invalid'});
  const ef = path.join(botDir(pid),'.env');
  send(res,200,{content: fs.existsSync(ef) ? fs.readFileSync(ef,'utf8') : ''});
});

route('PUT','/api/projects/:pid/env', needAuth, async (req,res) => {
  const {pid} = req.params;
  if (!validPid(pid)) return send(res,400,{error:'Invalid'});
  const ef = path.join(botDir(pid),'.env');
  fs.writeFileSync(ef, req.body.content||'', 'utf8');
  try { fs.chmodSync(ef,0o640); } catch {}
  activity('env',pid,'Config vars updated');
  send(res,200,{ok:true});
});

// ── Bot control ───────────────────────────────────────────
route('POST','/api/projects/:pid/start', needAuth, async (req,res) => {
  const {pid} = req.params;
  if (!validPid(pid)) return send(res,400,{error:'Invalid'});
  const [ok,r] = await botStart(pid);
  if (!ok) return send(res, r==='Already running'?409:500, {error:r});
  activity('start',pid,'Bot started');
  send(res,200,{ok:true, pid:r});
});

route('POST','/api/projects/:pid/stop', needAuth, (req,res) => {
  const {pid} = req.params;
  botStop(pid);
  activity('stop',pid,'Bot stopped');
  send(res,200,{ok:true});
});

route('POST','/api/projects/:pid/restart', needAuth, async (req,res) => {
  const {pid} = req.params;
  botStop(pid);
  await new Promise(r=>setTimeout(r,600));
  const [ok,r] = await botStart(pid);
  if (!ok) return send(res,500,{error:r});
  activity('restart',pid,'Bot restarted');
  send(res,200,{ok:true, pid:r});
});

// ── Files ─────────────────────────────────────────────────
route('GET','/api/projects/:pid/files', needAuth, (req,res) => {
  const {pid} = req.params;
  if (!validPid(pid)||!fs.existsSync(botDir(pid))) return send(res,404,{error:'Not found'});
  const bd = botDir(pid);
  const files = fs.readdirSync(bd)
    .filter(f=>!f.startsWith('.'))
    .map(f=>{
      const fp=path.join(bd,f); const st=fs.statSync(fp);
      return st.isFile() ? {name:f,size:st.size,modified:st.mtime.toISOString()} : null;
    }).filter(Boolean).sort((a,b)=>a.name.localeCompare(b.name));
  send(res,200,files);
});

route('GET','/api/projects/:pid/files/*', needAuth, (req,res) => {
  const {pid} = req.params; const fn = req.params[0]||'';
  try {
    const fp = safeJoin(botDir(pid),fn);
    if (!fs.existsSync(fp)) return send(res,404,{error:'Not found'});
    send(res,200,{name:fn, content:fs.readFileSync(fp,'utf8')});
  } catch(e) { send(res,403,{error:'Forbidden'}); }
});

route('PUT','/api/projects/:pid/files/*', needAuth, async (req,res) => {
  const {pid} = req.params; const fn = req.params[0]||'';
  try {
    const fp = safeJoin(botDir(pid),fn);
    fs.mkdirSync(path.dirname(fp),{recursive:true});
    fs.writeFileSync(fp, req.body.content||'','utf8');
    send(res,200,{ok:true, size:fs.statSync(fp).size});
  } catch(e) { send(res,403,{error:e.message}); }
});

route('DELETE','/api/projects/:pid/files/*', needAuth, (req,res) => {
  const {pid} = req.params; const fn = req.params[0]||'';
  try {
    const fp = safeJoin(botDir(pid),fn);
    if (!fs.existsSync(fp)) return send(res,404,{error:'Not found'});
    fs.unlinkSync(fp); send(res,200,{ok:true});
  } catch(e) { send(res,403,{error:e.message}); }
});

route('POST','/api/projects/:pid/files', needAuth, async (req,res) => {
  const {pid} = req.params; const {name=''} = req.body;
  if (!name||name.includes('..')||name.includes('/')) return send(res,400,{error:'Invalid name'});
  const fp = path.join(botDir(pid),name);
  if (fs.existsSync(fp)) return send(res,409,{error:'Exists'});
  fs.writeFileSync(fp,''); send(res,201,{ok:true});
});

// Upload via multipart
route('POST','/api/projects/:pid/upload', needAuth, async (req,res) => {
  const {pid} = req.params;
  if (!validPid(pid)) return send(res,400,{error:'Invalid'});
  try {
    const {files} = await parseMultipart(req);
    const f = files.file;
    if (!f) return send(res,400,{error:'No file'});
    const fn  = path.basename(f.filename||'upload');
    const dest = path.join(botDir(pid),fn);
    fs.writeFileSync(dest,f.buffer);
    send(res,201,{ok:true,name:fn,size:fs.statSync(dest).size});
  } catch(e) { send(res,500,{error:e.message}); }
});

route('GET','/api/projects/:pid/download/*', needAuth, (req,res) => {
  const {pid} = req.params; const fn = req.params[0]||'';
  try {
    const fp = safeJoin(botDir(pid),fn);
    if (!fs.existsSync(fp)) return send(res,404,'Not found','text/plain');
    res.writeHead(200,{'Content-Type':'application/octet-stream',
      'Content-Disposition':`attachment; filename="${path.basename(fn)}"`,
      'Access-Control-Allow-Origin':'*'});
    fs.createReadStream(fp).pipe(res);
  } catch(e) { send(res,403,{error:'Forbidden'}); }
});

// Backup as zip
route('GET','/api/projects/:pid/backup', needAuth, (req,res) => {
  const {pid} = req.params;
  if (!validPid(pid)||!fs.existsSync(botDir(pid))) return send(res,404,{error:'Not found'});
  const ts = new Date().toISOString().slice(0,19).replace('T','_').replace(/:/g,'-');
  const fname = `bot_${pid}_${ts}.zip`;
  try {
    const buf = execSync(`cd "${botDir(pid)}" && zip -r - . --exclude ".*"`,
      {maxBuffer:100*1024*1024, timeout:30000});
    res.writeHead(200,{'Content-Type':'application/zip',
      'Content-Disposition':`attachment; filename="${fname}"`,
      'Access-Control-Allow-Origin':'*'});
    res.end(buf);
  } catch(e) { send(res,500,{error:e.message}); }
});

// Restore from zip
route('POST','/api/projects/:pid/restore', needAuth, async (req,res) => {
  const {pid} = req.params;
  if (!validPid(pid)) return send(res,400,{error:'Invalid'});
  const bd = botDir(pid);
  if (!fs.existsSync(bd)) fs.mkdirSync(bd,{recursive:true});
  try {
    const {files} = await parseMultipart(req);
    const f = files.file;
    if (!f) return send(res,400,{error:'No file'});
    const tmp = path.join(os.tmpdir(),`restore_${pid}_${Date.now()}.zip`);
    fs.writeFileSync(tmp, f.buffer);
    execSync(`unzip -o "${tmp}" -d "${bd}"`,{timeout:30000,stdio:'pipe'});
    fs.unlinkSync(tmp);
    // auto-detect lang
    const m = readMeta(pid);
    if (!m.lang||m.lang==='python') {
      if (fs.existsSync(path.join(bd,'bot.js'))) { m.lang='node'; m.main='bot.js'; }
      else if (fs.existsSync(path.join(bd,'bot.rb'))) { m.lang='ruby'; m.main='bot.rb'; }
      else if (fs.existsSync(path.join(bd,'bot.php'))) { m.lang='php'; m.main='bot.php'; }
    }
    writeMeta(pid,m);
    const list = execSync(`unzip -Z1 "${tmp}" 2>/dev/null||true`).toString().trim().split('\n').filter(Boolean);
    activity('restore',pid,`Restored ${list.length} files`);
    send(res,200,{ok:true, files:list.length, lang:m.lang, main:m.main});
  } catch(e) { send(res,500,{error:e.message}); }
});

// ── Logs (SSE) ────────────────────────────────────────────
route('GET','/api/projects/:pid/logs', needAuth, (req,res) => {
  const {pid} = req.params;
  res.writeHead(200,{'Content-Type':'text/event-stream','Cache-Control':'no-cache',
    'X-Accel-Buffering':'no','Connection':'keep-alive','Access-Control-Allow-Origin':'*'});
  res.write('data: [00:00:00]|o|Connected\n\n');
  // replay buffer
  if (logBuf[pid]) for (const l of logBuf[pid]) res.write(`data: ${l.replace(/\n/g,' ')}\n\n`);
  const h = l => res.write(`data: ${l.replace(/\n/g,' ')}\n\n`);
  logBus.on(pid, h);
  const ka = setInterval(()=>res.write(':ka\n\n'),15000);
  req.on('close',()=>{ logBus.off(pid,h); clearInterval(ka); });
});

// ── Activity ──────────────────────────────────────────────
route('GET','/api/activity', needAuth, (req,res) => {
  const pid = req.query.pid;
  const list = pid ? activityLog.filter(a=>a.pid===pid) : activityLog;
  send(res,200,list.slice(0,50));
});

// ── Metrics ───────────────────────────────────────────────
route('GET','/api/projects/:pid/metrics', needAuth, (req,res) => {
  const {pid} = req.params;
  const proc = procs[pid];
  const running = !!proc && proc.exitCode===null;
  const up = running&&tstart[pid] ? Math.floor((Date.now()-tstart[pid])/1000) : 0;
  if (!running) return send(res,200,{running:false,cpu:0,ram:0,uptime:0,threads:0});
  try {
    const stat = fs.readFileSync(`/proc/${proc.pid}/status`,'utf8');
    const vmRss = parseInt((stat.match(/VmRSS:\s+(\d+)/)||[0,0])[1]);
    const threads = parseInt((stat.match(/Threads:\s+(\d+)/)||[0,1])[1]);
    const m = readMeta(pid);
    send(res,200,{running:true, pid:proc.pid, ram:Math.round(vmRss/1024),
      uptime:up, threads, ram_limit:m.ram_limit||DRAM, cpu_limit:m.cpu_limit||80});
  } catch { send(res,200,{running:true,pid:proc.pid,ram:0,uptime:up,threads:0}); }
});

route('GET','/api/system/metrics', needAuth, (req,res) => {
  try {
    const mem = fs.readFileSync('/proc/meminfo','utf8');
    const totKB = parseInt((mem.match(/MemTotal:\s+(\d+)/)||[0,0])[1]);
    const avlKB = parseInt((mem.match(/MemAvailable:\s+(\d+)/)||[0,0])[1]);
    const disk = execSync('df / --output=size,used -B1 | tail -1',{stdio:'pipe'}).toString().trim().split(/\s+/);
    const load = os.loadavg();
    const running = Object.values(procs).filter(p=>p.exitCode===null).length;
    const total = fs.existsSync(BD)?fs.readdirSync(BD).filter(p=>fs.statSync(path.join(BD,p)).isDirectory()).length:0;
    send(res,200,{
      cpu:Math.round(load[0]*100)/100, load_1:load[0],load_5:load[1],load_15:load[2],
      ram_total:Math.round(totKB/1024/1024*100)/100,
      ram_used:Math.round((totKB-avlKB)/1024/1024*100)/100,
      ram_percent:Math.round((totKB-avlKB)/totKB*100),
      disk_total:Math.round(parseInt(disk[0])/1e9*10)/10,
      disk_used:Math.round(parseInt(disk[1])/1e9*10)/10,
      disk_percent:Math.round(parseInt(disk[1])/parseInt(disk[0])*100),
      bots_running:running, bots_total:total,
    });
  } catch(e) { send(res,500,{error:e.message}); }
});

route('GET','/api/server/status', needAuth, (req,res) => {
  try {
    const uptime = parseFloat(fs.readFileSync('/proc/uptime','utf8').split(' ')[0]);
    const mem = fs.readFileSync('/proc/meminfo','utf8');
    const totKB = parseInt((mem.match(/MemTotal:\s+(\d+)/)||[0,0])[1]);
    const avlKB = parseInt((mem.match(/MemAvailable:\s+(\d+)/)||[0,0])[1]);
    const disk = execSync('df / --output=size,used -B1 | tail -1',{stdio:'pipe'}).toString().trim().split(/\s+/);
    const load = os.loadavg();
    const running = Object.values(procs).filter(p=>p.exitCode===null).length;
    const total = fs.existsSync(BD)?fs.readdirSync(BD).filter(p=>fs.statSync(path.join(BD,p)).isDirectory()).length:0;
    const panelOk = spawnSync('systemctl',['is-active','--quiet','botpanel'],{stdio:'pipe'}).status===0;
    const nginxOk = spawnSync('systemctl',['is-active','--quiet','nginx'],{stdio:'pipe'}).status===0;
    send(res,200,{
      uptime_sec:Math.round(uptime), load_1:load[0],load_5:load[1],load_15:load[2],
      ram_total:Math.round(totKB/1024/1024*100)/100,
      ram_used:Math.round((totKB-avlKB)/1024/1024*100)/100,
      ram_pct:Math.round((totKB-avlKB)/totKB*100),
      disk_total:Math.round(parseInt(disk[0])/1e9*10)/10,
      disk_used:Math.round(parseInt(disk[1])/1e9*10)/10,
      disk_pct:Math.round(parseInt(disk[1])/parseInt(disk[0])*100),
      panel_active:panelOk, nginx_active:nginxOk,
      bots_running:running, bots_total:total,
      hostname:os.hostname(), node:process.version,
    });
  } catch(e) { send(res,500,{error:e.message}); }
});

route('GET','/api/system/info', needAuth, (req,res) => {
  const se = cmd => { try{return execSync(cmd,{stdio:'pipe',timeout:3000}).toString().trim();}catch{return 'n/a';} };
  send(res,200,{
    version:VER, node:process.version,
    python:se('python3 --version').replace('Python ',''),
    ruby:se('ruby --version').split(' ')[1]||'n/a',
    php:se('php --version').split('\n')[0].split(' ')[1]||'n/a',
    os:`${os.type()} ${os.release()}`, hostname:os.hostname(),
    bots_total:fs.existsSync(BD)?fs.readdirSync(BD).filter(p=>fs.statSync(path.join(BD,p)).isDirectory()).length:0,
  });
});

// ── Server power ──────────────────────────────────────────
route('POST','/api/server/restart_panel', needAuth, async (req,res) => {
  const {mode='soft'} = req.body;
  if (mode==='hard') Object.keys(procs).forEach(pid=>botStop(pid));
  send(res,200,{ok:true,mode});
  activity('power','panel',`Panel ${mode} restart`);
  setTimeout(()=>spawn('sudo',['systemctl','restart','botpanel'],{detached:true,stdio:'ignore'}).unref(),300);
});

route('POST','/api/server/reboot', needAuth, async (req,res) => {
  const {mode='soft'} = req.body;
  send(res,200,{ok:true,mode});
  activity('power','server',`Server ${mode} reboot`);
  setTimeout(()=>{
    if (mode==='hard') {
      try {
        execSync('sudo sh -c "echo 1 > /proc/sys/kernel/sysrq"',{stdio:'pipe'});
        execSync('sudo sh -c "echo b > /proc/sysrq-trigger"',{stdio:'pipe'});
      } catch { spawn('sudo',['reboot','-f'],{detached:true,stdio:'ignore'}).unref(); }
    } else {
      spawn('sudo',['systemctl','reboot'],{detached:true,stdio:'ignore'}).unref();
    }
  },300);
});

route('POST','/api/server/update', needAuth, (req,res) => {
  send(res,200,{ok:true});
  setTimeout(()=>{
    for (const loc of ['/root/install.sh','/home/install.sh','/tmp/install.sh']) {
      if (fs.existsSync(loc)) { spawn('bash',[loc,'--update'],{detached:true,stdio:'ignore'}).unref(); return; }
    }
    spawn('sudo',['systemctl','restart','botpanel'],{detached:true,stdio:'ignore'}).unref();
  },300);
});

// ── Diagnose ──────────────────────────────────────────────
route('POST','/api/projects/:pid/diagnose', needAuth, async (req,res) => {
  const {pid} = req.params;
  if (!validPid(pid)) return send(res,400,{error:'Invalid'});
  const m = readMeta(pid); const bd = botDir(pid); const results = [];
  results.push({check:'Token set',ok:!!m.token,msg:m.token?m.token.slice(0,14)+'…':'Not set'});
  if (m.token && m.platform==='telegram') {
    try {
      const r = await new Promise((resolve,reject)=>{
        const u = new URL(`https://api.telegram.org/bot${m.token}/getMe`);
        https.get(u.toString(), res2=>{
          let d=''; res2.on('data',c=>d+=c); res2.on('end',()=>resolve(JSON.parse(d)));
        }).on('error',reject);
      });
      if (r.ok) results.push({check:'Token valid',ok:true,msg:'@'+r.result.username});
      else results.push({check:'Token valid',ok:false,msg:r.description||'Bad token'});
    } catch(e) { results.push({check:'Token valid',ok:false,msg:e.message}); }
  }
  const rf = {python:'requirements.txt',php:'composer.json',ruby:'Gemfile',node:'package.json'}[m.lang||'python'];
  results.push({check:'Deps file',ok:fs.existsSync(path.join(bd,rf||'')),msg:rf||'n/a'});
  const envFile = path.join(bd,'.env');
  results.push({check:'.env file',ok:fs.existsSync(envFile),msg:fs.existsSync(envFile)?'Present':'Not found'});
  results.push({check:'Bot running',ok:!!procs[pid]&&procs[pid].exitCode===null,msg:procs[pid]?.exitCode===null?'Running':'Stopped'});
  send(res,200,{results});
});

// ── Webhook proxy ─────────────────────────────────────────
const webhookHandler = async (req,res) => {
  const {pid} = req.params;
  if (!validPid(pid)) return send(res,400,{error:'Invalid'});
  const m = readMeta(pid);
  if (!m.webhook_port) return send(res,503,'Bot webhook not configured','text/plain');
  const sub = req.params[0]||'/';
  const qs  = req._qs ? '?'+req._qs : '';
  const target = `http://127.0.0.1:${m.webhook_port}${sub}${qs}`;
  const chunks=[]; req.on('data',c=>chunks.push(c));
  req.on('end',()=>{
    const body = Buffer.concat(chunks);
    const u = new URL(target);
    const opts={hostname:u.hostname,port:u.port,path:u.pathname+u.search,method:req.method,
      headers:{...req.headers,host:u.host,'content-length':body.length}};
    const pr = http.request(opts, upstream=>{
      res.writeHead(upstream.statusCode, upstream.headers);
      upstream.pipe(res);
    });
    pr.on('error',()=>res.end('Bot not running'));
    pr.end(body);
  });
};
route('*','/webhook/:pid', webhookHandler);
route('*','/webhook/:pid/*', webhookHandler);

// ═══════════════════════════════════════════════════════════
// BOT PROCESS MANAGEMENT
// ═══════════════════════════════════════════════════════════
async function botStart(pid) {
  if (!fs.existsSync(botDir(pid))) return [false,'Not found'];
  if (procs[pid]?.exitCode===null) return [false,'Already running'];
  try { await installDeps(pid); } catch(e) { logPush(pid,`[${ts()}]|w|[deps] ${e.message}`); }
  const m   = readMeta(pid);
  const cmd = getCmd(pid,m);
  const env = getEnv(pid,m);
  if (!logBuf[pid]) logBuf[pid]=[];
  logPush(pid,`[${ts()}]|o|Starting "${pid}" (${path.basename(cmd[0])})...`);
  const proc = spawn(cmd[0],cmd.slice(1),{cwd:botDir(pid),env:{...process.env,...env},stdio:['ignore','pipe','pipe']});
  procs[pid]=proc; tstart[pid]=Date.now();
  const streamLine = stream => {
    let buf='';
    stream.on('data',chunk=>{
      buf+=chunk.toString();
      const lines=buf.split('\n'); buf=lines.pop();
      for (const l of lines) logPush(pid,`[${ts()}]|${classify(l)}|${l}`);
    });
  };
  streamLine(proc.stdout); streamLine(proc.stderr);
  proc.once('exit',code=>{
    delete procs[pid]; delete tstart[pid];
    logPush(pid,`[${ts()}]|wd|[WD] Crashed rc=${code}, restart in 3s...`);
    setTimeout(async()=>{
      const m2=readMeta(pid);
      if (m2.autostart!==false&&!procs[pid]) {
        const [ok,r]=await botStart(pid);
        logPush(pid,`[${ts()}]|wd|[WD] Restart: ${ok?'OK pid='+r:'FAIL '+r}`);
      }
    },3000);
  });
  // RAM watchdog
  const wd=setInterval(()=>{
    if (!procs[pid]||procs[pid].exitCode!==null){clearInterval(wd);return;}
    try {
      const st=fs.readFileSync(`/proc/${proc.pid}/status`,'utf8');
      const ram=parseInt((st.match(/VmRSS:\s+(\d+)/)||[0,0])[1])/1024;
      const lim=(readMeta(pid).ram_limit||DRAM);
      if(ram>lim){logPush(pid,`[${ts()}]|wd|[WD] RAM ${ram.toFixed(0)}>${lim}MB, killing`);proc.kill('SIGKILL');}
    } catch {}
  },10000);
  return [true,proc.pid];
}

function botStop(pid) {
  const p=procs[pid];
  if (p?.exitCode===null) {
    p.removeAllListeners('exit');
    p.kill('SIGTERM');
    setTimeout(()=>{try{p.kill('SIGKILL');}catch{}},5000);
  }
  delete procs[pid]; delete tstart[pid];
}

const ts = ()=>new Date().toTimeString().slice(0,8);
const classify = l=>/\b(error|exception|traceback|critical|fatal)\b/i.test(l)?'e':/\b(warn|warning)\b/i.test(l)?'w':l.startsWith('[WD]')?'wd':'o';

function getCmd(pid,m){
  const lang=m.lang||'python', main=m.main||'bot.py';
  if (m.run_cmd) return m.run_cmd.split(' ');
  if (lang==='python'){const py=path.join(PD,'bots_venv',pid,'bin','python3');return[fs.existsSync(py)?py:'python3',main];}
  if (lang==='node') return ['node',main];
  if (lang==='php')  return ['php',main];
  if (lang==='ruby'){
    const bd2=path.join(PD,'bots_venv',pid,'ruby_gems');
    const gf=path.join(botDir(pid),'Gemfile');
    const hasGems=fs.existsSync(bd2)&&fs.readdirSync(bd2).length>0;
    return hasGems&&fs.existsSync(gf)?['bundle','exec','ruby',main]:['ruby',main];
  }
  return ['python3',main];
}

function getEnv(pid,m){
  const lang=m.lang||'python';
  const e={HOME:botDir(pid),BOT_DIR:botDir(pid),PYTHONUNBUFFERED:'1'};
  if(m.token) e.BOT_TOKEN=m.token;
  if(m.webhook_port) e.WEBHOOK_PORT=String(m.webhook_port);
  if(m.platform) e.BOT_PLATFORM=m.platform;
  // .env file
  const ef=path.join(botDir(pid),'.env');
  if(fs.existsSync(ef)){
    for(const line of fs.readFileSync(ef,'utf8').split('\n')){
      const l=line.trim();
      if(!l||l.startsWith('#')||!l.includes('=')) continue;
      const [k,...vs]=l.split('='); const v=vs.join('=').trim().replace(/^["']|["']$/g,'');
      if(k.trim()) e[k.trim()]=v;
    }
  }
  if(lang==='ruby'){
    const bd2=path.join(PD,'bots_venv',pid,'ruby_gems');
    e.BUNDLE_PATH=bd2; e.BUNDLE_GEMFILE=path.join(botDir(pid),'Gemfile');
    const cfgP=path.join(PD,'.ruby_gem_dir');
    const sys=fs.existsSync(cfgP)?fs.readFileSync(cfgP,'utf8').trim():'/usr/local/bundle';
    try{const gp=execSync('gem environment gempath',{stdio:'pipe',timeout:5000}).toString().trim();
      e.GEM_PATH=[bd2,sys,...gp.split(':')].filter(Boolean).join(':');}
    catch{e.GEM_PATH=[bd2,sys].join(':');}
    e.GEM_HOME=bd2;
  }
  if(lang==='node'){
    try{const gm=execSync('npm root -g',{stdio:'pipe',timeout:5000}).toString().trim();
      e.NODE_PATH=[path.join(botDir(pid),'node_modules'),gm].filter(Boolean).join(':');}catch{}
  }
  return e;
}

async function installDeps(pid){
  const m=readMeta(pid); const lang=m.lang||'python'; const bd=botDir(pid);
  const log=msg=>logPush(pid,`[${ts()}]|o|[deps] ${msg}`);
  if(lang==='python'){
    const vd=path.join(PD,'bots_venv',pid);
    if(!fs.existsSync(vd)){log('Creating venv...');execSync(`python3 -m venv "${vd}"`,{timeout:60000,stdio:'pipe'});}
    const rf=path.join(bd,'requirements.txt');
    if(fs.existsSync(rf)){
      log('Installing Python packages...');
      try{execSync(`"${path.join(vd,'bin','pip')}" install --quiet --no-cache-dir -r "${rf}"`,{timeout:300000,stdio:'pipe'});log('OK');}
      catch(e){log('pip FAILED: '+e.stderr?.toString().slice(0,200));}
    }
  } else if(lang==='node'){
    const pf=path.join(bd,'package.json');
    if(fs.existsSync(pf)){
      log('Installing Node.js packages...');
      try{execSync(`npm install --prefix "${bd}" --no-audit --no-fund`,{cwd:bd,timeout:300000,stdio:'pipe'});log('OK');}
      catch{log('npm failed, using global fallback');
        try{const gm=execSync('npm root -g',{timeout:5000,stdio:'pipe'}).toString().trim();
          const nm=path.join(bd,'node_modules');
          if(!fs.existsSync(nm)&&gm&&fs.existsSync(gm)){fs.symlinkSync(gm,nm);log('Linked global node_modules');}
        }catch{}
      }
    }
  } else if(lang==='ruby'){
    const gf=path.join(bd,'Gemfile');
    if(fs.existsSync(gf)){
      log('Installing Ruby gems...');
      const bd2=path.join(PD,'bots_venv',pid,'ruby_gems');
      try{execSync(`bundle install`,{cwd:bd,timeout:300000,stdio:'pipe',
        env:{...process.env,BUNDLE_PATH:bd2,BUNDLE_GEMFILE:gf,HOME:bd}});log('OK');}
      catch(e){log('bundle failed: '+e.stderr?.toString().slice(0,150));
        const gems=(fs.readFileSync(gf,'utf8').split('\n')
          .filter(l=>l.trim().startsWith('gem '))
          .map(l=>l.trim().split(/\s+/)[1]?.replace(/['"]/g,'')).filter(Boolean));
        for(const g of gems){
          try{execSync(`gem install ${g} --no-document`,{timeout:120000,stdio:'pipe'});log(`${g}: OK`);}
          catch{log(`${g}: FAILED`);}
        }
      }
    }
  } else if(lang==='php'){log('PHP: using built-in extensions');}
}

// ── Bot templates ─────────────────────────────────────────
function makeDepsFile(lang,plat){
  if(lang==='python') return {telegram:'python-telegram-bot>=20.0\n',discord:'discord.py>=2.0\n',whatsapp:'flask\nrequests\n',viber:'viberbot\nflask\n'}[plat]||'requests\n';
  if(lang==='node'){const d={telegram:'{"node-telegram-bot-api":"*"}',discord:'{"discord.js":"^14.0.0"}',whatsapp:'{"express":"*","axios":"*"}',viber:'{"viber-bot":"*","express":"*"}'}[plat]||'{}';return `{"name":"bot","version":"1.0.0","dependencies":${d}}\n`;}
  if(lang==='ruby') return "source 'https://rubygems.org'\n";
  return '{"require":{}}\n';
}

function makeBotTemplate(tpl,tok,lang,plat){
  // Node.js Telegram
  if(lang==='node'&&plat==='telegram'){
    if(tpl==='echo') return `const TBot=require('node-telegram-bot-api');\nconst bot=new TBot('${tok}',{polling:true});\nbot.on('message',msg=>{if(msg.text)bot.sendMessage(msg.chat.id,msg.text);});\nconsole.log('Echo bot started');\n`;
    if(tpl==='menu') return `const TBot=require('node-telegram-bot-api');\nconst bot=new TBot('${tok}',{polling:true});\nconst kb={reply_markup:{keyboard:[['Help','About']],resize_keyboard:true}};\nbot.onText(/\\/start/,msg=>bot.sendMessage(msg.chat.id,'Hello!',kb));\nbot.on('message',msg=>{\n  if(msg.text==='Help')bot.sendMessage(msg.chat.id,'Press buttons!');\n  if(msg.text==='About')bot.sendMessage(msg.chat.id,'Bot Manager v3');\n});\nconsole.log('Menu bot started');\n`;
    return `const TBot=require('node-telegram-bot-api');\nconst bot=new TBot('${tok}',{polling:true});\nbot.onText(/\\/start/,msg=>bot.sendMessage(msg.chat.id,'Hello! Type /help'));\nbot.onText(/\\/help/,msg=>bot.sendMessage(msg.chat.id,'/start\\n/help'));\nconsole.log('Bot started');\n`;
  }
  // Node.js Discord
  if(lang==='node'&&plat==='discord') return `const {Client,GatewayIntentBits}=require('discord.js');\nconst client=new Client({intents:[GatewayIntentBits.Guilds,GatewayIntentBits.GuildMessages,GatewayIntentBits.MessageContent]});\nclient.once('ready',()=>console.log('Logged in as '+client.user.tag));\nclient.on('messageCreate',msg=>{\n  if(msg.author.bot)return;\n  if(msg.content==='!ping')msg.reply('Pong!');\n});\nclient.login('${tok}');\n`;
  // Ruby stdlib Telegram
  if(lang==='ruby'&&plat==='telegram'){
    const hdr='require "net/http"\nrequire "json"\nrequire "uri"\nrequire "openssl"\n';
    const fn='def tg(m,p={})\n  u=URI("https://api.telegram.org/bot"+TOKEN+"/"+m.to_s)\n  h=Net::HTTP.new(u.host,u.port);h.use_ssl=true;h.verify_mode=OpenSSL::SSL::VERIFY_NONE\n  JSON.parse(h.post(u.path,p.to_json,"Content-Type"=>"application/json").body)\nrescue=>e;STDERR.puts e.to_s;{}\nend\n';
    return hdr+`TOKEN=ENV["BOT_TOKEN"]||"${tok}"\n`+fn+
      'offset=0;puts "Bot started (no gems)"\nloop do\n  (tg("getUpdates",{timeout:25,offset:offset})["result"]||[]).each do |u|\n    offset=u["update_id"]+1\n    msg=u["message"];next unless msg\n    chat=msg["chat"]["id"];text=msg["text"]||""\n    case text\n    when "/start" then tg("sendMessage",{chat_id:chat,text:"Hello! Type /help"})\n    when "/help" then tg("sendMessage",{chat_id:chat,text:"/start\n/help"})\n    end\n  end\nrescue Interrupt;exit\nrescue=>e;STDERR.puts e;sleep 3\nend\n';
  }
  // PHP Telegram
  if(lang==='php'&&plat==='telegram') return `<?php\n$token=getenv('BOT_TOKEN')?:\"${tok}\";\n$offset=0;\nwhile(true){\n  $r=@json_decode(file_get_contents("https://api.telegram.org/bot$token/getUpdates?timeout=30&offset=$offset"),true);\n  foreach($r["result"]??[] as $u){\n    $offset=$u["update_id"]+1;\n    $chat=$u["message"]["chat"]["id"]??"";\n    $text=$u["message"]["text"]??"";\n    if($text==="/start")@file_get_contents("https://api.telegram.org/bot$token/sendMessage?chat_id=$chat&text=Hello!");\n  }\n  sleep(1);\n}\n`;
  // Python Telegram (default)
  if(tpl==='echo') return `#!/usr/bin/env python3\nimport os,logging\nfrom telegram import Update\nfrom telegram.ext import ApplicationBuilder,MessageHandler,filters,ContextTypes\nlogging.basicConfig(level=logging.INFO,format='%(asctime)s %(levelname)s %(message)s')\nBOT_TOKEN=os.environ.get('BOT_TOKEN','${tok}')\nasync def echo(u:Update,c:ContextTypes.DEFAULT_TYPE):\n  if u.message and u.message.text:await u.message.reply_text(u.message.text)\nif __name__=='__main__':\n  ApplicationBuilder().token(BOT_TOKEN).build().run_polling(drop_pending_updates=True)\n`;
  if(tpl==='menu') return `#!/usr/bin/env python3\nimport os,logging\nfrom telegram import Update,ReplyKeyboardMarkup\nfrom telegram.ext import ApplicationBuilder,CommandHandler,MessageHandler,filters,ContextTypes\nlogging.basicConfig(level=logging.INFO,format='%(asctime)s %(levelname)s %(message)s')\nBOT_TOKEN=os.environ.get('BOT_TOKEN','${tok}')\nMENU=ReplyKeyboardMarkup([['Help','About']],resize_keyboard=True)\nasync def start(u:Update,c:ContextTypes.DEFAULT_TYPE):await u.message.reply_text('Hello!',reply_markup=MENU)\nasync def handle(u:Update,c:ContextTypes.DEFAULT_TYPE):\n  t=u.message.text\n  if t=='Help':await u.message.reply_text('Press buttons!')\n  elif t=='About':await u.message.reply_text('Bot Manager v3')\nif __name__=='__main__':\n  a=ApplicationBuilder().token(BOT_TOKEN).build()\n  a.add_handler(CommandHandler('start',start))\n  a.add_handler(MessageHandler(filters.TEXT&~filters.COMMAND,handle))\n  a.run_polling(drop_pending_updates=True)\n`;
  // basic python
  return `#!/usr/bin/env python3\nimport os,logging\nfrom telegram import Update\nfrom telegram.ext import ApplicationBuilder,CommandHandler,ContextTypes\nlogging.basicConfig(level=logging.INFO,format='%(asctime)s %(levelname)s %(message)s')\nBOT_TOKEN=os.environ.get('BOT_TOKEN','${tok}')\nasync def start(u:Update,c:ContextTypes.DEFAULT_TYPE):await u.message.reply_text('Hello! Type /help')\nasync def help_cmd(u:Update,c:ContextTypes.DEFAULT_TYPE):await u.message.reply_text('/start\\n/help')\nif __name__=='__main__':\n  a=ApplicationBuilder().token(BOT_TOKEN).build()\n  a.add_handler(CommandHandler('start',start))\n  a.add_handler(CommandHandler('help',help_cmd))\n  a.run_polling(drop_pending_updates=True)\n`;
}

// ── Autostart ─────────────────────────────────────────────
function autostart(){
  if(!fs.existsSync(BD)) return;
  setTimeout(async()=>{
    for(const pid of fs.readdirSync(BD)){
      if(!fs.statSync(path.join(BD,pid)).isDirectory()) continue;
      try{const m=readMeta(pid);if(m.autostart){const[ok,r]=await botStart(pid);console.log(`[autostart] ${ok?'OK':'FAIL'} ${pid}: ${r}`);}}
      catch(e){console.error(`[autostart] ${pid}:`,e.message);}
    }
  },3000);
}

// ── GitHub import ─────────────────────────────────────────
route('POST','/api/projects/:pid/github-import', needAuth, async (req,res) => {
  const {pid} = req.params;
  const {url='', branch='main'} = req.body;
  if (!validPid(pid)) return send(res,400,{error:'Invalid'});
  if (!url.startsWith('https://github.com/')) return send(res,400,{error:'Only github.com URLs'});
  const bd = botDir(pid);
  try {
    execSync(`git clone --depth=1 -b "${branch}" "${url}" "${bd}_tmp" 2>&1`, {timeout:60000, stdio:'pipe'});
    execSync(`cp -r "${bd}_tmp/." "${bd}/" && rm -rf "${bd}_tmp"`, {timeout:10000, stdio:'pipe'});
    activity('github',pid,`Imported from ${url}`);
    send(res,200,{ok:true});
  } catch(e) {
    try { execSync(`rm -rf "${bd}_tmp"`, {stdio:'pipe'}); } catch {}
    send(res,500,{error:e.message.slice(0,200)});
  }
});

// ── Shutdown ──────────────────────────────────────────────
process.on('SIGTERM',()=>{Object.keys(procs).forEach(botStop);process.exit(0);});
process.on('SIGINT', ()=>{Object.keys(procs).forEach(botStop);process.exit(0);});

// ── Start ─────────────────────────────────────────────────
server.listen(PORT,'127.0.0.1',()=>{
  console.log(`[botpanel] Node.js v${process.version} started on :${PORT}`);
  autostart();
});

