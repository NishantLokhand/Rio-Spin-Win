import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';
import { transformSync } from '../web/node_modules/esbuild/lib/main.js';
import { requireFieldUserMarket } from '../supabase/functions/_shared/fieldUserMarket.mjs';

// Run the real Edge handler with local in-memory clients. No network or secrets.
const source = readFileSync(new URL('../supabase/functions/admin-users/index.ts', import.meta.url), 'utf8')
  .replace(/^import .*;\r?\n/gm, '');
const code = transformSync(source, { loader: 'ts', target: 'es2022' }).code;

function service() {
  const created = [], linked = [];
  let handler;
  const caller = { auth: { getUser: async () => ({ data: { user: { id: 'admin' } } }) } };
  const admin = {
    from: () => ({ select: () => ({ eq: () => ({ single: async () => ({ data: { role: 'admin', is_active: true } }) }) }) }),
    auth: { admin: { createUser: async body => { created.push(body); return { data: { user: { id: 'new-user' } } }; } } },
    rpc: async (name, args) => { linked.push({ name, args }); return { data: { ok: true, id: 'new-user' } }; },
  };
  vm.runInNewContext(code, {
    Deno: { env: { get: key => key }, serve: fn => { handler = fn; } },
    createClient: (url, key) => key === 'SUPABASE_ANON_KEY' ? caller : admin,
    requireFieldUserMarket, Response,
  });
  return { created, linked, call: body => handler({ method: 'POST', headers: new Headers(), json: async () => body }) };
}

test('service rejects missing Market for Promoter, TSE and MER before creating an auth identity', async () => {
  for (const designation of ['PROMOTER', 'TSE', 'MER']) {
    for (const market of [undefined, '', ' \t\n ', 123]) {
      const local = service();
      const response = await local.call({ action: 'create', role: 'promoter', login_id: 'synthetic', full_name: 'Local fixture', pin: '123456', organization: { designation, market } });
      assert.equal(response.status, 400);
      assert.match((await response.json()).error, /Market is required/);
      assert.equal(local.created.length, 0);
      assert.equal(local.linked.length, 0);
    }
  }
});

test('service passes trimmed Market to atomic onboarding for new and linked organizational records', async () => {
  for (const person_id of [undefined, 'existing-person']) {
    const local = service();
    const response = await local.call({ action: 'create', role: 'promoter', login_id: 'synthetic', full_name: 'Local fixture', pin: '123456', organization: { designation: 'TSE', person_id, market: '  LUCKNOW  ' } });
    assert.equal(response.status, 200);
    assert.equal(local.created.length, 1);
    assert.equal(local.linked[0].name, 'create_linked_field_user');
    assert.equal(local.linked[0].args.p_organization.market, 'LUCKNOW');
    assert.equal(local.linked[0].args.p_organization.person_id, person_id);
  }
});
