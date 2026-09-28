// Local stand-in for Supabase Auth + REST gateway + admin-users function (TESTING ONLY).
// Auth: password grant against auth.users (bcrypt via pgcrypto), HS256 JWT.  REST: proxied to PostgREST.
import http from 'node:http';
import crypto from 'node:crypto';
import pg from 'pg';

const SECRET = 'local-dev-jwt-secret-at-least-32-characters-long';
const PGRST = 'http://127.0.0.1:3000';
const DOMAIN = 'login.riospinwin.app';
const db = new pg.Pool({ connectionString: 'postgres://postgres@127.0.0.1:54322/rio' });
const refresh = new Map();

const b64 = (o) => Buffer.from(typeof o === 'string' ? o : JSON.stringify(o)).toString('base64url');
function sign(payload) {
  const h = b64({ alg: 'HS256', typ: 'JWT' }); const p = b64(payload);
  return `${h}.${p}.${crypto.createHmac('sha256', SECRET).update(`${h}.${p}`).digest('base64url')}`;
}
function verify(tok) {
  try {
    const [h, p, s] = tok.split('.');
    if (crypto.createHmac('sha256', SECRET).update(`${h}.${p}`).digest('base64url') !== s) return null;
    const c = JSON.parse(Buffer.from(p, 'base64url')); return c.exp > Date.now() / 1000 ? c : null;
  } catch { return null; }
}
export const anonKey = sign({ role: 'anon', exp: 4102444800 });
const userObj = (u) => ({ id: u.id, aud: 'authenticated', role: 'authenticated', email: u.email, app_metadata: {}, user_metadata: {}, created_at: u.created_at });
function session(u) {
  const exp = Math.floor(Date.now() / 1000) + 3600;
  const rt = crypto.randomBytes(16).toString('hex'); refresh.set(rt, u);
  return { access_token: sign({ sub: u.id, role: 'authenticated', aud: 'authenticated', email: u.email, exp }), token_type: 'bearer',
    expires_in: 3600, expires_at: exp, refresh_token: rt, user: userObj(u) };
}
const cors = { 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Headers': '*', 'Access-Control-Allow-Methods': '*', 'Access-Control-Expose-Headers': '*' };
const send = (res, code, body) => { res.writeHead(code, { ...cors, 'Content-Type': 'application/json' }); res.end(body == null ? '' : JSON.stringify(body)); };
const readBody = (req) => new Promise((r) => { let d = ''; req.on('data', (c) => (d += c)); req.on('end', () => r(d)); });

async function adminUsers(req, res, body) {
  const c = verify((req.headers.authorization || '').replace('Bearer ', ''));
  const me = c && (await db.query('select role,is_active from app_users where id=$1', [c.sub])).rows[0];
  if (!me || me.role !== 'admin') return send(res, 403, { error: 'Admin only' });
  const b = JSON.parse(body);
  if (b.action === 'create') {
    const email = `${b.login_id.toLowerCase()}@${DOMAIN}`;
    const client = await db.connect();
    try {
      await client.query('begin');
      const id = (await client.query("insert into auth.users(email, encrypted_password) values ($1, extensions.crypt($2, extensions.gen_salt('bf'))) returning id", [email, b.pin])).rows[0].id;
      await client.query('insert into app_users(id, role, login_id, full_name, mobile, can_approve_outlets, can_override_cost_target) values ($1,$2,$3,$4,$5,$6,$7)',
        [id, b.role, b.login_id.toLowerCase(), b.full_name, b.mobile, !!b.can_approve_outlets, !!b.can_override_cost_target]);
      if (b.role === 'promoter') await client.query('insert into promoters(user_id, promoter_code, promoter_type, agency_name, supervisor_id, home_state_id) values ($1,$2,$3,$4,$5,$6)',
        [id, b.promoter.promoter_code, b.promoter.promoter_type, b.promoter.agency_name, b.promoter.supervisor_id, b.promoter.home_state_id]);
      await client.query('select write_audit_as($1,$2,$3,$4,$5)', [c.sub, 'USER_CREATED', 'app_users', id, JSON.stringify({ role: b.role })]);
      await client.query('commit'); return send(res, 200, { ok: true, id });
    } catch (e) { await client.query('rollback'); return send(res, 400, { error: e.message }); } finally { client.release(); }
  }
  if (b.action === 'reset_pin') { await db.query("update auth.users set encrypted_password = extensions.crypt($2, extensions.gen_salt('bf')) where id=$1", [b.user_id, b.pin]); return send(res, 200, { ok: true }); }
  if (b.action === 'set_active') { await db.query('update app_users set is_active=$2 where id=$1', [b.user_id, !!b.active]); return send(res, 200, { ok: true }); }
  return send(res, 400, { error: 'Unknown action' });
}

http.createServer(async (req, res) => {
  if (req.method === 'OPTIONS') { res.writeHead(204, cors); return res.end(); }
  const url = new URL(req.url, 'http://x');
  const body = await readBody(req);
  try {
    if (url.pathname === '/auth/v1/token') {
      const b = JSON.parse(body || '{}');
      if (url.searchParams.get('grant_type') === 'password') {
        const u = (await db.query('select id,email,created_at from auth.users where email=$1 and encrypted_password = extensions.crypt($2, encrypted_password)', [b.email, b.password])).rows[0];
        return u ? send(res, 200, session(u)) : send(res, 400, { error: 'invalid_grant', error_description: 'Invalid login credentials', msg: 'Invalid login credentials' });
      }
      const u = refresh.get(b.refresh_token);
      return u ? send(res, 200, session(u)) : send(res, 400, { error: 'invalid_grant' });
    }
    if (url.pathname === '/auth/v1/user') {
      const c = verify((req.headers.authorization || '').replace('Bearer ', ''));
      if (!c) return send(res, 401, { msg: 'invalid' });
      const u = (await db.query('select id,email,created_at from auth.users where id=$1', [c.sub])).rows[0];
      return send(res, 200, userObj(u));
    }
    if (url.pathname === '/auth/v1/logout') return send(res, 204);
    if (url.pathname === '/functions/v1/admin-users') return adminUsers(req, res, body);
    if (url.pathname.startsWith('/rest/v1')) {
      const headers = { ...req.headers }; delete headers.host; delete headers['content-length'];
      if (!headers.authorization || headers.authorization === `Bearer ${anonKey}`) headers.authorization = `Bearer ${anonKey}`;
      const r = await fetch(PGRST + url.pathname.replace('/rest/v1', '') + url.search, { method: req.method, headers, body: ['GET', 'HEAD'].includes(req.method) ? undefined : body });
      const out = Buffer.from(await r.arrayBuffer());
      const h = { ...cors }; r.headers.forEach((v, k) => { if (!['content-encoding', 'transfer-encoding', 'connection'].includes(k) && !k.startsWith('access-control')) h[k] = v; });
      res.writeHead(r.status, h); return res.end(out);
    }
    send(res, 404, { error: 'not found' });
  } catch (e) { send(res, 500, { error: String(e) }); }
}).listen(54321, () => console.log('mini-supabase on :54321  anonKey=' + anonKey));
