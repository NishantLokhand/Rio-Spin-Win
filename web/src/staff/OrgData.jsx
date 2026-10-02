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

const standardRoles = new Set(['PROMOTER', 'MER', 'TSE', 'ASM']);
function sourceStateKey(value) {
  const key = labelKey(value).replace(/[^A-Z]/g, '');
  if (['UP', 'UTTARPRADESH'].includes(key)) return 'UTTAR PRADESH';
  if (['MH', 'MAHARASHTRA', 'MAHARASHTRAROM'].includes(key)) return 'MAHARASHTRA';
  return norm(value).toUpperCase();
}
function sourceTextScore(left, right) {
  const a = labelKey(left).replace(/[^A-Z0-9]/g, '');
  const b = labelKey(right).replace(/[^A-Z0-9]/g, '');
  if (!a || !b) return 0;
  if (a === b) return 1;
  const previous = Array.from({ length: b.length + 1 }, (_, i) => i);
  for (let i = 1; i <= a.length; i++) {
    let diagonal = previous[0]; previous[0] = i;
    for (let j = 1; j <= b.length; j++) {
      const above = previous[j];
      previous[j] = Math.min(previous[j] + 1, previous[j - 1] + 1, diagonal + (a[i - 1] === b[j - 1] ? 0 : 1));
      diagonal = above;
    }
  }
  return 1 - previous[b.length] / Math.max(a.length, b.length);
}
function parseSourceTruthWorkbook(rows) {
  if (!rows.length) throw new Error('The selected workbook has no rows.');
  const headers = rows[0].map((value) => norm(value).toLowerCase());
  const required = ['record_type', 'employee_key', 'employee_name', 'organizational_role', 'state', 'territory_market', 'area', 'beat', 'outlet_code', 'outlet_name', 'sku_code', 'inventory_quantity'];
  const missing = required.filter((name) => !headers.includes(name));
  if (missing.length) throw new Error(`This is not the Rio single-source workbook. Missing columns: ${missing.join(', ')}.`);
  const col = Object.fromEntries(headers.map((name, index) => [name, index]));
  const read = (row, field) => row[col[field]] ?? '';
  const employees = new Map(); const outlets = []; const inventoryByKey = new Map(); const warnings = [];
  const beatsByKey = new Map();
  rows.slice(1).forEach((row, index) => {
    const type = norm(read(row, 'record_type')).toUpperCase();
    const key = norm(read(row, 'employee_key'));
    const name = norm(read(row, 'employee_name'));
    const designation = role(read(row, 'organizational_role'));
    if (type === 'EMPLOYEE') {
      if (!key || !name || !standardRoles.has(designation)) { warnings.push(`Skipped malformed employee row ${index + 2}.`); return; }
      const item = {
        source_key: key, designation, employee_name: name, mobile: norm(read(row, 'mobile_number')),
        fas_id: norm(read(row, 'fas_id')), qa_employee_id: norm(read(row, 'qa_employee_id')),
        state_raw: norm(read(row, 'state')), market_raw: norm(read(row, 'territory_market')),
        zone_raw: norm(read(row, 'zone')), area_raw: norm(read(row, 'area')),
        source_system: 'RIO_ONE_SOURCE_OF_TRUTH',
        source_ids: { employee_key: key, app_access_profile: norm(read(row, 'app_access_profile')), data_quality_note: norm(read(row, 'data_quality_note')), source_reference: norm(read(row, 'source_reference')) },
        beat_values: [],
      };
      const prior = employees.get(key);
      if (prior) {
        warnings.push(`Duplicate employee key ${key} on row ${index + 2}; rows were consolidated.`);
        for (const field of ['mobile', 'fas_id', 'qa_employee_id', 'state_raw', 'market_raw', 'zone_raw', 'area_raw']) prior[field] ||= item[field];
        prior.source_ids.source_reference += item.source_ids.source_reference ? `; ${item.source_ids.source_reference}` : '';
      } else employees.set(key, item);
    } else if (type === 'BEAT') {
      if (!key || !norm(read(row, 'beat'))) { warnings.push(`Skipped malformed beat row ${index + 2}.`); return; }
      const values = beatsByKey.get(key) || [];
      values.push(norm(read(row, 'beat'))); beatsByKey.set(key, values);
    } else if (type === 'OUTLET') {
      if (!key || !name || !standardRoles.has(designation) || !norm(read(row, 'outlet_name'))) { warnings.push(`Skipped malformed outlet row ${index + 2}.`); return; }
      outlets.push({ employee_key: key, employee_name: name, designation, state_raw: norm(read(row, 'state')),
        market_raw: norm(read(row, 'territory_market')), area_raw: norm(read(row, 'area')), beat: norm(read(row, 'beat')),
        outlet_code: norm(read(row, 'outlet_code')), outlet_label: norm(read(row, 'outlet_name')),
        source_reference: norm(read(row, 'source_reference')), source_row: index + 2 });
    } else if (type === 'INVENTORY') {
      const sku = norm(read(row, 'sku_code')).toUpperCase();
      if (!key || !standardRoles.has(designation) || !['SNACK5', 'SNACK10'].includes(sku)) { warnings.push(`Skipped unsupported inventory row ${index + 2}${sku ? ` (${sku})` : ''}.`); return; }
      const item = inventoryByKey.get(key) || { employee_key: key, employee_name: name, designation,
        mobile: norm(read(row, 'mobile_number')), fas_id: norm(read(row, 'fas_id')), qa_employee_id: norm(read(row, 'qa_employee_id')),
        state_raw: norm(read(row, 'state')), market_raw: norm(read(row, 'territory_market')), area_raw: norm(read(row, 'area')),
        source_row: index + 2, snack5: 0, snack10: 0, seen: new Set() };
      const qty = Number(read(row, 'inventory_quantity'));
      if (!Number.isFinite(qty) || qty < 0) warnings.push(`Invalid ${sku} quantity on row ${index + 2}; treated as zero.`);
      const field = sku === 'SNACK5' ? 'snack5' : 'snack10';
      if (item.seen.has(sku)) warnings.push(`Duplicate ${sku} inventory row for ${name}; first quantity kept.`);
      else { item[field] = Number.isFinite(qty) && qty >= 0 ? Math.floor(qty) : 0; item.seen.add(sku); }
      inventoryByKey.set(key, item);
    }
  });
  for (const [key, item] of employees) item.beat_values = [...new Set([...(beatsByKey.get(key) || []), ...(item.beat_values || [])])];
  const canonicalByIdentity = new Map(); const aliasKey = new Map();
  for (const [key, item] of employees) {
    const identity = `${item.designation}|${labelKey(item.employee_name)}|${sourceStateKey(item.state_raw)}`;
    const candidates = canonicalByIdentity.get(identity) || [];
    const stableFields = ['mobile', 'fas_id', 'qa_employee_id'];
    const hasStableConflict = (prior) => stableFields.some((field) => prior[field] && item[field] && labelKey(prior[field]) !== labelKey(item[field]));
    const canonical = candidates.find((prior) => {
      if (hasStableConflict(prior)) return false;
      const sharedStableIdentity = stableFields.some((field) => prior[field] && item[field] && labelKey(prior[field]) === labelKey(item[field]));
      const sameArea = labelKey(prior.area_raw) && labelKey(prior.area_raw) === labelKey(item.area_raw);
      const stateMarketAlias = [prior.market_raw, item.market_raw].some((market) => labelKey(market) === labelKey(item.state_raw));
      return sharedStableIdentity || (sameArea && stateMarketAlias);
    });
    if (candidates.length && !canonical) warnings.push(`Possible same-name ${item.designation} in ${item.state_raw} on row key ${key}; kept as a separate employee because stable identity/territory did not confirm a duplicate.`);
    if (canonical) {
      aliasKey.set(key, canonical.source_key);
      for (const field of ['mobile', 'fas_id', 'qa_employee_id', 'market_raw', 'zone_raw', 'area_raw']) canonical[field] ||= item[field];
      canonical.beat_values = [...new Set([...canonical.beat_values, ...item.beat_values])];
      warnings.push(`Possible duplicate person ${item.employee_name} (${item.designation}, ${item.state_raw}) was consolidated from employee key ${key} to ${canonical.source_key}.`);
    } else {
      aliasKey.set(key, key); candidates.push(item); canonicalByIdentity.set(identity, candidates);
    }
  }
  const master = [...employees.values()].filter((item) => aliasKey.get(item.source_key) === item.source_key);
  const normalizedOutlets = outlets.map((item) => ({ ...item, employee_key: aliasKey.get(item.employee_key) || item.employee_key }));
  for (const key of beatsByKey.keys()) if (!employees.has(key)) warnings.push(`Beat rows reference missing employee key ${key}.`);
  for (const item of normalizedOutlets) if (!master.some((p) => p.source_key === item.employee_key)) warnings.push(`Outlet row ${item.source_row} references missing employee key ${item.employee_key}.`);
  const inventoryMap = new Map();
  for (const source of inventoryByKey.values()) {
    const key = aliasKey.get(source.employee_key) || source.employee_key;
    const item = inventoryMap.get(key) || { ...source, employee_key: key, source_row: source.source_row, seen: new Set() };
    for (const sku of source.seen) {
      if (item.seen.has(sku)) { warnings.push(`Duplicate ${sku} stock for ${source.employee_name} after person consolidation; first quantity kept.`); continue; }
      item[sku === 'SNACK5' ? 'snack5' : 'snack10'] = source[sku === 'SNACK5' ? 'snack5' : 'snack10']; item.seen.add(sku);
    }
    inventoryMap.set(key, item);
  }
  const inventory = [...inventoryMap.values()].map(({ seen, ...row }) => row);
  const promoterKeys = master.filter((p) => p.designation === 'PROMOTER').map((p) => ({ employee_key: p.source_key, source_state: sourceStateKey(p.state_raw) }));
  const staffKeys = master.filter((p) => ['TSE', 'MER'].includes(p.designation)).map((p) => ({ employee_key: p.source_key, designation: p.designation, source_state: sourceStateKey(p.state_raw) }));
  return { master, inventory, outlets: normalizedOutlets, promoterKeys, staffKeys, warnings, beatsByKey, aliasKey };
}

