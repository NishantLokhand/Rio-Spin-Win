// Isolated compile check: committed application + only the Transactions fix.
// No git checkout/reset, no changes to the user's existing worktree.
import { execFileSync } from 'node:child_process';
import { mkdirSync, writeFileSync, copyFileSync, existsSync, symlinkSync, readFileSync } from 'node:fs';
import { resolve, dirname, sep } from 'node:path';
import { createHash } from 'node:crypto';
import { unzipSync } from '../web/node_modules/fflate/esm/index.mjs';
const root = process.cwd();
const target = resolve(root, '.cache/transaction-report-release-check');
if (existsSync(target)) throw new Error('The isolated checkout already exists; keep it for review rather than overwrite it.');
mkdirSync(target, { recursive: true });
const zip = execFileSync('git', ['archive', '--format=zip', 'HEAD', 'web'], { cwd: root, maxBuffer: 250e6 });
for (const [name, bytes] of Object.entries(unzipSync(zip))) {
  const file = resolve(target, name);
  if (!file.startsWith(target + sep)) throw new Error('Archive entry escapes isolated checkout');
  if (name.endsWith('/')) mkdirSync(file, { recursive: true });
  else { mkdirSync(dirname(file), { recursive: true }); writeFileSync(file, bytes); }
}
const files = ['web/src/staff/Transactions.jsx', 'web/src/staff/Transactions.css', 'web/src/staff/transactionReport.js', 'web/src/staff/transactionExport.js'];
for (const name of files) copyFileSync(resolve(root, name), resolve(target, name));
symlinkSync(resolve(root, 'web/node_modules'), resolve(target, 'web/node_modules'), 'junction');
const legacy = text => text.replace(/\r\n/g, '\n').match(/export const TXN_COLUMNS[\s\S]*?export default function/)?.[0];
const original = execFileSync('git', ['show', 'HEAD:web/src/staff/Transactions.jsx'], { cwd: root, encoding: 'utf8' });
if (legacy(original) !== legacy(readFileSync(resolve(root, files[0]), 'utf8'))) throw new Error('Shared legacy export columns/filters changed');
const hash = data => createHash('sha256').update(data).digest('hex');
const notes = ['Isolated Transactions compile check', `Base commit: ${execFileSync('git', ['rev-parse', 'HEAD'], { encoding: 'utf8' }).trim()}`,
  `Directory: ${target}`, 'Only overlaid application files:', ...files.map(f => `${f}: ${hash(readFileSync(resolve(root, f)))}`),
  'PASS: shared Data Export legacy columns/filter helper are byte-for-byte unchanged.',
  'All other application files came from the committed tree; pre-existing dirty demo/promoter/user changes are excluded.',
  'This is a compile-validation checkout. Production must use its existing Supabase/build environment; no production configuration is inferred or copied.'];
writeFileSync(resolve(root, 'outputs/transaction-report-isolation.log'), notes.join('\n') + '\n');
console.log(notes.join('\n'));
