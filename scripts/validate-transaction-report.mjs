// Only writes fixture/setup data in a NEW local database. Never production.
import { readFileSync, writeFileSync, mkdirSync, existsSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import assert from 'node:assert/strict';
import { buildTransactionReport } from '../web/src/staff/transactionReport.js';

const container = 'supabase_db_rio-spin-win-v7-sandbox';
const base = readFileSync('outputs/v8-demo005-validation.log', 'utf8').match(/New LOCAL database: (rio_v8_demo005_\d+)/)?.[1];
const db = `rio_transaction_report_${Date.now()}`;
const migration = readFileSync('supabase/migrations/20261105000100_transaction_report_datasets.sql', 'utf8');
const rollback = readFileSync('supabase/rollbacks/20261105000100_remove_transaction_report_datasets.sql', 'utf8');
const inputPath = '.cache/transaction-audit-20261105/transactions_2026-10-01_2026-11.json';
if (!existsSync(inputPath)) throw new Error('Read-only extracted source workbook fixture is required: ' + inputPath);
const raw = JSON.parse(readFileSync(inputPath, 'utf8'));
const fixtureUser = 'ee000000-0000-0000-0000-000000000001';
const controlUser = 'ee000000-0000-0000-0000-000000000002';
const supervisor = 'ee000000-0000-0000-0000-000000000003';
const admin = 'a0000000-0000-0000-0000-000000000001';
const cutoff = '2026-11-06T00:00:00Z';
const log = [`Transaction reporting validation ${new Date().toISOString()}`, `New LOCAL database: ${db}`, `Local schema source: ${base}`,
  `Migration SHA256: ${createHash('sha256').update(migration).digest('hex')}`];
const quote = v => `'${String(v).replaceAll("'", "''")}'`;
const jsonSql = v => quote(JSON.stringify(v)) + '::jsonb';
const uid = text => { const h = createHash('sha256').update('txn-report-fixture:' + text).digest('hex').slice(0, 32); return `${h.slice(0, 8)}-${h.slice(8, 12)}-${h.slice(12, 16)}-${h.slice(16, 20)}-${h.slice(20)}`; };
function run(args, input) {
  const r = spawnSync('docker', ['exec', '-i', container, ...args], { input, encoding: 'utf8', maxBuffer: 50e6 });
  if (r.error || r.status) throw new Error(`${r.error || ''}\n${r.stdout}\n${r.stderr}`);
  return r.stdout;
}
function sql(input) { return run(['psql', '-X', '-U', 'postgres', '-d', db, '-At', '-v', 'ON_ERROR_STOP=1'], input); }
function pass(label) { log.push('PASS: ' + label); console.log('PASS: ' + label); }
function rpc(filters = {}, after = null, asOf = cutoff, limit = 250, user = admin) {
  const out = sql(`begin read only;set local role authenticated;select set_config('request.jwt.claim.sub',${quote(user)},true);
    select public.transaction_report_page(${jsonSql(filters)},${after ? quote(after) : 'null'},${asOf ? quote(asOf) : 'null'},${limit});rollback;`);
  const line = out.split(/\r?\n/).find(l => l.startsWith('{'));
  if (!line) throw new Error(out);
  return JSON.parse(line);
}
function readAll(filters, limit = 250, user = admin) {
  const rows = []; let after = null; let asOf = cutoff; const cursors = new Set();
  do {
    const r = rpc(filters, after, asOf, limit, user);
    assert.equal(Date.parse(r.as_of), Date.parse(asOf));
    rows.push(...r.bills); after = r.next_after;
    if (after) { assert.ok(!cursors.has(after)); cursors.add(after); }
  } while (after);
  assert.equal(new Set(rows.map(r => r.transaction_id)).size, rows.length);
  return rows;
}
let tables;
function snapshot() {
  if (!tables) tables = JSON.parse(sql(`select jsonb_agg(tablename order by tablename) from pg_tables where schemaname='public'`).trim());
  const parts = tables.map(t => `select ${quote(t)} as name,md5(coalesce(jsonb_agg(to_jsonb(t) order by to_jsonb(t)::text)::text,'[]')) as hash from public."${t.replaceAll('"', '""')}" t`);
  const data = sql(`select jsonb_object_agg(name,hash) from (${parts.join(' union all ')}) x`).trim();
  const code = sql(`select jsonb_build_object(
    'functions',(select md5(string_agg(p.oid::text||p.prosrc||coalesce(p.proacl::text,''),chr(10) order by p.oid)) from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname<>'transaction_report_page'),
    'views',(select md5(string_agg(c.oid::text||pg_get_viewdef(c.oid)||coalesce(c.relacl::text,''),chr(10) order by c.oid)) from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and c.relkind='v'),
    'policies',(select md5(coalesce(jsonb_agg(to_jsonb(p) order by p.tablename,p.policyname)::text,'[]')) from pg_policies p where p.schemaname='public')
  )`).trim();
  return JSON.stringify({ data, code });
}
try {
  assert.ok(base);
  run(['createdb', '-U', 'postgres', db]);
  sql('create schema extensions;create extension pgcrypto with schema extensions;create extension pg_trgm with schema extensions;create extension plpgsql_check;');
  const dump = run(['pg_dump', '-U', 'postgres', '-d', base, '--no-owner', '--schema=public', '--schema=auth']);
  sql(dump.replace('CREATE SCHEMA public;', 'CREATE SCHEMA IF NOT EXISTS public;'));
  pass('New isolated database bootstrapped from the existing real V6/V7/V8 schema');
  const templateSale = JSON.parse(sql('select to_jsonb(s) from public.sales s limit 1').trim());
  const templateSpin = JSON.parse(sql('select to_jsonb(s) from public.spins s limit 1').trim());
  const templateProduct = JSON.parse(sql('select to_jsonb(p) from public.products p limit 1').trim());
  const existingProducts = JSON.parse(sql('select jsonb_object_agg(sku_code,to_jsonb(p)) from public.products p').trim());
  const productId = code => existingProducts[code]?.id || uid(code);
  const campaign = JSON.parse(sql("select to_jsonb(c) from public.campaigns c where code='RSW-2026'").trim());
  const prizes = JSON.parse(sql('select jsonb_object_agg(code,to_jsonb(p)) from public.prizes p').trim());
  const groups = raw.reduce((m, r) => m.set(r['Transaction ID'], [...(m.get(r['Transaction ID']) || []), r]), new Map());
  const sales = []; const spins = []; const items = []; const products = new Map();
  for (const [id, rows] of groups) {
    const r = rows[0];
    const codes = r['SKU Code'].split(', ').map(x => x.match(/^(.*) × (\d+)$/));
    const names = r.SKU.split(', ').map(x => x.match(/^(.*) × (\d+)$/));
    const time = [...rows].map(r => r.Date + 'T' + r.Time + '+05:30').sort()[0];
    const sale = { ...templateSale, id, campaign_id: campaign.id, promoter_id: fixtureUser, promoter_name: r['Promoter Name'], promoter_code: r['Promoter ID'],
      promoter_type: r['Promoter Type'], biz_date: r.Date, created_at: time, state_name: r.State, state_id: uid(r.State),
      territory_name: r.Territory, territory_id: uid(r.Territory), tse_name: r['TSE Name'], tse_code: r['TSE Code'], tse_id: r['TSE Code'] ? uid(r['TSE Code']) : null,
      outlet_id: uid(r['Outlet Code']), outlet_code: r['Outlet Code'], outlet_name: r['Outlet Name'], outlet_area: r.Area, outlet_city: r.City,
      outlet_license_no: r['Licence No.'], outlet_address: r['Outlet Address'], distributor: r.Distributor, quantity: r.Quantity,
      spins_allowed: r.Quantity, spins_used: rows.length, status: 'completed', product_id: productId(codes[0][1]), sku_code: codes[0][1], product_name: names[0][1] };
    sales.push(sale);
    codes.forEach((match, i) => {
      const pid = productId(match[1]);
      if (!existingProducts[match[1]]) products.set(pid, { ...templateProduct, id: pid, sku_code: match[1], name: names[i][1] });
      items.push({ id: uid(`${id}:${pid}`), sale_id: id, product_id: pid, sku_code: match[1], product_name: names[i][1], quantity: Number(match[2]), created_at: time });
    });
    [...rows].sort((a, b) => a.Time.localeCompare(b.Time)).forEach((r, index) => {
      const code = r.Prize.includes('Speaker') ? 'SPEAKER' : r['Prize Cost'] === 10 ? 'SNACK10' : 'SNACK5';
      spins.push({ ...templateSpin, id: uid(r['Spin ID']), spin_code: r['Spin ID'], sale_id: id, spin_no: index + 1, campaign_id: campaign.id,
        promoter_id: fixtureUser, biz_date: r.Date, created_at: r.Date + 'T' + r.Time + '+05:30', config_version: r['Prize Config Version'],
        prize_id: prizes[code].id, prize_code: code, prize_name: r.Prize, prize_cost: r['Prize Cost'], prize_tier: prizes[code].tier,
        redemption_status: r['Redemption Status'], inventory_status: r['Inventory Status'], handed_over_at: null,
        distribution_version: null, distribution_mode: null, pool_id: null, slot_position: null, original_prize_id: null, substituted: false });
    });
  }
  const fixtureRows = (table, rows) => `insert into public.${table} select * from jsonb_populate_recordset(null::public.${table},${jsonSql(rows)});`;
  sql(`set session_replication_role=replica;
    insert into auth.users(id,email) values (${quote(fixtureUser)},'transaction-benchmark@local.invalid'),(${quote(controlUser)},'transaction-controls@local.invalid'),(${quote(supervisor)},'transaction-supervisor@local.invalid');
    insert into public.app_users(id,login_id,full_name,role,is_active) values
      (${quote(fixtureUser)},'transaction-benchmark','Transaction Benchmark','promoter',true),
      (${quote(controlUser)},'transaction-controls','Transaction Controls','promoter',true),
      (${quote(supervisor)},'transaction-supervisor','Transaction Supervisor','supervisor',true);
    insert into public.promoters(user_id,promoter_code,supervisor_id) values (${quote(fixtureUser)},'TXN-BENCHMARK',${quote(supervisor)}),(${quote(controlUser)},'TXN-CONTROLS',null);
    ${fixtureRows('products', [...products.values()])}
    ${fixtureRows('sales', sales)} ${fixtureRows('sale_items', items)} ${fixtureRows('spins', spins)}
    set session_replication_role=origin;
    grant usage on schema public,auth to authenticated;
    grant select on public.sales,public.spins,public.sale_items,public.campaigns,public.app_users,public.promoters to authenticated;
    grant execute on function public.get_reporting_excluded_users() to authenticated;`);
  pass('Supplied export reconstructed as 40 bills / 220 real PostgreSQL spin records, without inventing missing rule or handover timestamps');
  const before = snapshot();
  sql(migration); sql(migration);
  assert.equal(snapshot(), before);
  pass('Migration and idempotent rerun preserve EVERY existing public table, function body/ACL, view and RLS policy');
  const f = { promoter_id: fixtureUser, date_from: '2026-10-01', date_to: '2026-11-05' };
  const source = readAll(f, 7);
  const report = buildTransactionReport(source);
  assert.deepEqual([report.bills.length, report.summary.units, report.spins.length, report.summary.handed_over, report.summary.prize_cost, report.summary.handed_over_cost, report.summary.sku_units], [40, 220, 220, 220, 2115, 2115, 220]);
  assert.equal(report.summary.checks, 0);
  assert.equal(report.spins.filter(s => s.prize_code === 'SPEAKER').length, 4);
  assert.ok(report.spins.every(s => s.distribution_version === 'Not recorded'));
  assert.ok(report.spins.every(s => s.handover_date == null));
  pass('Actual source benchmark: 40 bills, 220 units/spins, 4 speakers, INR2,115; all SKU totals reconcile');
  const key = source.find(b => b.items.length > 1).items[1].product_id;
  const skuSource = readAll({ ...f, product_id: key }, 7);
  assert.ok(skuSource.every(b => b.items.some(i => i.product_id === key)));
  const skuReport = buildTransactionReport(skuSource, { product_id: key });
  assert.ok(skuReport.skus.every(r => r.product_id === key));
  assert.equal(skuReport.summary.sku_units, skuSource.reduce((n, b) => n + b.items.filter(i => i.product_id === key).reduce((n, i) => n + i.quantity, 0), 0));
  pass('Mixed-SKU filter selects matching whole bills/prizes and exact matching SKU quantities');
  const example = source[0];
  for (const k of ['campaign_id', 'state_id', 'territory_id', 'outlet_id', 'area', 'city']) {
    const filtered = readAll({ ...f, [k]: example[k] });
    assert.equal(filtered.length, source.filter(b => b[k] === example[k]).length);
  }
  const dated = readAll({ ...f, date_from: '2026-10-30', date_to: '2026-11-02' });
  assert.equal(buildTransactionReport(dated).spins.length, 29);
  assert.equal(readAll(f, 11, supervisor).length, 40);
  assert.equal(readAll({ ...f, promoter_id: controlUser }, 11, supervisor).length, 0);
  assert.equal(readAll({ ...f, date_from: '2026-11-04' }).length, 0);
  pass('Date, user, campaign, geography, outlet filters and supervisor row-level scope verified');
  const controlSales = []; const controlItems = []; const controlSpins = [];
  const addControl = (name, qty, status, count, opts = {}) => {
    const id = uid('control-' + name);
    controlSales.push({ ...sales[0], id, promoter_id: controlUser, promoter_name: 'Transaction Controls', biz_date: '2026-11-02', created_at: '2026-11-02T18:20:00Z',
      quantity: qty, spins_allowed: qty, spins_used: count, status, ...opts });
    if (name !== 'legacy') controlItems.push({ ...items[0], id: uid(id + '-item'), sale_id: id, quantity: qty });
    for (let i = 0; i < count; i++) controlSpins.push({ ...spins[0], id: uid(id + '-spin-' + i), spin_code: 'CONTROL-' + name + '-' + i,
      sale_id: id, promoter_id: controlUser, spin_no: i + 1, created_at: '2026-11-02T18:35:00Z', biz_date: '2026-11-02',
      distribution_version: i === 1 ? 8 : 7, distribution_mode: i === 1 ? 'speaker_third_daily' : 'snacks',
      prize_code: 'SNACK10', prize_name: 'INR10', prize_cost: 10, prize_id: prizes.SNACK10.id,
      redemption_status: status === 'spun' ? (i === 0 ? 'pending' : 'not_redeemed') : 'handed_over',
      inventory_status: status === 'spun' ? (i === 0 ? 'reserved' : 'released') : 'deducted',
      handed_over_at: status === 'spun' ? null : '2026-11-04T03:30:00Z' });
    return id;
  };
  addControl('legacy', 4, 'open', 0);
  addControl('partial', 3, 'spun', 2);
  addControl('cancelled', 5, 'cancelled', 0);
  const midnight = addControl('midnight', 1, 'completed', 1);
  addControl('future', 1, 'open', 0, { created_at: '2026-11-07T00:00:00Z' });
  for (let i = 0; i < 260; i++) addControl('page-' + i, 1, 'open', 0);
  sql(`set session_replication_role=replica;${fixtureRows('sales', controlSales)}${fixtureRows('sale_items', controlItems)}${fixtureRows('spins', controlSpins)}set session_replication_role=origin;`);
  const controlsBefore = snapshot();
  const controls = readAll({ promoter_id: controlUser });
  assert.equal(controls.length, 264);
  assert.equal(rpc({ promoter_id: controlUser }, null, cutoff, 9999).bills.length, 250);
  const cr = buildTransactionReport(controls);
  assert.deepEqual([cr.bills.length, cr.summary.units, cr.spins.length, cr.summary.pending, cr.summary.handed_over_cost], [264, 268, 3, 1, 10]);
  assert.equal(cr.bills.find(b => b.transaction_id === midnight).bill_date, '2026-11-02');
  assert.equal(cr.spins.find(b => b.transaction_id === midnight).spin_date, '2026-11-03');
  assert.equal(cr.spins.find(b => b.transaction_id === midnight).handover_date, '2026-11-04');
  assert.equal(cr.bills.find(b => b.item_source === 'Legacy bill').bill_quantity, 4);
  pass('264 bill pagination, cancelled/open/partial/legacy bills, pending/not-redeemed prizes and cross-midnight spin/handover dates');
  const first = rpc({ promoter_id: controlUser }, null, null, 1);
  assert.ok(first.as_of && first.next_after);
  assert.equal(rpc({ promoter_id: controlUser }, first.next_after, first.as_of, 1).as_of, first.as_of);
  pass('Server cutoff and keyset cursor are stable across page requests; future bill excluded');
  const perms = JSON.parse(sql(`select jsonb_build_object('anonymous',has_function_privilege('anon','public.transaction_report_page(jsonb,uuid,timestamptz,integer)','execute'),
    'invoker',(select not prosecdef from pg_proc where oid='public.transaction_report_page(jsonb,uuid,timestamptz,integer)'::regprocedure),
    'stable',(select provolatile='s' from pg_proc where oid='public.transaction_report_page(jsonb,uuid,timestamptz,integer)'::regprocedure))`).trim());
  assert.deepEqual(perms, { anonymous: false, invoker: true, stable: true });
  assert.throws(() => rpc(f, null, cutoff, 250, fixtureUser), /STAFF_ONLY/);
  assert.equal(snapshot(), controlsBefore);
  pass('SELECT-only authenticated invoker RPC rejects promoters/anonymous; ALL reads preserve data/settings/functions/policies');
  sql(rollback); sql(rollback);
  assert.equal(sql("select to_regprocedure('public.transaction_report_page(jsonb,uuid,timestamptz,integer)') is null").trim(), 't');
  assert.equal(snapshot(), controlsBefore);
  pass('Rollback and repeated rollback remove only the new reporting RPC; all existing data and logic preserved');
  sql(migration);
  mkdirSync('.cache/transaction-ui-tools', { recursive: true });
  writeFileSync('.cache/transaction-ui-tools/report-fixture.json', JSON.stringify({ bills: source, report, db, user: fixtureUser, admin, cutoff }));
  const tests = spawnSync('node', ['--test', 'test/transaction-report.test.mjs'], { encoding: 'utf8', env: { ...process.env, TXN_SOURCE_JSON: inputPath } });
  log.push(tests.stdout + tests.stderr); assert.equal(tests.status, 0);
  pass('Frontend dataset/export regression tests including the supplied original workbook rows');
  log.push('ALL TRANSACTION REPORT DATABASE CHECKS PASSED. Production was not contacted.');
  console.log(log.at(-1));
} catch (e) {
  log.push('FAILED: ' + e.stack); console.error(log.at(-1)); process.exitCode = 1;
} finally {
  writeFileSync('outputs/transaction-report-validation.log', log.join('\n') + '\n');
}