function mapSourceTruthToExisting(parsed, existingPeople) {
  const originalToImportKey = new Map(); const updatedByKey = new Map();
  const active = (existingPeople || []).filter((person) => person.active);
  for (const item of parsed.master) {
    let candidates = active.filter((person) => person.source_key === item.source_key && person.designation === item.designation);
    let matchMethod = candidates.length ? 'employee_key' : '';
    if (!candidates.length) {
      for (const field of ['fas_id', 'qa_employee_id', 'mobile']) {
        if (!item[field]) continue;
        const key = field === 'mobile' ? String(item[field]).replace(/\D/g, '') : labelKey(item[field]);
        const matched = active.filter((person) => person.designation === item.designation && person[field]
          && (field === 'mobile' ? String(person[field]).replace(/\D/g, '') === key : labelKey(person[field]) === key));
        if (matched.length) { candidates = matched; matchMethod = field; break; }
      }
    }
    if (!candidates.length) {
      candidates = active.filter((person) => person.designation === item.designation
        && sourceStateKey(person.state_raw) === sourceStateKey(item.state_raw)
        && sourceTextScore(person.employee_name, item.employee_name) >= 0.5);
      if (candidates.length) matchMethod = 'name_similarity';
    }
    candidates.sort((a, b) => {
      const score = (person) => sourceTextScore(person.employee_name, item.employee_name) * 10
        + (labelKey(person.area_raw) === labelKey(item.area_raw) ? 2 : 0)
        + (labelKey(person.market_raw) === labelKey(item.market_raw) ? 1 : 0);
      return score(b) - score(a) || String(a.id).localeCompare(String(b.id));
    });
    const match = candidates[0];
    if (match && matchMethod === 'name_similarity') {
      const score = Math.round(sourceTextScore(match.employee_name, item.employee_name) * 100);
      parsed.warnings.push(`Name-based profile link for ${item.employee_name} chose ${match.source_key} at ${score}% similarity from ${candidates.length} candidate(s).`);
    } else if (match && candidates.length > 1) {
      parsed.warnings.push(`Stable identifier ${matchMethod} for ${item.employee_name} matched ${candidates.length} active profiles; selected ${match.source_key}.`);
    }
    const importKey = match?.source_key || item.source_key;
    originalToImportKey.set(item.source_key, importKey);
    const current = updatedByKey.get(importKey);
    if (current) {
      current.beat_values = [...new Set([...current.beat_values, ...item.beat_values])];
      for (const field of ['mobile', 'fas_id', 'qa_employee_id', 'state_raw', 'market_raw', 'zone_raw', 'area_raw']) current[field] ||= item[field];
      current.source_ids.source_reference += item.source_ids.source_reference ? `; ${item.source_ids.source_reference}` : '';
      parsed.warnings.push(`Merged source employee key ${item.source_key} into existing identity ${importKey}.`);
    } else {
      updatedByKey.set(importKey, { ...item, source_key: importKey,
        source_ids: { ...item.source_ids, source_employee_key: item.source_key, linked_existing_profile_id: match?.id || '' } });
      if (match && match.source_key !== item.source_key) parsed.warnings.push(`Matched ${item.employee_name} to existing organizational profile ${match.source_key} by stable identity/name.`);
    }
  }
  parsed.master = [...updatedByKey.values()];
  parsed.outlets = parsed.outlets.map((row) => ({ ...row, employee_key: originalToImportKey.get(row.employee_key) || row.employee_key }));
  const inventoryByKey = new Map();
  for (const row of parsed.inventory) {
    const key = originalToImportKey.get(row.employee_key) || row.employee_key;
    const current = inventoryByKey.get(key);
    if (!current) { inventoryByKey.set(key, { ...row, employee_key: key }); continue; }
    for (const field of ['snack5', 'snack10']) {
      if (current[field] === 0) current[field] = row[field];
      else if (row[field] && current[field] !== row[field]) parsed.warnings.push(`Conflicting ${field} stock for merged identity ${key}; kept ${current[field]}.`);
    }
  }
  parsed.inventory = [...inventoryByKey.values()];
  parsed.promoterKeys = parsed.master.filter((p) => p.designation === 'PROMOTER').map((p) => ({ employee_key: p.source_key, designation: p.designation, source_state: sourceStateKey(p.state_raw) }));
  parsed.staffKeys = parsed.master.filter((p) => ['TSE', 'MER'].includes(p.designation)).map((p) => ({ employee_key: p.source_key, designation: p.designation, source_state: sourceStateKey(p.state_raw) }));
  return parsed;
}

