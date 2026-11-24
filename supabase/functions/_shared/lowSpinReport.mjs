// Shared deterministic rendering for the scheduled report and local preview/tests.
export const BURGUNDY = '#722F37';
export const REPORT_TO = 'sanjay.waghela@gooddropwine.com';
export const REPORT_CC = ['shiv.kumar@gooddropwine.com', 'chandra.mohan@gooddropwine.com'];
export const REPORT_COLUMNS = [
  ['date','Date'],['label','User'],['user_type','Type'],['market','Market'],['state','State'],
  ['outlets','Outlets Visited'],['active_outlets','Outlets Covered'],['spins','Spins'],['units','Units Sold'],
  ['first_spin_time','First spin time (IST)'],['last_spin_time','Last spin time (IST)'],['activity_span','Activity span'],
  ['giveaway_cost','Giveaway Cost'],['avg_cost','Average Cost'],['prizes_given','Prizes Given'],
  ['active_days','Days With Spins'],['no_spin_days','Days Without Spins'],['activity_pct','Activity %'],
  ['snack5_used_pct','₹5 Snack Used % (Current)'],['snack10_used_pct','₹10 Snack Used % (Current)'],
  ['mobile','Mobile Number'],['account_status','Account Status'],['account_date','Account Created'],
];
const escape = value => String(value ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&apos;'}[c]));
const num = value => Number(value || 0).toLocaleString('en-IN', { maximumFractionDigits: 1 });
export function validateLowSpinReport(report) {
  if (!report || !/^\d{4}-\d{2}-\d{2}$/.test(report.date) || !Array.isArray(report.rows) || !Array.isArray(report.states) || !Array.isArray(report.markets)) throw new Error('Invalid low-spin report');
  const s = report.summary;
  for (const key of ['total_users','below_target','zero_users','low_active_users','target_reached']) {
    if (!Number.isInteger(Number(s?.[key])) || Number(s[key]) < 0) throw new Error('Invalid report summary');
  }
  if (Number(s.below_target) !== report.rows.length || Number(s.zero_users) + Number(s.low_active_users) !== report.rows.length
      || Number(s.target_reached) + report.rows.length !== Number(s.total_users)) throw new Error('Report totals do not reconcile');
  const seen = new Set();
  for (const row of report.rows) {
    if (row.date !== report.date || !row.key || seen.has(row.key) || !Number.isInteger(Number(row.spins)) || Number(row.spins) < 0 || Number(row.spins) >= 10) throw new Error('Invalid or duplicate user in 0–9 spin report');
    seen.add(row.key);
  }
  if (report.rows.filter(r => Number(r.spins) === 0).length !== Number(s.zero_users)) throw new Error('Zero-spin total does not reconcile');
  for (const groups of [report.states, report.markets]) {
    if (groups.reduce((n,r) => n+Number(r.below_target),0) !== report.rows.length
        || groups.reduce((n,r) => n+Number(r.total_users),0) !== Number(s.total_users)) throw new Error('Geography totals do not reconcile');
  }
  return report;
}
export function lowSpinEmail(report, { test = false } = {}) {
  validateLowSpinReport(report);
  const s = report.summary;
  const cell = 'padding:11px 12px;border-bottom:1px solid #e8dfe0;text-align:left;font:14px Arial,sans-serif;';
  const head = (labels) => `<tr>${labels.map(x=>`<th style="${cell}background:${BURGUNDY};color:#fff">${escape(x)}</th>`).join('')}</tr>`;
  const table = (headers,rows) => `<table width="100%" cellpadding="0" cellspacing="0" style="border-collapse:collapse">${head(headers)}${rows.map((row,i)=>`<tr style="background:${i%2?'#faf5f6':'#fff'}">${row.map(x=>`<td style="${cell}">${escape(x)}</td>`).join('')}</tr>`).join('')}</table>`;
  const kpi = (label,value) => `<td width="50%" style="padding:6px"><table width="100%" style="border:1px solid #e8dfe0;border-radius:8px;background:#fff"><tr><td style="padding:16px;color:${BURGUNDY};font:13px Arial,sans-serif">${escape(label)}<br><strong style="font-size:32px;line-height:42px">${num(value)}</strong></td></tr></table></td>`;
  const title = 'Less than 10 spins users';
  const subject = `${test?'[TEST] ':''}RIO Spin & Win | ${title} | ${report.date}`;
  const filename = `rio_less_than_10_spins_${report.date}.xlsx`;
  const html = `<!doctype html><html><head><meta name="viewport" content="width=device-width, initial-scale=1"></head><body style="margin:0;padding:24px 8px;background:#f3ecee;color:#2b2224;font-family:Arial,sans-serif">
  <table role="presentation" width="100%" cellpadding="0" cellspacing="0"><tr><td align="center"><table role="presentation" width="680" cellpadding="0" cellspacing="0" style="width:100%;max-width:680px;background:#fff;border-radius:12px;overflow:hidden">
  <tr><td style="padding:28px;background:${BURGUNDY};color:#fff"><div style="font-size:13px;letter-spacing:2px">RIO SPIN &amp; WIN</div><h1 style="font-size:27px;line-height:34px;margin:12px 0">${title}</h1><div style="font-size:16px">${escape(report.date)} · India time${report.in_progress?' · In progress':' · Complete day'}</div>${test?'<p style="margin:12px 0 0;font-size:13px">TEST DELIVERY — please verify the dashboard and attachment.</p>':''}</td></tr>
  <tr><td style="padding:24px"><p style="font-size:15px;line-height:23px;margin-top:0">Dear Sanjay Sir,<br>Here is the daily field-team follow-up for users with <strong>0–9 spins</strong>. The complete user list and summaries are attached in Excel.</p>
  <table role="presentation" width="100%" cellspacing="0"><tr>${kpi('Users below 10 spins',s.below_target)}${kpi('Zero spins',s.zero_users)}</tr><tr>${kpi('Users with 1–9 spins',s.low_active_users)}${kpi('Users with 10+ spins',s.target_reached)}</tr></table>
  <p style="padding:14px;background:#faf5f6;color:${BURGUNDY};font-size:15px"><strong>${num(s.below_target_pct)}%</strong> below 10 spins · <strong>${num(s.total_users)}</strong> eligible active users</p>
  <h2 style="font-size:20px;color:${BURGUNDY};margin:26px 0 12px">State performance</h2>${table(['State','Active users','0 spins','1–9 spins','10+ spins'],report.states.map(r=>[r.label,num(r.total_users),num(r.zero_users),num(r.low_active_users),num(r.target_reached)]))}
  <h2 style="font-size:20px;color:${BURGUNDY};margin:26px 0 12px">Markets needing follow-up</h2>${table(['State / Market','Below 10','Zero spins'],report.markets.filter(r=>r.below_target>0).slice(0,10).map(r=>[`${r.state} / ${r.label}`,num(r.below_target),num(r.zero_users)]))}
  <h2 style="font-size:20px;color:${BURGUNDY};margin:26px 0 12px">User follow-up</h2>${report.rows.length?table(['User','Type','Market','Spins'],report.rows.slice(0,20).map(r=>[r.label,r.user_type,r.market,num(r.spins)])):'<p>No users recorded fewer than 10 spins for this date.</p>'}
  ${report.rows.length>20?`<p style="font-size:13px;color:#6f6064">Showing 20 of ${num(report.rows.length)} users. All users are in the Excel attachment.</p>`:''}
  <p style="margin:24px 0"><a href="https://riospinandwin.com/#reports" style="display:inline-block;background:${BURGUNDY};padding:13px 22px;color:#fff;text-decoration:none;border-radius:6px;font-weight:bold">Open RIO reports</a></p>
  <p style="font-size:12px;line-height:19px;color:#77666c;margin-bottom:0">Current active field accounts only; test/demo, deleted and excluded accounts are omitted. State/City/Area describe the user profile. Outlets are recorded visits. Stock usage is current, not historical. Activity span is first-to-last spin, including gaps, not verified work hours.</p>
  </td></tr><tr><td style="padding:18px 24px;background:#faf5f6;color:#77666c;font-size:12px">RIO Spin &amp; Win · Daily management report · Generated automatically</td></tr></table></td></tr></table></body></html>`;
  const text = `Dear Sanjay Sir,\n${title} — ${report.date} (India time).\nBelow 10: ${s.below_target}; zero spins: ${s.zero_users}; 1–9 spins: ${s.low_active_users}; 10+ spins: ${s.target_reached}; eligible active users: ${s.total_users}.\nComplete Excel report attached.\nhttps://riospinandwin.com/#reports`;
  return { subject, html, text, filename };
}

// Small standards-based OOXML writer for Edge runtime: text stays text (no formula injection).
// zipSync is injected, keeping the renderer deterministic and independently testable.
export function lowSpinWorkbook(report, zipSync) {
  validateLowSpinReport(report);
  const files = {}, enc = new TextEncoder();
  const put = (name,text) => files[name]=enc.encode(text);
  const col = n => { let s='';for(n++;n;n=Math.floor((n-1)/26))s=String.fromCharCode(65+(n-1)%26)+s;return s; };
  function sheet(name,rows,widths,headerRow=1,merges=[]) {
    const xmlRows=rows.map((row,i)=>`<row r="${i+1}" ht="${i<headerRow-1?i===0?32:25:Math.min(409,Math.max(30,...row.map((raw,j)=>Math.ceil(String(raw?.v??raw??'').length/(widths[j]||20))*14)))}" customHeight="1">${row.map((raw,j)=>{
      const obj=raw&&typeof raw==='object'?raw:{v:raw};const v=obj.v;
      const style=obj.s??(i===headerRow-1?1:i%2?4:0);const ref=col(j)+(i+1);
      return typeof v==='number'&&Number.isFinite(v)?`<c r="${ref}" s="${style}" t="n"><v>${v}</v></c>`:`<c r="${ref}" s="${style}" t="inlineStr"><is><t xml:space="preserve">${escape(v??'')}</t></is></c>`;
    }).join('')}</row>`).join('');
    const last=col(Math.max(...rows.map(r=>r.length))-1)+Math.max(rows.length,1);
    return `<?xml version="1.0" encoding="UTF-8" standalone="yes"?><worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><dimension ref="A1:${last}"/><sheetViews><sheetView workbookViewId="0" showGridLines="0"><pane ySplit="${headerRow}" topLeftCell="A${headerRow+1}" activePane="bottomLeft" state="frozen"/></sheetView></sheetViews><cols>${widths.map((w,i)=>`<col min="${i+1}" max="${i+1}" width="${w}" customWidth="1"/>`).join('')}</cols><sheetData>${xmlRows}</sheetData>${headerRow===1?`<autoFilter ref="A1:${last}"/>`:''}${merges.length?`<mergeCells count="${merges.length}">${merges.map(x=>`<mergeCell ref="${x}"/>`).join('')}</mergeCells>`:''}<pageMargins left="0.25" right="0.25" top="0.4" bottom="0.4" header="0.2" footer="0.2"/><pageSetup orientation="landscape" paperSize="9" fitToWidth="1" fitToHeight="0"/></worksheet>`;
  }
  const s=report.summary;
  const summary=[
    [{v:'RIO SPIN & WIN',s:2}], [{v:'Less than 10 spins users',s:2}],
    [{v:`Report date: ${report.date} · India time${report.in_progress?' · In progress':' · Complete day'}`,s:3}],[],
    [{v:'Below 10 spins',s:1},{v:s.below_target,s:5},{v:'Zero spins',s:1},{v:s.zero_users,s:5}],
    [{v:'1–9 spins',s:1},{v:s.low_active_users,s:5},{v:'10+ spins',s:1},{v:s.target_reached,s:5}],
    [{v:'Eligible active users',s:1},{v:s.total_users,s:5},{v:'Below-target %',s:1},{v:Number(s.below_target_pct),s:6}],[],
    ['State','Active users','Zero spins','1–9 spins','10+ spins','Below 10'],
    ...report.states.map(r=>[r.label,r.total_users,r.zero_users,r.low_active_users,r.target_reached,r.below_target]),[],
    ['Current active field accounts; test/demo, deleted and excluded accounts omitted.'],
    ['User geography and recorded outlets are separate; stock usage shows current balances.'],
    ['Source: RIO app / report_less_than_ten_spins; daily India business date.'],
  ];
  // Explicitly style the state header without relying on its row index.
  summary[8]=summary[8].map(v=>({v,s:1}));
  const markets=[['State','Market','Active users','Below 10','Zero spins','1–9 spins','10+ spins'],
    ...report.markets.map(r=>[r.state,r.label,r.total_users,r.below_target,r.zero_users,r.low_active_users,r.target_reached])];
  const userHeader=REPORT_COLUMNS.map(([,label])=>label);
  const userData=r=>REPORT_COLUMNS.map(([key])=>{
    const value=r[key];return ['activity_pct','snack5_used_pct','snack10_used_pct'].includes(key)&&value!=null?{v:Number(value),s:6}:value;
  });
  const usersOneToNine=[userHeader,...report.rows.filter(r=>Number(r.spins)>=1).map(userData)];
  const zeroSpinUsers=[userHeader,...report.rows.filter(r=>Number(r.spins)===0).map(userData)];
  const names=['Dashboard','Market summary','Users 1-9 spins','Zero-spin users'];
  put('[Content_Types].xml',`<?xml version="1.0"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>${names.map((_,i)=>`<Override PartName="/xl/worksheets/sheet${i+1}.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>`).join('')}</Types>`);
  put('_rels/.rels','<?xml version="1.0"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>');
  put('xl/workbook.xml',`<?xml version="1.0"?><workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><bookViews><workbookView/></bookViews><sheets>${names.map((n,i)=>`<sheet name="${n}" sheetId="${i+1}" r:id="rId${i+1}"/>`).join('')}</sheets></workbook>`);
  put('xl/_rels/workbook.xml.rels',`<?xml version="1.0"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">${names.map((_,i)=>`<Relationship Id="rId${i+1}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet${i+1}.xml"/>`).join('')}<Relationship Id="rId${names.length+1}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/></Relationships>`);
  put('xl/styles.xml',`<?xml version="1.0"?><styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><numFmts count="1"><numFmt numFmtId="164" formatCode="0.00&quot;%&quot;"/></numFmts><fonts count="4"><font><sz val="11"/><color rgb="FF2B2224"/><name val="Calibri"/></font><font><b/><sz val="12"/><color rgb="FFFFFFFF"/><name val="Calibri"/></font><font><b/><sz val="22"/><color rgb="FF722F37"/><name val="Calibri"/></font><font><b/><sz val="26"/><color rgb="FF722F37"/><name val="Calibri"/></font></fonts><fills count="4"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill><fill><patternFill patternType="solid"><fgColor rgb="FF722F37"/><bgColor indexed="64"/></patternFill></fill><fill><patternFill patternType="solid"><fgColor rgb="FFFAF5F6"/><bgColor indexed="64"/></patternFill></fill></fills><borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders><cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs><cellXfs count="7"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0" applyAlignment="1"><alignment vertical="center" wrapText="1"/></xf><xf numFmtId="0" fontId="1" fillId="2" borderId="0" xfId="0" applyAlignment="1"><alignment vertical="center" wrapText="1"/></xf><xf numFmtId="0" fontId="2" fillId="0" borderId="0" xfId="0"/><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/><xf numFmtId="0" fontId="0" fillId="3" borderId="0" xfId="0" applyAlignment="1"><alignment vertical="center" wrapText="1"/></xf><xf numFmtId="0" fontId="3" fillId="3" borderId="0" xfId="0"/><xf numFmtId="164" fontId="0" fillId="0" borderId="0" xfId="0"/></cellXfs><cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles></styleSheet>`);
  put('xl/worksheets/sheet1.xml',sheet(names[0],summary,[30,18,26,18,18,18],4,['A1:F1','A2:F2','A3:F3',...summary.slice(-3).map((_,i)=>`A${summary.length-2+i}:F${summary.length-2+i}`)]));
  put('xl/worksheets/sheet2.xml',sheet(names[1],markets,[24,28,18,18,18,18,18]));
  const userWidths=REPORT_COLUMNS.map(([k])=>k==='outlets'?65:['label','prizes_given'].includes(k)?30:['market','state'].includes(k)?24:20);
  put('xl/worksheets/sheet3.xml',sheet(names[2],usersOneToNine,userWidths));
  put('xl/worksheets/sheet4.xml',sheet(names[3],zeroSpinUsers,userWidths));
  return zipSync(files,{level:6});
}
