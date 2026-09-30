// Creates the isolated RIO test promoter requested by the project owner.
// Requires a Supabase service-role key, which is read only at runtime and is never stored.
import { createClient } from '@supabase/supabase-js';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const envPath = path.join(root, 'web', '.env.local');
const envValues = fs.existsSync(envPath)
  ? Object.fromEntries(fs.readFileSync(envPath, 'utf8').split(/\r?\n/)
    .filter((line) => line.includes('=') && !line.trim().startsWith('#'))
    .map((line) => [line.slice(0, line.indexOf('=')).trim(), line.slice(line.indexOf('=') + 1).trim()]))
  : {};
const LOGIN = '9556600000';
const PROMOTER_CODE = 'TEST-9556600000';
const OUTLET_CODE = 'DEMO-9556600000';
const EMAIL_DOMAIN = envValues.VITE_LOGIN_DOMAIN || 'login.riospinwin.app';

function ask(prompt) {
  return new Promise((resolve) => {
    process.stdout.write(prompt);
    process.stdin.setEncoding('utf8');
    process.stdin.once('data', (value) => resolve(String(value).trim()));
  });
}

function askSecret(prompt) {
  return new Promise((resolve, reject) => {
    const input = process.stdin;
    if (!input.isTTY || typeof input.setRawMode !== 'function') {
      reject(new Error('Run this script in an interactive terminal so the service key and password can be entered privately.'));
      return;
    }
    let value = '';
    process.stdout.write(prompt);
    input.setEncoding('utf8');
    input.setRawMode(true);
    input.resume();
    const finish = (err) => {
      input.setRawMode(false);
      input.pause();
      input.removeListener('data', onData);
      process.stdout.write('\n');
      err ? reject(err) : resolve(value);
    };
    const onData = (key) => {
      if (key === '\u0003') return finish(new Error('Cancelled.'));
      if (key === '\r' || key === '\n') return finish();
      if (key === '\u007f' || key === '\b') {
        if (value.length) { value = value.slice(0, -1); process.stdout.write('\b \b'); }
        return;
      }
      if (key >= ' ') { value += key; process.stdout.write('*'); }
    };
    input.on('data', onData);
  });
}

async function requireOk(result, label) {
  if (result.error) throw new Error(`${label}: ${result.error.message}`);
  return result.data;
}