function dedupeSourceOutletRows(rows) {
  const buckets = new Map(); const kept = []; const nearDuplicateRows = []; let duplicateCount = 0;
  for (const row of rows) {
    const route = `${row.employee_key}|${beatKey(row.beat)}|${labelKey(row.area_raw)}`;
    const bucket = buckets.get(route) || { byCode: new Map(), byLabel: new Map(), byLength: new Map() };
    const code = String(row.outlet_code || outletCodeFromLabel(row.outlet_label)).replace(/\D/g, '');
    const name = outletLabel(row.outlet_label); const nameKey = labelKey(name).replace(/[^A-Z0-9]/g, '');
    const sameCode = code ? bucket.byCode.get(code) : null;
    const exactNames = bucket.byLabel.get(nameKey) || [];
    const exactName = exactNames.find((prior) => {
      const priorCode = String(prior.outlet_code || outletCodeFromLabel(prior.outlet_label)).replace(/\D/g, '');
      return !(code && priorCode && code !== priorCode);
    });
    let duplicate = sameCode || exactName;
    let conflictingNearName = null;
    if (!duplicate && nameKey) {
      const minLength = Math.ceil(nameKey.length * 0.9); const maxLength = Math.floor(nameKey.length / 0.9);
      for (let length = minLength; length <= maxLength && !duplicate; length++) {
        for (const prior of bucket.byLength.get(length) || []) {
          const priorCode = String(prior.outlet_code || outletCodeFromLabel(prior.outlet_label)).replace(/\D/g, '');
          if (code && priorCode && code !== priorCode) {
            if (!conflictingNearName && sourceTextScore(name, outletLabel(prior.outlet_label)) >= 0.9) conflictingNearName = prior;
            continue;
          }
          if (sourceTextScore(name, outletLabel(prior.outlet_label)) >= 0.9) { duplicate = prior; break; }
        }
      }
    }
    if (duplicate) {
      duplicateCount++;
      nearDuplicateRows.push({ row, prior: duplicate, kind: sameCode ? 'same outlet code' : exactName ? 'exact outlet name' : '90%+ similar outlet name', similarity: sourceTextScore(name, outletLabel(duplicate.outlet_label)) });
    }
    if (conflictingNearName) nearDuplicateRows.push({ row, prior: conflictingNearName, kind: 'similar name with different outlet code', similarity: sourceTextScore(name, outletLabel(conflictingNearName.outlet_label)) });
    bucket.byCode.set(code || `__row_${row.source_row}_${kept.length}`, bucket.byCode.get(code) || row);
    bucket.byLabel.set(nameKey, [...exactNames, row]);
    bucket.byLength.set(nameKey.length, [...(bucket.byLength.get(nameKey.length) || []), row]);
    buckets.set(route, bucket); kept.push(row);
  }
  return { rows: kept, duplicateCount, nearDuplicateRows };
}

