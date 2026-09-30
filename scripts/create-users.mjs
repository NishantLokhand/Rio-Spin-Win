// Creates login users in your Supabase project (works on Windows, Mac, Linux).
//
//   cd rio-spin-win
//   npm install
//   node scripts/create-users.mjs
//
// It asks for your Supabase URL (auto-read from web/.env.local) and your SERVICE ROLE / SECRET key.
// The service key is used only on your computer for this run — never put it in the web app.
import { createClient } from '@supabase/supabase-js';
import readline from 'node:readline/promises';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const envFile = path.join(root, 'web', '.env.local');
const envVals = fs.existsSync(envFile)
  ? Object.fromEntries(fs.readFileSync(envFile, 'utf8').split(/\r?\n/).filter((l) => l.includes('=') && !l.trim().startsWith('#'))
      .map((l) => [l.slice(0, l.indexOf('=')).trim(), l.slice(l.indexOf('=') + 1).trim()]))
  : {};

const rl = readline.createInterface({ input: process.stdin, output: process.stdout });
const ask = async (q, def) => ((await rl.question(def ? `${q} [${def}]: ` : `${q}: `)).trim() || def || '');

const url = process.env.SUPABASE_URL || await ask('Supabase Project URL', envVals.VITE_SUPABASE_URL);
const key = process.env.SUPABASE_SERVICE_ROLE_KEY || await ask('Service role key (Project Settings → API Keys → service_role / secret)');
const DOMAIN = envVals.VITE_LOGIN_DOMAIN || 'login.riospinwin.app';
if (!url.startsWith('https://') || !key) { console.error('\n✗ URL and service key are required.'); process.exit(1); }
const sb = createClient(url, key, { auth: { persistSession: false, autoRefreshToken: false } });

async function create({ role, login, pin, name, mobile = null, approve = false, override = false, promoter = null }) {
  const email = `${login.toLowerCase()}@${DOMAIN}`;
  const { data, error } = await sb.auth.admin.createUser({ email, password: pin, email_confirm: true });
  if (error) {
    if (/already/i.test(error.message)) { console.log(`• ${login} already exists — skipped`); return null; }
    throw new Error(`${login}: ${error.message}`);
  }
  const id = data.user.id;
  let r = await sb.from('app_users').insert({ id, role, login_id: login.toLowerCase(), full_name: name, mobile, can_approve_outlets: approve, can_override_cost_target: override });
  if (r.error) throw new Error(`app_users: ${r.error.message}`);
  if (promoter) { r = await sb.from('promoters').insert({ user_id: id, ...promoter }); if (r.error) throw new Error(`promoters: ${r.error.message}`); }
  console.log(`✓ ${role.padEnd(10)} login: ${login.padEnd(12)} PIN: ${pin}`);
  return id;
}

// Opening stock kit using the 200-spin reference mix (prize ids from supabase/seed.sql)
const KIT = [['50000000-0000-0000-0000-000000000001', 152], ['50000000-0000-0000-0000-000000000002', 34], ['50000000-0000-0000-0000-000000000003', 10],
  ['50000000-0000-0000-0000-000000000004', 3], ['50000000-0000-0000-0000-000000000005', 1]];
async function issueKit(promoterId, by) {
  for (const [prize, qty] of KIT) {
    let r = await sb.from('promoter_inventory').upsert({ promoter_id: promoterId, prize_id: prize, on_hand: qty, reserved: 0 });
    if (r.error) throw new Error(`stock: ${r.error.message}`);
    r = await sb.from('inventory_movements').insert({ promoter_id: promoterId, prize_id: prize, movement_type: 'issue', qty, on_hand_after: qty, performed_by: by, reference: 'Opening kit', note: 'Created by setup script' });
    if (r.error) throw new Error(`stock log: ${r.error.message}`);
  }
}

try {
  // quick connectivity + schema check
  const chk = await sb.from('campaigns').select('code').limit(1);
  if (chk.error) throw new Error(`Cannot read the database (${chk.error.message}). Did you run supabase/ALL_IN_ONE.sql?`);

  console.log('\nWhat do you want to create?\n  1) First ADMIN only\n  2) Admin + DEMO users (1 supervisor, 2 promoters with prize stock) — recommended for testing\n');
  const choice = await ask('Choose 1 or 2', '2');
  const adminLogin = await ask('Admin login (username)', 'admin');
  let adminPin = await ask('Admin password (min 6 characters)', 'admin123');
  if (adminPin.length < 6) { console.error('Password must be at least 6 characters'); process.exit(1); }

  let adminId = await create({ role: 'admin', login: adminLogin, pin: adminPin, name: 'Campaign Admin', approve: true, override: true });
  if (!adminId) adminId = (await sb.from('app_users').select('id').eq('login_id', adminLogin.toLowerCase()).single()).data?.id;

  if (choice === '2') {
    const UP = '10000000-0000-0000-0000-000000000001';
    const sup = await create({ role: 'supervisor', login: 'sup.lucknow', pin: '222222', name: 'Vikas Tiwari', mobile: '9000000001', approve: true });
    const supId = sup || (await sb.from('app_users').select('id').eq('login_id', 'sup.lucknow').single()).data?.id;
    const p1 = await create({ role: 'promoter', login: '9876500001', pin: '111111', name: 'Ravi Kumar', mobile: '9876500001',
      promoter: { promoter_code: 'PRM-001', promoter_type: 'permanent', supervisor_id: supId, home_state_id: UP } });
    const p2 = await create({ role: 'promoter', login: '9876500002', pin: '111111', name: 'Sneha Yadav', mobile: '9876500002',
      promoter: { promoter_code: 'PRM-002', promoter_type: 'agency', agency_name: 'BrandBuzz Activations', supervisor_id: supId, home_state_id: UP } });
    for (const p of [p1, p2].filter(Boolean)) await issueKit(p, adminId);
    if (p1 || p2) console.log('✓ Issued one prize kit (152/34/10/3/1) to each new promoter');
    console.log('\nDemo PINs are for testing only — change them before going live.');
  }
  console.log('\nDone. Start the app:  cd web  →  npm run dev  →  http://localhost:5173\n');
} catch (e) {
  console.error('\n✗ ' + e.message + '\n');
  process.exitCode = 1;
} finally { rl.close(); }
