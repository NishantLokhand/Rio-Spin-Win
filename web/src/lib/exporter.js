// CSV + Excel export (Excel via SheetJS, loaded on demand)
function csvCell(v) {
  if (v == null) return '';
  const s = typeof v === 'object' ? JSON.stringify(v) : String(v);
  return /[",\n]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s;
}

function download(blob, filename) {
  const a = document.createElement('a');
  a.href = URL.createObjectURL(blob); a.download = filename;
  document.body.appendChild(a); a.click(); a.remove();
  setTimeout(() => URL.revokeObjectURL(a.href), 2000);
}

/** columns: [{key, label}] */
export function exportCSV(rows, columns, name) {
  const cols = columns || Object.keys(rows[0] || {}).map((k) => ({ key: k, label: k }));
  const lines = [cols.map((c) => csvCell(c.label)).join(',')];
  for (const r of rows) lines.push(cols.map((c) => csvCell(r[c.key])).join(','));
  download(new Blob(['﻿' + lines.join('\n')], { type: 'text/csv;charset=utf-8' }), `${name}.csv`);
}

export async function exportXLSX(rows, columns, name) {
  const XLSX = await import('xlsx');
  const cols = columns || Object.keys(rows[0] || {}).map((k) => ({ key: k, label: k }));
  const data = rows.map((r) => Object.fromEntries(cols.map((c) => [c.label, r[c.key]])));
  const ws = XLSX.utils.json_to_sheet(data, { header: cols.map((c) => c.label) });
  const wb = XLSX.utils.book_new();
  XLSX.utils.book_append_sheet(wb, ws, name.slice(0, 31));
  const out = XLSX.write(wb, { bookType: 'xlsx', type: 'array' });
  download(new Blob([out], { type: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet' }), `${name}.xlsx`);
}

/** Parse an uploaded .xlsx/.xls/.csv into array of objects with normalised keys */
export async function parseSheet(file) {
  const XLSX = await import('xlsx');
  const buf = await file.arrayBuffer();
  const wb = XLSX.read(buf, { type: 'array' });
  const ws = wb.Sheets[wb.SheetNames[0]];
  const rows = XLSX.utils.sheet_to_json(ws, { defval: '', raw: false });
  return rows.map((r) => Object.fromEntries(Object.entries(r).map(([k, v]) => [
    String(k).trim().toLowerCase().replace(/[^a-z0-9]+/g, '_').replace(/^_|_$/g, ''), typeof v === 'string' ? v.trim() : v,
  ])));
}
