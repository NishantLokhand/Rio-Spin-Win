import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import * as XLSX from 'xlsx';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const source = path.join(root, 'source_file');
const files = await (await import('node:fs/promises')).readdir(source);
const findFile = (prefix) => path.join(source, files.find((name) => name.startsWith(prefix) && name.endsWith('.xlsx')) || '');
async function sheet(file) {
  const buf = await readFile(file);
  const book = XLSX.read(buf, { type: 'buffer' });
  return XLSX.utils.sheet_to_json(book.Sheets[book.SheetNames[0]], { header: 1, defval: '' });
}
const [up, mh, inv] = await Promise.all([
  sheet(findFile('UP_')),
  sheet(findFile('Maharahstra')),
  sheet(findFile('MH-UP')),
]);
const clean = (x) => String(x ?? '').trim().replace(/\s+/g, ' ').toUpperCase();
const role = (x) => clean(x);
const upPeople = up.slice(1).filter((r) => clean(r[2]) && ['PROMOTER','TSE','MER'].includes(role(r[3])));
const mhPeople = mh.slice(1).filter((r) => clean(r[6]) && ['TSE','MER'].includes(role(r[7])));
const inventory = inv.slice(1).filter((r) => clean(r[6]) && ['PROMOTER','TSE','MER','ASM'].includes(role(r[7])));
const counts = (rows, index) => Object.fromEntries([...new Set(rows.map((r) => role(r[index])))].map((v) => [v, rows.filter((r) => role(r[index]) === v).length]));
assert.deepEqual(counts(upPeople, 3), { TSE: 10, MER: 25, PROMOTER: 44 });
assert.deepEqual(counts(mhPeople, 7), { TSE: 30, MER: 19 });
assert.deepEqual(counts(inventory, 7), { TSE: 40, MER: 45, ASM: 6, PROMOTER: 42 });
assert.ok(inventory.every((r) => Number(r[10]) === 152 && Number(r[11]) === 34), 'Inventory rows should retain the source allocation quantities 152/34.');
for (const col of [1, 2]) {
  const ids = mhPeople.map((r) => clean(r[col])).filter(Boolean);
  assert.equal(ids.length, new Set(ids).size, `Maharashtra source identifier column ${col} must be unique.`);
}
const masterPromoters = new Set(upPeople.filter((r) => role(r[3]) === 'PROMOTER').map((r) => clean(r[2])));
const masterPromoterKeys = new Set(upPeople.filter((r) => role(r[3]) === 'PROMOTER').map((r) => `${clean(r[2])}|UTTAR PRADESH|${clean(r[0])}`));
const upInventoryPromoters = inventory.filter((r) => role(r[7]) === 'PROMOTER' && clean(r[4]) === 'UTTAR PRADESH');
const invNames = new Set(upInventoryPromoters.map((r) => clean(r[6])));
assert.equal(upInventoryPromoters.length, 42);
assert.ok(upInventoryPromoters.every((r) => masterPromoterKeys.has(`${clean(r[6])}|${clean(r[4])}|${clean(r[5])}`)), 'Every UP promoter inventory row must match one master by exact normalized name, state and market.');
const missing = [...masterPromoters].filter((name) => !invNames.has(name)).sort();
assert.deepEqual(missing, ['AJIT PRATAP', 'MONU VISHKWRMA']);
console.log('Workbook source checks passed:', JSON.stringify({
  upMaster: counts(upPeople, 3), maharashtraMaster: counts(mhPeople, 7), inventory: counts(inventory, 7),
  upPromoterInventoryMatched: upInventoryPromoters.length, upPromotersWithoutInventory: missing.length,
}));