let createdAuthId = null;
let createdOutletId = null;
let demoOutletId = null;
let createdOrgId = null;
let createdOrgRecord = false;
let createdAssignment = false;
let sb = null;
try {
  const url = process.env.SUPABASE_URL || envValues.VITE_SUPABASE_URL || await ask('Supabase project URL: ');
  const serviceKey = process.env.SUPABASE_SERVICE_ROLE_KEY || await askSecret('Supabase service-role key (hidden): ');
  const password = await askSecret(`Password for ${LOGIN} (hidden): `);
  if (!url.startsWith('https://') || !serviceKey) throw new Error('A valid project URL and service-role key are required.');
  if (password.length < 6) throw new Error('The password must be at least 6 characters.');
  sb = createClient(url, serviceKey, { auth: { persistSession: false, autoRefreshToken: false } });

  // Reuse an existing active TSE only to satisfy the outlet hierarchy required by the schema.
  // No promoter or supervisor is associated with that TSE by this setup.
  const tses = await requireOk(await sb.from('tses').select('id,territory_id').eq('status', 'active').order('code').limit(1), 'Find active TSE');
  if (!tses?.length) throw new Error('No active TSE exists. Create one through the admin master screen first.');
  const tse = tses[0];
  const territory = await requireOk(await sb.from('territories').select('id,state_id').eq('id', tse.territory_id).single(), 'Find TSE territory');
  const state = await requireOk(await sb.from('states').select('id,name').eq('id', territory.state_id).single(), 'Find TSE state');

  const existing = await requireOk(await sb.from('app_users').select('id,role').eq('login_id', LOGIN).maybeSingle(), 'Check login');
  let userId;
  if (existing) {
    if (existing.role !== 'promoter') throw new Error(`Login ${LOGIN} already exists with a non-promoter role; no changes were made.`);
    const promoter = await requireOk(await sb.from('promoters').select('promoter_code').eq('user_id', existing.id).maybeSingle(), 'Check promoter profile');
    if (promoter?.promoter_code !== PROMOTER_CODE) throw new Error(`Login ${LOGIN} belongs to an existing non-test promoter; no changes were made.`);
    userId = existing.id;
  } else {
    const email = `${LOGIN}@${EMAIL_DOMAIN}`;
    const auth = await sb.auth.admin.createUser({ email, password, email_confirm: true, app_metadata: { app_role: 'promoter', test_account: true }, user_metadata: { full_name: 'Demo Promoter' } });
    if (auth.error) throw new Error(`Create authentication login: ${auth.error.message}`);
    userId = auth.data.user.id;
    createdAuthId = userId;
    await requireOk(await sb.from('app_users').insert({ id: userId, role: 'promoter', login_id: LOGIN, full_name: 'Demo Promoter', mobile: LOGIN }), 'Create app user');
    await requireOk(await sb.from('promoters').insert({ user_id: userId, promoter_code: PROMOTER_CODE, promoter_type: 'temporary', home_state_id: state.id, supervisor_id: null }), 'Create promoter profile');
  }

  let outlet = await requireOk(await sb.from('outlets').select('id,name,tse_id').eq('outlet_code', OUTLET_CODE).maybeSingle(), 'Check demo outlet');
  if (outlet && outlet.name !== 'Demo outlet') throw new Error('The demo outlet code is already used by a different outlet; no changes were made.');
  if (!outlet) {
    outlet = await requireOk(await sb.from('outlets').insert({
      tse_id: tse.id, outlet_code: OUTLET_CODE, name: 'Demo outlet', area: 'Demo', city: state.name,
      distributor: 'Test only', status: 'active', source: 'upload',
    }).select('id,name,tse_id').single(), 'Create demo outlet');
    createdOutletId = outlet.id;
  }
  demoOutletId = outlet.id;

  const org = await requireOk(await sb.from('org_people').select('id,auth_user_id,designation').eq('source_key', `TEST:${LOGIN}`).maybeSingle(), 'Check organizational promoter record');
  if (org && (org.auth_user_id !== userId || org.designation !== 'PROMOTER')) throw new Error('A conflicting organizational record already uses the test source key.');
  if (org) createdOrgId = org.id;
  else {
    const inserted = await requireOk(await sb.from('org_people').insert({
      designation: 'PROMOTER', employee_name: 'Demo Promoter', mobile: LOGIN, source_key: `TEST:${LOGIN}`,
      source_system: 'admin_test_setup', source_ids: { test_account: true }, state_raw: state.name,
      area_raw: 'Demo', beat_values: [], active: true, auth_user_id: userId, assignment_source: 'manual',
    }).select('id').single(), 'Create organizational promoter record');
    createdOrgId = inserted.id;
    createdOrgRecord = true;
  }

  const assigned = await requireOk(await sb.from('promoter_outlet_assignments').select('promoter_id').eq('outlet_id', outlet.id).eq('active', true), 'Check demo outlet access');
  if (assigned.some((row) => row.promoter_id !== createdOrgId)) throw new Error('The demo outlet already has another promoter assignment; no access changes were made.');
  if (existing) {
    const authUpdate = await sb.auth.admin.updateUserById(userId, { password });
    if (authUpdate.error) throw new Error(`Update existing test login: ${authUpdate.error.message}`);
  }
  const alreadyAssigned = assigned.some((row) => row.promoter_id === createdOrgId);
  await requireOk(await sb.from('promoter_outlet_assignments').upsert({ promoter_id: createdOrgId, outlet_id: outlet.id, active: true }, { onConflict: 'promoter_id,outlet_id' }), 'Assign demo outlet');
  createdAssignment = !alreadyAssigned;
  await requireOk(await sb.from('promoter_outlet_assignments').delete().eq('promoter_id', createdOrgId).neq('outlet_id', outlet.id), 'Limit test promoter to one outlet');

  console.log(`Created/verified isolated test promoter ${LOGIN} and its single outlet, Demo outlet.`);
  console.log('No supervisor was assigned and no prize inventory was issued. Admins retain access through the existing admin policies.');
} catch (error) {
  if (sb && createdOrgId && createdAssignment && demoOutletId) await sb.from('promoter_outlet_assignments').delete().eq('promoter_id', createdOrgId).eq('outlet_id', demoOutletId);
  if (sb && createdOrgRecord && createdOrgId) await sb.from('org_people').delete().eq('id', createdOrgId);
  if (sb && createdOutletId) await sb.from('outlets').delete().eq('id', createdOutletId);
  if (sb && createdAuthId) await sb.auth.admin.deleteUser(createdAuthId);
  if (createdAuthId) console.error(`Any new login created during this failed attempt was rolled back.`);
  console.error(`\nSetup failed: ${error.message}`);
  process.exitCode = 1;
}