function sourceOutletContext(outlets, masters) {
  const territoryById = new Map((masters?.territories || []).map((t) => [t.id, t]));
  const stateById = new Map((masters?.states || []).map((s) => [s.id, s]));
  const tseById = new Map((masters?.tses || []).map((t) => [t.id, t]));
  return (outlets || []).filter((o) => o.status === 'active').map((o) => {
    const tse = tseById.get(o.tse_id); const territory = territoryById.get(tse?.territory_id);
    return { ...o, state_name: stateById.get(territory?.state_id)?.name || '', territory_name: territory?.name || '', tse_code: tse?.code || '', tse_name: tse?.name || '' };
  });
}

function indexSourceOutlets(enriched) {
  const byState = new Map(); const byCode = new Map(); const byOutletCode = new Map(); const byStateName = new Map(); const byStateBeat = new Map(); const byStateArea = new Map();
  const add = (map, key, outlet) => {
    if (!key) return;
    const list = map.get(key);
    if (list) list.push(outlet);
    else map.set(key, [outlet]);
  };
  for (const outlet of enriched) {
    const state = sourceStateKey(outlet.state_name); const code = String(outlet.outlet_code || '').replace(/\D/g, '');
    add(byState, state, outlet); add(byCode, `${state}|${code}`, outlet);
    add(byOutletCode, String(outlet.outlet_code || '').toUpperCase(), outlet);
    add(byStateName, `${state}|${labelKey(outlet.name)}`, outlet);
    add(byStateBeat, `${state}|${beatKey(outlet.beat)}`, outlet);
    for (const area of [outlet.area, outlet.city, outlet.territory_name]) add(byStateArea, `${state}|${labelKey(area)}`, outlet);
  }
  return { enriched, byState, byCode, byOutletCode, byStateName, byStateBeat, byStateArea, candidateCache: new Map() };
}
function sourceOutletCandidates(index, row) {
  const state = sourceStateKey(row.state_raw); const rawCode = String(row.outlet_code || outletCodeFromLabel(row.outlet_label)).replace(/\D/g, '');
  const cleanName = outletLabel(row.outlet_label); const nameKey = labelKey(cleanName);
  const beat = beatKey(row.beat); const area = labelKey(row.area_raw); const market = labelKey(row.market_raw);
  const cacheKey = `${state}|${rawCode}|${nameKey}|${beat}|${area}|${market}`;
  const cached = index.candidateCache?.get(cacheKey);
  if (cached) return cached;

  const codeMatches = index.byCode.get(`${state}|${rawCode}`) || [];
  const nameMatches = index.byStateName.get(`${state}|${nameKey}`) || [];
  // Exact identifiers and labels are common in the source workbook. Avoid
  // scoring every outlet in the same beat/area when either gives a small,
  // high-confidence candidate set.
  let candidates;
  if (codeMatches.length || nameMatches.length) candidates = [...codeMatches, ...nameMatches];
  else {
    const beatMatches = beat ? index.byStateBeat.get(`${state}|${beat}`) || [] : [];
    const areaMatches = [...(area ? index.byStateArea.get(`${state}|${area}`) || [] : []),
      ...(market ? index.byStateArea.get(`${state}|${market}`) || [] : [])];
    if (beatMatches.length && areaMatches.length) {
      const areaIds = new Set(areaMatches.map((outlet) => outlet.id));
      candidates = beatMatches.filter((outlet) => areaIds.has(outlet.id));
      if (!candidates.length) candidates = beatMatches;
    } else candidates = beatMatches.length ? beatMatches : areaMatches;
  }
  const minNameLength = Math.ceil(labelKey(cleanName).replace(/[^A-Z0-9]/g, '').length / 2);
  const maxNameLength = labelKey(cleanName).replace(/[^A-Z0-9]/g, '').length * 2;
  const seen = new Set();
  const result = candidates.filter((outlet) => {
    if (seen.has(outlet.id)) return false;
    seen.add(outlet.id);
    const length = labelKey(outlet.name).replace(/[^A-Z0-9]/g, '').length;
    return length >= minNameLength && length <= maxNameLength;
  });
  index.candidateCache?.set(cacheKey, result);
  return result;
}

