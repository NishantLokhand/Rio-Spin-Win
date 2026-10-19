import assert from 'node:assert/strict';
import * as XLSX from '../web/node_modules/xlsx/xlsx.mjs';
import { exportWorkbook } from '../web/src/lib/exporter.js';
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
assert.deepEqual(book.SheetNames, ['Summary', 'Daily Detail']);
assert.deepEqual(XLSX.utils.sheet_to_json(book.Sheets['Daily Detail']), [{ Date: '2026-10-17', User: 'A', Spins: 0 }]);
assert.equal(book.Sheets['Daily Detail']['!autofilter'].ref, 'A1:C2');
assert.equal(book.Sheets.Summary.B2.v, 1);
console.log('PASS: two-sheet history Excel export, sortable ISO dates, numeric zero and column filters.');
