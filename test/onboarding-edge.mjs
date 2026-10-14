import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { createRequire } from 'node:module';
const webRequire = createRequire(new URL('../web/package.json', import.meta.url));
const { transform } = createRequire(webRequire.resolve('vite/package.json'))('esbuild');
const source = await readFile(new URL('../supabase/functions/admin-users/index.ts', import.meta.url), 'utf8');
const { code } = await transform(source.replace(/^import .*createClient.*;$/m, ''), { loader: 'ts', target: 'es2022' });
async function scenario({ role = 'admin', rpcError = null, cleanupError = null } = {}) {
  let handler; const calls = []; let clients = 0;
  const caller = { auth: { getUser: async () => ({ data: { user: { id: 'actor' } } }) } };
  const admin = {
    from: () => ({ select: () => ({ eq: () => ({ single: async () => ({ data: { role, is_active: true } }) }) }) }),
    auth: { admin: {
      createUser: async () => { calls.push('auth-create'); return { data: { user: { id: 'new-user' } } }; },
      deleteUser: async (id) => { calls.push(['auth-delete', id]); return { error: cleanupError }; },
    } },
    rpc: async (name, args) => { calls.push([name, args]); return { data: { ok: true, id: 'new-user', org_person_id: 'person' }, error: rpcError }; },
  };
  new Function('createClient', 'Deno', code)(() => clients++ === 0 ? caller : admin, {
    env: { get: () => 'test' }, serve: (fn) => { handler = fn; },
  });
  const response = await handler(new Request('https://example.test', { method: 'POST', body: JSON.stringify({
    action: 'create', role: 'promoter', login_id: '9000000099', full_name: 'Test', pin: 'test123', organization: { designation: 'TSE' },
  }) }));
  return { response, body: await response.json(), calls };
}
const success = await scenario();
assert.equal(success.response.status, 200); assert.equal(success.body.org_person_id, 'person');
assert.equal(success.calls[1][0], 'create_linked_field_user');
assert.equal(success.calls[1][1].p_organization.designation, 'TSE');
assert.equal(success.calls.some((c) => c[0] === 'auth-delete'), false);
const fail = await scenario({ rpcError: { message: 'Already linked' } });
assert.equal(fail.response.status, 400); assert.deepEqual(fail.calls.at(-1), ['auth-delete', 'new-user']);
const cleanup = await scenario({ rpcError: { message: 'Already linked' }, cleanupError: { message: 'Unavailable' } });
assert.match(cleanup.body.error, /cleanup failed/);
const denied = await scenario({ role: 'promoter' });
assert.equal(denied.response.status, 403); assert.equal(denied.calls.length, 0);
console.log('PASS: edge authorization, atomic RPC routing, auth cleanup on failure and visible cleanup errors');
