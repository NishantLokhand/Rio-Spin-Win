import { unzipSync, zipSync, strFromU8, strToU8 } from 'fflate';

// Write real OOXML frozen panes. SheetJS CE does not serialize a !freeze setting.
export function freezeExcelHeaders(bytes) {
  const files = unzipSync(new Uint8Array(bytes));
  for (const name of Object.keys(files)) {
    if (!/^xl\/worksheets\/sheet\d+\.xml$/.test(name)) continue;
    let xml = strFromU8(files[name]);
    const views = '<sheetViews><sheetView workbookViewId="0"><pane ySplit="1" topLeftCell="A2" activePane="bottomLeft" state="frozen"/><selection pane="bottomLeft" activeCell="A2" sqref="A2"/></sheetView></sheetViews>';
    if (/<sheetViews\b/.test(xml)) xml = xml.replace(/<sheetViews\b[^>]*>[\s\S]*?<\/sheetViews>/, views);
    else xml = xml.replace(/(<dimension\b[^>]*\/>)/, `$1${views}`);
    if (!xml.includes('state="frozen"')) throw new Error('Could not freeze the Excel header row.');
    files[name] = strToU8(xml);
  }
  return zipSync(files, { level: 1 });
}
