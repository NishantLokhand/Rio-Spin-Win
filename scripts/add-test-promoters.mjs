// Script to add 5 test promoters to your Supabase project:
// Mobile: 9876500010 .. 9876500050
// PIN:    111120 .. 111160 (or 111110 .. 111150)
//
// Usage in Command Prompt:
//   node scripts/add-test-promoters.mjs
// or
//   npm run add-promoters
//
import { createClient } from '@supabase/supabase-js';
import readline from 'node:readline/promises';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const envFile = path.join(root, 'web', '.env.local');
const envVals = fs.existsSync(envFile)
  ? Object.fromEntries(
      fs
        .readFileSync(envFile, 'utf8')
        .split(/\r?\n/)
        .filter((l) => l.includes('=') && !l.trim().startsWith('#'))
        .map((l) => [l.slice(0, l.indexOf('=')).trim(), l.slice(l.indexOf('=') + 1).trim()])
    )
  : {};

const rl = readline.createInterface({ input: process.stdin, output: process.stdout });
const ask = async (q, def) => ((await rl.question(def ? `${q} [${def}]: ` : `${q}: `)).trim() || def || '');

console.log('====================================================');
console.log(' RIO SPIN & WIN 2026 — Add 5 Test Promoters');
console.log('====================================================\n');

const url = process.env.SUPABASE_URL || (await ask('Supabase Project URL', envVals.VITE_SUPABASE_URL));
const key = process.env.SUPABASE_SERVICE_ROLE_KEY || (await ask('Service role key (Project Settings → API Keys → service_role / secret)'));
const DOMAIN = envVals.VITE_LOGIN_DOMAIN || 'login.riospinwin.app';

if (!url || !url.startsWith('https://') || !key) {
  console.error('\n✗ Error: Valid Supabase URL and service role key are required.');
  process.exit(1);
}

const sb = createClient(url, key, { auth: { persistSession: false, autoRefreshToken: false } });

// 5 test promoters specification
const TEST_PROMOTERS = [
  { mobile: '9876500010', pin: '111120', code: 'PRM-010', name: 'Test Promoter 1' },
  { mobile: '9876500020', pin: '111130', code: 'PRM-020', name: 'Test Promoter 2' },
  { mobile: '9876500030', pin: '111140', code: 'PRM-030', name: 'Test Promoter 3' },
  { mobile: '9876500040', pin: '111150', code: 'PRM-040', name: 'Test Promoter 4' },
  { mobile: '9876500050', pin: '111160', code: 'PRM-050', name: 'Test Promoter 5' },
];

// Standard opening kit using the 200-spin reference mix (152 / 34 / 10 / 3 / 1)
const KIT = [
  ['50000000-0000-0000-0000-000000000001', 152],
  ['50000000-0000-0000-0000-000000000002', 34],
  ['50000000-0000-0000-0000-000000000003', 10],
  ['50000000-0000-0000-0000-000000000004', 3],
  ['50000000-0000-0000-0000-000000000005', 1],
];

async function issueOpeningKit(promoterId, adminId) {
  for (const [prize, qty] of KIT) {
    const r1 = await sb.from('promoter_inventory').upsert({
      promoter_id: promoterId,
      prize_id: prize,
      on_hand: qty,
      reserved: 0,
    });
    if (r1.error) throw new Error(`Failed to assign stock: ${r1.error.message}`);

    const r2 = await sb.from('inventory_movements').insert({
      promoter_id: promoterId,
      prize_id: prize,
      movement_type: 'issue',
      qty,
      on_hand_after: qty,
      performed_by: adminId,
      reference: 'Opening kit',
      note: 'Initial stock kit for test promoter',
    });
    if (r2.error) throw new Error(`Failed to record stock movement: ${r2.error.message}`);
  }
}

try {
  // 1. Verify connection and fetch supervisor + state
  const { data: sups, error: supErr } = await sb
    .from('app_users')
    .select('id, login_id, full_name')
    .eq('role', 'supervisor')
    .limit(1);

  if (supErr) throw new Error(`Database connection failed: ${supErr.message}`);
  const supervisorId = sups && sups.length > 0 ? sups[0].id : null;

  const { data: states } = await sb.from('states').select('id, name').limit(1);
  const stateId = states && states.length > 0 ? states[0].id : null;

  // Find admin for stock issue attribution
  const { data: admins } = await sb.from('app_users').select('id').eq('role', 'admin').limit(1);
  const adminId = admins && admins.length > 0 ? admins[0].id : null;

  console.log('Supervisor ID mapped:', supervisorId || 'None');
  console.log('Home State mapped:', states && states[0] ? states[0].name : 'Default');
  console.log('\nCreating 5 test promoters...\n');

  for (const p of TEST_PROMOTERS) {
    const email = `${p.mobile.toLowerCase()}@${DOMAIN}`;

    // A. Check if auth user exists, or create new
    let userId = null;
    const { data: authData, error: authErr } = await sb.auth.admin.createUser({
      email,
      password: p.pin,
      email_confirm: true,
    });

    if (authErr) {
      if (/already/i.test(authErr.message)) {
        console.log(`• ${p.mobile} already exists in Auth. Updating password & profile...`);
        // Fetch existing auth user id
        const { data: existingUsers } = await sb.auth.admin.listUsers();
        const found = existingUsers?.users?.find((u) => u.email === email);
        if (found) {
          userId = found.id;
          await sb.auth.admin.updateUserById(userId, { password: p.pin });
        }
      } else {
        throw new Error(`Auth creation failed for ${p.mobile}: ${authErr.message}`);
      }
    } else {
      userId = authData.user.id;
    }

    if (!userId) {
      console.warn(`⚠️ Could not determine user ID for ${p.mobile}, skipping.`);
      continue;
    }

    // B. Upsert app_users record
    const { error: appErr } = await sb.from('app_users').upsert({
      id: userId,
      role: 'promoter',
      login_id: p.mobile,
      full_name: p.name,
      mobile: p.mobile,
      can_approve_outlets: false,
      can_override_cost_target: false,
      is_active: true,
    });
    if (appErr) throw new Error(`app_users upsert failed: ${appErr.message}`);

    // C. Upsert promoters record
    const { error: promErr } = await sb.from('promoters').upsert({
      user_id: userId,
      promoter_code: p.code,
      promoter_type: 'permanent',
      supervisor_id: supervisorId,
      home_state_id: stateId,
    });
    if (promErr) throw new Error(`promoters upsert failed: ${promErr.message}`);

    // D. Issue opening prize stock kit so they are spin-ready
    await issueOpeningKit(userId, adminId);

    console.log(`✓ Added Promoter: Login: ${p.mobile}  |  PIN: ${p.pin}  |  Code: ${p.code}  |  Stock: 200 units`);
  }

  console.log('\n====================================================');
  console.log('🎉 Successfully created/updated all 5 test promoters!');
  console.log('Each promoter has been issued an opening prize inventory kit.');
  console.log('You can now log in with any of these numbers on mobile.');
  console.log('====================================================\n');
} catch (err) {
  console.error('\n✗ Error:', err.message, '\n');
  process.exitCode = 1;
} finally {
  rl.close();
}
