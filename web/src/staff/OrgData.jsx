import React, { useMemo, useState } from 'react';
import { supabase } from '../lib/supabase.js';
import { rpc, selectAll, friendly } from '../lib/api.js';
import { Panel, DataTable, Field, Badge, Tabs } from './ui.jsx';

const norm = (v) => String(v ?? '').trim().replace(/\s+/g, ' ');
const keyPart = (v) => norm(v).toUpperCase().replace(/[^A-Z0-9]+/g, '-').replace(/^-|-$/g, '');
const beatKey = (v) => norm(v).replace(/\u00a0/g, ' ').toLowerCase().replace(/[^a-z0-9]/g, '');
const labelKey = (v) => norm(v).normalize('NFKC').replace(/\u00a0/g, ' ').toLocaleUpperCase('en-IN');
const outletLabel = (v) => norm(v).replace(/^\s*\(?\s*\d{3,}\s*\)?\s*[-–:]?\s*/, '').replace(/\u00a0/g, ' ').trim();
function outletCodeFromLabel(v) { const match = norm(v).match(/^\s*(?:\(\s*(\d{3,})\s*\)|(\d{3,})(?=\s|[-–:]))/); return match?.[1] || match?.[2] || ''; }
const role = (v) => ({ PROMOTER: 'PROMOTER', PROMO: 'PROMOTER', TSE: 'TSE', MER: 'MER', ASM: 'ASM' }[norm(v).toUpperCase()] || '');
async function readWorkbook(file) {
  const XLSX = await import('xlsx');
  const book = XLSX.read(await file.arrayBuffer(), { type: 'array' });
  return { names: book.SheetNames, sheets: book.Sheets, rows: (name) => XLSX.utils.sheet_to_json(book.Sheets[name], { header: 1, defval: '' }) };
}
function parseUP(rows) {
  return rows.slice(1).filter((r) => norm(r[2]) && role(r[3])).map((r) => ({
    designation: role(r[3]), employee_name: norm(r[2]), state_raw: 'UTTAR PRADESH', market_raw: norm(r[0]), area_raw: norm(r[1]),
    beat_values: r.slice(4).map(norm).filter(Boolean), source_system: 'UP_TSE_MER_PROMO_AREAS', source_ids: { source_row: rows.indexOf(r) + 1 },
    source_key: `UP:${role(r[3])}:${keyPart(r[2])}:${keyPart(r[0])}:${keyPart(r[1])}`,
  }));
}
function parseMH(rows) {
  return rows.slice(1).filter((r) => norm(r[6]) && role(r[7])).map((r) => ({
    designation: role(r[7]), employee_name: norm(r[6]), mobile: norm(r[8]), fas_id: norm(r[1]), qa_employee_id: norm(r[2]),
    state_raw: norm(r[4]), market_raw: norm(r[5]), zone_raw: norm(r[3]), area_raw: norm(r[9]), beat_values: r.slice(10).map(norm).filter(Boolean),
    source_system: 'MH_TSE_MER_PROMO_AREAS', source_ids: { sr_no: norm(r[0]) },
    source_key: `MH:${norm(r[1]) || norm(r[2]) || norm(r[8]) || `${role(r[7])}:${keyPart(r[6])}:${keyPart(r[4])}:${keyPart(r[5])}`}`,
  }));
}
function parseInventory(rows) {
  return rows.slice(1).map((r, index) => ({ r, source_row: index + 2 })).filter(({ r }) => norm(r[6]) && role(r[7])).map(({ r, source_row }) => ({
    source_row, employee_name: norm(r[6]), designation: role(r[7]), fas_id: norm(r[1]), qa_employee_id: norm(r[2]), zone_raw: norm(r[3]),
    state_raw: norm(r[4]), market_raw: norm(r[5]), mobile: norm(r[8]), area_raw: norm(r[9]), snack5: Number(r[10]) || 0, snack10: Number(r[11]) || 0,
  }));
}

function parsePromoterOutletRows(workbook) {
  const sheetName = workbook.names.find((name) => name.trim().toLowerCase() === 'promoter wise');
  if (!sheetName) throw new Error('The UP workbook is missing its “Promoter Wise” sheet.');
  const rows = workbook.rows(sheetName);
  return rows.slice(1).flatMap((row, index) => {
    const promoterName = norm(row[0]);
    if (!promoterName) return [];
    const outlets = row.slice(3).map(norm).filter(Boolean);
    return outlets.map((label, outletIndex) => ({ promoter_name: promoterName, market: norm(row[1]), beat: norm(row[2]), outlet_label: label, source_row: index + 2, outlet_index: outletIndex + 1 }));
  });
}

function parseStaffOutletRows(workbook) {
  const sheetName = workbook.names.find((name) => name.trim().toLowerCase() === 'mer and tse');
  if (!sheetName) return { present: false, rows: [] };
  const rows = workbook.rows(sheetName);
  const mapped = rows.slice(1).flatMap((row, index) => {
    const designation = role(row[3]);
    const employeeName = norm(row[2]);
    if (!employeeName || !['TSE', 'MER'].includes(designation)) return [];
    return row.slice(5).map(norm).filter(Boolean).map((outletLabel, outletIndex) => ({
      designation, employee_name: employeeName, state_raw: 'UTTAR PRADESH',
      market_raw: norm(row[0]), area_raw: norm(row[1]), beat: norm(row[4]),
      outlet_label: outletLabel, source_row: index + 2, outlet_index: outletIndex + 1,
    }));
  });
  return { present: true, rows: mapped };
}

function stableOutletCode(prefix, value) {
  let hash = 2166136261;
  for (const char of labelKey(value)) hash = Math.imul(hash ^ char.charCodeAt(0), 16777619);
  return `${prefix}-${(hash >>> 0).toString(16).toUpperCase().padStart(8, '0')}`;
}