function planSourceTruthOutlets(sourceRows, employees, outletIndex, masters) {
  const peopleByKey = new Map(employees.map((p) => [p.source_key, p]));
  const tSEs = employees.filter((p) => p.designation === 'TSE');
  const existingTseByIdentity = new Map();
  for (const tse of masters?.tses || []) {
    const territory = (masters?.territories || []).find((item) => item.id === tse.territory_id);
    const state = (masters?.states || []).find((item) => item.id === territory?.state_id);
    const key = `${labelKey(tse.name)}|${sourceStateKey(state?.name)}`;
    existingTseByIdentity.set(key, [...(existingTseByIdentity.get(key) || []), { ...tse, territory_name: territory?.name || '' }]);
  }
  const planned = new Map(); const missingTse = [];
  for (const row of sourceRows) {
    const person = peopleByKey.get(row.employee_key);
    const state = sourceStateKey(row.state_raw || person?.state_raw);
    const cleanName = outletLabel(row.outlet_label);
    const rawCode = String(row.outlet_code || outletCodeFromLabel(row.outlet_label)).replace(/\D/g, '');
    const candidates = sourceOutletCandidates(outletIndex, { ...row, state_raw: state });
    const scored = candidates.map((o) => {
      const nameScore = sourceTextScore(cleanName, o.name);
      const sameBeat = beatKey(o.beat) && beatKey(o.beat) === beatKey(row.beat);
      const sameArea = [o.area, o.city, o.territory_name].some((v) => labelKey(v) === labelKey(row.area_raw) || labelKey(v) === labelKey(row.market_raw));
      const codeMatch = rawCode && String(o.outlet_code || '').replace(/\D/g, '') === rawCode;
      return { outlet: o, nameScore, sameBeat, sameArea, codeMatch, score: codeMatch ? 1.25 : nameScore + (sameBeat ? 0.18 : 0) + (sameArea ? 0.08 : 0) };
    }).sort((a, b) => b.score - a.score || String(a.outlet.id).localeCompare(String(b.outlet.id)));
    let match = scored.find((x) => x.codeMatch && labelKey(x.outlet.name) === labelKey(cleanName))?.outlet;
    if (!match) match = scored.find((x) => labelKey(x.outlet.name) === labelKey(cleanName) && x.sameBeat)?.outlet;
    if (!match) match = scored.find((x) => x.nameScore >= 0.5 && (x.sameBeat || x.sameArea))?.outlet;
    if (!match) match = scored.find((x) => x.nameScore >= 0.5)?.outlet;
    if (match) continue;

    let owner;
    if (person?.designation === 'TSE') owner = person;
    else {
      const candidates = tSEs.filter((t) => sourceStateKey(t.state_raw) === state && (t.beat_values || []).some((beat) => beatKey(beat) === beatKey(row.beat)));
      const areaMatches = candidates.filter((t) => labelKey(t.area_raw) === labelKey(row.area_raw) || labelKey(t.market_raw) === labelKey(row.market_raw));
      const selected = areaMatches.length === 1 ? areaMatches[0] : candidates.length === 1 ? candidates[0] : null;
      if (selected) owner = selected;
    }
    if (!owner) { missingTse.push({ employee_name: row.employee_name, market: row.market_raw, beat: row.beat, outlet_label: row.outlet_label }); continue; }
    const routeCode = stableOutletCode('RIO-SOT', `${state}|${row.area_raw}|${row.beat}|${cleanName}`);
    const existing = (outletIndex.byOutletCode.get(routeCode.toUpperCase()) || [])[0];
    if (existing) continue;
    const existingTses = existingTseByIdentity.get(`${labelKey(owner.employee_name)}|${state}`) || [];
    const existingTse = existingTses.length === 1 ? existingTses[0] : null;
    const territory = existingTse?.territory_name || owner.market_raw || owner.area_raw || state;
    planned.set(routeCode, { state: state === 'MAHARASHTRA' ? 'Maharashtra' : state === 'UTTAR PRADESH' ? 'Uttar Pradesh' : row.state_raw,
      territory, tse_code: existingTse?.code || owner.source_key, tse_name: owner.employee_name,
      outlet_code: routeCode, outlet_name: cleanName, area: row.area_raw || row.market_raw,
      beat: row.beat, city: row.market_raw || row.area_raw, distributor: '', status: 'active' });
  }
  return { rows: [...planned.values()], missingTse };
}

