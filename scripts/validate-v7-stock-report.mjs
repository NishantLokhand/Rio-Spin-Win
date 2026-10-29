import { readFileSync, writeFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
const baselineLog = readFileSync('outputs/v7-postgres-validation.log', 'utf8');
const database = baselineLog.match(/NEW isolated database: (rio_v7_validation_\d+)/)?.[1];
if (!database) throw new Error('Isolated V7 validation database is missing');
const snapshot = `create temporary table v7_stock_function_snapshot as
 select p.oid,md5(p.prosrc) as body_hash from pg_proc p join pg_namespace n on n.oid=p.pronamespace
 where n.nspname='public' and p.proname in ('_draw_cumulative_prize','_draw_cumulative_prize_v6_20261029','_draw_prize_v7_20261029','_v7_distribution_mode','set_prize_v7_enabled');
 create temporary table v7_stock_counter_snapshot as select * from public.prize_v7_allocations;`;
const migration = readFileSync('supabase/migrations/20261029000200_v7_remaining_stock_report.sql', 'utf8');
const tests = readFileSync('test/v7-stock-report.sql', 'utf8');
const result = spawnSync('docker', ['exec', '-i', 'supabase_db_rio-spin-win-v7-sandbox',
  'psql', '-X', '-U', 'postgres', '-d', database, '-v', 'ON_ERROR_STOP=1'],
  { input: snapshot + '\n' + migration + '\n' + tests, encoding: 'utf8' });
const log = [`Local reporting test: ${new Date().toISOString()}`, `Database: ${database}`,
  result.stdout, result.stderr, result.status === 0 ? 'ALL REPORT CHECKS PASSED' : 'REPORT CHECKS FAILED'].join('\n').replace(/[ \t]+$/gm, '').trimEnd() + '\n';
writeFileSync('outputs/v7-stock-report-validation.log', log);
console.log(log);
if (result.error) throw result.error;
process.exitCode = result.status ?? 1;