function buildOutletMasterRows(upRows, promoterRows, outlets, masters, { sameNameMayExistAcrossRoutes = false } = {}) {
  const tseRows = parseUP(upRows).filter((p) => p.designation === 'TSE');
  const byCode = new Set((outlets || []).map((o) => String(o.outlet_code || '').toUpperCase()));
  const byName = new Map();
  for (const o of outlets || []) {
    const key = labelKey(o.name);
    byName.set(key, [...(byName.get(key) || []), o]);
  }
  const tseContext = (masters?.tses || []).map((t) => {
    const territory = (masters?.territories || []).find((x) => x.id === t.territory_id);
    const state = (masters?.states || []).find((x) => x.id === territory?.state_id);
    return { ...t, territory_name: territory?.name || '', state_name: state?.name || '' };
  });
  const planned = new Map();
  const missingTse = new Map();
  const outletConflicts = new Map();
  for (const item of promoterRows) {
    const tseMatches = item.source_tse
      ? tseRows.filter((t) => labelKey(t.employee_name) === labelKey(item.source_tse.name)
        && labelKey(t.area_raw) === labelKey(item.source_tse.area))
      : tseRows.filter((t) => (t.beat_values || []).some((beat) => beatKey(beat) === beatKey(item.beat)));
    if (tseMatches.length !== 1) {
      const key = `${labelKey(item.promoter_name)}|${labelKey(item.market)}|${labelKey(item.beat)}`;
      missingTse.set(key, { promoter_name: item.promoter_name, market: item.market, beat: item.beat, match_count: tseMatches.length });
      continue;
    }
    const sourceTse = tseMatches[0];
    const existingTses = tseContext.filter((t) => labelKey(t.name) === labelKey(sourceTse.employee_name) && labelKey(t.state_name) === labelKey('UTTAR PRADESH'));
    const existingTse = existingTses.length === 1 ? existingTses[0] : null;
    const tseName = sourceTse.employee_name;
    const tseCode = existingTse?.code || stableOutletCode('UP-ROSTER-TSE', `${sourceTse.employee_name}|${sourceTse.area_raw}`);
    const territory = existingTse?.territory_name || sourceTse.area_raw || item.market || 'Uttar Pradesh';
    for (const rawLabel of [item.outlet_label]) {
      const code = outletCodeFromLabel(rawLabel);
      const cleanName = outletLabel(rawLabel);
      const outletCode = code || stableOutletCode('UP-PW', `${item.market}|${item.beat}|${cleanName}`);
      if (byCode.has(outletCode.toUpperCase())) {
        const codeMatches = (outlets || []).filter((o) => String(o.outlet_code || '').toUpperCase() === outletCode.toUpperCase());
        if (code && codeMatches.length === 1 && labelKey(codeMatches[0].name) !== labelKey(cleanName)) {
          const key = `${outletCode.toUpperCase()}|${labelKey(cleanName)}`;
          outletConflicts.set(key, { promoter_name: item.promoter_name, outlet_code: outletCode, workbook_name: cleanName, existing_name: codeMatches[0].name });
        }
        continue;
      }
      const existingNames = byName.get(labelKey(cleanName)) || [];
      if (!code && existingNames.length > 0) {
        const sameRoute = existingNames.some((o) => beatKey(o.beat) === beatKey(item.beat)
          && [o.area, o.city].some((v) => labelKey(v) === labelKey(item.market)));
        if (!sameNameMayExistAcrossRoutes || sameRoute) continue;
      }
      if (!cleanName) continue;
      const record = { state: 'Uttar Pradesh', territory, tse_code: tseCode, tse_name: tseName,
        outlet_code: outletCode, outlet_name: cleanName, area: item.market, beat: item.beat,
        city: item.market, distributor: '', status: 'active' };
      planned.set(outletCode.toUpperCase(), record);
      byCode.add(outletCode.toUpperCase());
    }
  }
  return { rows: [...planned.values()], missingTse: [...missingTse.values()], outletConflicts: [...outletConflicts.values()] };
}

function staffOutletIdentity(item) {
  const code = outletCodeFromLabel(item.outlet_label);
  return code ? `CODE:${code}` : `ROUTE:${labelKey(item.area_raw)}|${beatKey(item.beat)}|${labelKey(outletLabel(item.outlet_label))}`;
}

function buildStaffOutletMasterRows(staffRows, upRows, outlets, masters) {
  const tseRoster = parseUP(upRows).filter((p) => p.designation === 'TSE');
  const byRoute = new Map();
  const tseOwners = new Map();
  for (const item of staffRows) {
    const routeKey = staffOutletIdentity(item);
    const entry = byRoute.get(routeKey) || { ...item };
    byRoute.set(routeKey, entry);
    if (item.designation === 'TSE') {
      const owners = tseOwners.get(routeKey) || new Map();
      owners.set(`${labelKey(item.employee_name)}|${labelKey(item.area_raw)}`, { name: item.employee_name, area: item.area_raw });
      tseOwners.set(routeKey, owners);
    }
  }
  const syntheticRows = [...byRoute.values()].map((item) => {
    const explicitOwners = [...(tseOwners.get(staffOutletIdentity(item))?.values() || [])]
      .sort((a, b) => `${labelKey(a.name)}|${labelKey(a.area)}`.localeCompare(`${labelKey(b.name)}|${labelKey(b.area)}`));
    const beatOwners = tseRoster.filter((t) => (t.beat_values || []).some((beat) => beatKey(beat) === beatKey(item.beat)));
    const selectedOwner = explicitOwners[0]
      || (beatOwners.length === 1 ? { name: beatOwners[0].employee_name, area: beatOwners[0].area_raw } : null);
    return {
      promoter_name: item.employee_name, market: item.area_raw, beat: item.beat,
      outlet_label: item.outlet_label,
      source_tse: selectedOwner,
    };
  });
  const plan = buildOutletMasterRows(upRows, syntheticRows, outlets, masters, { sameNameMayExistAcrossRoutes: true });
  const missingTse = syntheticRows.filter((r) => !r.source_tse).map((r) => ({
    employee_name: r.promoter_name, market: r.market, beat: r.beat,
    outlet_label: r.outlet_label, match_count: 0,
  }));
  const sharedTseOutlets = [...tseOwners.values()].filter((owners) => owners.size > 1).length;
  return { ...plan, missingTse: [...plan.missingTse, ...missingTse], sharedTseOutlets, sourceOutlets: staffRows.length };
}