function resolveSourceTruthOutlet(row, outletIndex) {
  const cleanName = outletLabel(row.outlet_label);
  const rawCode = String(row.outlet_code || outletCodeFromLabel(row.outlet_label)).replace(/\D/g, '');
  const candidates = sourceOutletCandidates(outletIndex, row).map((o) => {
    const nameScore = sourceTextScore(cleanName, o.name); const sameBeat = beatKey(o.beat) === beatKey(row.beat);
    const sameArea = [o.area, o.city, o.territory_name].some((v) => labelKey(v) === labelKey(row.area_raw) || labelKey(v) === labelKey(row.market_raw));
    const codeMatch = rawCode && String(o.outlet_code || '').replace(/\D/g, '') === rawCode;
    return { outlet: o, nameScore, sameBeat, sameArea, codeMatch, score: (codeMatch ? 1.25 : nameScore) + (sameBeat ? 0.18 : 0) + (sameArea ? 0.08 : 0) };
  }).sort((a, b) => b.score - a.score || String(a.outlet.id).localeCompare(String(b.outlet.id)));
  let result = candidates.find((x) => x.codeMatch && labelKey(x.outlet.name) === labelKey(cleanName));
  result ||= candidates.find((x) => labelKey(x.outlet.name) === labelKey(cleanName) && x.sameBeat);
  result ||= candidates.find((x) => x.nameScore >= 0.5 && (x.sameBeat || x.sameArea));
  result ||= candidates.find((x) => x.nameScore >= 0.5);
  if (result) return { outlet_id: result.outlet.id, status: result.nameScore < 1 && !result.codeMatch ? 'fuzzy_matched' : 'matched', match_score: result.nameScore };
  const state = sourceStateKey(row.state_raw);
  const generatedCode = stableOutletCode('RIO-SOT', `${state}|${row.area_raw}|${row.beat}|${cleanName}`);
  const created = (outletIndex.byOutletCode.get(generatedCode.toUpperCase()) || []).find((o) => labelKey(o.name) === labelKey(cleanName));
  return created ? { outlet_id: created.id, status: 'created', match_score: 1 } : { outlet_id: '', status: 'outlet_not_found', match_score: 0 };
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

function downloadSimilarOutletCodes(report) {
  const rows = report?.nearDuplicateOutlets || [];
  const columns = ['issue', 'employee_name', 'designation', 'state', 'area', 'beat', 'outlet_code', 'outlet_name', 'related_outlet_code', 'related_outlet_name', 'similarity_percent', 'source_row'];
  const quote = (value) => `"${String(value ?? '').replaceAll('"', '""')}"`;
  const csv = [columns.map(quote).join(','), ...rows.map((entry) => {
    const values = { issue: entry.kind, employee_name: entry.row.employee_name, designation: entry.row.designation, state: entry.row.state_raw,
      area: entry.row.area_raw, beat: entry.row.beat, outlet_code: entry.row.outlet_code, outlet_name: entry.row.outlet_label,
      related_outlet_code: entry.prior.outlet_code, related_outlet_name: entry.prior.outlet_label,
      similarity_percent: Math.round((entry.similarity ?? sourceTextScore(outletLabel(entry.row.outlet_label), outletLabel(entry.prior.outlet_label))) * 100),
      source_row: entry.row.source_row };
    return columns.map((column) => quote(values[column])).join(',');
  })].join('\r\n');
  const blob = new Blob(['\uFEFF', csv], { type: 'text/csv;charset=utf-8' });
  const url = URL.createObjectURL(blob); const link = document.createElement('a');
  link.href = url; link.download = 'source-truth-outlet-duplicate-review.csv';
  document.body.appendChild(link); link.click(); link.remove(); URL.revokeObjectURL(url);
}

export default function OrgData({ data }) {
  const [tab, setTab] = useState('people');
  const [people, setPeople] = useState(null);
  const [stock, setStock] = useState(null);
  const [stockAdjustments, setStockAdjustments] = useState([]);
  const [promoterStock, setPromoterStock] = useState([]);
  const [assignments, setAssignments] = useState(null);
  const [merAssignments, setMerAssignments] = useState([]);
  const [workbookAssignments, setWorkbookAssignments] = useState([]);
  const [busy, setBusy] = useState(false);
  const [importStage, setImportStage] = useState('');
  const [err, setErr] = useState('');
  const [notice, setNotice] = useState('');
  const [outletImportReport, setOutletImportReport] = useState(null);
  const [files, setFiles] = useState({ source: null });
  const [runKey, setRunKey] = useState('rio-source-truth-2026-10-02-v1');
  const [outletMode, setOutletMode] = useState('');
  const [filters, setFilters] = useState({ designation: 'all', state: 'all', market: 'all', area: 'all', beat: 'all', tse: 'all', mer: 'all', assignment: 'all', inventory: 'all', active: 'all', q: '' });
  const [newPerson, setNewPerson] = useState({ designation: 'PROMOTER', employee_name: '', mobile: '', state_raw: '', market_raw: '', area_raw: '', beat: '' });

  async function refresh() {
    try {
      const [p, i, adj, pi] = await Promise.all([
        selectAll('org_people', '*', (q) => q.order('designation').order('employee_name')),
        selectAll('org_inventory', '*', (q) => q.order('employee_name')),
        selectAll('org_inventory_adjustments', '*'),
        selectAll('promoter_inventory', '*'),
      ]);
      setPeople(p); setStock(i); setStockAdjustments(adj); setPromoterStock(pi);
    } catch (e) { setErr(friendly(e)); }
  }
  async function refreshOutletAccess() {
    try {
      const [a, ma, wa] = await Promise.all([
        selectAll('promoter_outlet_assignments', '*'),
        selectAll('promoter_mer_assignments', '*'),
        selectAll('promoter_outlet_workbook_assignments', '*'),
      ]);
      setAssignments(a); setMerAssignments(ma); setWorkbookAssignments(wa);
    } catch (e) { setErr(friendly(e)); }
  }
  React.useEffect(() => { refresh(); }, []);
  React.useEffect(() => { if (tab === 'outlets') refreshOutletAccess(); }, [tab]);
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
    setBusy(true); setImportStage('Reading workbook'); setErr(''); setNotice('');
    try {
      if (!files.source) throw new Error('Choose the Rio single-source-of-truth workbook.');
      if (!people || !data.outletsLoaded) throw new Error('The outlet directory is still loading. Wait a moment and try again.');
      if (!outletMode) throw new Error('Choose how the workbook outlet list should interact with MER outlet access.');
      const book = await readWorkbook(files.source);
      const parsed = mapSourceTruthToExisting(parseSourceTruthWorkbook(book.rows(book.names[0])), people);
      setImportStage('Matching outlet rows');
      await new Promise((resolve) => setTimeout(resolve, 0));
      const deduped = dedupeSourceOutletRows(parsed.outlets);
      const sourceOutletRows = deduped.rows;
      const existingOutlets = data.outletsFull || [];
      const outletIndex = indexSourceOutlets(sourceOutletContext(existingOutlets, data.masters));
      const outletMasterPlan = planSourceTruthOutlets(sourceOutletRows, parsed.master, outletIndex, data.masters);
      const allPlannedOutlets = outletMasterPlan.rows;
      let createdOutlets = 0;
      let outletMasterErrors = [];
      setImportStage(`Saving ${allPlannedOutlets.length.toLocaleString()} new outlet records`);
      await new Promise((resolve) => setTimeout(resolve, 0));
      for (let i = 0; i < allPlannedOutlets.length; i += 500) {
        const imported = await rpc('import_outlets', { p_rows: allPlannedOutlets.slice(i, i + 500) }, { timeoutMs: 120000 });
        createdOutlets += imported.inserted || 0;
        outletMasterErrors = [...outletMasterErrors, ...(imported.errors || [])];
      }
      setImportStage('Resolving outlet assignments');
      await new Promise((resolve) => setTimeout(resolve, 0));
      const currentOutlets = allPlannedOutlets.length
        ? await selectAll('outlets', 'id,outlet_code,name,area,city,beat,tse_id,status,source,external_ref', (q) => q.order('name'))
        : existingOutlets;
      const currentIndex = indexSourceOutlets(sourceOutletContext(currentOutlets, data.masters));
      const resolvedOutlets = sourceOutletRows.map((row) => ({ ...row, ...resolveSourceTruthOutlet(row, currentIndex) }));
      const groupedRows = new Map();
      for (const row of resolvedOutlets) {
        const key = `${row.designation}|${row.employee_key}|${sourceStateKey(row.state_raw)}`;
        if (!groupedRows.has(key)) groupedRows.set(key, []);
        groupedRows.get(key).push(row);
      }
      const groupAccess = (peopleRows) => peopleRows.map((person) => {
        const assigned = groupedRows.get(`${person.designation}|${person.employee_key}|${person.source_state}`) || [];
        return { employee_key: person.employee_key, designation: person.designation, source_state: person.source_state,
          outlet_ids: [...new Set(assigned.map((row) => row.outlet_id).filter(Boolean))],
          unresolved_count: assigned.filter((row) => !row.outlet_id).length };
      });
      const promoterRows = groupAccess(parsed.promoterKeys); const staffRows = groupAccess(parsed.staffKeys);
      const unresolvedPromoterRows = resolvedOutlets.filter((row) => row.designation === 'PROMOTER' && !row.outlet_id);
      const unresolvedStaffRows = resolvedOutlets.filter((row) => ['TSE', 'MER'].includes(row.designation) && !row.outlet_id);
      const fuzzyCount = resolvedOutlets.filter((row) => row.status === 'fuzzy_matched').length;
      const sharedTseOutlets = new Map();
      for (const row of resolvedOutlets.filter((item) => item.designation === 'TSE' && item.outlet_id)) {
        sharedTseOutlets.set(row.outlet_id, new Set([...(sharedTseOutlets.get(row.outlet_id) || []), row.employee_key]));
      }
      const outletResolution = {
        stats: { promoter_count: promoterRows.length, source_rows: sourceOutletRows.filter((r) => r.designation === 'PROMOTER').length,
          matched_rows: resolvedOutlets.filter((r) => r.designation === 'PROMOTER' && r.outlet_id).length, unresolved_rows: unresolvedPromoterRows.length },
        outletRows: unresolvedPromoterRows.map((r) => ({ ...r, promoter_name: r.employee_name })),
        staffOutlet: { stats: { employee_count: staffRows.length, source_rows: sourceOutletRows.filter((r) => ['TSE', 'MER'].includes(r.designation)).length,
          matched_rows: resolvedOutlets.filter((r) => ['TSE', 'MER'].includes(r.designation) && r.outlet_id).length, unresolved_rows: unresolvedStaffRows.length }, outletRows: unresolvedStaffRows },
        outletMaster: { created: createdOutlets, attempted: allPlannedOutlets.length, errors: outletMasterErrors.length, missingTse: outletMasterPlan.missingTse, staffMissingTse: [], outletConflicts: [], sharedTseOutlets: [...sharedTseOutlets.values()].filter((owners) => owners.size > 1).length },
        warnings: parsed.warnings, duplicate_outlet_rows_flagged: deduped.duplicateCount, fuzzy_matches: fuzzyCount,
        nearDuplicateOutlets: deduped.nearDuplicateRows,
      };
      setOutletImportReport(outletResolution);
      setImportStage('Saving employee and inventory records');
      await new Promise((resolve) => setTimeout(resolve, 0));
      const result = await rpc('import_org_master_inventory', {
        p_master: parsed.master, p_inventory: parsed.inventory, p_run_key: runKey.trim(),
      }, { timeoutMs: 120000 });
      const makeBatches = (rows, maxIds = 1800, maxPeople = 6) => {
        const batches = []; let batch = []; let batchIds = 0;
        for (const row of rows) {
          const size = row.outlet_ids.length;
          if (batch.length && (batch.length >= maxPeople || batchIds + size > maxIds)) {
            batches.push(batch); batch = []; batchIds = 0;
          }
          batch.push(row); batchIds += size;
        }
        if (batch.length) batches.push(batch);
        return batches;
      };
      const promoterBatches = makeBatches(promoterRows);
      const staffBatches = makeBatches(staffRows);
      const accessBatches = [
        ...promoterBatches.map((rows) => ({ kind: 'promoter', rows })),
        ...staffBatches.map((rows) => ({ kind: 'staff', rows })),
      ];
      const accessTotals = { assignments: 0, staff_assignments: 0, missing_people: 0, invalid_outlets: 0, duplicate_outlet_ids: 0 };
      let completedBatches = 0;
      try {
        for (let i = 0; i < accessBatches.length; i++) {
          const batch = accessBatches[i];
          setImportStage(`Saving ${batch.kind} outlet access ${i + 1}/${accessBatches.length}`);
          await new Promise((resolve) => setTimeout(resolve, 0));
          const access = await rpc('import_org_source_of_truth_access', {
            p_run_key: runKey.trim(), p_promoter_mode: outletMode,
            p_promoter_rows: batch.kind === 'promoter' ? batch.rows : [],
            p_staff_rows: batch.kind === 'staff' ? batch.rows : [],
          }, { timeoutMs: 120000 });
          accessTotals.assignments += access.assignments || 0;
          accessTotals.staff_assignments += access.staff_assignments || 0;
          accessTotals.missing_people += access.missing_people || 0;
          accessTotals.invalid_outlets += access.invalid_outlets || 0;
          accessTotals.duplicate_outlet_ids += access.duplicate_outlet_ids || 0;
          completedBatches++;
        }
      } catch (error) {
        throw new Error(`Outlet access stopped after ${completedBatches} of ${accessBatches.length} batches. Completed batches are saved; retry with the same run key and selected access mode to resume safely. ${friendly(error)}`);
      }
      let postImportNote = '';
      try {
        setImportStage('Linking inventory and reconciling stock');
        await new Promise((resolve) => setTimeout(resolve, 0));
        await rpc('import_org_source_of_truth', {
          p_master: [], p_inventory: parsed.inventory, p_run_key: runKey.trim(),
          p_promoter_mode: outletMode, p_promoter_rows: [], p_staff_rows: [],
        }, { timeoutMs: 120000 });
      } catch (error) {
        postImportNote = ` Outlet access was saved, but inventory linking/stock reconciliation needs a retry: ${friendly(error)}`;
      }
      const matchedCount = resolvedOutlets.filter((r) => r.outlet_id).length;
      const dataQualityCount = parsed.warnings.length + outletMasterErrors.length + unresolvedPromoterRows.length + unresolvedStaffRows.length
        + accessTotals.missing_people + accessTotals.invalid_outlets;
      setNotice(`Imported ${result.master_rows} employee records and ${result.inventory_rows || 0} inventory records${result.inventory_already_imported ? ' (opening inventory for this run key was already applied)' : ''}. Created ${createdOutlets} outlet master records; matched ${matchedCount} of ${sourceOutletRows.length} outlet rows, including ${fuzzyCount} fuzzy matches. Kept every source outlet row and flagged ${deduped.duplicateCount} possible duplicate rows. Promoter access: ${accessTotals.assignments} assignments; TSE/MER access: ${accessTotals.staff_assignments} assignments. ${dataQualityCount} data-quality items need review (${accessTotals.missing_people} missing employee keys, ${accessTotals.invalid_outlets} rejected outlet IDs).${postImportNote}`);
      setImportStage('Import complete');
    } catch (e) { setErr(friendly(e)); }
    finally { setBusy(false); setImportStage(''); }
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
      await refreshOutletAccess(); setNotice('Outlet permissions saved.');
    } catch (e) { setErr(friendly(e)); }
    finally { setBusy(false); }
  }
  async function setMers(personId, merIds) {
    setBusy(true); setErr('');
    try {
      await rpc('set_promoter_mers', { p_promoter_id: personId, p_mer_ids: merIds });
      await refreshOutletAccess(); setNotice('MER mappings saved. The promoter receives outlet access from each mapped MER’s matching beats.');
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
      {!data.outletsLoaded && <p className="muted">{data.outletsLoadError ? `Outlet directory could not load: ${data.outletsLoadError}` : 'Loading the outlet directory…'}</p>}
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
    {tab === 'import' && <Panel title="Import Rio source-of-truth workbook"><p>Upload the single-sheet <b>Master Data</b> workbook. It contains employee, beat, outlet, and inventory rows; employee keys connect them. Outlet names are matched within the same state and route, with a best fuzzy match from 50% similarity when available. Every source outlet row is retained; exact and 90%+ similar assignments are flagged for review without being removed.</p>
      <div className="s-form"><Field label="Rio source-of-truth workbook"><input type="file" accept=".xlsx" onChange={(e) => setFiles({ source: e.target.files?.[0] || null })} /></Field>
        <Field label="Promoter outlet access"><select value={outletMode} onChange={(e) => setOutletMode(e.target.value)}><option value="">Choose access behavior</option><option value="workbook_exact">Use workbook list as exact access</option><option value="workbook_additive">Add workbook outlets to existing access</option></select></Field>
        <Field label="Import run key" hint="Keep the same key when retrying this workbook. Use a new key only for a distinct initial inventory snapshot; existing prize balances are not overwritten on repeat imports."><input value={runKey} onChange={(e) => setRunKey(e.target.value)} /></Field>
        <p className="muted">Exact mode replaces a promoter’s workbook access when the full outlet list resolves. If some rows are unresolved, the importer keeps prior access and still adds every resolved outlet; unresolved rows remain available in the review CSV. Additive mode only adds resolved outlets. TSE/MER workbook assignments are always added while existing access is retained. Repeating a run key does not apply initial stock twice.</p>
        {!data.outletsLoaded && <p className="muted">{data.outletsLoadError ? `Outlet directory could not load: ${data.outletsLoadError}` : 'Loading the outlet directory…'}</p>}
        <button className="s-btn" disabled={busy || !files.source || !outletMode || !data.outletsLoaded} onClick={runImport}>{busy ? `${importStage || 'Importing'}…` : 'Import and reconcile'}</button>
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
          {outletImportReport.nearDuplicateOutlets?.length > 0 && <><p>{outletImportReport.nearDuplicateOutlets.length} possible duplicate outlet pairs were flagged. All source outlet rows were kept.</p><button type="button" className="s-btn sm" onClick={() => downloadSimilarOutletCodes(outletImportReport)}>Download outlet duplicate review (CSV)</button></>}
          {outletImportReport.stats.unresolved_rows > 0 && <><button type="button" className="s-btn sm" onClick={() => downloadUnresolvedOutlets(outletImportReport)}>Download all {outletImportReport.stats.unresolved_rows} unresolved promoter entries (CSV)</button><div className="org-import-unmatched">{outletImportReport.outletRows.filter((r) => r.status !== 'matched').slice(0, 12).map((r, i) => <div key={`${r.source_row}-${r.outlet_index}-${i}`}><b>{r.promoter_name}</b> — {r.outlet_label} <small>({r.status.replaceAll('_', ' ')})</small></div>)}{outletImportReport.stats.unresolved_rows > 12 && <small>Showing first 12 unresolved entries. Download the CSV for the complete list.</small>}</div></>}
          {[...outletImportReport.outletMaster.missingTse, ...outletImportReport.outletMaster.staffMissingTse].length > 0 && <div className="org-import-unmatched">{[...outletImportReport.outletMaster.missingTse, ...outletImportReport.outletMaster.staffMissingTse].slice(0, 8).map((r, i) => <div key={`${r.employee_name || r.promoter_name}-${r.beat}-${i}`}><b>{r.employee_name || r.promoter_name}</b> — {r.market} / {r.beat} <small>({r.match_count ? 'ambiguous TSE beat match' : 'no TSE beat match'})</small></div>)}</div>}
          {outletImportReport.outletMaster.outletConflicts.length > 0 && <div className="org-import-unmatched">{outletImportReport.outletMaster.outletConflicts.slice(0, 8).map((r) => <div key={`${r.outlet_code}-${r.workbook_name}`}><b>{r.outlet_code}</b> — workbook “{r.workbook_name}”, existing “{r.existing_name}”</div>)}</div>}
          {(outletImportReport.duplicate_outlet_rows_flagged > 0 || outletImportReport.fuzzy_matches > 0 || outletImportReport.warnings.length > 0) && <div className="org-import-notes"><b>Import warnings</b><p>{outletImportReport.duplicate_outlet_rows_flagged} exact/90%+ duplicate candidates flagged and kept · {outletImportReport.nearDuplicateOutlets?.length || 0} possible duplicate pairs · {outletImportReport.fuzzy_matches} fuzzy outlet matches</p>{outletImportReport.warnings.slice(0, 12).map((warning, index) => <div key={index}>{warning}</div>)}{outletImportReport.warnings.length > 12 && <small>Showing 12 of {outletImportReport.warnings.length} data-quality warnings.</small>}</div>}
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
