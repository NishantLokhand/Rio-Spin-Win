// Transactions-only workbook layout. Existing exporter behavior is preserved.
import { transactionExcelRows } from './transactionReport.js';
import { freezeExcelHeaders } from '../lib/freezeExcelHeaders.js';

export function createTransactionWorkbook(XLSX, sheets) {
  const wb = XLSX.utils.book_new();
  for (const { name, rows, columns } of sheets) {
    const ws = XLSX.utils.json_to_sheet(transactionExcelRows(rows, columns), { header: columns.map(c => c.label) });
    if (ws['!ref']) ws['!autofilter'] = { ref: ws['!ref'] };
    ws['!cols'] = columns.map(({ key, label }) => ({ wch: key === 'sku_basket' ? 65
      : ['transaction_id', 'outlet_code'].includes(key) ? 39
      : /name|address|mode|check/.test(key) ? 29 : Math.max(15, Math.min(28, label.length + 2)) }));
    columns.forEach(({ key }, col) => {
      const format = /^(bill_date|bill_recorded_date|spin_date|handover_date)$/.test(key) ? 'yyyy-mm-dd'
        : /^(bill_time|spin_time|handover_time)$/.test(key) ? 'hh:mm:ss'
          : /cost$/.test(key) ? '"₹"#,##0.00' : null;
      if (format) rows.forEach((_, row) => {
        const cell = ws[XLSX.utils.encode_cell({ r: row + 1, c: col })];
        if (cell?.t === 'n') cell.z = format;
      });
    });
    XLSX.utils.book_append_sheet(wb, ws, name);
  }
  return wb;
}

export async function exportTransactionWorkbook(sheets, name) {
  const XLSX = await import('xlsx');
  const wb = createTransactionWorkbook(XLSX, sheets);
  const bytes = freezeExcelHeaders(XLSX.write(wb, { bookType: 'xlsx', type: 'array' }));
  const url = URL.createObjectURL(new Blob([bytes], { type: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet' }));
  const link = document.createElement('a');
  link.href = url; link.download = `${name}.xlsx`; document.body.appendChild(link); link.click(); link.remove();
  setTimeout(() => URL.revokeObjectURL(url), 2000);
}