function resolveStaffOutletRows(rows, people, outlets) {
  const byEmployee = new Map();
  const active = (outlets || []).filter((o) => o.status === 'active');
  const byCode = new Map(); const byExactCode = new Map(); const byNameBeat = new Map();
  for (const outlet of active) {
    const storedCode = String(outlet.outlet_code || '').trim();
    const digits = /^\d+$/.test(storedCode) ? storedCode : '';
    if (digits) byCode.set(digits, [...(byCode.get(digits) || []), outlet]);
    byExactCode.set(String(outlet.outlet_code || '').toUpperCase(), [...(byExactCode.get(String(outlet.outlet_code || '').toUpperCase()) || []), outlet]);
    const nameKey = labelKey(outlet.name); const beat = beatKey(outlet.beat);
    if (nameKey && beat) byNameBeat.set(`${nameKey}|${beat}`, [...(byNameBeat.get(`${nameKey}|${beat}`) || []), outlet]);
  }
  const peopleByIdentity = new Map();
  for (const person of people || []) {
    if (!person.active || person.source_system !== 'UP_TSE_MER_PROMO_AREAS') continue;
    const k = [person.designation,person.employee_name,person.state_raw,person.market_raw,person.area_raw].map(labelKey).join('|');
    peopleByIdentity.set(k, [...(peopleByIdentity.get(k) || []), person]);
  }
  const outletRows = rows.map((item) => {
    const identity = [item.designation,item.employee_name,item.state_raw,item.market_raw,item.area_raw].map(labelKey).join('|');
    const candidates = peopleByIdentity.get(identity) || [];
    const person = candidates.length === 1 ? candidates[0] : null;
    const code = outletCodeFromLabel(item.outlet_label);
    const cleanName = outletLabel(item.outlet_label);
    let outlet = null; let status = '';
    if (code) {
      const codeMatches = byCode.get(code) || [];
      if (codeMatches.length === 1 && labelKey(codeMatches[0].name) === labelKey(cleanName)) outlet = codeMatches[0];
      else if (codeMatches.length === 1 || codeMatches.length > 1) status = codeMatches.length > 1 ? 'ambiguous_code' : 'outlet_code_name_conflict';
    }
    if (!outlet && !status) {
      const generatedCode = stableOutletCode('UP-PW', `${item.area_raw}|${item.beat}|${cleanName}`);
      const generatedMatches = byExactCode.get(generatedCode.toUpperCase()) || [];
      if (generatedMatches.length === 1 && labelKey(generatedMatches[0].name) === labelKey(cleanName)) outlet = generatedMatches[0];
      else if (generatedMatches.length > 1 || generatedMatches.length === 1) status = generatedMatches.length > 1 ? 'ambiguous_generated_code' : 'generated_code_name_conflict';
    }
    if (!outlet && !status) {
      const nameMatches = [...new Set([
        ...(byNameBeat.get(`${labelKey(item.outlet_label)}|${beatKey(item.beat)}`) || []),
        ...(byNameBeat.get(`${labelKey(cleanName)}|${beatKey(item.beat)}`) || []),
      ])];
      const areaMatches = nameMatches.filter((o) => labelKey(o.area) === labelKey(item.area_raw) || labelKey(o.city) === labelKey(item.area_raw));
      const scoped = areaMatches.length ? areaMatches : nameMatches;
      if (scoped.length === 1) outlet = scoped[0];
      else if (scoped.length > 1) status = 'ambiguous_name';
    }
    status ||= !person ? (candidates.length > 1 ? 'ambiguous_employee' : 'employee_not_found') : outlet ? 'matched' : 'outlet_not_found';
    const key = person?.id || `${item.designation}|${labelKey(item.employee_name)}|${labelKey(item.market_raw)}|${labelKey(item.area_raw)}`;
    const current = byEmployee.get(key) || {
      designation: item.designation, employee_name: item.employee_name,
      state_raw: item.state_raw, market_raw: item.market_raw, area_raw: item.area_raw,
      person_id: person?.id || '', expected_count: 0, unresolved_count: 0,
      outlet_ids: new Set(),
    };
    current.expected_count += 1;
    if (outlet) current.outlet_ids.add(outlet.id);
    else current.unresolved_count += 1;
    byEmployee.set(key, current);
    return { ...item, outlet_id: outlet?.id || '', status, candidate_count: candidates.length };
  });
  const staffRows = [...byEmployee.values()].map((p) => ({ ...p, outlet_ids: [...p.outlet_ids] }));
  const employeeKeys = new Set(rows.map((r) => `${r.designation}|${labelKey(r.employee_name)}|${labelKey(r.market_raw)}|${labelKey(r.area_raw)}`));
  return {
    staffRows, outletRows,
    stats: {
      source_rows: rows.length, employee_count: employeeKeys.size,
      matched_rows: outletRows.filter((r) => r.status === 'matched').length,
      unresolved_rows: outletRows.filter((r) => r.status !== 'matched').length,
      employees_complete: staffRows.filter((p) => p.unresolved_count === 0 && p.person_id).length,
      employees_preserved: staffRows.filter((p) => p.unresolved_count > 0 || !p.person_id).length,
    },
  };
}

function downloadUnresolvedStaffOutlets(report) {
  const rows = (report?.outletRows || []).filter((row) => row.status !== 'matched');
  const columns = ['source_row', 'outlet_index', 'designation', 'employee_name', 'market_raw', 'area_raw', 'beat', 'outlet_label', 'reason', 'candidate_count'];
  const quote = (value) => `"${String(value ?? '').replaceAll('"', '""')}"`;
  const csv = [columns.map(quote).join(','), ...rows.map((row) => columns.map((column) => quote(column === 'reason' ? row.status.replaceAll('_', ' ') : row[column])).join(','))].join('\r\n');
  const blob = new Blob(['\uFEFF', csv], { type: 'text/csv;charset=utf-8' });
  const url = URL.createObjectURL(blob); const link = document.createElement('a');
  link.href = url; link.download = 'up-tse-mer-outlet-unresolved.csv';
  document.body.appendChild(link); link.click(); link.remove(); URL.revokeObjectURL(url);
}

function resolvePromoterOutletRows(rows, people, outlets) {
  const byPromoter = new Map();
  const outletRows = rows.map((item) => {
    const sameName = (people || []).filter((p) => p.designation === 'PROMOTER' && p.active && labelKey(p.employee_name) === labelKey(item.promoter_name));
    const sameMarket = sameName.filter((p) => labelKey(p.area_raw) === labelKey(item.market) || labelKey(p.market_raw) === labelKey(item.market));
    const candidates = sameMarket.length ? sameMarket : sameName;
    const person = candidates.length === 1 ? candidates[0] : null;
    let outlet = null;
    let match = '';
    let status = '';
    let candidateCount;
    const code = outletCodeFromLabel(item.outlet_label);
    if (person && code) {
      const matches = (outlets || []).filter((o) => o.status === 'active' && String(o.outlet_code || '').replace(/\D/g, '') === code);
      if (matches.length === 1 && labelKey(matches[0].name) === labelKey(outletLabel(item.outlet_label))) { outlet = matches[0]; match = 'code'; }
      else if (matches.length === 1) status = 'outlet_code_name_conflict';
      else if (matches.length > 1) { status = 'ambiguous_code'; candidateCount = matches.length; }
    }
    if (person && !outlet && !status) {
      const exactNames = new Set([labelKey(item.outlet_label), labelKey(outletLabel(item.outlet_label))]);
      const matches = (outlets || []).filter((o) => o.status === 'active' && exactNames.has(labelKey(o.name)));
      if (matches.length === 1) { outlet = matches[0]; match = 'exact_name'; }
      else if (matches.length > 1) { status = 'ambiguous_name'; candidateCount = matches.length; }
    }
    status ||= !person ? (sameName.length > 1 ? 'ambiguous_promoter' : 'promoter_not_found') : outlet ? 'matched' : 'outlet_not_found';
    if (person) {
      const current = byPromoter.get(person.id) || { promoter_id: person.id, promoter_name: person.employee_name, expected_count: 0, matched_ids: new Set(), unresolved_count: 0, rows: 0 };
      current.expected_count += 1; current.rows += 1;
      if (outlet) current.matched_ids.add(outlet.id);
      else current.unresolved_count += 1;
      byPromoter.set(person.id, current);
    }
    return { ...item, person_id: person?.id || '', outlet_id: outlet?.id || '', match, status, candidate_count: candidateCount || (status === 'ambiguous_promoter' ? sameName.length : undefined) };
  });
  const promoterRows = [...byPromoter.values()].map((p) => ({ promoter_id: p.promoter_id, promoter_name: p.promoter_name, expected_count: p.expected_count, unresolved_count: p.unresolved_count, outlet_ids: [...p.matched_ids], matched_count: p.matched_ids.size }));
  const stats = {
    source_rows: rows.length, promoter_count: new Set(rows.map((r) => labelKey(r.promoter_name))).size,
    matched_rows: outletRows.filter((r) => r.status === 'matched').length,
    unresolved_rows: outletRows.filter((r) => r.status !== 'matched').length,
    distinct_promoters_matched: promoterRows.length,
  };
  return { promoterRows, outletRows, stats };
}

function downloadUnresolvedOutlets(report) {
  const rows = (report?.outletRows || []).filter((row) => row.status !== 'matched');
  const columns = ['source_row', 'outlet_index', 'promoter_name', 'market', 'beat', 'outlet_label', 'reason', 'candidate_count'];
  const quote = (value) => `"${String(value ?? '').replaceAll('"', '""')}"`;
  const csv = [columns.map(quote).join(','), ...rows.map((row) => columns.map((column) => quote(column === 'reason' ? row.status.replaceAll('_', ' ') : row[column])).join(','))].join('\r\n');
  const blob = new Blob(['\uFEFF', csv], { type: 'text/csv;charset=utf-8' });
  const url = URL.createObjectURL(blob);
  const link = document.createElement('a');
  link.href = url;
  link.download = 'up-promoter-outlet-unresolved.csv';
  document.body.appendChild(link);
  link.click();
  link.remove();
  URL.revokeObjectURL(url);
}

