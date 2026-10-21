import assert from 'node:assert/strict';
import * as XLSX from '../web/node_modules/xlsx/xlsx.mjs';
import { exportWorkbook, exportXLSX, exportCSV } from '../web/src/lib/exporter.js';
import { createRequire } from 'node:module';
import { writeFile } from 'node:fs/promises';
const { unzipSync, strFromU8 } = createRequire(new URL('../web/package.json',import.meta.url))('fflate');
let saved;
const create = URL.createObjectURL;
URL.createObjectURL = (blob) => { saved = blob; return 'blob:test'; };
globalThis.document = { createElement: () => ({ click() {}, remove() {} }), body: { appendChild() {} } };
await exportWorkbook([
  { name: 'Summary', rows: [{ user: 'A', missed: 1 }], columns: [{ key: 'user', label: 'User' }, { key: 'missed', label: 'Days Without Spins' }] },
  { name: 'Daily Detail', rows: [{ date: '2026-10-17', user: 'A', spins: 0 }], columns: [{ key: 'date', label: 'Date' }, { key: 'user', label: 'User' }, { key: 'spins', label: 'Spins' }] },
], 'history');
URL.createObjectURL = create;
const book = XLSX.read(await saved.arrayBuffer(), { type: 'array' });
const multi = new Uint8Array(await saved.arrayBuffer());
for(const [name,bytes] of Object.entries(unzipSync(multi))) if(/^xl\/worksheets\/sheet\d+\.xml$/.test(name)) {
  const xml=strFromU8(bytes);assert.match(xml,/<pane ySplit="1" topLeftCell="A2" activePane="bottomLeft" state="frozen"\/>/);
  assert.match(xml,/<autoFilter/);
}
assert.deepEqual(book.SheetNames, ['Summary', 'Daily Detail']);
assert.deepEqual(XLSX.utils.sheet_to_json(book.Sheets['Daily Detail']), [{ Date: '2026-10-17', User: 'A', Spins: 0 }]);
assert.equal(book.Sheets['Daily Detail']['!autofilter'].ref, 'A1:C2');
assert.equal(book.Sheets.Summary.B2.v, 1);
URL.createObjectURL = (blob) => { saved = blob; return 'blob:test'; };
const columns=[{key:'user',label:'User'},{key:'spins',label:'Spins'}];
await exportXLSX([{user:'मराठी, User',spins:0}],columns,'single');
const single=new Uint8Array(await saved.arrayBuffer());
assert.match(strFromU8(unzipSync(single)['xl/worksheets/sheet1.xml']),/state="frozen"/);
assert.deepEqual(XLSX.utils.sheet_to_json(XLSX.read(single).Sheets.single),[{User:'मराठी, User',Spins:0}]);
await writeFile(new URL('../.cache/frozen-header-test.xlsx',import.meta.url),single);
exportCSV([{user:'मराठी, User',spins:0}],columns,'csv');
assert.equal(await saved.text(),'User,Spins\n"मराठी, User",0');
URL.createObjectURL = create;
console.log('PASS: two-sheet history Excel export, sortable ISO dates, numeric zero and column filters.');
console.log('PASS: real frozen header XML on every Excel sheet; single-sheet data and CSV headers/escaping unchanged.');