export default function OrgData({ data, reloadData }) {
  const [tab, setTab] = useState('people');
  const [people, setPeople] = useState(null);
  const [stock, setStock] = useState(null);
  const [stockAdjustments, setStockAdjustments] = useState([]);
  const [promoterStock, setPromoterStock] = useState([]);
  const [assignments, setAssignments] = useState(null);
  const [merAssignments, setMerAssignments] = useState([]);
  const [workbookAssignments, setWorkbookAssignments] = useState([]);
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState('');
  const [notice, setNotice] = useState('');
  const [outletImportReport, setOutletImportReport] = useState(null);
  const [files, setFiles] = useState({ up: null, mh: null, inventory: null });
  const [runKey, setRunKey] = useState('source-files-2026-09-30-v1');
  const [outletMode, setOutletMode] = useState('');
  const [filters, setFilters] = useState({ designation: 'all', state: 'all', market: 'all', area: 'all', beat: 'all', tse: 'all', mer: 'all', assignment: 'all', inventory: 'all', active: 'all', q: '' });
  const [newPerson, setNewPerson] = useState({ designation: 'PROMOTER', employee_name: '', mobile: '', state_raw: '', market_raw: '', area_raw: '', beat: '' });

  async function refresh() {
    try {
      const [p, i, a, ma, wa, adj, pi] = await Promise.all([
        selectAll('org_people', '*', (q) => q.order('designation').order('employee_name')),
        selectAll('org_inventory', '*', (q) => q.order('employee_name')),
        selectAll('promoter_outlet_assignments', '*'),
        selectAll('promoter_mer_assignments', '*'),
        selectAll('promoter_outlet_workbook_assignments', '*'),
        selectAll('org_inventory_adjustments', '*'),
        selectAll('promoter_inventory', '*'),
      ]);
      setPeople(p); setStock(i); setAssignments(a); setMerAssignments(ma); setWorkbookAssignments(wa); setStockAdjustments(adj); setPromoterStock(pi);
    } catch (e) { setErr(friendly(e)); }
  }
  React.useEffect(() => { refresh(); }, []);
  const users = data.promoters.filter((u) => u.role === 'promoter');
  const filtered = useMemo(() => (people || []).filter((p) => {
    const value = (v) => v || 'Unspecified';
    const search = filters.q.toLowerCase();
    return (filters.designation === 'all' || p.designation === filters.designation)
      && (filters.state === 'all' || value(p.state_raw) === filters.state)
      && (filters.market === 'all' || value(p.market_raw) === filters.market)
      && (filters.area === 'all' || value(p.area_raw) === filters.area)
      && (filters.beat === 'all' || (p.beat_values || []).some((b) => value(b) === filters.beat))
      && (filters.tse === 'all' || (filters.tse === 'none' ? !p.mapped_tse_id : p.mapped_tse_id === filters.tse))
      && (filters.mer === 'all' || (filters.mer === 'none' ? !merAssignments.some((a) => a.promoter_id === p.id) : merAssignments.some((a) => a.promoter_id === p.id && a.mer_id === filters.mer)))
      && (filters.assignment === 'all' || (filters.assignment === 'MER_ASSIGNED' ? merAssignments.some((a) => a.promoter_id === p.id) : filters.assignment === 'TSE_AND_MER_ASSIGNED' ? p.mapped_tse_id && merAssignments.some((a) => a.promoter_id === p.id) : filters.assignment === 'TSE_ASSIGNED' ? p.mapped_tse_id && !merAssignments.some((a) => a.promoter_id === p.id) : filters.assignment === 'NO_TSE_OR_MER' ? !p.mapped_tse_id && !merAssignments.some((a) => a.promoter_id === p.id) : true))
      && (filters.inventory === 'all' || (filters.inventory === 'with' ? stock?.some((s) => s.person_id === p.id) : !stock?.some((s) => s.person_id === p.id)))
      && (filters.active === 'all' || String(p.active) === filters.active)
      && (!search || [p.employee_name,p.mobile,p.fas_id,p.qa_employee_id,p.market_raw,p.area_raw,...(p.beat_values||[])].some((x) => String(x||'').toLowerCase().includes(search)));
  }), [people, stock, filters, merAssignments]);
  const distinct = (key) => [...new Set((people || []).map((p) => p[key] || 'Unspecified'))].sort();
  const fieldFilter = (key, label, opts, includeNone = false) => <select key={key} aria-label={label} value={filters[key]} onChange={(e) => setFilters({ ...filters, [key]: e.target.value })}><option value="all">All {label}</option>{includeNone && <option value="none">Unassigned</option>}{opts.map((o) => typeof o === 'string' ? <option key={o} value={o}>{o}</option> : <option key={o.id} value={o.id}>{o.employee_name}</option>)}</select>;

  async function runImport() {
    setBusy(true); setErr(''); setNotice('');
    try {
      if (!files.up || !files.mh || !files.inventory) throw new Error('Choose all three workbooks before importing.');
      if (!people || !data.outletsFull) throw new Error('Organizational people and the outlet directory are still loading. Wait a moment and try again.');
      if (!outletMode) throw new Error('Choose how the workbook outlet list should interact with MER outlet access.');
      const [upBook, mhBook, invBook] = await Promise.all([readWorkbook(files.up), readWorkbook(files.mh), readWorkbook(files.inventory)]);
      const upRows = upBook.rows(upBook.names[0]);
      const mhRows = mhBook.rows(mhBook.names[0]);
      const invRows = invBook.rows(invBook.names[0]);
      const master = [...parseUP(upRows), ...parseMH(mhRows)];
      const inventory = parseInventory(invRows);
      const sourceOutletRows = parsePromoterOutletRows(upBook);
      const sourceStaffOutlets = parseStaffOutletRows(upBook);
      const outletMasterPlan = buildOutletMasterRows(upRows, sourceOutletRows, data.outletsFull, data.masters);
      const staffOutletMasterPlan = sourceStaffOutlets.present
        ? buildStaffOutletMasterRows(sourceStaffOutlets.rows, upRows, [
          ...data.outletsFull,
          ...outletMasterPlan.rows.map((o) => ({ ...o, name: o.outlet_name, status: 'active' })),
        ], data.masters)
        : { rows: [], missingTse: [], outletConflicts: [], sharedTseOutlets: 0, sourceOutlets: 0 };
      const allPlannedByCode = new Map();
      for (const outlet of [...outletMasterPlan.rows, ...staffOutletMasterPlan.rows]) {
        const key = String(outlet.outlet_code || '').toUpperCase();
        const previous = allPlannedByCode.get(key);
        if (!previous || labelKey(previous.outlet_name) === labelKey(outlet.outlet_name)) allPlannedByCode.set(key, outlet);
      }
      const allPlannedOutlets = [...allPlannedByCode.values()];
      let createdOutlets = 0;
      let outletMasterErrors = [];
      for (let i = 0; i < allPlannedOutlets.length; i += 500) {
        const imported = await rpc('import_outlets', { p_rows: allPlannedOutlets.slice(i, i + 500) }, { timeoutMs: 120000 });
        createdOutlets += imported.inserted || 0;
        outletMasterErrors = [...outletMasterErrors, ...(imported.errors || [])];
      }
      const currentOutlets = await selectAll('outlets', 'id,outlet_code,name,area,city,beat,tse_id,status,source,external_ref', (q) => q.order('name'));
      const outletResolution = resolvePromoterOutletRows(sourceOutletRows, people, currentOutlets);
      const staffOutletResolution = resolveStaffOutletRows(sourceStaffOutlets.rows, people, currentOutlets);
      outletResolution.staffOutlet = staffOutletResolution;
      outletResolution.outletMaster = {
        created: createdOutlets, attempted: allPlannedOutlets.length, errors: outletMasterErrors.length,
        missingTse: outletMasterPlan.missingTse, outletConflicts: [...outletMasterPlan.outletConflicts, ...staffOutletMasterPlan.outletConflicts],
        staffMissingTse: staffOutletMasterPlan.missingTse, sharedTseOutlets: staffOutletMasterPlan.sharedTseOutlets,
      };
      setOutletImportReport(outletResolution);
      const accessRows = outletMode === 'workbook_exact'
        ? outletResolution.promoterRows.filter((p) => p.unresolved_count === 0 && p.outlet_ids.length > 0)
        : outletResolution.promoterRows.filter((p) => p.outlet_ids.length > 0);
      if (!accessRows.length) throw new Error('No promoter has a unique outlet list to import. Outlet records that could be matched were created; review unresolved entries below.');
      const result = await rpc('import_org_master_inventory_with_staff_outlets', {
        p_master: master, p_inventory: inventory, p_run_key: runKey.trim(),
        p_promoter_outlet_rows: accessRows, p_promoter_outlet_mode: outletMode,
        p_promoter_unresolved_count: outletResolution.stats.unresolved_rows,
        p_staff_outlet_rows: staffOutletResolution.staffRows.map((row) => ({
          designation: row.designation, employee_name: row.employee_name, state_raw: row.state_raw,
          market_raw: row.market_raw, area_raw: row.area_raw, outlet_ids: row.outlet_ids,
          expected_count: row.expected_count, unresolved_count: row.unresolved_count + (row.person_id ? 0 : 1),
        })),
      }, { timeoutMs: 120000 });
      const inventoryReconciliation = await rpc('reconcile_org_promoter_inventory', {}, { timeoutMs: 120000 });
      const outletResult = result.outlet_access || {};
      const staffResult = result.staff_outlet_access || {};
      setNotice(`Imported/updated ${result.master_rows} master rows; ${result.inventory_rows || 0} inventory rows processed${result.inventory_already_imported ? ' (initial inventory was already applied)' : ''}. Opening stock reconciled: ${inventoryReconciliation.stock_balances_seeded} balances seeded; ${inventoryReconciliation.unmatched_rows} inventory rows need review. Created ${createdOutlets} outlet master records. Promoters: ${outletResult.promoter_count} accounts, ${outletResult.assignment_count} outlet assignments. UP TSE/MER: ${staffResult.employees_updated || 0} complete maps refreshed, ${staffResult.employees_partial || 0} partial maps updated with unique matches, ${staffResult.assignments || 0} outlet assignments, ${staffResult.accounts_linked || 0} login profiles linked.${staffResult.employees_preserved ? ` ${staffResult.employees_preserved} employee profiles could not be uniquely matched and were left unchanged.` : ''}${outletResolution.stats.unresolved_rows ? ` ${outletResolution.stats.unresolved_rows} promoter workbook entries remain unresolved; those promoters keep MER/manual access.` : ''}`);
      await refresh(); await reloadData();
    } catch (e) { setErr(friendly(e)); }
    finally { setBusy(false); }
  }

  async function saveAssignment(person, field, value) {
    setErr('');
    const patch = { [field]: value || null, assignment_source: 'manual', updated_at: new Date().toISOString() };
    const { error } = await supabase.from('org_people').update(patch).eq('id', person.id);
    if (error) setErr(friendly(error)); else await refresh();
  }
  async function setOutlets(personId, outletIds) {
    setBusy(true); setErr('');
    try {
      await rpc('set_promoter_outlets', { p_promoter_id: personId, p_outlet_ids: outletIds });
      await refresh(); setNotice('Outlet permissions saved.');
    } catch (e) { setErr(friendly(e)); }
    finally { setBusy(false); }
  }
  async function setMers(personId, merIds) {
    setBusy(true); setErr('');
    try {
      await rpc('set_promoter_mers', { p_promoter_id: personId, p_mer_ids: merIds });
      await refresh(); setNotice('MER mappings saved. The promoter receives outlet access from each mapped MER’s matching beats.');
    } catch (e) { setErr(friendly(e)); }
    finally { setBusy(false); }
  }
  async function linkLogin(person, authUserId) {
    if (!authUserId || (person.auth_user_id && person.auth_user_id !== authUserId)) return;
    try { await rpc('link_org_promoter', { p_person_id: person.id, p_user_id: authUserId }); await refresh(); setNotice('Promoter login linked. Initial snack allocation was seeded only if the account had no existing balance.'); }
    catch (e) { setErr(friendly(e)); }
  }
  async function toggleActive(person) {
    const { error } = await supabase.from('org_people').update({ active: !person.active, updated_at: new Date().toISOString() }).eq('id', person.id);
    if (error) setErr(friendly(error)); else await refresh();
  }
  async function saveOverride(person, field, value) {
    const normalized = norm(value);
    const patch = field === 'beat_override' ? { [field]: normalized ? normalized.split(',').map(norm).filter(Boolean) : null }
      : { [field]: normalized || null };
    const { error } = await supabase.from('org_people').update({ ...patch, updated_at: new Date().toISOString() }).eq('id', person.id);
    if (error) setErr(friendly(error)); else await refresh();
  }
  async function createPerson() {
    setErr('');
    const name = norm(newPerson.employee_name);
    if (!name) { setErr('Employee name is required.'); return; }
    const sourceKey = `ADMIN:${newPerson.designation}:${keyPart(name)}:${keyPart(newPerson.state_raw)}:${keyPart(newPerson.market_raw)}:${keyPart(newPerson.area_raw)}:${Date.now()}`;
    const { error } = await supabase.from('org_people').insert({
      designation: newPerson.designation, employee_name: name, mobile: norm(newPerson.mobile) || null, source_key: sourceKey,
      source_system: 'admin', source_ids: {}, state_raw: norm(newPerson.state_raw) || null, market_raw: norm(newPerson.market_raw) || null,
      area_raw: norm(newPerson.area_raw) || null, beat_values: norm(newPerson.beat) ? [norm(newPerson.beat)] : [], assignment_source: 'manual',
    });
    if (error) { setErr(friendly(error)); return; }
    setNewPerson({ ...newPerson, employee_name: '', mobile: '', area_raw: '', beat: '' }); await refresh(); setNotice(`${newPerson.designation} record created. Add a login/outlet assignment if the employee is a promoter.`);
  }
  async function adjustOrgStock(row, code, delta, note) {
    try {
      await rpc('adjust_org_inventory', { p_inventory_id: row.id, p_prize_code: code, p_qty_delta: Number(delta), p_note: note });
      await refresh(); setNotice('Employee inventory adjustment saved.');
    } catch (e) { setErr(friendly(e)); }
  }

  return <div className="s-page">
    <Tabs value={tab} onChange={setTab} tabs={[{ key: 'people', label: 'People & assignments' }, { key: 'outlets', label: 'Outlet access' }, { key: 'inventory', label: 'Employee inventory' }, { key: 'import', label: 'Import workbooks' }]} />
    {err && <div className="s-err">{err}</div>}{notice && <div className="s-note">{notice}</div>}
    {tab === 'people' && <>
      <Panel title="Add organizational record"><div className="s-grid2"><Field label="Designation"><select value={newPerson.designation} onChange={(e) => setNewPerson({ ...newPerson, designation: e.target.value })}><option>PROMOTER</option><option>TSE</option><option>MER</option><option>ASM</option></select></Field><Field label="Employee name"><input value={newPerson.employee_name} onChange={(e) => setNewPerson({ ...newPerson, employee_name: e.target.value })} /></Field><Field label="Mobile"><input value={newPerson.mobile} onChange={(e) => setNewPerson({ ...newPerson, mobile: e.target.value })} /></Field><Field label="Source state"><input value={newPerson.state_raw} onChange={(e) => setNewPerson({ ...newPerson, state_raw: e.target.value })} /></Field><Field label="Market"><input value={newPerson.market_raw} onChange={(e) => setNewPerson({ ...newPerson, market_raw: e.target.value })} /></Field><Field label="Area"><input value={newPerson.area_raw} onChange={(e) => setNewPerson({ ...newPerson, area_raw: e.target.value })} /></Field><Field label="Beat"><input value={newPerson.beat} onChange={(e) => setNewPerson({ ...newPerson, beat: e.target.value })} /></Field></div><button className="s-btn" onClick={createPerson}>Add record</button></Panel>
      <Panel title="Organizational directory">
      <div className="org-filters"><input value={filters.q} onChange={(e) => setFilters({ ...filters, q: e.target.value })} placeholder="Search name, ID or mobile" />{fieldFilter('designation','designation',['PROMOTER','TSE','MER','ASM'])}{fieldFilter('state','state',distinct('state_raw'))}{fieldFilter('market','market',distinct('market_raw'))}{fieldFilter('area','area',distinct('area_raw'))}{fieldFilter('beat','beat',[...new Set((people || []).flatMap((p) => p.beat_values || []))].sort())}{fieldFilter('tse','TSE',(people || []).filter((p) => p.designation==='TSE'),true)}{fieldFilter('mer','MER',(people || []).filter((p) => p.designation==='MER'),true)}{fieldFilter('assignment','assignment status',['TSE_ASSIGNED','MER_ASSIGNED','TSE_AND_MER_ASSIGNED','NO_TSE_OR_MER'])}{fieldFilter('inventory','inventory status',['with','without'])}{fieldFilter('active','active status',['true','false'])}</div>
      {people && <DataTable rows={filtered.map((p) => {
        const mapped = merAssignments.filter((a) => a.promoter_id === p.id);
        const hasMer = mapped.length > 0;
        return { ...p, beats: (p.beat_values || []).join(', '), linked: users.find((u) => u.id === p.auth_user_id)?.full_name || (p.auth_user_id ? 'Linked' : 'No login'),
          assignment_status: p.designation !== 'PROMOTER' ? 'NOT_APPLICABLE' : p.mapped_tse_id && hasMer ? 'TSE_AND_MER_ASSIGNED' : p.mapped_tse_id ? 'TSE_ASSIGNED' : hasMer ? 'MER_ASSIGNED' : 'NO_TSE_OR_MER' };
      })} exportName="organizational_directory" columns={[
        { key: 'employee_name', label: 'Employee' }, { key: 'designation', label: 'Role' }, { key: 'mobile', label: 'Mobile' }, { key: 'state_raw', label: 'Source state' }, { key: 'market_raw', label: 'Source market' }, { key: 'area_raw', label: 'Source area' }, { key: 'beats', label: 'Source beat(s)' },
        { key: 'market_override', label: 'Manual market', render: (p) => <InlineEdit value={p.market_override} placeholder={p.market_raw || 'Add override'} save={(v) => saveOverride(p,'market_override',v)} /> },
        { key: 'area_override', label: 'Manual area', render: (p) => <InlineEdit value={p.area_override} placeholder={p.area_raw || 'Add override'} save={(v) => saveOverride(p,'area_override',v)} /> },
        { key: 'beat_override', label: 'Manual beats', render: (p) => <InlineEdit value={(p.beat_override || []).join(', ')} placeholder={(p.beat_values || []).join(', ') || 'Add override'} save={(v) => saveOverride(p,'beat_override',v)} /> },
        { key: 'linked', label: 'Login' },
        { key: 'auth_user_id', label: 'Link promoter login', render: (p) => p.designation !== 'PROMOTER' ? '—' : <select aria-label={`Login for ${p.employee_name}`} value={p.auth_user_id || ''} disabled={!!p.auth_user_id} onChange={(e) => linkLogin(p, e.target.value)}><option value="">No login linked</option>{users.filter((u) => !(people || []).some((x) => x.auth_user_id === u.id && x.id !== p.id)).map((u) => <option key={u.id} value={u.id}>{u.full_name} · {u.login_id}</option>)}</select> },
        { key: 'assignment_status', label: 'Assignment status' },
        { key: 'mapped_tse_id', label: 'Mapped TSE', render: (p) => p.designation !== 'PROMOTER' ? '—' : <select aria-label={`TSE for ${p.employee_name}`} value={p.mapped_tse_id || ''} onChange={(e) => saveAssignment(p, 'mapped_tse_id', e.target.value)}><option value="">None</option>{(people || []).filter((x) => x.designation === 'TSE').map((x) => <option key={x.id} value={x.id}>{x.employee_name}</option>)}</select> },
        { key: 'mapped_mer_ids', label: 'Mapped MERs', noExport: true, render: (p) => p.designation !== 'PROMOTER' ? '—' : <MerMapping person={p} relations={merAssignments.filter((a) => a.promoter_id === p.id)} mers={(people || []).filter((x) => x.designation === 'MER' && x.active)} save={setMers} busy={busy} /> },
        { key: 'active', label: 'Active', render: (p) => <><Badge tone={p.active ? 'green' : 'red'}>{p.active ? 'Active' : 'Inactive'}</Badge><button className="s-btn ghost sm" onClick={() => toggleActive(p)}>{p.active ? 'Deactivate' : 'Activate'}</button></> },
      ]} />}
    </Panel></>}
    {tab === 'outlets' && <Panel title="Promoter outlet access"><p className="muted">Access can come from mapped MER beats, manual outlet assignments, or the UP Promoter Wise workbook. The selected workbook mode controls whether that promoter’s workbook list replaces or adds to MER/manual access.</p>
      {people?.filter((p) => p.designation === 'PROMOTER').map((p) => {
        const assigned = (assignments || []).filter((a) => a.promoter_id === p.id && a.active).map((a) => a.outlet_id);
        const workbook = workbookAssignments.filter((a) => a.promoter_id === p.id && a.source_state === 'UTTAR PRADESH').map((a) => a.outlet_id);
        const merIds = merAssignments.filter((a) => a.promoter_id === p.id).map((a) => a.mer_id);
        const merBeats = new Set((people || []).filter((m) => merIds.includes(m.id)).flatMap((m) => m.beat_override || m.beat_values || []).map(beatKey).filter(Boolean));
        const inherited = (data.outletsFull || []).filter((o) => o.status === 'active' && merBeats.has(beatKey(o.beat))).map((o) => o.id);
        return <OutletAssignment key={p.id} person={p} outlets={data.outletsFull} assigned={assigned} inherited={inherited} workbook={workbook} mode={p.outlet_access_mode || 'mer'} save={setOutlets} busy={busy} />;
      })}
    </Panel>}
    {tab === 'inventory' && <Panel title="Employee inventory allocations"><p className="muted">Source allocations stay separate from live consumption. Promoter adjustments are also applied to the existing promoter stock ledger when an account is linked. TSE/MER/ASM stock never transfers to promoters automatically.</p>
      {stock && <DataTable rows={stock.map((s) => { const a = stockAdjustments.filter((x) => x.org_inventory_id === s.id); const person = people?.find((p) => p.id === s.person_id); const uid = person?.auth_user_id; const id5 = data.masters.prizes.find((p) => p.code === 'SNACK5')?.id; const id10 = data.masters.prizes.find((p) => p.code === 'SNACK10')?.id; const bal = (id) => promoterStock.find((x) => x.promoter_id === uid && x.prize_id === id)?.on_hand ?? 0; return { ...s, current5: uid ? bal(id5) : s.snack5_initial + a.filter((x) => x.prize_code === 'SNACK5').reduce((n, x) => n + x.qty_delta, 0), current10: uid ? bal(id10) : s.snack10_initial + a.filter((x) => x.prize_code === 'SNACK10').reduce((n, x) => n + x.qty_delta, 0), inventory_status: (uid ? bal(id5) + bal(id10) : s.snack5_initial + s.snack10_initial) ? 'Has stock' : 'No stock' }; })} exportName="employee_inventory" columns={[
        { key: 'employee_name', label: 'Employee' }, { key: 'designation', label: 'Designation' }, { key: 'state_raw', label: 'State' }, { key: 'market_raw', label: 'Market' }, { key: 'area_raw', label: 'Area' },
        { key: 'snack5_initial', label: '₹5 initial', align: 'r' }, { key: 'current5', label: '₹5 current', align: 'r' }, { key: 'snack10_initial', label: '₹10 initial', align: 'r' }, { key: 'current10', label: '₹10 current', align: 'r' }, { key: 'inventory_status', label: 'Status' }, { key: 'fas_id', label: 'FAS ID' }, { key: 'qa_employee_id', label: 'QA Emp. ID' },
        { key: 'adjust', label: 'Adjust', noExport: true, render: (s) => <StockAdjust row={s} save={adjustOrgStock} /> },
      ]} />}
    </Panel>}
    {tab === 'import' && <Panel title="Import organizational master, outlets, and initial inventory"><p>Choose the UP master, Maharashtra master, and combined inventory workbook. Master people come only from the first two files. The inventory workbook is reconciled to those records and cannot create directory people. The UP file’s <b>Promoter Wise</b> sheet assigns promoter outlets; its optional <b>MER and TSE</b> sheet assigns the listed outlets to those employees. Mapped TSE/MER access is stored separately, so a shared outlet does not overwrite its existing TSE or promoter assignment.</p>
      <div className="s-form"><Field label="Uttar Pradesh TSE / MER / Promoter master"><input type="file" accept=".xlsx,.xls" onChange={(e) => setFiles({ ...files, up: e.target.files?.[0] || null })} /></Field>
        <Field label="Maharashtra TSE / MER master"><input type="file" accept=".xlsx,.xls" onChange={(e) => setFiles({ ...files, mh: e.target.files?.[0] || null })} /></Field>
        <Field label="MH-UP inventory workbook"><input type="file" accept=".xlsx,.xls" onChange={(e) => setFiles({ ...files, inventory: e.target.files?.[0] || null })} /></Field>
        <Field label="UP promoter outlet access"><select value={outletMode} onChange={(e) => setOutletMode(e.target.value)}><option value="">Choose access behavior</option><option value="workbook_exact">Use workbook list as exact access (replaces MER and manual access)</option><option value="workbook_additive">Add workbook outlets to MER and manual access</option></select></Field>
        <Field label="Import run key" hint="Keep the same key to safely repeat this import. Use a new key only for a distinct inventory snapshot; existing promoter stock will never be overwritten or added twice."><input value={runKey} onChange={(e) => setRunKey(e.target.value)} /></Field>
        <p className="muted">Exact mode applies to each promoter only when that promoter’s complete outlet list resolves; incomplete promoters retain MER/manual access. Additive mode adds uniquely resolved outlets. TSE/MER lists add only uniquely matched outlets when some rows are unresolved, keeping existing access; a fully resolved list replaces that employee’s map. Re-running the same key does not reapply initial inventory.</p>
        <button className="s-btn" disabled={busy || !files.up || !files.mh || !files.inventory || !outletMode} onClick={runImport}>{busy ? 'Importing…' : 'Import and reconcile'}</button>
        {outletImportReport && <div className="org-import-summary">
          <b>Promoter outlet matching report</b>
          <p>{outletImportReport.stats.promoter_count} workbook promoters · {outletImportReport.stats.source_rows} outlet entries · {outletImportReport.stats.matched_rows} matched · {outletImportReport.stats.unresolved_rows} unresolved</p>
          {outletImportReport.staffOutlet?.stats.employee_count > 0 && <>
            <b>TSE / MER outlet matching report</b>
            <p>{outletImportReport.staffOutlet.stats.employee_count} employees · {outletImportReport.staffOutlet.stats.source_rows} outlet entries · {outletImportReport.staffOutlet.stats.matched_rows} matched · {outletImportReport.staffOutlet.stats.unresolved_rows} unresolved · {outletImportReport.outletMaster.sharedTseOutlets} outlets listed under multiple TSEs</p>
            {outletImportReport.staffOutlet.stats.unresolved_rows > 0 && <>
              <button type="button" className="s-btn sm" onClick={() => downloadUnresolvedStaffOutlets(outletImportReport.staffOutlet)}>Download all {outletImportReport.staffOutlet.stats.unresolved_rows} unresolved TSE/MER entries (CSV)</button>
              <div className="org-import-unmatched">{outletImportReport.staffOutlet.outletRows.filter((r) => r.status !== 'matched').slice(0, 12).map((r, i) => <div key={`${r.source_row}-${r.outlet_index}-${i}`}><b>{r.designation} · {r.employee_name}</b> — {r.outlet_label} <small>({r.status.replaceAll('_', ' ')})</small></div>)}{outletImportReport.staffOutlet.stats.unresolved_rows > 12 && <small>Showing first 12 unresolved TSE/MER entries. Download the CSV for the complete list.</small>}</div>
            </>}
          </>}
          <p>Created {outletImportReport.outletMaster.created} outlet master records · {outletImportReport.outletMaster.missingTse.length + outletImportReport.outletMaster.staffMissingTse.length} route groups without a unique TSE · {outletImportReport.outletMaster.outletConflicts.length} outlet code/name conflicts · {outletImportReport.outletMaster.errors} outlet import errors</p>
          {outletImportReport.stats.unresolved_rows > 0 && <><button type="button" className="s-btn sm" onClick={() => downloadUnresolvedOutlets(outletImportReport)}>Download all {outletImportReport.stats.unresolved_rows} unresolved promoter entries (CSV)</button><div className="org-import-unmatched">{outletImportReport.outletRows.filter((r) => r.status !== 'matched').slice(0, 12).map((r, i) => <div key={`${r.source_row}-${r.outlet_index}-${i}`}><b>{r.promoter_name}</b> — {r.outlet_label} <small>({r.status.replaceAll('_', ' ')})</small></div>)}{outletImportReport.stats.unresolved_rows > 12 && <small>Showing first 12 unresolved entries. Download the CSV for the complete list.</small>}</div></>}
          {[...outletImportReport.outletMaster.missingTse, ...outletImportReport.outletMaster.staffMissingTse].length > 0 && <div className="org-import-unmatched">{[...outletImportReport.outletMaster.missingTse, ...outletImportReport.outletMaster.staffMissingTse].slice(0, 8).map((r, i) => <div key={`${r.employee_name || r.promoter_name}-${r.beat}-${i}`}><b>{r.employee_name || r.promoter_name}</b> — {r.market} / {r.beat} <small>({r.match_count ? 'ambiguous TSE beat match' : 'no TSE beat match'})</small></div>)}</div>}
          {outletImportReport.outletMaster.outletConflicts.length > 0 && <div className="org-import-unmatched">{outletImportReport.outletMaster.outletConflicts.slice(0, 8).map((r) => <div key={`${r.outlet_code}-${r.workbook_name}`}><b>{r.outlet_code}</b> — workbook “{r.workbook_name}”, existing “{r.existing_name}”</div>)}</div>}
        </div>}
      </div>
    </Panel>}
  </div>;
}

function MerMapping({ person, relations, mers, save, busy }) {
  const manual = relations.filter((a) => a.assignment_source === 'manual').map((a) => a.mer_id);
  const automatic = relations.filter((a) => a.assignment_source === 'source_area_match').map((a) => a.mer_id);
  const [selected, setSelected] = useState(manual);
  const [open, setOpen] = useState(false);
  React.useEffect(() => setSelected(manual), [manual.join('|')]);
  const autoNames = automatic.map((id) => mers.find((m) => m.id === id)?.employee_name).filter(Boolean);
  return <div className="org-mer-map"><details onToggle={(e) => setOpen(e.currentTarget.open)}>
    <summary>{automatic.length + manual.length ? `${automatic.length + manual.length} MER${automatic.length + manual.length === 1 ? '' : 's'} mapped` : 'No MER mapped'}</summary>
    {open && <><div className="org-mer-auto">{autoNames.length ? <>Source market/area matches: {autoNames.join(', ')}</> : 'No source market/area match.'}</div>
      <div className="org-mer-list">{mers.map((m) => {
        const isAuto = automatic.includes(m.id);
        const isManual = selected.includes(m.id);
        return <label key={m.id}><input type="checkbox" checked={isAuto || isManual} disabled={isAuto} onChange={(e) => setSelected(e.target.checked ? [...selected, m.id] : selected.filter((id) => id !== m.id))} />{m.employee_name}<small>{isAuto ? 'Source market/area match' : `${m.market_raw || ''} · ${m.area_raw || ''}`}</small></label>;
      })}{!mers.length && <p className="muted">No active MER records.</p>}</div>
      <button className="s-btn sm" disabled={busy} onClick={() => save(person.id, selected.filter((id) => !automatic.includes(id)))}>Save manual mappings</button>
    </>}
  </details></div>;
}

function OutletAssignment({ person, outlets, assigned, inherited = [], workbook = [], mode = 'mer', save, busy }) {
  const [selected, setSelected] = useState(assigned);
  const [open, setOpen] = useState(false);
  const [query, setQuery] = useState('');
  React.useEffect(() => setSelected(assigned), [assigned.join('|')]);
  const workbookSet = new Set(workbook);
  const inheritedSet = new Set(mode === 'workbook_exact' ? workbook : mode === 'workbook_additive' ? [...inherited, ...workbook] : inherited);
  const effective = mode === 'workbook_exact' ? workbookSet.size : new Set([...inheritedSet, ...assigned]).size;
  const filtered = outlets.filter((o) => [o.name,o.outlet_code,o.area,o.city,o.beat].some((x) => String(x || '').toLowerCase().includes(query.toLowerCase())));
  const modeLabel = mode === 'workbook_exact' ? 'Exact workbook list' : mode === 'workbook_additive' ? 'Workbook + MER/manual' : 'MER/manual';
  return <div className="org-outlet-row"><div><b>{person.employee_name}</b><small>{person.state_raw} · {person.market_raw || 'Market unspecified'} · {effective} outlets available · {modeLabel}</small></div>
    {mode === 'workbook_exact' ? <span className="muted">{workbook.length} outlets from UP Promoter Wise</span> : <details onToggle={(e) => setOpen(e.currentTarget.open)}><summary>Manage direct outlets</summary>{open && <><input className="org-outlet-search" value={query} onChange={(e) => setQuery(e.target.value)} placeholder="Search outlet, code, area or beat" /><div className="org-outlet-list">{filtered.map((o) => { const fromWorkbook = workbookSet.has(o.id); const fromMer = inheritedSet.has(o.id) && !fromWorkbook; return <label key={o.id}><input type="checkbox" checked={selected.includes(o.id) || inheritedSet.has(o.id)} disabled={inheritedSet.has(o.id)} onChange={(e) => setSelected(e.target.checked ? [...selected, o.id] : selected.filter((id) => id !== o.id))} />{o.name}<small>{fromWorkbook ? 'From promoter workbook' : fromMer ? 'From mapped MER' : `${o.area || ''} · ${o.outlet_code}`}</small></label>; })}{!filtered.length && <p className="muted">No matching outlets.</p>}</div><button className="s-btn sm" disabled={busy} onClick={() => save(person.id, selected)}>Save direct outlet access</button></>}</details>}
  </div>;
}

function StockAdjust({ row, save }) {
  const [code, setCode] = useState('SNACK5');
  const [delta, setDelta] = useState('');
  const [note, setNote] = useState('');
  return <div className="org-stock-adjust"><select value={code} onChange={(e) => setCode(e.target.value)} aria-label="Snack type"><option value="SNACK5">₹5</option><option value="SNACK10">₹10</option></select><input type="number" value={delta} onChange={(e) => setDelta(e.target.value)} placeholder="± qty" aria-label="Stock quantity change" /><input value={note} onChange={(e) => setNote(e.target.value)} placeholder="Reason" aria-label="Adjustment reason" /><button className="s-btn sm" disabled={!Number(delta) || !note.trim()} onClick={() => { save(row, code, delta, note); setDelta(''); setNote(''); }}>Save</button></div>;
}

function InlineEdit({ value, placeholder, save }) {
  const [draft, setDraft] = useState(value || '');
  React.useEffect(() => setDraft(value || ''), [value]);
  return <input className="org-inline-edit" value={draft} placeholder={placeholder} onChange={(e) => setDraft(e.target.value)} onBlur={() => { if (draft !== (value || '')) save(draft); }} />;
}
